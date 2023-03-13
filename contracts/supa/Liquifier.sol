// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {WalletState} from "../wallet/WalletState.sol";
import {ISupa} from "../interfaces/ISupa.sol";
import {INonfungiblePositionManager} from "../external/interfaces/INonfungiblePositionManager.sol";
import {Call} from "../lib/Call.sol";

struct SqrtPricePriceRangeX96 {
    uint160 minSell;
    uint160 maxBuy;
}

/// @title Logic for liquify functionality of wallet
/// @dev It is designed to be an extension for walletLogic contract.
/// Functionally, it's a part of the walletLogic contract, but has been extracted into a separate
/// contract for better code structuring. This is why the contract is declared as abstract
///   The only function it exports is `liquify`. The rest are private function that are parts of
/// `liquify`
abstract contract Liquifier is WalletState {
    /// @notice Only this address or the Wallet owner can call this function
    error OnlySelfOrOwner();

    modifier selfOrWalletOwner() {
        if (msg.sender != address(this) && msg.sender != supa.getWalletOwner(address(this))) {
            revert OnlySelfOrOwner();
        }
        _;
    }

    /// @notice Advanced version of liquidate function. Potentially unwanted side-affect of
    /// liquidation is a debt on the liquidator. So liquify would liquidate and then re-balance
    /// obtained assets to have no debt. This is the algorithm:
    ///   * liquidate creditAccount of target `wallet`
    ///   * terminate all obtained ERC721s (NFTs)
    ///   * buy/sell `erc20s` for `numeraire` so the balance of `wallet` on that ERC20s matches the
    ///     debt of `wallet` on it's creditAccount. E.g.:
    ///     - for 1 WETH of debt on creditAccount and 3 WETH on the balance of wallet - sell 2 WETH
    ///     - for 3 WETH of debt on creditAccount and 1 WETH on the balance of wallet - buy 2 WETH
    ///     - for no debt on creditAccount and 1 WETH on the balance of wallet - sell 2 WETH
    ///     - for 1 WETH of debt on creditAccount and no WETH on the balance of dSave - buy 1 WETH
    ///   * deposit `erc20s` and `numeraire` to cover debts
    ///
    /// !! IMPORTANT: because this function executes quite a lot of logic on top of Supa.liquidate(),
    /// there is a risk that for liquidatable position with a long list of NFTs it will run out
    /// of gas. As for now, it's up to liquidator to estimate if specific position is liquifiable,
    /// or Supa.liquidate() need to be used (with further assets re-balancing in other transactions)
    /// @dev notes on erc20s: the reason for erc20s been a call parameter, and not been calculated
    /// inside of liquify, is reducing gas costs
    ///   erc20s should NOT include numeraire. Otherwise, the transaction would be reverted with an
    /// error from uniswap router
    ///   It's the responsibility of caller to provide the correct list of erc20s. Assets
    /// re-balancing would be performed only by this list of tokens and numeraire.
    ///   * if erc20s misses a token that liquidatable have debt on - the debt on this erc20 would
    ///     persist on liquidator's creditAccount as-is
    ///   * if erc20s misses a token that liquidatable have collateral on - the token would persist
    ///     on liquidator's creditAccount. It may result in generating debt in numeraire on liquidator
    ///     creditAccount by the end of liquify (because the token would not be soled for numeraire,
    ///     there may not be enough numeraire to buy tokens to cover debts, and so they will be
    ///     bought in debt)
    ///   * if erc20s misses a token that would be obtained as the result of NFT termination - same
    ///     as previous, except of the token to be persisted on wallet instead of creditAccount of
    ///     liquidator
    ///   Because no buy/sell would be done for prices from outside of the erc20sAllowedPriceRanges,
    /// too narrow range may result in not having enough of some ERC20 to cover the debt. So the
    /// eventual state would still include some debt
    /// @param wallet - the address of a wallet to liquidate
    /// @param swapRouter - the address of a Uniswap swap router to be used to buy/sell erc20s
    /// @param nftManager - the address of a Uniswap NonFungibleTokenManager to be used to terminate
    /// ERC721 (NFTs)
    /// @param numeraire - the address of an ERC20 to be used to convert to and from erc20s. The
    /// liquidation reward would be in this token
    /// @param erc20s - the list of ERC20 that liquidated has debt, collateral or that would be
    /// obtained from termination of any ERC721 that he owns. Except of numeraire, that should
    /// never be included in erc20s array
    /// @param erc20sAllowedPriceRanges - the list of root squares of allowed prices in Q96 for
    /// `erc20s` swaps on Uniswap in `numeraire`. This is the protection against sandwich-attack -
    /// if the price would be lower/higher for sell/buy
    ///   It's up to liquidator to decide what range is acceptable. +/- 1% of price before liquify
    /// call seems to be reasonable
    ///   Zero minSell/maxBuy value for a specific ERC20 would disable the corresponding check
    /// Uniswap docs - https://docs.uniswap.org/contracts/v3/guides/swaps/single-swaps
    /// It doesn't explained in Uniswap docs, but this is how it actually works:
    /// * if the price for each token would be below the specified limit
    /// then full amount would be converted and no error would be thrown
    /// * if at least some amount of tokens can be bought by the price that is below the limit
    /// then only that amount of tokens would be bought and no error would be thrown
    /// * if no tokens can be bought by the price below the limit
    /// then error would be thrown with message "SPL"
    function liquify(
        address wallet,
        address swapRouter,
        address nftManager,
        address numeraire,
        IERC20[] calldata erc20s,
        SqrtPricePriceRangeX96[] calldata erc20sAllowedPriceRanges
    ) external selfOrWalletOwner {
        if (msg.sender != address(this)) {
            /* prettier-ignore */ // list of liquify arguments as-is
            return callOverBatchExecute(wallet, swapRouter, nftManager, numeraire, erc20s, erc20sAllowedPriceRanges);
        }

        supa.liquidate(wallet);

        (
            IERC20[] memory erc20sCollateral,
            uint256[] memory erc20sDebtAmounts
        ) = analyseCreditAccountStructure(erc20s, numeraire);

        supa.withdrawFull(erc20sCollateral);
        terminateERC721s(nftManager);

        (
            uint256[] memory erc20sToSellAmounts,
            uint256[] memory erc20sToBuyAmounts
        ) = calcSellAndBuyERC20Amounts(erc20s, erc20sDebtAmounts);
        sellERC20s(swapRouter, erc20s, erc20sToSellAmounts, numeraire, erc20sAllowedPriceRanges);
        buyERC20s(swapRouter, erc20s, erc20sToBuyAmounts, numeraire, erc20sAllowedPriceRanges);

        deposit(erc20s, numeraire);
    }

    function callOverBatchExecute(
        address wallet,
        address swapRouter,
        address nftManager,
        address numeraire,
        IERC20[] calldata erc20s,
        SqrtPricePriceRangeX96[] calldata erc20sAllowedPriceRanges
    ) private {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(this),
            callData: abi.encodeWithSelector(
                this.liquify.selector,
                wallet,
                swapRouter,
                nftManager,
                numeraire,
                erc20s,
                erc20sAllowedPriceRanges
            ),
            value: 0
        });
        supa.executeBatch(calls);
    }

    /// @param nftManager - passed as-is from liquify function. The address of a Uniswap
    ///   NonFungibleTokenManager to be used to terminate ERC721 (NFTs)
    function terminateERC721s(address nftManager) private {
        INonfungiblePositionManager manager = INonfungiblePositionManager(nftManager);
        ISupa.NFTData[] memory nfts = supa.getCreditAccountERC721(address(this));
        for (uint256 i = 0; i < nfts.length; i++) {
            ISupa.NFTData memory nft = nfts[i];
            supa.withdrawERC721(nft.erc721, nft.tokenId);
            (, , , , , , , uint128 nftLiquidity, , , , ) = manager.positions(nft.tokenId);
            manager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: nft.tokenId,
                    liquidity: nftLiquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );
            manager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: nft.tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

            manager.burn(nft.tokenId);
        }
    }

    function analyseCreditAccountStructure(
        IERC20[] calldata erc20s,
        address numeraire
    ) private view returns (IERC20[] memory erc20sCollateral, uint256[] memory erc20sDebtAmounts) {
        uint256 numOfERC20sCollateral = 0;
        int256[] memory balances = new int256[](erc20s.length);

        for (uint256 i = 0; i < erc20s.length; i++) {
            int256 balance = supa.getCreditAccountERC20(address(this), erc20s[i]);
            if (balance > 0) {
                numOfERC20sCollateral++;
                balances[i] = balance;
            } else if (balance < 0) {
                balances[i] = balance;
            }
        }

        int256 creditAccountNumeraireBalance = supa.getCreditAccountERC20(
            address(this),
            IERC20(numeraire)
        );
        if (creditAccountNumeraireBalance > 0) {
            numOfERC20sCollateral++;
        }

        erc20sCollateral = new IERC20[](numOfERC20sCollateral);
        erc20sDebtAmounts = new uint256[](erc20s.length);

        if (creditAccountNumeraireBalance > 0) {
            erc20sCollateral[0] = IERC20(numeraire);
        }

        for (uint256 i = 0; i < erc20s.length; i++) {
            if (balances[i] > 0) {
                erc20sCollateral[--numOfERC20sCollateral] = erc20s[i];
            } else if (balances[i] < 0) {
                erc20sDebtAmounts[i] = uint256(-balances[i]);
            }
        }
    }

    function calcSellAndBuyERC20Amounts(
        IERC20[] calldata erc20s,
        uint256[] memory erc20sDebtAmounts
    )
        private
        view
        returns (uint256[] memory erc20ToSellAmounts, uint256[] memory erc20ToBuyAmounts)
    {
        erc20ToBuyAmounts = new uint256[](erc20s.length);
        erc20ToSellAmounts = new uint256[](erc20s.length);

        for (uint256 i = 0; i < erc20s.length; i++) {
            uint256 balance = erc20s[i].balanceOf(address(this));
            if (balance > erc20sDebtAmounts[i]) {
                erc20ToSellAmounts[i] = balance - erc20sDebtAmounts[i];
            } else if (balance < erc20sDebtAmounts[i]) {
                erc20ToBuyAmounts[i] = erc20sDebtAmounts[i] - balance;
            }
        }
    }

    function sellERC20s(
        address swapRouter,
        IERC20[] memory erc20sToSell,
        uint256[] memory amountsToSell,
        address erc20ToSellFor,
        SqrtPricePriceRangeX96[] calldata erc20sAllowedPriceRanges
    ) private {
        for (uint256 i = 0; i < erc20sToSell.length; i++) {
            if (amountsToSell[i] == 0) continue;

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(erc20sToSell[i]),
                tokenOut: erc20ToSellFor,
                fee: 500,
                recipient: address(this),
                deadline: type(uint256).max, // ignore - total transaction type should be limited at Supa level
                amountIn: amountsToSell[i],
                amountOutMinimum: 0,
                // see comments on `erc20sAllowedPriceRanges` parameter of `liquify`
                sqrtPriceLimitX96: erc20sAllowedPriceRanges[i].minSell
            });

            try ISwapRouter(swapRouter).exactInputSingle(params) {} catch Error(
                string memory reason
            ) {
                // "SPL" means that proposed sell price is too low. If so - silently skip conversion.
                // For any other error - revert
                // Consider emitting or logging
                // Consider ignoring some other errors if it's appropriate
                // Consider replacing with `Strings.equal` on OpenZeppelin next release
                if (keccak256(abi.encodePacked(reason)) != keccak256(abi.encodePacked("SPL"))) {
                    revert(reason);
                }
            }
        }
    }

    function buyERC20s(
        address swapRouter,
        IERC20[] memory erc20sToBuy,
        uint256[] memory amountsToBuy,
        address erc20ToBuyFor,
        SqrtPricePriceRangeX96[] calldata erc20sAllowedPriceRanges
    ) private {
        for (uint256 i = 0; i < erc20sToBuy.length; i++) {
            if (amountsToBuy[i] == 0) continue;

            ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter
                .ExactOutputSingleParams({
                    tokenIn: erc20ToBuyFor,
                    tokenOut: address(erc20sToBuy[i]),
                    fee: 500,
                    recipient: address(this),
                    deadline: type(uint256).max, // ignore - total transaction type should be limited at Supa level
                    amountOut: amountsToBuy[i],
                    amountInMaximum: type(uint256).max,
                    // see comments on `erc20sAllowedPriceRanges` parameter of `liquify`
                    sqrtPriceLimitX96: erc20sAllowedPriceRanges[i].maxBuy
                });

            try ISwapRouter(swapRouter).exactOutputSingle(params) {} catch Error(
                string memory reason
            ) {
                // "SPL" means that proposed buy price is too high. If so - silently skip conversion.
                // For any other error - revert
                // Consider emitting or logging
                // Consider ignoring some other errors if it's appropriate
                // Consider replacing with `Strings.equal` on OpenZeppelin next release
                if (keccak256(abi.encodePacked(reason)) != keccak256(abi.encodePacked("SPL"))) {
                    revert(reason);
                }
            }
        }
    }

    function deposit(IERC20[] memory erc20s, address numeraire) private {
        supa.depositFull(erc20s);
        IERC20[] memory numeraireArray = new IERC20[](1);
        numeraireArray[0] = IERC20(numeraire);
        supa.depositFull(numeraireArray);
    }
}
