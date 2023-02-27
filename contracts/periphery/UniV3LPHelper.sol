// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {INonfungiblePositionManager} from "contracts/external/interfaces/INonfungiblePositionManager.sol";
import {IDOS} from "contracts/interfaces/IDOS.sol";

contract UniV3LPHelper {
    IDOS public dos;
    INonfungiblePositionManager public nonfungiblePositionManager;

    constructor(address _dos, address _nonfungiblePositionManger) {
        dos = IDOS(_dos);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManger);
    }

    function mintAndDeposit(INonfungiblePositionManager.MintParams memory params) external payable {
        IERC20(params.token0).transferFrom(msg.sender, address(this), params.amount0Desired);
        IERC20(params.token1).transferFrom(msg.sender, address(this), params.amount1Desired);
        IERC20(params.token0).approve(address(nonfungiblePositionManager), type(uint256).max);
        IERC20(params.token1).approve(address(nonfungiblePositionManager), type(uint256).max);
        params.recipient = address(this);
        (uint256 tokenId, , , ) = nonfungiblePositionManager.mint(params);

        IERC721(address(nonfungiblePositionManager)).approve(address(dos), tokenId);
        dos.depositERC721ForSafe(address(nonfungiblePositionManager), msg.sender, tokenId);
    }
}
