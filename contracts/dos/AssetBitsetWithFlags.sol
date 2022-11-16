// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../lib/FsUtils.sol";
import "../lib/FsMath.sol";

import "./AssetId.sol";

/**
 * @dev Number of flags stored in an `AssetBitsetWithFlags` value.
 *
 * These take space from the bitset, reducing the total number of asset identifiers that can be
 * stored.
 *
 * This value can not be easily changed after DOS is deployed.  So we may want to keep one or two
 * bits as a spare for future expansion.
 *
 * Individual bit values could differ, depending on the `AssetBitsetWithFlags` usage, but, at the
 * moment, the only set of flags is defined in `./PortfolioFlags.sol`.
 *
 * TODO Move these flags into the highest bits, and count them from the highest bit down.  This
 * constant then should specify how many bits are used by the flags as before.  It would make it
 * possible to add flags, while we still did not extend our bitset to use the highest bits.  As
 * asset ids are assigned from the lowest bits, we can then start with just 3 bits, instead of 4.
 */
uint8 constant ASSET_BITSET_FLAGS_COUNT = 4;

/**
 * @dev Flags stored by an `AssetBitsetWithFlags` instance are all stored in the first word of
 * the bitset array.  This is a mask that separates flags from the bitset data.
 */
uint256 constant ASSET_BITSET_FLAGS_MASK = (1 << ASSET_BITSET_FLAGS_COUNT) - 1;

/**
 * @dev As bitset uses a fixed memory storage, this is the maximum index value it can store.
 */
uint16 constant ASSET_BITSET_MAX_INDEX = 255 - ASSET_BITSET_FLAGS_COUNT;

/**
 * @title Encodes ids of a set of assets as a bitset, allowing for an efficient enumeration.
 *
 * @notice Also holds a number of flags, with meaning defined by the user of this type.  But
 * the number of the flags is fixed and is equal to `ASSET_BITSET_FLAGS_COUNT`.
 */
struct AssetBitsetWithFlags {
    uint256[1] words;
}

using AssetBitsetWithFlagsImpl for AssetBitsetWithFlags global;

/**
 * @title Functions used with the `AssetBitsetWithFlags` type.
 */
