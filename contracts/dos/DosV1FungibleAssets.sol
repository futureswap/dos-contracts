// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IDosPortfolioApiV1.sol";

import "../lib/FsUtils.sol";

import "./DosV1Storage.sol";
import "./PortfolioFlags.sol";

library DosV1FungibleAssets {
    using SafeERC20 for IERC20;

    /*
     * === IDosPortfolioApiV1 ===
     */

    /**
     * @notice An implementation for `IDosPortfolioApiV1.transfer()` for fungible assets.
     *
     * Must be protected with a liquidity check.
     */
    function transfer(
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        mapping(address => AssetHolding) storage holding,
        AssetIndex assetIdx,
        address from,
        address to,
        uint256 amount
    ) internal {
        /*
         * We need an up to date asset information, in case `amount` is `MAX_AMOUNT`.
         * `updateBalance()` also needs it, so we just call it early regardless.
         */
        updateFunding(funding, assetIdx);

        if (amount == IDosPortfolioApiV1_MAX_AMOUNT) {
            int256 shares = holding[from].fungibleShares[assetIdx];
            if (shares <= 0) {
                return;
            }

            uint256 shares_ui = FsMath.safeCastToUnsigned(shares);
            amount = funding[assetIdx].collateral.getAsset(shares_ui);
        }

        int256 amount_si = FsMath.safeCastToSigned(amount);

        updateBalanceNoUpdateFunding(funding, holding, assetIdx, from, -amount_si);
        updateBalanceNoUpdateFunding(funding, holding, assetIdx, to, amount_si);
    }

    /**
     * @notice An implementation for `IDosPortfolioApiV1.deposit()` for fungible assets.
     */
    function deposit(
        mapping(AssetIndex => FungibleAssetInfo) storage assetInfo,
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        mapping(address => AssetHolding) storage holding,
        AssetIndex assetIdx,
        address portfolio,
        uint256 amount
    ) internal {
        IERC20 token = assetInfo[assetIdx].token;

        if (amount == IDosPortfolioApiV1_MAX_AMOUNT) {
            amount = token.balanceOf(portfolio);
        }

        int256 amount_si = FsMath.safeCastToSigned(amount);

        token.safeTransferFrom(portfolio, address(this), amount);
        updateBalance(funding, holding, assetIdx, portfolio, amount_si);
    }

    /**
     * @notice An implementation for `IDosPortfolioApiV1.withdraw()` for fungible assets.
     *
     * Must be protected with a liquidity check.
     */
    function withdraw(
        mapping(AssetIndex => FungibleAssetInfo) storage assetInfo,
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        mapping(address => AssetHolding) storage holding,
        AssetIndex assetIdx,
        address portfolio,
        uint256 amount
    ) internal {
        /*
         * We need an up to date asset information, in case `amount` is `MAX_AMOUNT`.
         * `updateBalance()` also needs it, so we just call it early regardless.
         */
        updateFunding(funding, assetIdx);

        if (amount == IDosPortfolioApiV1_MAX_AMOUNT) {
            int256 shares = holding[portfolio].fungibleShares[assetIdx];
            if (shares <= 0) {
                return;
            }

            uint256 shares_ui = FsMath.safeCastToUnsigned(shares);
            amount = funding[assetIdx].collateral.getAsset(shares_ui);
        }

        int256 amount_si = FsMath.safeCastToSigned(amount);

        assetInfo[assetIdx].token.safeTransfer(portfolio, amount);
        updateBalanceNoUpdateFunding(funding, holding, assetIdx, portfolio, -amount_si);
    }

    /**
     * @notice An implementation for `IDosPortfolioApiV1.balanceOf()` for fungible assets.
     */
    function balanceOf(
        mapping(address => AssetHolding) storage holding,
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        AssetIndex assetIdx,
        address portfolio
    ) internal view returns (int256 asset) {
        /*
         * TODO As written this does not account for the asset transferred since the last
         * `updateFunding()` call.  So, a proper solution would need to look at the last funding
         * update and, unfortunately, will require adjustment to account for all the funding that
         * happened since then.
         *
         * An alternative would be to make this function into a non-view function.  Which is
         * probably non-ideal.
         */

        int256 shares = holding[portfolio].fungibleShares[assetIdx];
        if (shares == 0) {
            return 0;
        } else if (shares > 0) {
            uint256 shares_ui = FsMath.safeCastToUnsigned(shares);
            uint256 asset_ui = funding[assetIdx].collateral.getAsset(shares_ui);
            return FsMath.safeCastToSigned(asset_ui);
        } else {
            uint256 shares_ui = FsMath.safeCastToUnsigned(-shares);
            uint256 asset_ui = funding[assetIdx].debt.getAsset(shares_ui);
            return -FsMath.safeCastToSigned(asset_ui);
        }
    }

    /*
     * === Fungible token related functions ===
     */

    /**
     * @notice Changes `portfolio` balance for the specified fungible asset.
     *
     * Will call `updateFunding()` internally for `assetIdx`.
     *
     * @param funding Shared asset pool information.
     * @param holding Records of the shares of individual portfolios in the `funding` pool.
     * @param assetIdx Target fungible asset index.
     * @param portfolio Target portfolio address.
     * @param amount Amount adjustment.  Expressed in the same units as the asset token.
     */
    function updateBalance(
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        mapping(address => AssetHolding) storage holding,
        AssetIndex assetIdx,
        address portfolio,
        int256 amount
    ) internal {
        updateFunding(funding, assetIdx);
        updateBalanceNoUpdateFunding(funding, holding, assetIdx, portfolio, amount);
    }

    /**
     * @notice Changes `portfolio` balance for the specified fungible asset.
     *
     * Will *not* call `updateBalance()` internally for `assetIdx`.  Use `updateBalance()` if you
     * want combine it with an `updateFunding()` call.
     *
     * @param funding Shared asset pool information.
     * @param holding Records of the shares of individual portfolios in the `funding` pool.
     * @param assetIdx Target fungible asset index.
     * @param portfolio Target portfolio address.
     * @param amount Amount adjustment.  Expressed in the same units as the asset token.
     */
    function updateBalanceNoUpdateFunding(
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        mapping(address => AssetHolding) storage holding,
        AssetIndex assetIdx,
        address portfolio,
        int256 amount
    ) internal {
        int256 assetPre = extractPosition(funding, holding, portfolio, assetIdx);

        int256 assetPost = assetPre + amount;

        insertPosition(funding, holding, portfolio, assetIdx, assetPost);

        AssetHolding storage portfolioHolding = holding[portfolio];

        /*
         * Try to reduce storage access, by only updating the bitset if it needs to be updated.
         */
        AssetId assetId = AssetIdImpl.fromClassAndIndex(AssetIdClass.Fungible, assetIdx);
        if (assetPre == 0 && assetPost != 0) {
            portfolioHolding.assetIdsAndFlags.addId(assetId);
        } else if (assetPre != 0 && assetPost == 0) {
            portfolioHolding.assetIdsAndFlags.removeId(assetId);
        }

        /*
         * Try to reduce storage access, by only updating the bitsets if they need to be updated.
         */
        if (assetPre >= 0 && assetPost < 0) {
            if (portfolioHolding.borrowedAssetIdsAndFlags.hasNoIds()) {
                portfolioHolding.assetIdsAndFlags.setFlag(PortfolioFlags.HAS_DEBT);
            }
            portfolioHolding.borrowedAssetIdsAndFlags.addId(assetId);
        } else if (assetPre < 0 && assetPost >= 0) {
            portfolioHolding.borrowedAssetIdsAndFlags.removeId(assetId);
            if (portfolioHolding.borrowedAssetIdsAndFlags.hasNoIds()) {
                portfolioHolding.assetIdsAndFlags.clearFlag(PortfolioFlags.HAS_DEBT);
            }
        }
    }

    /**
     * @notice Moves asset between borrowers and landers, based on the current yield rate.
     *
     * @param funding Shared asset pool information.
     * @param assetIdx Target fungible asset index.
     */
    function updateFunding(
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        AssetIndex assetIdx
    ) internal {
        FungibleAssetFunding storage assetFunding = funding[assetIdx];

        uint256 lastUpdate = assetFunding.lastUpdate;
        int256 rate = assetFunding.borrowInterestRate;

        if (lastUpdate == block.timestamp) return;

        int256 timeDelta = FsMath.safeCastToSigned(block.timestamp - lastUpdate);
        assetFunding.lastUpdate = block.timestamp;

        int256 debt = FsMath.safeCastToSigned(assetFunding.debt.totalAsset);

        /*
         * We move funds at random intervals of time.  Yet, we want the funding rate to be the same
         * regardless of how frequently we do the update.  So we use a continuous compound interest
         * here:
         *
         *   https://en.wikipedia.org/wiki/Compound_interest#Continuous_compounding
         *
         * We need to compute the interest delta for the time delta.  Based on the compound interest
         * formula:
         *
         *   debt1 = debt0 * exp(rate * (time1 - time0))
         *
         * Meaning:
         *
         *   (debt1 - debt0) = debt0 * (exp(rate * (time1 - time0)) - 1)
         *
         *   debtDelta = debt0 * (exp(rate * timeDelta) - 1)
         *
         * `exp(...)` is scaled by `FIXED_POINT_SCALE`, so `-1` is actually `FIXED_POINT_SCALE`.
         */
        int256 expScale = FsMath.FIXED_POINT_SCALE;
        uint256 interest = FsMath.safeCastToUnsigned(
            (debt * (FsMath.exp(rate * timeDelta) - expScale)) / expScale
        );

        assetFunding.debt.totalAsset -= interest;
        assetFunding.collateral.totalAsset += interest;
    }

    /**
     * @notice Runs `updateFunding()` for all assets of a given portfolio.
     *
     * When computing portfolio state, we need to use the most up-to-date asset balances.
     */
    function updateFundingForAllPortfolioAssets(
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        mapping(address => AssetHolding) storage holding,
        address portfolio
    ) internal {
        AssetId[] memory assetIds = holding[portfolio].assetIdsAndFlags.getAssetIds();
        for (uint256 i = 0; i < assetIds.length; ++i) {
            AssetId id = assetIds[i];
            AssetIdClass cls = id.getClass();
            if (cls == AssetIdClass.Fungible) {
                updateFunding(funding, id.getIndex());
            }
        }
    }

    /*
     * === Implementation ===
     *
     * These functions have additional constraints that are easy to miss, so it is better to reduce
     * their scope, if possible.
     */

    /**
     * @notice Removes the specified portfolio asset from the shared pool.
     *
     * Expects funding to be already paid.  So you need to make sure that `updateFunding()` call has
     * happened, somewhere in the same transaction, before this function is invoked.
     *
     * NOTE This function should be called for a given portfolio and asset only once, and then it
     * should be followed by an `insertPosition()` call.
     * `holding[portfolio].fungibleShares[assetIdx]` is *not* updated by this function and it is
     * expected that `insertPosition()` will do an updated.
     *
     * @param funding Shared asset pool information.
     * @param holding Records of the shares of individual portfolios in the `funding` pool.
     * @param portfolio Target portfolio.
     * @param assetIdx Index of a fungible asset to extract.
     * @return Amount of asset extracted for this position.
     */
    function extractPosition(
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        mapping(address => AssetHolding) storage holding,
        address portfolio,
        AssetIndex assetIdx
    ) private returns (int256) {
        FungibleAssetFunding storage assetFunding = funding[assetIdx];

        int256 shares = holding[portfolio].fungibleShares[assetIdx];
        if (shares == 0) {
            return 0;
        } else if (shares > 0) {
            uint256 shares_ui = FsMath.safeCastToUnsigned(shares);
            uint256 asset = assetFunding.collateral.extractPosition(shares_ui);
            return FsMath.safeCastToSigned(asset);
        } else {
            uint256 shares_ui = FsMath.safeCastToUnsigned(-shares);
            uint256 asset = assetFunding.debt.extractPosition(shares_ui);
            return -FsMath.safeCastToSigned(asset);
        }
    }

    /**
     * @notice Inserts an asset amount into the shared asset pool, provided or borrowed by the
     * specified portfolio.
     *
     * Expects funding to be already paid.  So you need to make sure that `updateFunding()` call has
     * happened, somewhere in the same transaction, before this function is invoked.
     *
     * NOTE This function is expected to be called once after a call to `extractPosition()`.
     *
     * @param funding Shared asset pool information.
     * @param holding Records of the shares of individual portfolios in the `funding` pool.
     * @param portfolio Target portfolio.
     * @param asset Index of a fungible asset to extract.
     * @return shares Amount of shares allocated for the inserted asset.
     */
    function insertPosition(
        mapping(AssetIndex => FungibleAssetFunding) storage funding,
        mapping(address => AssetHolding) storage holding,
        address portfolio,
        AssetIndex assetIdx,
        int256 asset
    ) private returns (int256 shares) {
        FungibleAssetFunding storage assetFunding = funding[assetIdx];

        if (asset == 0) {
            shares = 0;
        } else if (asset > 0) {
            uint256 asset_ui = FsMath.safeCastToUnsigned(asset);
            uint256 shares_ui = assetFunding.collateral.insertPosition(asset_ui);
            shares = FsMath.safeCastToSigned(shares_ui);
        } else {
            uint256 asset_ui = FsMath.safeCastToUnsigned(-asset);
            uint256 shares_ui = assetFunding.debt.insertPosition(asset_ui);
            shares = -FsMath.safeCastToSigned(shares_ui);
        }

        /*
         * We would expect `fungibleShares` to have a value of `0`, but as `extractPosition()` does
         * not update `fungibleShares`, we can not verify it here.  So we just write over the
         * previous value.
         */
        holding[portfolio].fungibleShares[assetIdx] = shares;
        return shares;
    }
}
