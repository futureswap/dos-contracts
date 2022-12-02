// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface IERC20ValueOracle {
    function calcValue(int256 balance) external view returns (int256);
}
