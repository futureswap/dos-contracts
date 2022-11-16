// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/**
 * @dev A special value used by a number of functions in the `ITokenAssessor` interface.
 *
 * Move into the interface when
 *
 *   https://github.com/ethereum/solidity/issues/8775
 *
 * is resolved.
 */
uint256 constant ITokenAssessor_MAX_VALUE = type(uint256).max;

/**
 * @title Computes risk adjusted value of an asset balance.
 *
 * @notice Adjustment depends on the intended use: as a collateral or as a debt.
 *
 * This interface is used for fungible, ERC20 tokens.  For NFT, ERC721 tokens see `INftAssessor`.
 *
 * Assessors may have configuration parameters that specify risk tolerances for the asset in
 * question.  See `ISingleAssetAssessor` for one of the configuration interfaces.
 */
interface ITokenAssessor {
    /**
     * @notice Returns a collateral risk adjusted value of `amount` units of asset, in the same
     * units as the asset.
     *
     * Returned value is expected to be strictly less than `amount`.
     *
     * In case this asset can not be used as a collateral, this function must return `0`.  Though it
     * should also be reflected in the asset registration information.
     */
    function asCollateral(uint256 amount) external view returns (uint256 adjusted);

    /**
     * @notice Returns a debt risk adjusted value of `amount` units of asset, in the same units as
     * the asset.
     *
     * Returned value is expected to be strictly higher than `amount`.
     *
     * In case this asset can not be used as debt, this function must return
     * `ITokenAssessor_MAX_VALUE`.  Though it should also be reflected in the asset registration
     * information.
     */
    function asDebt(uint256 amount) external view returns (uint256 adjusted);
}
