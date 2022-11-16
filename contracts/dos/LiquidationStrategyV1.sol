// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./AssetBitsetWithFlags.sol";
import "./AssetId.sol";

/**
 * @notice Liquidation strategy attached to a portfolio.
 *
 * = Overview =
 * A liquidation strategy describes exact steps that the DOS liquidation system is going to follow,
 * should the portfolio risk levels exceed the allowed levels.
 *
 * In DOS v1, unlike Euler (and other similar systems), liquidations are directly part of the system
 * itself.  There is no third party market for liquidations.  The idea is that this way DOS has more
 * control of the risk factors, and might support wider ranges of collateral/borrow ratios.  It
 * seems to be also useful for cases when we want to support more complex tokens, such as NFTs, that
 * may liquidate into a specific set of tokens, rather than having a liquid market.
 *
 * For now, a liquidation strategy is represented by a 256 bit word, that is encoding the strategy
 * as as described below.  Every portfolio that wants to hold debt should have an associated
 * liquidation strategy, that specifies how this debt can be liquidated in case the debt value
 * approaches the corresponding collateral value.
 *
 * A strategy is used to both asses the portfolio "health" or a risk level, as well as to actually
 * perform a liquidation.
 *
 * Portfolio that does not hold any debt does not need a liquidation strategy.  While one can still
 * specify a liquidation strategy for a portfolio with no debt, it is not going to be used until
 * debt is introduced.
 *
 * TODO We may want to consider a "default" liquidation strategy to be used in case a portfolio with
 * debt does not specify a liquidation strategy.  This should be a strict extension of the "no
 * default strategy" case.  So, we should be able to skip it for v1, and add it later, should we see
 * it is necessary.
 *
 * Strategy descriptions and execution environment are versions.  Below is a description of
 * strategies v1.
 *
 * = Strategy execution =
 *
 * When evaluating strategy, DOS allocates 16 "slots" that will hold assets.  Assets held by the
 * portfolio are assigned in to these slots.
 *
 * Slot rules:
 *
 *   1. A slot may contain both positive, as well as a negative amount of a given asset.
 *   2. When assets are assigned into slots, slots are tagged with the asset id, matching the asset
 *      held in this slot.
 *   3. Slot tags do not change for the duration of the strategy evaluation.
 *   4. Only asset that matches the slot tag can be added into the slot or removed from the slot.
 *
 * In order to borrow an asset, this asset has to be part of the portfolio liquidation strategy.
 * Or, alternatively, any borrowed asset should be mentioned in the portfolio liquidation strategy.
 *
 * Assets that are not borrowed can be part of the liquidation strategy, or may be omitted from it.
 *
 * A liquidation strategy first assigns assets into slots, and then describes a sequence of
 * exchanges that convert assets from one type into another, moving them between corresponding
 * slots.
 *
 * In order for the portfolio to be liquid, after a strategy if fully executed, all slots have to
 * have zero or positive values.  If any of the slots contain a negative value, portfolio can be
 * liquidated.
 *
 * When portfolio is liquidated, the liquidation system will follow the same steps.  As during the
 * liquidity assessment collateral and borrowed amounts are adjusted, during the liquidation process
 * end result should be able to liquidate all debt, leaving portfolio with some assets still.
 *
 * If that turned out to be impossible, portfolio is locked and marked as bankrupt.  It is still
 * possible to try to liquidate it.  But it may require manual operations.  TODO We should define
 * this process better.
 *
 * == Strategy setup ==
 *
 * Strategy lists all participating assets in sequence.  They are assigned into the available slots
 * in sequence.  Each asset uses one slot, and a strategy can not use more than than 16 assets, but
 * it may use less.
 *
 * When an asset is assigned into a slot, slot is given a tag that matches the asset id and an
 * amount is assigned into the slot.  For assets held by the portfolio, assigned value is
 * positive, and for assets borrowed by the portfolio the assigned value is negative.  Amount
 * assigned into a slot is equal to the amount of asset held by the portfolio, adjusted by a risk
 * factor.  Risk factor adjustment is performed by "asset assessors", see
 * `./interfaces/ITokenAssessor.sol`, for example.
 *
 * For collateral, assessors will decrease the amount assigned into the slots, and for borrows,
 * assessors will increase the absolute value of the amount, still keeping it negative.
 *
 * A strategy may assign an asset into a slot that is not held by the portfolio.  Effectively
 * assigning a tag into a slot.  It can be used in slot operations later.  Assigned value will be 0
 * in this case.
 *
 * It is an error if by the end of the strategy setup any of the assets borrowed by the portfolio is
 * not assigned into a slot.
 *
 * == Strategy operations ==
 *
 * Operations that convert between two token types, use liquidity system oracles to determine the
 * conversion ratio.  When strategy is executed, conversion ration is defined by the market where
 * the swap operation happens.
 *
 * 1. "SwapAll"
 *
 *    Converts all tokens in slot A into asset of slot B and add them into slot B.  Slot A now has a
 *    value of 0.
 *
 *    When Slot A value before the conversion is:
 *
 *      - positive: conversion happens as described.
 *
 *      - zero: operation is ignored.
 *
 *      - negative: strategy fails.
 *
 * 2. "SwapUpTo"
 *
 *    Convert `x` tokens in slot A into asset of slot B and add them into slot B.
 *
 *    If slot B has a positive or zero value before this operation, nothing happens.  If slot B has
 *    a negative value before this operation, `x` is chosen to be the minimum of:
 *
 *      - abs(slot B amount) / conversion rate
 *
 *      - all of the slot A amount
 *
 * 3. "MultiSwapAll"
 *
 *    Certain tokens, most likely NFTs, may represent a combination of other tokens.  An example
 *    would be a Uniswap v3 LP NFT token.  Those may not be swappable into anything, but the
 *    underlying tokens.  Curve LP tokens is another example of a "complex token", though the
 *    swapping operation for them has additional parameters that determine which combination of the
 *    underlying tokens is produced.
 *
 *    `MultiSwapAll` is a swap that converts all tokens from slot A into more than one target slots,
 *    that have to match underlying token types.
 *
 * TODO We may need to introduce additional operations.  For example, if we decide to encode
 * conversion rations for Curve LP tokens.
 *
 * = Strategy encoding =
 *
 * Strategy is encoded into a 256 bit word.  A strategy that can not be encoded into 256 bits is
 * incorrect for `LiquidationStrategyV1`.
 *
 * As a special case, a default value of a 256 bit word of 0 is interpreted as an "empty"
 * liquidation strategy - one that does not list any operations and does not allocate any slots.
 * This special case is considered as a valid strategy, in addition to the encoding presented below.
 *
 * It is a bit easier to describe a decoding process.  Encoding is valid as long as decoding
 * produces a valid strategy.  To decode the strategy, assign its value into a variable `v` and
 * process `v` by taking lower bits, and processing them as defined below.  After taking `N` bits
 * form `v`, shift `v` right by `N` bits:
 *
 * 1. Take 1 bit, and treat it as the `strategy version`. `0b0` means this is a v1 strategy.  If it
 *    is `0b1`, this strategy is invalid.
 *
 * 2. Take 3 bits, and treat them as a `slotCount`.  Add `2` to `slotCount`.  This is the number of
 *    slots this strategy is going to use.
 *
 *    Repeat `slotCount` times:
 *
 *      2.1. Take 16 bits, and assign them into `assetId`, as specified in `AssetId.fromRaw()`.  It
 *        is invalid to use an invalid `AssetId` encoding.
 *
 *      2.2. Assign `assetId` as a tag for the next available slot.
 *
 *        Assign amount of the owned asset into the slot, using a risk adjusted amount, as produced
 *        by the corresponding assessor.
 *
 *        For NFTs just assign the number of owned tokens.  Risk adjustment for NFTs is done during
 *        the `MultiSwapAll` operation.
 *
 * 3. Until `v` is non-zero:
 *
 *      3.1. Take the next 3 bits as an `operationId`.
 *
 *      3.2. When `operationId` is `0b000`:
 *
 *          3.2.1. Take the next 4 bits as `fromSlot`.
 *
 *          3.2.2. Take the next 4 bits as `toSlot`.
 *
 *          3.2.3. Perform the `SwapAll` operation between `fromSlot` and `toSlot`, as described
 *            above.
 *
 *      3.3. When `operationId` is `0b001`:
 *
 *          3.3.1. Take the next 4 bits as `fromSlot`.
 *
 *          3.3.2. Take the next 4 bits as `toSlot`.
 *
 *          3.3.3. Perform the `SwapUpTo` operation between `fromSlot` and `toSlot`, as described
 *            above.
 *
 *      3.4. When `operationId` is `0b010`:
 *
 *          3.4.1. Take the next 4 bits as `fromSlot`.
 *
 *          3.4.2. Take the next 3 bits as a `toSlotCount` value.  Add 1 to `toSlotCount`.
 *
 *          3.4.3. Create an empty `toSlots` list and perform `toSlotCount` times:
 *
 *              3.4.3.1. Take the next 4 bits as a `toSlot` value.  Append it into the `toSlots`
 *                list.
 *
 *          3.4.4. Perform the `MultiSwapAll` operation between `fromSlot` and `toSlots`.  Strategy
 *            fails if `toSlots` has to match the source asset definition, provided by the
 *            registered asset description.
 *
 *            TODO Link to the function that describes complex assets in the `IDosAssetRegistryV1`
 *            and/or a matching assessor or another interface that describes complex assets.
 *
 *      3.5. Any other `operationId` value is invalid.
 *
 * = Notes =
 *
 * == Space allocation ==
 *
 * Usage of bits in a v1 strategy encoding:
 *
 * 0:
 *      version bit
 *
 * 1-35 to 1-163:
 *      slot tags
 *      min is `3 + 2 * 16 = 35`, max is `3 + 9*16 = 147`
 *
 * 36-255 to 148-255:
 *      operations
 *          SwapAll: `3 + 4 + 4 = 11`
 *          SwapUpTo: `3 + 4 + 4 = 11`
 *          MultiSwapAll: min is `3 + 4 + 3 + 4 = 14`, max is `3 + 4 + 3 + 8 * 4 = 42`
 *
 *      With 9 slots, operations have 108 bits of space.
 *
 *      108 bits is enough for up to 9 `SwapAll` or `SwapUpTo` operations, covering 8 swaps needed
 *      to consolidate 9 slots into 1.
 *
 *      An `MultiSwapAll` that targets all 9 slots (1 source and 8 destination) is 42 bits, taking
 *      almost half the operations space.  It will then need 7 swaps, for consolidating the unpacked
 *      assets, and that is `42 + 7*11 = 119`.
 *
 *      But an `MultiSwapAll` for 8 slots (1 source and 7 destination) is 38 bits, and that fits
 *      with a subsequent 6 swaps: `38 + 6*11 = 104`.
 *
 * == AssetId encoding ==
 *
 * An interesting alternative is to use several different encodings for asset ids, in order to
 * optimize based on the fact that ids are not evenly distributed.  We are more likely to use a
 * limited number of assets, considering each pair requires a valid trading pool for
 * liquidations, I would imagine, it would be a very long time before we cross an asset id of
 * 256, that can be encoded in 8 bits instead of 16.
 *
 * We use variable length encoding for asset ids in the slot setup part of the strategy, encoding
 * IDs from 0 to 255 using 9 bits, and IDs between 256 and 65,536 using 17 bits.  As slot setup
 * is the largest part of the strategy encoding, it can save space.
 *
 * It both complicates the encoding format and, considering that 256 bits still provide enough space
 * to encode swap operations for all 10 slots, it is unclear what the practical benefit would be.
 * Maybe if we would add more operations and some of them would require more bits for storage,
 * it could be useful.  Or if we would allow more slots and more than 1 word for strategy
 * storage.  At the same time, if we extend the strategy storage, we may instead consider encoding
 * strategies as contracts as described in the "Alternative representation" note below.
 *
 * == Alternative representation ==
 *
 * If we store more than 1 word of strategy data, it seems to be cheaper to have a contract
 * deployed, that has a view function returning the strategy data in memory.  And the strategy would
 * be just directly encoded inside the function as constant assigned into the returned value.  If
 * this is the case, a strategy would be an address of a contract, rather than the strategy value
 * itself.
 *
 * Reading 1 word of storage is 2,100 units of gas.  Calling a function is 2,600 units of gas.
 * Producing 1 word of value encoded as a constant in code and storing it in memory would be around
 * 6 units of gas.
 *
 * As we expect there to be a rather limited amount of liquidation strategies used by most users,
 * extra overhead of deploying a contract could be worth it.  I did not check it, so this design
 * needs to be checked first, to see if it really is saving gas.
 */
