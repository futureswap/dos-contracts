// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "./AssetBitsetWithFlags.sol";
import "./SharedAsset.sol";
import "./LiquidationStrategyV1.sol";
import "./interfaces/assessor/INftAssessor.sol";
import "./interfaces/assessor/ITokenAssessor.sol";

/*
 * This file contains storage structures used by `DosV1` and its implementation libraries.
 */

/**
 * @notice Describes a fungible, ERC20, non-rebasing token.
 */
struct FungibleAssetInfo {
    IERC20 token;
    ITokenAssessor assessor;
    bool useAsCollateral;
    bool useAsDebt;
}

/**
 * @notice Describes an NFT, ERC721 token.
 *
 * In DOS v1 NFT can only be used as collateral, so there are not separate `useAsCollateral`, and
 * `useAsDebt` flags.
 */
struct NftAssetInfo {
    IERC721 token;
    INftAssessor assessor;
}

/**
 * @notice Stores global asset ownership.
 */
struct FungibleAssetFunding {
    /**
     * @notice Holds record of all the collateral deposited into DOS by all portfolios, holding this
     * asset.  Also records ratio between asset units and shares units for this collateral.
     */
    SharedAsset collateral;
    /**
     * @notice Holds record of all the debt, for all portfolios in this DOS instance, for this
     * particular asset type.  Also records ratio between asset units and shares units for this
     * debt.
     */
    SharedAsset debt;
    /**
     * @notice Time of the last asset movement between `debt` and `collateral`.
     *
     * Asset is moved between `debt` and `collateral`, when borrowers pay their fees, and yield is
     * attributed to the lenders.  We record the timestamp of the last update, in seconds since Unix
     * epoch, into this field.
     *
     * TODO We may want to pack this field and the next one.
     */
    uint256 lastUpdate;
    /**
     * @notice Interest rate paid on the outstanding debt of this asset.
     *
     * Expressed as a percentage of asset paid per 1 second of time, as a fixed point decimal
     * integer with a scale of `FIXED_POINT_SCALE`.
     *
     * A value of `1` (written as `FIXED_POINT_SCALE`), would mean that 100% of the dept is paid to
     * the borrowers as a fee every second.
     */
    int256 borrowInterestRate;
}

/**
 * @notice Lists fungible, ERC20 holdings for a single portfolio.
 */
struct AssetHolding {
    /**
     * @notice A set of all `AssetId`s that this portfolio owns or have borrowed.  Along with any of
     * the `PortfolioFlags`.
     *
     * Asset ids retrieved from this set can be used to index into `fungibleShares`, for `AssetId`s
     * of `AssetIdClass.Funding` class.  For `AssetId`s of `AssetIdClass.Nft` class, index into
     * `nftAssets`.
     */
    AssetBitsetWithFlags assetIdsAndFlags;
    /**
     * @notice Space for the `assetIdsAndFlags` to grow, should we need to store more asset ids in
     * the future.
     */
    uint256[9] __assetIdsAndFlags_gap;
    /**
     * @notice Assets borrowed by this portfolio.  Must be a subset of `assetIdsAndFlags`.
     *
     * For any asset borrowed by the portfolio, this set should contain this asset ID.  And for all
     * other assets, this set should not contain their IDs.
     *
     * When this set contains any IDs, `assetIdsAndFlags` should have `PortfolioFlags.HAS_DEBT` set.
     *
     * At the moment, this field should not have any flags set.
     */
    AssetBitsetWithFlags borrowedAssetIdsAndFlags;
    uint256[9] __borrowedAssetIdsAndFlags_gap;
    /**
     * @notice Liquidation strategy that is used in order to evaluate portfolio holdings risk and to
     * liquidate debt in case the risk level is too high.
     *
     * See `./LiquidationStrategyV1.sol` for details.
     *
     * Is required when portfolio holds any debt, in other words, when `borrowedAssetIdsAndFlags`
     * contains anything.  Ignored for a portfolio with no debt, and a default value of 0 can be
     * used, called "empty strategy".
     */
    LiquidationStrategyV1 liquidationStrategy;
    uint256[9] __liquidationStrategy_gap;
    /**
     * @notice Holdings of the specified fungible asset for the current portfolio.
     *
     * Negative `shares` indicate that portfolio is holding debt.  It could be somewhat confusing
     * that we combine collateral and debt in the same field, as collateral shares have different
     * value from the debt shares.
     *
     * In other words, `+1` unit of shares represent a different amount of asset, in absolute terms,
     * compared to a `-1` unit of shares, as collateral and debt shares are converted into assets
     * via `FungibleAssetFunding.collateral` and `FungibleAssetFunding.debt` respectively.
     *
     * Alternatively, we can encode a collateral/debt flag, and the share amount would always be
     * positive.
     */
    mapping(AssetIndex => int256) fungibleShares;
    /**
     * @notice Holdings of the specified NFT asset for the current portfolio.
     *
     * In DOS v1 NFT assets can no be borrowed, so, unlike `fungibleShares`, these values can be
     * only positive.
     */
    mapping(AssetIndex => NftAssetHolding) nftAssets;
}

/**
 * @notice Lists holdings of an NFT token of a given type for a single portfolio.
 *
 * TODO We may want to introduce more efficient encoding of the `tokenId` values, as, I would guess,
 * they are probably allocated starting with `0`.  Meaning they are never going to use most of the
 * 256 bits of the allocated space.
 */
struct NftAssetHolding {
    /**
     * @notice An array of token IDs of the given NFT asset type, owned by this portfolio.
     */
    uint256[] tokenIds;
}
