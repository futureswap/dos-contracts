// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Call} from "../lib/Call.sol";

interface IWallet {
    event TokensApproved(address sender, uint256 amount, bytes data);
    event TokensReceived(address spender, address sender, uint256 amount, bytes data);

    function executeBatch(Call[] memory calls) external payable;
}
