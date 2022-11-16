// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface IAssetValueOracle {
    function calcValue(int256 balance) external view returns (int256);
}
