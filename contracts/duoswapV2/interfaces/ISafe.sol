// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ISafe {
    struct Call {
        address to;
        bytes callData;
        uint256 value;
    }
    
    function executeBatch(Call[] memory calls) external;
}