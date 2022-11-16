// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./DosV1ExchangeRegistry.sol";
import "./DosV1FungibleAssets.sol";
import "./DosV1Storage.sol";
import "./LiquidationStrategyV1.sol";
import "./interfaces/exchange/IFungibleOneForOneSwap.sol";

/**
 * @title Liquidation subsystem of DOS v1.
 */
library DosV1Liquidation {
    /*
     * === IDosPortfolioApiV1 ===
     */

    /**
     * @dev When deciding if a given asset was completely liquidated or not we allow this much debt
     * to be still preset, and yet determine that it was completely liquidated.
     *
     * This is useful, as some of the math operations may accumulate errors, we do not want a
     * strategy to be marking a portfolio as illiquid due to a rounding error, rather then due to
     * the actual lack of asset.  This is important, in particular for the `SwapUpTo` operation that
     * is trying to use only the necessary amount of asset.
     *
     * Our liquidity check has additional safety margins built in, so rounding errors should not
     * affect the risk of the check in any way, as long as this value is really small.
     *
     * 1024 should be plenty for rounding errors.  Our FsMath.FIXED_POINT_SCALE is 2^64, and most
     * tokens use 10^18 or, at least, 10^6.
     */
    int256 public constant DEBT_ROUNDING_ERROR = 1 << 10;

    /**
     * @notice Checks if a given `portfolio` is liquid or not.
     *
     * Runs a liquidation strategy and returns true if all debt is liquidated in the process.
     *
     * NOTE Call `updateFundingForAllPortfolioAssets()` before calling this function, as it needs up
     * to date state of all the portfolio asset balances.
     *
     * @dev As Solidity is not very generic, I had to encode the liquidation strategy encoding
     * inside of this method.
     */
    function isLiquid(
        mapping(AssetIndex => FungibleAssetInfo) storage fungibleAssetInfo,
        mapping(AssetIndex => NftAssetInfo) storage /* nftAssetInfo */,
        mapping(AssetIndex => FungibleAssetFunding) storage fungibleAssetFunding,
        mapping(address => AssetHolding) storage holding,
        mapping(AssetIndex => mapping(AssetIndex => IFungibleOneForOneSwap))
            storage exchangeFungibleOneForOne,
        address portfolio,
        LiquidationStrategyV1 memory strategy
    ) internal view returns (bool) {
        FsUtils.Assert(strategy.words.length == 1);

        uint256 strategyBits = strategy.words[0];

        strategyBits >>= LiquidationStrategyV1Impl.VERSION_BIT_WIDTH;

        (
            uint8 slotCount,
            AssetId[] memory slotTags,
            int256[] memory slotAssets,
            uint256 operationsBits,
            bool slotAllocationSuccess
        ) = processStrategySlotAllocation(
                fungibleAssetInfo,
                fungibleAssetFunding,
                holding,
                portfolio,
                strategyBits
            );

        if (!slotAllocationSuccess) {
            return false;
        }

        while (operationsBits != 0) {
            uint8 operationId = uint8(
                operationsBits & ((1 << LiquidationStrategyV1Impl.OPERATION_BIT_WIDTH) - 1)
            );
            operationsBits >>= LiquidationStrategyV1Impl.OPERATION_BIT_WIDTH;

            if (
                operationId == uint8(LiquidationStrategyV1Impl.Operations.SwapAll) ||
                operationId == uint8(LiquidationStrategyV1Impl.Operations.SwapUpTo)
            ) {
                (uint256 restBits, bool processOperationSuccess) = processSwapOperation(
                    exchangeFungibleOneForOne,
                    slotTags,
                    slotAssets,
                    operationId,
                    operationsBits
                );

                if (!processOperationSuccess) {
                    return false;
                }

                operationsBits = restBits;
            } else if (operationId == uint8(LiquidationStrategyV1Impl.Operations.MultiSwapAll)) {
                /* TODO NFT collateral is not fully implemented yet. */
                return false;
            } else {
                /* Should never happen, as `strategy.isValid()` does not allow this. */
                return false;
            }
        }

        /*
         * If we still have any debt left after running the liquidation strategy, then this
         * portfolio is underwater.
         */
        for (uint8 slotI = 0; slotI < slotCount; ++slotI) {
            if (slotAssets[slotI] < -DEBT_ROUNDING_ERROR) {
                return false;
            }
        }

        return true;
    }

    /**
     * @notice Runs a liquidation strategy for the given `portfolio`, removing all debt.
     *
     * This function call needs to be protected by an `!isLiquid()` check, to make sure that a
     * portfolio that is liquid is not accidentally liquidated.  While this function runs the
     * liquidation strategy, it does not use risk margins that `isLiquid()` checks, so we can not
     * tell if the risk level of the portfolio was exceeded or not during the actual liquidation.
     *
     * We could run the risk calculation code in parallel, essentially duplicating the `isLiquid()`
     * code in here as well.  It probably would not save that much gas, and as the liquidations
     * should not be frequent operations, I figured, this optimization is not worth it.  We would
     * still access all the same storage slots, though, we will duplicate a number of storage
     * reads.
     *
     * NOTE Call `updateFundingForAllPortfolioAssets()` before calling this function, as it needs up
     * to date state of all the portfolio asset balances.
     *
     * NOTE This function is the first candidate for being marked `external`, if, or when, `DosV1`
     * side exceeds maximum contract side.
     *
     * @dev As Solidity is not very generic, I had to encode the liquidation strategy encoding
     * inside of this method.
     */
    function liquidate(
        mapping(AssetIndex => FungibleAssetInfo) storage /* fungibleAssetInfo */,
        mapping(AssetIndex => NftAssetInfo) storage /* nftAssetInfo */,
        mapping(AssetIndex => FungibleAssetFunding) storage /* fungibleAssetFunding */,
        mapping(address => AssetHolding) storage /* holding */,
        mapping(AssetIndex => mapping(AssetIndex => IFungibleOneForOneSwap)) storage,
        /* exchangeFungibleOneForOne */
        address /* portfolio */,
        LiquidationStrategyV1 memory /* strategy */
    ) internal pure {
        require(false, "TODO: Implement liquidate()");
    }

    function getSwapAllAmount(
        mapping(AssetIndex => mapping(AssetIndex => IFungibleOneForOneSwap))
            storage exchangeFungibleOneForOne,
        AssetIndex from,
        int256 fromAmount,
        AssetIndex to
    ) internal view returns (int256) {
        IFungibleOneForOneSwap swapInfo = DosV1ExchangeRegistry.getIFungibleOneForOneSwap(
            exchangeFungibleOneForOne,
            from,
            to
        );
        int256 price = swapInfo.getOraclePrice(from, to);

        return (fromAmount * price) / FsMath.FIXED_POINT_SCALE;
    }

    /**
     * @dev Parses strategy slot allocation part, returning the rest of the strategy bits.
     */
    function processStrategySlotAllocation(
        mapping(AssetIndex => FungibleAssetInfo) storage fungibleAssetInfo,
        mapping(AssetIndex => FungibleAssetFunding) storage fungibleAssetFunding,
        mapping(address => AssetHolding) storage holding,
        address portfolio,
        uint256 strategyBits
    )
        internal
        view
        returns (
            uint8 slotCount,
            AssetId[] memory slotTags,
            int256[] memory slotAssets,
            uint256 /* operationsBits */,
            bool /* success */
        )
    {
        slotCount =
            2 +
            uint8(strategyBits & ((1 << LiquidationStrategyV1Impl.SLOT_COUNT_BIT_WIDTH) - 1));

        /*
         * Not sure if it is cheaper to just allocate a fixed width array with 9 elements, or to use
         * an array with a dynamic length.
         */
        slotTags = new AssetId[](slotCount);
        slotAssets = new int256[](slotCount);

        for (uint8 slotI = 0; slotI < slotCount; ++slotI) {
            uint16 rawAssetId = uint16(
                strategyBits & ((1 << LiquidationStrategyV1Impl.SLOT_ASSET_ID_BIT_WIDTH) - 1)
            );
            strategyBits >>= LiquidationStrategyV1Impl.SLOT_ASSET_ID_BIT_WIDTH;

            AssetId assetId = AssetIdImpl.fromRaw(rawAssetId);
            slotTags[slotI] = assetId;

            AssetIndex assetIdx = assetId.getIndex();

            if (assetId.getClass() == AssetIdClass.Fungible) {
                int256 asset = DosV1FungibleAssets.balanceOf(
                    holding,
                    fungibleAssetFunding,
                    assetIdx,
                    portfolio
                );

                FungibleAssetInfo storage info = fungibleAssetInfo[assetIdx];
                if (asset > 0) {
                    if (!info.useAsCollateral) {
                        return (slotCount, slotTags, slotAssets, strategyBits, false);
                    }

                    uint256 asset_ui = FsMath.safeCastToUnsigned(asset);
                    slotAssets[slotI] = FsMath.safeCastToSigned(
                        info.assessor.asCollateral(asset_ui)
                    );
                } else if (asset < 0) {
                    if (!info.useAsDebt) {
                        return (slotCount, slotTags, slotAssets, strategyBits, false);
                    }

                    uint256 asset_ui = FsMath.safeCastToUnsigned(-asset);
                    slotAssets[slotI] = -FsMath.safeCastToSigned(info.assessor.asDebt(asset_ui));
                } else {
                    /* asset == 0, `slotAssets[slotI]` is already 0. */
                }
            } else {
                require(false, "isLiquid(): NFT not implemented");
            }
        }

        return (slotCount, slotTags, slotAssets, strategyBits, true);
    }

    function processSwapOperation(
        mapping(AssetIndex => mapping(AssetIndex => IFungibleOneForOneSwap))
            storage exchangeFungibleOneForOne,
        AssetId[] memory slotTags,
        int256[] memory slotAssets,
        uint8 operationId,
        uint256 operationsBits
    ) internal view returns (uint256 /* restBits */, bool /* success */) {
        uint8 fromSlot = uint8(
            operationsBits & ((1 << LiquidationStrategyV1Impl.SLOT_REF_BIT_WIDTH) - 1)
        );
        uint8 toSlot = uint8(
            operationsBits & ((1 << LiquidationStrategyV1Impl.SLOT_REF_BIT_WIDTH) - 1)
        );

        int256 fromSlotAsset = slotAssets[fromSlot];
        if (fromSlotAsset < 0) {
            return (operationsBits, false);
        }

        if (fromSlotAsset == 0) {
            return (operationsBits, true);
        }

        AssetId from = slotTags[fromSlot];
        AssetId to = slotTags[toSlot];

        if (operationId == uint8(LiquidationStrategyV1Impl.Operations.SwapAll)) {
            slotAssets[toSlot] += getSwapAllAmount(
                exchangeFungibleOneForOne,
                from.getIndex(),
                fromSlotAsset,
                to.getIndex()
            );
            slotAssets[fromSlot] = 0;
        } else {
            /* `SwapUpTo` */
            int256 toSlotAsset = slotAssets[toSlot];

            if (toSlotAsset >= 0) {
                return (operationsBits, true);
            }

            (int256 usedFromAmount, int256 toChange) = getSwapUpToAmounts(
                exchangeFungibleOneForOne,
                from.getIndex(),
                fromSlotAsset,
                to.getIndex(),
                toSlotAsset
            );
            slotAssets[fromSlot] -= usedFromAmount;
            slotAssets[toSlot] += toChange;
        }

        return (operationsBits, true);
    }

    function getSwapUpToAmounts(
        mapping(AssetIndex => mapping(AssetIndex => IFungibleOneForOneSwap))
            storage exchangeFungibleOneForOne,
        AssetIndex from,
        int256 fromAmount,
        AssetIndex to,
        int256 toAsset
    ) internal view returns (int256 usedFromAmount, int256 toChange) {
        IFungibleOneForOneSwap swapInfo = DosV1ExchangeRegistry.getIFungibleOneForOneSwap(
            exchangeFungibleOneForOne,
            from,
            to
        );

        /*
         * We want price of `to` in units of `from`, as we want to know how much of the `from` asset
         * do we really need.
         */
        int256 priceOfToInFrom = swapInfo.getOraclePrice(to, from);
        int256 priceOfFromInTo = swapInfo.getOraclePrice(from, to);

        /* This is how much we need to cover all of the `to` debt. */
        int256 neededFromAmount = (-toAsset * priceOfToInFrom) / FsMath.FIXED_POINT_SCALE;

        usedFromAmount = fromAmount <= neededFromAmount ? fromAmount : neededFromAmount;
        toChange = (usedFromAmount * priceOfFromInTo) / FsMath.FIXED_POINT_SCALE;
    }
}
