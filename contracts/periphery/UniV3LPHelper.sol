// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {INonfungiblePositionManager} from "contracts/external/interfaces/INonfungiblePositionManager.sol";
import {ISupa} from "contracts/interfaces/ISupa.sol";

contract UniV3LPHelper {
    ISupa public supa;
    address public nonfungiblePositionManager;

    constructor(address _supa, address _nonfungiblePositionManger) {
        supa = ISupa(_supa);
        nonfungiblePositionManager = _nonfungiblePositionManger;
    }

    function mintAndDeposit(INonfungiblePositionManager.MintParams memory params) external payable {
        // Transfer tokens to this contract
        IERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);

        // Approve tokens to nonfungiblePositionManager
        IERC20(params.token0).approve(nonfungiblePositionManager, params.amount0Desired);
        IERC20(params.token1).approve(nonfungiblePositionManager, params.amount1Desired);

        // Update recipient to this contract
        params.recipient = address(this);

        // Mint LP token
        (uint256 tokenId, , , ) = INonfungiblePositionManager(nonfungiblePositionManager).mint(
            params
        );

        // Approve LP token to Supa
        IERC721(address(nonfungiblePositionManager)).approve(address(supa), tokenId);
        // Deposit LP token to credit account
        supa.depositERC721ForSafe(nonfungiblePositionManager, msg.sender, tokenId);
    }
}