library AssetBitsetWithFlagsImpl {
    /**
     * @return assetIds All the asset idx stored in the bitset.
     */
    function getAssetIds(
        AssetBitsetWithFlags storage self
    ) internal view returns (AssetId[] memory assetIds) {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        uint256 bitset = self.words[0] >> ASSET_BITSET_FLAGS_COUNT;

        uint256 idCount = FsMath.bitCount(bitset);
        assetIds = new AssetId[](idCount);
        uint16 assetId = 0;
        uint16 idIndex = 0;

        /*
         * We know that the lowest `ASSET_BITSET_FLAGS_COUNT` are used for flags, so we can skip
         * them.
         */
        while (bitset != 0) {
            if ((bitset & 1) != 0) {
                assetIds[idIndex++] = AssetIdImpl.fromRaw(assetId);
            }

            bitset >>= 1;
            ++assetId;
        }

        FsUtils.Assert(idCount == idIndex);
    }

    function hasNoIds(AssetBitsetWithFlags storage self) internal view returns (bool) {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        uint256 bitset = self.words[0] >> ASSET_BITSET_FLAGS_COUNT;
        return bitset == 0;
    }

    /**
     * @notice Adds an asset id into the bitset.
     */
    function addId(AssetBitsetWithFlags storage self, AssetId id) internal {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        uint16 rawId = AssetId.unwrap(id);
        require(rawId < ASSET_BITSET_MAX_INDEX, "AssetBitset: max asset id is 251");

        self.words[0] |= 1 << (rawId + ASSET_BITSET_FLAGS_COUNT);
    }

    /**
     * @notice Returns just the bitset part.
     */
    function getBitset(
        AssetBitsetWithFlags storage self
    ) internal view returns (AssetBitsetMem memory) {
        FsUtils.Assert(self.words.length == 1);

        uint256 bitset = self.words[0] & ~ASSET_BITSET_FLAGS_MASK;
        return AssetBitsetMem([bitset]);
    }

    /**
     * @notice Removes an asset id from the bitset.
     */
    function removeId(AssetBitsetWithFlags storage self, AssetId id) internal {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        uint16 rawId = AssetId.unwrap(id);
        require(rawId < ASSET_BITSET_MAX_INDEX, "AssetBitset: max asset id is 251");

        self.words[0] &= ~(1 << (rawId + ASSET_BITSET_FLAGS_COUNT));
    }

    /**
     * @return flags stored in the `AssetBitsetWithFlags`, as a bitset.
     */
    function getFlags(AssetBitsetWithFlags storage self) internal view returns (uint8 flags) {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);
        /* `flags` can only hold 8 bits. */
        FsUtils.Assert(ASSET_BITSET_FLAGS_COUNT <= 8);

        flags = uint8(self.words[0] & ASSET_BITSET_FLAGS_MASK);
    }

    /**
     * @notice Sets the specified flag.
     *
     * `flag` should have only 1 bit set, and should be in the `ASSET_BITSET_FLAGS_MASK`.
     */
    function setFlag(AssetBitsetWithFlags storage self, uint8 flag) internal {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        /* `flag` should not contain more than 1 set bit.  It is an API contract. */
        FsUtils.Assert(flag & (flag - 1) == 0);

        require(flag & ~uint8(ASSET_BITSET_FLAGS_MASK) == 0, "Unsupported `flag`");

        self.words[0] |= flag;
    }

    /**
     * @notice Clears the specified flag.
     *
     * `flag` should have only 1 bit set, and should be in the `ASSET_BITSET_FLAGS_MASK`.
     */
    function clearFlag(AssetBitsetWithFlags storage self, uint8 flag) internal {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        /* `flag` should not contain more than 1 set bit.  It is an API contract. */
        FsUtils.Assert(flag & (flag - 1) == 0);

        require(flag & ~uint8(ASSET_BITSET_FLAGS_MASK) == 0, "Unsupported `flag`");

        self.words[0] &= ~flag;
    }

    /**
     * @notice Sets all the flags stored in the `AssetBitsetWithFlags` to the specified value.
     */
    function resetAllFlags(AssetBitsetWithFlags storage self, uint8 flags) internal {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);
        /* `flags` can only hold 8 bits. */
        FsUtils.Assert(ASSET_BITSET_FLAGS_COUNT <= 8);

        require(flags & uint8(~ASSET_BITSET_FLAGS_MASK) == 0, "Only support 4 flags");

        uint256 raw = self.words[0];
        raw &= ~ASSET_BITSET_FLAGS_MASK;
        raw |= uint256(flags);
        self.words[0] = raw;
    }
}

/**
 * @title Just the assets bitset portion of `AssetBitsetWithFlags`, designed to be stored in memory.
 *
 * @dev Bit layout is the same as in `AssetBitsetWithFlags`, allowing for easy comparison.
 */
struct AssetBitsetMem {
    uint256[1] words;
}

using AssetBitsetMemImpl for AssetBitsetMem global;

/**
 * @title Functions used with the `AssetBitsetMem` type.
 */
library AssetBitsetMemImpl {
    function hasNoIds(AssetBitsetMem memory self) internal pure returns (bool) {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        uint256 bitset = self.words[0] >> ASSET_BITSET_FLAGS_COUNT;
        return bitset == 0;
    }

    /**
     * @notice Adds an asset id into the bitset.
     */
    function addId(AssetBitsetMem memory self, AssetId id) internal pure {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        uint16 rawId = AssetId.unwrap(id);
        require(rawId < ASSET_BITSET_MAX_INDEX, "AssetBitset: max asset id is 251");

        self.words[0] |= 1 << (rawId + ASSET_BITSET_FLAGS_COUNT);
    }

    /**
     * @notice Removes an asset id from the bitset.
     */
    function removeId(AssetBitsetMem memory self, AssetId id) internal pure {
        /* We assume that there is only one word of data in the code below. */
        FsUtils.Assert(self.words.length == 1);

        uint16 rawId = AssetId.unwrap(id);
        require(rawId < ASSET_BITSET_MAX_INDEX, "AssetBitset: max asset id is 251");

        self.words[0] &= ~(1 << (rawId + ASSET_BITSET_FLAGS_COUNT));
    }

    /**
     * @notice Checks that this bitset contains all the assets mentioned in another bitset.
     */
    function containsAll(
        AssetBitsetMem memory self,
        AssetBitsetMem memory other
    ) internal pure returns (bool) {
        FsUtils.Assert(self.words.length == 1);

        return (other.words[0] & ~self.words[0]) == 0;
    }
}
