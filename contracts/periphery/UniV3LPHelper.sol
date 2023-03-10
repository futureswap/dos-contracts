// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "contracts/external/interfaces/INonfungiblePositionManager.sol";
import {ISupa} from "contracts/interfaces/ISupa.sol";

/// @title Supa UniswapV3 LP Position Helper
contract UniV3LPHelper {
    ISupa public supa;
    address public nonfungiblePositionManager;

    constructor(address _supa, address _nonfungiblePositionManger) {
        supa = ISupa(_supa);
        nonfungiblePositionManager = _nonfungiblePositionManger;
    }

    /// @notice Mint and deposit LP token to credit account
    /// @param params MintParams struct
    function mintAndDeposit(
        INonfungiblePositionManager.MintParams memory params
    ) external payable returns (uint256 tokenId) {
        // Transfer tokens to this contract
        IERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);

        // Approve tokens to nonfungiblePositionManager
        IERC20(params.token0).approve(nonfungiblePositionManager, params.amount0Desired);
        IERC20(params.token1).approve(nonfungiblePositionManager, params.amount1Desired);

        // Update recipient to this contract
        params.recipient = address(this);

        // Mint LP token
        (tokenId, , , ) = INonfungiblePositionManager(nonfungiblePositionManager).mint(params);

        // Approve LP token to Supa
        IERC721(address(nonfungiblePositionManager)).approve(address(supa), tokenId);

        // Deposit LP token to credit account
        supa.depositERC721ForWallet(nonfungiblePositionManager, msg.sender, tokenId);
    }

    /// @notice Collect fees and reinvest
    /// @param tokenId LP token ID
    function reinvest(uint256 tokenId) external {
        // transfer LP token to this contract
        IERC721(address(nonfungiblePositionManager)).transferFrom(
            msg.sender,
            address(this),
            tokenId
        );
        // collect accrued fees
        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(nonfungiblePositionManager)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

        // get token addresses
        (, , address token0, address token1, , , , , , , , ) = INonfungiblePositionManager(
            nonfungiblePositionManager
        ).positions(tokenId);

        // approve tokens to nonfungiblePositionManager
        IERC20(token0).approve(nonfungiblePositionManager, amount0);
        IERC20(token1).approve(nonfungiblePositionManager, amount1);

        // reinvest
        INonfungiblePositionManager(nonfungiblePositionManager).increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: tokenId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // approve LP token to Supa
        IERC721(address(nonfungiblePositionManager)).approve(address(supa), tokenId);

        // deposit LP token to credit account
        supa.depositERC721ForWallet(nonfungiblePositionManager, msg.sender, tokenId);
    }

    function quickWithdraw(uint256 tokenId) external {
        // transfer LP token to this contract
        IERC721(address(nonfungiblePositionManager)).transferFrom(
            msg.sender,
            address(this),
            tokenId
        );

        // get current position values
        (
            ,
            ,
            address token0,
            address token1,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            ,

        ) = INonfungiblePositionManager(nonfungiblePositionManager).positions(tokenId);

        // remove liquidity
        INonfungiblePositionManager(nonfungiblePositionManager).decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // collect tokens
        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(nonfungiblePositionManager)
            .collect(
                INonfungiblePositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: address(this),
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );

        // approve tokens to supa
        IERC20(token0).approve(address(supa), amount0);
        IERC20(token1).approve(address(supa), amount1);

        // deposit tokens to credit account
        supa.depositERC20ForWallet(token0, msg.sender, amount0);
        supa.depositERC20ForWallet(token1, msg.sender, amount1);

        // transfer lp token to msg.sender
        IERC721(address(nonfungiblePositionManager)).transferFrom(
            address(this),
            msg.sender,
            tokenId
        );
    }
}
