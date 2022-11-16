// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/*
 * These are flags used for portfolio holdings.  For assets of any kind: fungible and non-fungible.
 *
 * There flags are stored inside of the `assetIdsAndFlags` field in the `AssetHolding` structure.
 * `borrowedAssetIdsAndFlags` does not have any flags defined for it, at the moment.
 */
library PortfolioFlags {
    /**
     * @notice Is set when `borrowedAssetIdsAndFlags` stores any `AssetId` set.
     *
     * It is an optimization, that avoids reading `borrowedAssetIdsAndFlags` for portfolios that do
     * not contain any debt.
     */
    uint8 public constant HAS_DEBT = 1 << 0;

    /**
     * @notice This flag is set when a batch operation for portfolio is running, and at least one
     * operation in the batch requires a liquidity check.
     *
     * This flag can only be set when `INSIDE_BATCH` is also set.  And is an optimization, allowing
     * us to skip liquidity checks for batch operations that did not contain operations that require
     * a liquidity check.
     */
    uint8 public constant DO_LIQUIDITY_CHECK = 1 << 1;

    /**
     * @notice This flag is set when a batch operation for portfolio have started and liquidity
     * checks should be delayed until the end of the batch.
     *
     * At the moment, we are going to make `batch()` non-reenterable.  But we can allow
     * reenternancy, as the only problem with that is just a need to record the number of nested
     * `batch()` calls.  If we extend this flag into 2 bits, we would be able to support up to 3
     * nested calls to `batch()` before we would have to fail.
     */
    uint8 public constant INSIDE_BATCH = 1 << 2;
}
