// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "../external/interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IDOS.sol";
import "./DSafeState.sol";

/// @title Logic for liquify functionality of dSafe
/// @dev It is designed to be an extension for dSafeLogic contract.
/// Functionally, it's a part of the dSafeLogic contract, but has been extracted into a separate
/// contract for better code structuring. This is why the contract is declared as abstract
///   The only function it exports is `liquify`. The rest are private function that are parts of
/// `liquify`
abstract contract Liquifier is DSafeState {
    modifier selfOrDSafeOwner() {
        require(
            msg.sender == address(this) || msg.sender == dos.getDSafeOwner(address(this)),
            "only self or owner"
        );
        _;
    }

    /// @notice Advanced version of liquidate function. Potentially unwanted side-affect of
    /// liquidation is a debt on the liquidator. So liquify would liquidate and then re-balance
    /// obtained assets to have no debt. This is the algorithm:
    ///   * liquidate dAccount of target `dSafe`
    ///   * terminate all obtained ERC721s (NFTs)
    ///   * buy/sell `erc20s` for `numeraire` so the balance of `dSafe` on that ERC20s matches the
    ///     debt of `dSafe` on it's dAccount. E.g.:
    ///     - for 1 WETH of debt on dAccount and 3 WETH on the balance of dSafe - sell 2 WETH
    ///     - for 3 WETH of debt on dAccount and 1 WETH on the balance of dSafe - buy 2 WETH
    ///     - for no debt on dAccount and 1 WETH on the balance of dSafe - sell 2 WETH
    ///     - for 1 WETH of debt on dAccount and no WETH on the balance of dSave - buy 1 WETH
    ///   * deposit `erc20s` to cover the debt and `numeraire` if there is a debt on it
    ///
    /// !! IMPORTANT: because this function executes quite a lot of logic on top of DOS.liquidate(),
    /// there is a risk that for liquidatable position with a long list of NFTs it will run out
    /// of gas. As for now, it's up to liquidator to estimate if specific position is liquifiable,
    /// or DOS.liquidate() need to be used (with further assets re-balancing in other transactions)
    /// @dev notes on erc20s: the reason for erc20s been a call parameter, and not been calculated
    /// inside of liquify, is reducing gas costs
    ///   erc20s should NOT include numeraire. Otherwise, the transaction would be reverted with an
    /// error from uniswap router
    ///   It's the responsibility of caller to provide the correct list of erc20s. Assets
    /// re-balancing would be performed only by this list of tokens and numeraire.
    ///   * if erc20s misses a token that liquidatable have debt on - the debt on this erc20 would
    ///     persist on liquidator's dAccount as-is
    ///   * if erc20s misses a token that liquidatable have collateral on - the token would persist
    ///     on liquidator's dAccount. It may result in generating debt in numeraire on liquidator
    ///     dAccount by the end of liquify (because the token would not be soled for numeraire,
    ///     there may not be enough numeraire to buy tokens to cover debts, and so they will be
    ///     bought in debt)
    ///   * if erc20s misses a token that would be obtained as the result of NFT termination - same
    ///     as previous, except of the token to be persisted on dSafe instead of dAccount of
    ///     liquidator
    /// @param dSafe - the address of a dSafe to liquidate
    /// @param swapRouter - the address of a Uniswap swap router to be used to buy/sell erc20s
    /// @param nftManager - the address of a Uniswap NonFungibleTokenManager to be used to terminate
    /// ERC721 (NFTs)
    /// @param numeraire - the address of an ERC20 to be used to convert to and from erc20s. The
    /// liquidation reward would be in this token
    /// @param erc20s - the list of ERC20 that liquidated has debt, collateral or that would be
    /// obtained from termination of any ERC721 that he owns. Except of numeraire, that should
    /// never be included in erc20s array
    function liquify(
        address dSafe,
        address swapRouter,
        address nftManager,
        address numeraire,
        IERC20[] calldata erc20s
    ) external selfOrDSafeOwner {
        if (msg.sender != address(this)) {
            return callOverBatchExecute(dSafe, swapRouter, nftManager, numeraire, erc20s);
        }

        dos.liquidate(dSafe);

        (
            IERC20[] memory erc20sCollateral,
            IERC20[] memory erc20sDebt,
            uint256[] memory erc20sDebtAmounts
        ) = analiseDAccountStructure(erc20s, numeraire);

        dos.withdrawFull(erc20sCollateral);
        terminateERC721s(nftManager);

        (
            uint256[] memory erc20sToSellAmounts,
            uint256[] memory erc20sToBuyAmounts
        ) = calcSellAndBuyERC20Amounts(erc20s, erc20sDebtAmounts);
        sellERC20s(swapRouter, erc20s, erc20sToSellAmounts, numeraire);
        buyERC20s(swapRouter, erc20s, erc20sToBuyAmounts, numeraire);

        dos.depositFull(erc20sDebt);
    }

    function callOverBatchExecute(
        address dSafe,
        address swapRouter,
        address nftManager,
        address numeraire,
        IERC20[] calldata erc20s
    ) private {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(this),
            callData: abi.encodeWithSelector(
                this.liquify.selector,
                dSafe,
                swapRouter,
                nftManager,
                numeraire,
                erc20s
            ),
            value: 0
        });
        dos.executeBatch(calls);
    }

    function analiseDAccountStructure(
        IERC20[] calldata erc20s,
        address numeraire
    )
        private
        view
        returns (
            IERC20[] memory erc20sCollateral,
            IERC20[] memory erc20sDebt,
            uint256[] memory erc20sDebtAmounts
        )
    {
        uint256 numOfERC20sCollateral = 0;
        uint256 numOfERC20sDebt = 0;
        int256[] memory balances = new int256[](erc20s.length);

        for (uint256 i = 0; i < erc20s.length; i++) {
            int256 balance = dos.getDAccountERC20(address(this), erc20s[i]);
            if (balance > 0) {
                numOfERC20sCollateral++;
                balances[i] = balance;
            } else if (balance < 0) {
                numOfERC20sDebt++;
                balances[i] = balance;
            }
        }

        int256 dAccountNumeraireBalance = dos.getDAccountERC20(address(this), IERC20(numeraire));
        if (dAccountNumeraireBalance > 0) {
            numOfERC20sCollateral++;
        } else if (dAccountNumeraireBalance < 0) {
            numOfERC20sDebt++;
        }

        erc20sCollateral = new IERC20[](numOfERC20sCollateral);
        erc20sDebt = new IERC20[](numOfERC20sDebt);
        erc20sDebtAmounts = new uint256[](erc20s.length);

        if (dAccountNumeraireBalance > 0) {
            erc20sCollateral[0] = IERC20(numeraire);
        } else if (dAccountNumeraireBalance < 0) {
            erc20sDebt[0] = IERC20(numeraire);
        }

        for (uint256 i = 0; i < erc20s.length; i++) {
            if (balances[i] > 0) {
                erc20sCollateral[--numOfERC20sCollateral] = erc20s[i];
            } else if (balances[i] < 0) {
                erc20sDebt[--numOfERC20sDebt] = erc20s[i];
                erc20sDebtAmounts[i] = uint256(-balances[i]);
            }
        }
    }

    /// @param nftManager - passed as-is from liquify function. The address of a Uniswap
    ///   NonFungibleTokenManager to be used to terminate ERC721 (NFTs)
    function terminateERC721s(address nftManager) private {
        INonfungiblePositionManager manager = INonfungiblePositionManager(nftManager);
        IDOS.NFTData[] memory nfts = dos.getDAccountERC721(address(this));
        for (uint256 i = 0; i < nfts.length; i++) {
            IDOS.NFTData memory nft = nfts[i];
            dos.withdrawERC721(nft.erc721, nft.tokenId);
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
        address erc20ToSellFor
    ) private {
        for (uint256 i = 0; i < erc20sToSell.length; i++) {
            if (amountsToSell[i] == 0) continue;

            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
                tokenIn: address(erc20sToSell[i]),
                tokenOut: erc20ToSellFor,
                fee: 500,
                recipient: address(this),
                deadline: type(uint256).max,
                amountIn: amountsToSell[i],
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            ISwapRouter(swapRouter).exactInputSingle(params);
        }
    }

    function buyERC20s(
        address swapRouter,
        IERC20[] memory erc20sToBuy,
        uint256[] memory amountsToBuy,
        address erc20ToBuyFor
    ) private {
        for (uint256 i = 0; i < erc20sToBuy.length; i++) {
            if (amountsToBuy[i] == 0) continue;

            ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter
                .ExactOutputSingleParams({
                    tokenIn: erc20ToBuyFor,
                    tokenOut: address(erc20sToBuy[i]),
                    fee: 500,
                    recipient: address(this),
                    deadline: type(uint256).max, // recommend limiting this to block.time
                    amountOut: amountsToBuy[i],
                    amountInMaximum: type(uint256).max, // recommend limiting this
                    sqrtPriceLimitX96: 0
                });
            ISwapRouter(swapRouter).exactOutputSingle(params);
        }
    }
}
