// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../lib/FsUtils.sol";

/**
 * @title Pool of asset, with ownership expressed in shares.
 *
 * @notice In order to be able to move asset in equal proportions between borrowers and lenders
 * without updating balances for every single borrower/lender, we use indirection.
 *
 * Instead of recording asset ownership directly, we record ownership as a share of the assets in
 * the pool.  For example, owning 50% of the shares, means that the party owns 50% of the asset in
 * the pool.
 *
 * This allows for a constant time updates of the total amount of asset, with the update distributed
 * between all the owners, proportional to their total ownership.  In other words, we can charge
 * everyone a 3% fee, in a single, constant time operation.  By just reducing the total amount of
 * asset, keeping the shares information intact.
 */
struct SharedAsset {
    /**
     * @notice Total amount of asset in the pool.  Recorded in the token precision.
     */
    uint256 totalAsset;
    /**
     * @notice Total amount of shares split between all the owners of the asset in this pool.
     *
     * Initially, 1 share means ownership of 1 unit of asset, but as time passes, this ratio will
     * change, when asset is added or removed without changing the amount of shares.
     *
     * TODO Should we use a multiplier in our initial ratio, to keep more precisions?
     * For example, we can start with a ratio of 100 shares means ownership of 1 unit of asset.
     * In v4 we introduced share classes, in order to limit maximum ratio value between assets to
     * shares.  In practice, we did not see the ratio to drift that much, but share classes required
     * additional maintenance.  Scaling shares at the beginning might be an easy improvement without
     * the additional complexity of the share class solution.
     */
    uint256 totalShares;
}

using SharedAssetImpl for SharedAsset global;

/**
 * @title Functions used with the `SharedAsset` type.
 */
library SharedAssetImpl {
    /**
     * @return asset The asset amount for the given share.
     */
    function getAsset(
        SharedAsset storage self,
        uint256 shares
    ) internal view returns (uint256 asset) {
        return (self.totalAsset * shares) / self.totalShares;
    }

    /**
     * @notice Adds the specified amount of `asset` into the pool, increasing both asset and shares
     * in the pool accordingly.
     *
     * @return shares The amount of shares allocated for the inserted asset.
     */
    function insertPosition(
        SharedAsset storage self,
        uint256 asset
    ) internal returns (uint256 shares) {
        uint256 totalShares = self.totalShares;
        uint256 totalAsset = self.totalAsset;

        if (totalShares == 0) {
            FsUtils.Assert(totalAsset == 0);
            // TODO Consider scaling shares:
            // shares = 100 * assert;
            shares = asset;
        } else {
            shares = (totalShares * asset) / totalAsset;
        }

        self.totalShares = totalShares + shares;
        self.totalAsset = totalAsset + asset;
    }

    /**
     * @notice Removes the amount of `asset` from the pool, matching the `shares`.  Decreases both
     * asset and shares in the pool accordingly.
     *
     * @return asset The amount of asset subtracted from the pool.
     */
    function extractPosition(
        SharedAsset storage self,
        uint256 shares
    ) internal returns (uint256 asset) {
        asset = self.getAsset(shares);
        self.totalAsset -= asset;
        self.totalShares -= shares;
    }
}
