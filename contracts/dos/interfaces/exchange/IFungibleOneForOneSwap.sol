// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../../AssetId.sol";

/**
 * @title A connection to an exchange capable of swapping two fungible tokens, one for another.
 */
interface IFungibleOneForOneSwap {
    /**
     * @notice Swaps `toAmount` of `to` for `from`. If `toAmount` is positive, then the `recipient`
     * will receive `to`, and if negative, they receive `from`.
     *
     * TODO This function API is a draft.  It is likely to change when
     * `DosV1Liquidation.liquidate()` is implemented.
     *
     * @param recipient The recipient to send tokens to.
     * @param from An address of a token this swapper supports.
     * @param to An address of a token this swapper supports.
     * @param toAmount Amount of `to` to swap. This method will revert if `toAmount` is zero.
     * @return fromAmount The amount of `from` paid (negative) or received (positive).
     */
    function swap(
        address recipient,
        AssetIndex from,
        AssetIndex to,
        int256 toAmount
    ) external returns (int256 fromAmount);

    /**
     * @notice Returns a spot price of 1 unit of `from` in units of `to`.
     *      Representation is a fixed point decimal with precision set by `FsMath.FIXED_POINT_SCALE`
     *      (defined to be `1 << 64`).
     *
     * This method may return price directly from the underlying exchange, which could be
     * manipulatable.  It can be used as a price to show in the application UI, but for risk
     * assessment purposes, `getOraclePrice()` should be used.
     *
     * @param from The token to return price for.
     * @param to The token to return price relatively to.
     * @return price Price of 1 unit of `from` in units of `to`.
     */
    function getSpotPrice(AssetIndex from, AssetIndex to) external view returns (int256 price);

    /**
     * @notice Returns an oracle price of 1 unit of `from` in units of `to`.
     *      Representation is a fixed point decimal with precision set by `FsMath.FIXED_POINT_SCALE`
     *      (defined to be `1 << 64`).
     *
     * This method should be used when computing portfolio price for risk assessment.
     *
     * @param from The token to return price for.
     * @param to The token to return price relatively to.
     * @return price Price of 1 unit of `from` in units of `to`.
     */
    function getOraclePrice(AssetIndex from, AssetIndex to) external view returns (int256 price);
}
