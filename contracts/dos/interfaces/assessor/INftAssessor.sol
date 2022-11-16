// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../../AssetId.sol";

/**
 * @title Computes risk adjusted value of an NFT asset.
 *
 * @notice DOS v1 only supports NFTs as collateral.
 *
 * This interface is used for NFT, ERC721 tokens.  For fungible, ERC20 tokens see `ITokenAssessor`.
 *
 * Each NFT token is expected to be converted into 1 or more underlying tokens, with IDs returned by
 * `AssetId`.  `asCollateral()` then returns value of a given NFT token when it is converted into
 * the same set of underlying tokens, when used as a collateral.
 *
 * TODO This interface is a rather rough draft.  It is still not completely clear what a UX of using
 * an NFT as a collateral would be.  And it would be ideal to look at a few different NFTs before a
 * defining a common interface.
 */
interface INftAssessor {
    /**
     * @notice Returns a list of asset IDs, that tokens of this type convert into.
     *
     * All returned IDs must be fungible tokens, supported by DOS.
     */
    function getUnderlyingIds() external view returns (AssetId[] calldata ids);

    /**
     * @notice Returns a risk adjusted value, when the specified token is converted into a
     * corresponding list of underlying tokens.
     *
     * `values` array should have the same length as the array returned by `getUnderlyingIds()`.
     *
     * If a token can not be converted into one or all of the corresponding underlying tokens for
     * some reason, this function should return `0` for one or all of those `values` elements.
     */
    function asCollateral(uint256 tokenId) external view returns (uint256[] calldata values);
}
