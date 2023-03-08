// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/// @title ERC20 value oracle interface
interface IERC20ValueOracle {
    /// @notice Emitted when risk factors are set
    /// @param collateralFactor Collateral factor
    /// @param borrowFactor Borrow factor
    event RiskFactorsSet(int256 indexed collateralFactor, int256 indexed borrowFactor);

    function calcValue(
        int256 balance
    ) external view returns (int256 value, int256 riskAdjustedValue);
}
