// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @title NFT Value Oracle Interface
interface INFTValueOracle {
    function calcValue(
        uint256 tokenId
    ) external view returns (int256 value, int256 riskAdjustedValue);
}
