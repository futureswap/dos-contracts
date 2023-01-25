// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/// @title NFT Value Oracle Interface
interface INFTValueOracle {
    /// @notice Emitted when collateral factor is set
    /// @param collateralFactor Collateral factor
    event CollateralFactorSet(int256 indexed collateralFactor);

    function calcValue(
        uint256 tokenId
    ) external view returns (int256 value, int256 riskAdjustedValue);
}
