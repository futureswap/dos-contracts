// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/**
 * @title Wraps a DOS asset id.
 */
type AssetId is uint16;

using AssetIdImpl for AssetId global;

/**
 * @title Class of an asset.
 *
 * @notice We often want to operate on assets in a uniform way, but often APIs and implementations
 * are different between ERC20 and ERC721.  In order to help deal with this duality, asset ids
 * are all `uint16`, but the value space is split between different classes, each covering a
 * different type of tokens.
 */
enum AssetIdClass {
    Fungible,
    Nft
}

/**
 * @title Asset index within a given `AssetIdClass`.
 */
type AssetIndex is uint16;

using AssetIndexImpl for AssetIndex global;

/**
 * @title Functions used with the `AssetId` type.
 */
library AssetIdImpl {
    /**
     * @notice Lower bits of the asset id is used to record asset class.
     *
     * Classes split the uint16 value space into disjoint sets, each numbering its own class of
     * assets.
     *
     * A value of `AssetIdClass` is stored in these bits.  While one bit is enough to store two
     * values defined by `AssetIdClass` at the moment, we reserve one more bit for future
     * extensibility.
     */
    uint16 public constant CLASS_BIT_WIDTH = 2;

    /**
     * @notice Part of the asset id that encodes the asset class.
     */
    uint16 public constant CLASS_BIT_MASK = (uint16(1) << CLASS_BIT_WIDTH) - 1;

    /**
     * @notice Constructs an `AssetId` from a `uint16`.  Not all `uint16` values are valid
     * `AssetId`s.  Reverts when `raw` is not a valid `AssetId`.
     */
    function fromRaw(uint16 raw) internal pure returns (AssetId id) {
        uint8 class = uint8(raw & 0x3);
        require(class <= uint8(type(AssetIdClass).max), "Invalid asset class field");
        id = AssetId.wrap(raw);
    }

    /**
     * @notice Checks if a `fromRaw()` call would succeed.
     */
    function isValidRaw(uint16 raw) internal pure returns (bool) {
        uint8 class = uint8(raw & 0x3);
        return class <= uint8(type(AssetIdClass).max);
    }

    /**
     * @notice Constructs an `AssetId` of the given class from an `index`.
     *
     * `index` is an arbitrary value, though it must fit into `uint16`, after `CLASS_BIT_WIDTH`
     * lower bits are already used to store the class.
     *
     * This function is used in order to populate asset id classes in a compact manner.
     */
    function fromClassAndIndex(
        AssetIdClass c,
        AssetIndex index
    ) internal pure returns (AssetId id) {
        index.requireValidIndex();
        uint16 rawIndex = AssetIndex.unwrap(index);
        id = AssetId.wrap((rawIndex << CLASS_BIT_WIDTH) | uint16(c));
    }

    function getClass(AssetId id) internal pure returns (AssetIdClass c) {
        c = AssetIdClass(AssetId.unwrap(id) & CLASS_BIT_MASK);
    }

    function getIndex(AssetId id) internal pure returns (AssetIndex index) {
        index = AssetIndex.wrap(AssetId.unwrap(id) >> CLASS_BIT_MASK);
    }
}

/**
 * @title Functions used with the `AssetIndex` type.
 */
library AssetIndexImpl {
    function requireValidIndex(AssetIndex self) internal pure {
        require(
            AssetIndex.unwrap(self) <= (type(uint16).max >> AssetIdImpl.CLASS_BIT_WIDTH),
            "index is too big"
        );
    }
}
