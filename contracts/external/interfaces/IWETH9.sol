// SPDX-License-Identifier: MIT1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IERC20WithMetadata is IERC20, IERC20Metadata {}

interface IWETH9 is IERC20WithMetadata {
    receive() external payable;

    function deposit() external payable;

    function withdraw(uint256 wad) external;
}
