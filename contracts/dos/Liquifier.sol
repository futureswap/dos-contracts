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
    ///   * liquidate target `dSafe`
    ///   * terminate all obtained ERC721s (NFTs)
    ///   * sell for `numeraire` all obtained from liquidation and from ERC721 termination `erc20s`
    ///   * for all `erc20s` that created debt as the result of liquidation,
    ///     buy that tokens in the amount of debt
    ///   * deposit bought `erc20s` to cover the debt and `numeraire` if there is a debt on it
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
    ///   ERC721 (NFTs)
    /// @param numeraire - the address of an ERC20 to be used to convert to and from erc20s. The
    ///   liquidation reward would be in this token
    /// @param erc20s - the list of ERC20 that liquidated has debt, collateral or that would be
    ///   obtained from termination of any ERC721 that he owns. Except of numeraire, that should
    ///   never be included in erc20s array
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
            IERC20[] memory erc20sToWithdraw,
            uint256[] memory erc20sToSellAmounts,
            IERC20[] memory erc20sToDeposit,
            uint256[] memory erc20sToBuyAmounts
        ) = analiseDAccountStructure(erc20s, numeraire);

        dos.withdrawFull(erc20sToWithdraw);
        terminateERC721s(nftManager, erc20s, erc20sToSellAmounts);
        sellERC20s(swapRouter, erc20s, erc20sToSellAmounts, numeraire);
        buyERC20s(swapRouter, erc20s, erc20sToBuyAmounts, numeraire);

        dos.depositFull(erc20sToDeposit);
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
            IERC20[] memory erc20sToWithdraw,
            uint256[] memory erc20sToSellAmounts,
            IERC20[] memory erc20sToDeposit,
            uint256[] memory erc20sToBuyAmounts
        )
    {
        uint256 numToWithdraw;
        uint256 numToDeposit;
        int256[] memory balances = new int256[](erc20s.length);

        for (uint256 i = 0; i < erc20s.length; i++) {
            int256 balance = dos.getDAccountERC20(address(this), erc20s[i]);
            if (balance > 0) {
                balances[i] = balance;
                numToWithdraw++;
            } else if (balance < 0) {
                balances[i] = balance;
                numToDeposit++;
            }
        }

        int256 dAccountNumeraireBalance = dos.getDAccountERC20(address(this), IERC20(numeraire));
        if (dAccountNumeraireBalance > 0) {
            numToWithdraw++;
        } else if (dAccountNumeraireBalance < 0) {
            numToDeposit++;
        }

        erc20sToWithdraw = new IERC20[](numToWithdraw);
        erc20sToSellAmounts = new uint256[](erc20s.length);
        erc20sToDeposit = new IERC20[](numToDeposit);
        erc20sToBuyAmounts = new uint256[](erc20s.length);

        if (dAccountNumeraireBalance > 0) {
            erc20sToWithdraw[0] = IERC20(numeraire);
        } else if (dAccountNumeraireBalance < 0) {
            erc20sToDeposit[0] = IERC20(numeraire);
        }

        for (uint256 i = 0; i < erc20s.length; i++) {
            int256 balance = balances[i];
            if (balance > 0) {
                erc20sToWithdraw[--numToWithdraw] = erc20s[i];
                erc20sToSellAmounts[i] = uint256(balance);
            } else if (balance < 0) {
                erc20sToDeposit[--numToDeposit] = erc20s[i];
                erc20sToBuyAmounts[i] = uint256(-balance);
            }
        }
    }

    // !modifies the erc20sToSellAmounts! amounts of tokens obtained from NFTs termination would
    // be added to the corresponding items of erc20sToSellAmounts
    function terminateERC721s(
        address nftManager,
        IERC20[] calldata erc20s,
        uint256[] memory erc20sToSellAmounts
    ) private {
        INonfungiblePositionManager manager = INonfungiblePositionManager(nftManager);
        IDOS.NFTData[] memory nfts = dos.getDAccountERC721(address(this));
        for (uint256 i; i < nfts.length; i++) {
            IDOS.NFTData memory nft = nfts[i];
            dos.withdrawERC721(nft.erc721, nft.tokenId);
            (, , address token0, address token1, , , , uint128 nftLiquidity, , , , ) = manager
                .positions(nft.tokenId);
            manager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: nft.tokenId,
                    liquidity: nftLiquidity,
                    amount0Min: 0,
                    amount1Min: 0,
                    deadline: type(uint256).max
                })
            );
            (uint256 amount0, uint256 amount1) = manager.collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: nft.tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
            for (uint256 j = 0; j < erc20s.length; j++) {
                if (address(erc20s[j]) == token0) {
                    erc20sToSellAmounts[j] += amount0;
                } else if (address(erc20s[j]) == token1) {
                    erc20sToSellAmounts[j] += amount1;
                }
            }

            manager.burn(nft.tokenId);
        }
    }

    function sellERC20s(
        address swapRouter,
        IERC20[] memory erc20sToSell,
        uint256[] memory amountsToSell,
        address erc20ToSellFor
    ) private {
        for (uint256 i; i < erc20sToSell.length; i++) {
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
