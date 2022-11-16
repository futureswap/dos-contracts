// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/**
 * @title Configures risk tolerance factor in an asset assessor.
 *
 * @notice When computing risk adjusted value of an asset assessor adjusts asset value depending on
 * the expected asset risk level.
 *
 * When asset is used as a collateral, value is reduced, and when it is borrowed, value is
 * increased.
 *
 * This way the liquidation system would have a better chance at liquidating before portfolio
 * crosses the bankruptcy line.
 *
 * There are multiple ways to adjust for the liquidation risk, including using additional sources of
 * information.  But the simplest approach is to just multiply asset value by a constant.
 *
 * For collateral, this constant is in range [0, 1).  For borrow, it is `1 / [0, 1)`.
 *
 * Assessors that use this simples strategy when computing risk adjusted value may implement this
 * interface, to allow for the strategy parameters to be adjusted.
 */
interface ISimpleAssetAssessor {
    /**
     * @notice Sets a multiplier applied to the asset value when asset is used as a collateral.
     *
     * @param factor A fixed decimal number with 18 digits of precision.  Has to be in range of [0,
     * 1).
     */
    function setCollateralFactor(uint256 factor) external;

    /**
     * @notice Sets a multiplier applied as `1 / factor` to the asset value when asset is borrowed.
     *
     * @param factor A fixed decimal number with 18 digits of precision.  Has to be in range of [0,
     * 1).
     */
    function setBorrowFactor(uint256 factor) external;
}