struct LiquidationStrategyV1 {
    uint256[1] words;
}

using LiquidationStrategyV1Impl for LiquidationStrategyV1 global;

library LiquidationStrategyV1Impl {
    uint256 public constant VERSION_BIT_WIDTH = 1;

    uint256 public constant VERSION = 0;

    uint256 public constant SLOT_COUNT_BIT_WIDTH = 3;

    uint256 public constant MAX_SLOT_COUNT = 9;

    uint256 public constant SLOT_ASSET_ID_BIT_WIDTH = 16;

    uint256 public constant OPERATION_BIT_WIDTH = 3;

    uint256 public constant SLOT_REF_BIT_WIDTH = 4;

    uint256 public constant MULTI_SWAP_ALL_TARGET_SLOT_COUNT_BIT_WIDTH = 3;

    enum Operations {
        SwapAll,
        SwapUpTo,
        MultiSwapAll
    }

    /**
     * @notice A helper that treats a `uint256` as a strategy encoding, calling `isValid()` to check
     * for syntax errors.
     */
    function fromRaw(uint256 bits) internal pure returns (LiquidationStrategyV1 memory) {
        LiquidationStrategyV1 memory strategy = LiquidationStrategyV1({ words: [bits] });
        require(strategy.isValid(), "Invalid strategy");
        return strategy;
    }

    /**
     * @notice Performs a syntactic check of a strategy definition.
     *
     * Returns false if strategy encoding is incorrect, irrespective of the tokens registered in DOS
     * or assets in control of the portfolio this strategy is for.
     */
    function isValid(LiquidationStrategyV1 memory self) internal pure returns (bool) {
        FsUtils.Assert(self.words.length == 1);

        /*
         * The following does not need any range checks from the compiler, as the whole purpose of
         * this code is to verify ranges, and all the checks are explicit.  It could save a bit of
         * gas if we disable the compiler generated ones?
         */
        unchecked {
            uint256 bits = self.words[0];

            uint256 version = bits & ((1 << VERSION_BIT_WIDTH) - 1);
            bits >>= VERSION_BIT_WIDTH;
            if (version != VERSION) {
                return false;
            }

            FsUtils.Assert(SLOT_COUNT_BIT_WIDTH < 8);
            uint8 slotCount = 2 + uint8(bits & ((1 << SLOT_COUNT_BIT_WIDTH) - 1));
            bits >>= SLOT_COUNT_BIT_WIDTH;
            if (slotCount > MAX_SLOT_COUNT) {
                return false;
            }

            for (uint8 slotI = 0; slotI < slotCount; ++slotI) {
                uint16 rawAssetId = uint16(bits & ((1 << SLOT_ASSET_ID_BIT_WIDTH) - 1));
                bits >>= SLOT_ASSET_ID_BIT_WIDTH;

                if (!AssetIdImpl.isValidRaw(rawAssetId)) {
                    return false;
                }
            }

            FsUtils.Assert(OPERATION_BIT_WIDTH < 8);
            FsUtils.Assert(SLOT_REF_BIT_WIDTH < 8);
            FsUtils.Assert(MULTI_SWAP_ALL_TARGET_SLOT_COUNT_BIT_WIDTH < 8);
            while (bits != 0) {
                uint8 operationId = uint8(bits & ((1 << OPERATION_BIT_WIDTH) - 1));
                bits >>= OPERATION_BIT_WIDTH;

                if (
                    operationId == uint8(Operations.SwapAll) ||
                    operationId == uint8(Operations.SwapUpTo)
                ) {
                    uint8 slotA = uint8(bits & ((1 << SLOT_REF_BIT_WIDTH) - 1));
                    uint8 slotB = uint8(bits & ((1 << SLOT_REF_BIT_WIDTH) - 1));
                    if (slotA >= MAX_SLOT_COUNT || slotB >= MAX_SLOT_COUNT || slotA == slotB) {
                        return false;
                    }
                } else if (operationId == uint8(Operations.MultiSwapAll)) {
                    uint8 slotA = uint8(bits & ((1 << SLOT_REF_BIT_WIDTH) - 1));
                    if (slotA >= MAX_SLOT_COUNT) {
                        return false;
                    }

                    uint8 targetSlotCount = 1 +
                        uint8(bits & ((1 << MULTI_SWAP_ALL_TARGET_SLOT_COUNT_BIT_WIDTH) - 1));
                    if (targetSlotCount > MAX_SLOT_COUNT) {
                        return false;
                    }

                    /* All targeted slots must be different, and they can not target `slotA`. */
                    uint16 usedSlots = uint16(1) << slotA;
                    for (uint8 targetSlotI = 0; targetSlotI < targetSlotCount; ++targetSlotI) {
                        uint8 targetSlot = uint8(bits & ((1 << SLOT_REF_BIT_WIDTH) - 1));
                        if (targetSlot >= MAX_SLOT_COUNT || usedSlots & (1 << targetSlot) != 0) {
                            return false;
                        }
                        usedSlots |= uint16(1) << targetSlot;
                    }
                } else {
                    /* Unexpected `operationId`. */
                    return false;
                }
            }
        }

        return true;
    }

    /**
     * @notice Extracts a bitset of all the asset IDs this strategy targets.
     *
     * Used in the verification logic when checking that a strategy mentions all the debt assets.
     *
     * NOTE Requires `self` to be verified with `isValid()`.
     */
    function getReferencedAssets(
        LiquidationStrategyV1 memory self
    ) internal pure returns (AssetBitsetMem memory bitset) {
        FsUtils.Assert(self.words.length == 1);

        unchecked {
            uint256 bits = self.words[0];

            bits >>= VERSION_BIT_WIDTH;
            uint8 slotCount = 2 + uint8(bits & ((1 << SLOT_COUNT_BIT_WIDTH) - 1));

            for (uint8 slotI = 0; slotI < slotCount; ++slotI) {
                uint16 rawAssetId = uint16(bits & ((1 << SLOT_ASSET_ID_BIT_WIDTH) - 1));
                bits >>= SLOT_ASSET_ID_BIT_WIDTH;

                AssetId slotId = AssetIdImpl.fromRaw(rawAssetId);
                bitset.addId(slotId);
            }
        }

        return bitset;
    }
}
