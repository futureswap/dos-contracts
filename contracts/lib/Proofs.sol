// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {FsUtils} from "./FsUtils.sol";

type BytesView is uint256;

type RLPItem is uint256;

type RLPIterator is uint256;

library BytesViewLib {
    uint256 private constant WORD_SIZE = 32;

    error OutOfBounds();
    error InvalidScalarEncoding();

    function mload(uint256 ptr) internal pure returns (bytes32 res) {
        assembly {
            res := mload(ptr)
        }
    }

    function mstore(uint256 ptr, bytes32 value) internal pure {
        assembly {
            mstore(ptr, value)
        }
    }

    function memPtr(bytes memory b) internal pure returns (uint256 res) {
        assembly {
            res := add(b, 0x20)
        }
    }

    function mCopy(uint256 src, uint256 dest, uint256 len) internal pure {
        unchecked {
            // copy as many word sizes as possible
            for (; len >= WORD_SIZE; len -= WORD_SIZE) {
                mstore(dest, mload(src));

                src += WORD_SIZE;
                dest += WORD_SIZE;
            }
            if (len == 0) return;
            // left over bytes. Mask is used to remove unwanted bytes from the word
            FsUtils.Assert(len > 0 && len < WORD_SIZE);
            bytes32 mask = bytes32((1 << ((WORD_SIZE - len) << 3)) - 1);
            bytes32 srcpart = mload(src) & ~mask; // zero out src
            bytes32 destpart = mload(dest) & mask; // retrieve the bytes
            mstore(dest, destpart | srcpart);
        }
    }

    function empty() internal pure returns (BytesView) {
        return BytesView.wrap(0);
    }

    function wrap(uint256 ptr, uint256 len) internal pure returns (BytesView) {
        return BytesView.wrap((ptr << 128) | len);
    }

    function length(BytesView b) internal pure returns (uint256) {
        return BytesView.unwrap(b) & type(uint128).max;
    }

    function memPtr(BytesView b) private pure returns (uint256) {
        return BytesView.unwrap(b) >> 128;
    }

    function fromBytes(bytes memory b) internal pure returns (BytesView) {
        return BytesViewLib.wrap(memPtr(b), b.length);
    }

    function toBytes(BytesView b) internal pure returns (bytes memory res) {
        uint len = length(b);
        res = new bytes(len);
        mCopy(memPtr(b), BytesViewLib.memPtr(res), len);
    }

    function unsafeLoadUInt8(BytesView b, uint256 offset) internal pure returns (uint256) {
        unchecked {
            return uint256(mload(memPtr(b) + offset)) >> 248;
        }
    }

    function loadUInt8(BytesView b, uint256 offset) internal pure returns (uint256) {
        if (offset >= length(b)) revert OutOfBounds();
        return unsafeLoadUInt8(b, offset);
    }

    function unsafeLoadBytes32(BytesView b, uint256 offset) internal pure returns (bytes32) {
        unchecked {
            return mload(memPtr(b) + offset);
        }
    }

    function loadBytes32(BytesView b, uint256 offset) internal pure returns (bytes32) {
        if (offset + 32 > length(b)) revert OutOfBounds();
        return unsafeLoadBytes32(b, offset);
    }

    // Decode scalar value (non-negative integer) as described in yellow paper
    function decodeScalar(BytesView b) internal pure returns (uint256) {
        uint len = length(b);
        if (len == 0) return 0;
        bytes32 data = unsafeLoadBytes32(b, 0);
        if (data[0] == 0) revert InvalidScalarEncoding();
        return uint256(data >> ((WORD_SIZE - len) << 3)); // reverts if len > 32
    }

    function unsafeSlice(
        BytesView b,
        uint256 offset,
        uint256 len
    ) internal pure returns (BytesView) {
        unchecked {
            FsUtils.Assert(offset + len <= length(b));
            return BytesViewLib.wrap(memPtr(b) + offset, len);
        }
    }

    function slice(BytesView b, uint256 offset, uint256 len) internal pure returns (BytesView) {
        if (offset + len > length(b)) revert OutOfBounds();
        return unsafeSlice(b, offset, len);
    }

    function unsafeSkip(BytesView b, uint256 offset) internal pure returns (BytesView) {
        unchecked {
            FsUtils.Assert(offset <= length(b));
            return BytesViewLib.wrap(memPtr(b) + offset, length(b) - offset);
        }
    }

    function skip(BytesView b, uint256 offset) internal pure returns (BytesView) {
        if (offset > length(b)) revert OutOfBounds();
        return unsafeSkip(b, offset);
    }

    function keccak(BytesView b) internal pure returns (bytes32 res) {
        uint256 ptr = memPtr(b);
        uint256 len = length(b);
        assembly {
            res := keccak256(ptr, len)
        }
    }
}

library RLP {
    using BytesViewLib for BytesView;
    using RLP for RLPItem;
    using RLP for RLPIterator;

    error InvalidRLPItem();
    error ItemIsNotList();
    error ItemIsNotBytes();

    function isList(RLPItem item) internal pure returns (bool) {
        FsUtils.Assert(buffer(item).length() > 0);
        return buffer(item).unsafeLoadUInt8(0) >= 0xc0;
    }

    function isBytes(RLPItem item) internal pure returns (bool) {
        return !isList(item);
    }

    function requireRLPItem(BytesView b) internal pure returns (RLPItem) {
        uint256 len = rlpLen(b);
        if (len != b.length()) revert InvalidRLPItem();
        return asRLPItem(b);
    }

    function requireBytesView(RLPItem item) internal pure returns (BytesView) {
        if (!isBytes(item)) revert ItemIsNotBytes();
        return toBytesView(item);
    }

    function toBytesView(RLPItem item) internal pure returns (BytesView) {
        unchecked {
            FsUtils.Assert(isBytes(item));
            uint256 tag = buffer(item).unsafeLoadUInt8(0);
            if (tag < 0x80) {
                return buffer(item).unsafeSlice(0, 1);
            } else if (tag < 0xb8) {
                return buffer(item).unsafeSlice(1, tag - 0x80);
            } else {
                uint256 lenLen = tag - 0xb7;
                uint256 len = uint256(buffer(item).unsafeLoadBytes32(1)) >> (8 * (32 - lenLen));
                return buffer(item).unsafeSlice(1 + lenLen, len);
            }
        }
    }

    function requireRLPItemIterator(RLPItem item) internal pure returns (RLPIterator) {
        if (!isList(item)) revert ItemIsNotList();
        return toRLPItemIterator(item);
    }

    function toRLPItemIterator(RLPItem item) internal pure returns (RLPIterator) {
        unchecked {
            FsUtils.Assert(isList(item));
            uint256 len = 0;
            uint256 lenLen = 0;
            uint256 initial = buffer(item).unsafeLoadUInt8(0);
            if (initial < 0xf8) {
                len = initial - 0xc0;
            } else {
                lenLen = initial - 0xf7;
                len = uint256(buffer(item).unsafeLoadBytes32(1)) >> (8 * (32 - lenLen));
            }
            FsUtils.Assert(len + lenLen + 1 == buffer(item).length()); // , "RLP: Invalid length it");
            BytesView b = buffer(item).unsafeSlice(1 + lenLen, len);
            return RLPIterator.wrap(BytesView.unwrap(b));
        }
    }

    function unsafeNext(RLPIterator it) internal pure returns (RLPItem item, RLPIterator nextIt) {
        FsUtils.Assert(buffer(it).length() > 0); // "RLP: Iterator out of bounds");
        uint256 len = rlpLen(buffer(it));
        item = asRLPItem(buffer(it).unsafeSlice(0, len));
        nextIt = asRLPIterator(buffer(it).unsafeSkip(len));
    }

    function next(RLPIterator it) internal pure returns (RLPItem item, RLPIterator nextIt) {
        FsUtils.Assert(buffer(it).length() > 0); // "RLP: Iterator out of bounds");
        uint256 len = rlpLen(buffer(it));
        item = asRLPItem(buffer(it).slice(0, len));
        nextIt = asRLPIterator(buffer(it).unsafeSkip(len));
    }

    function unsafeSkipNext(RLPIterator it) internal pure returns (RLPIterator nextIt) {
        FsUtils.Assert(buffer(it).length() > 0); // "RLP: Iterator out of bounds");
        uint256 len = rlpLen(buffer(it));
        nextIt = asRLPIterator(buffer(it).unsafeSkip(len));
    }

    function hasNext(RLPIterator it) internal pure returns (bool) {
        return buffer(it).length() > 0;
    }

    function length(RLPItem item) internal pure returns (uint256) {
        return buffer(item).length();
    }

    function keccak(RLPItem item) internal pure returns (bytes32 res) {
        return buffer(item).keccak();
    }

    function buffer(RLPItem item) private pure returns (BytesView) {
        return BytesView.wrap(RLPItem.unwrap(item));
    }

    function buffer(RLPIterator it) private pure returns (BytesView) {
        return BytesView.wrap(RLPIterator.unwrap(it));
    }

    function rlpLen(BytesView b) private pure returns (uint256) {
        unchecked {
            FsUtils.Assert(b.length() > 0); // "RLP: Empty buffer");
            uint256 len = 0;
            uint256 lenLen = 0;
            uint256 initial = b.unsafeLoadUInt8(0);
            if (initial < 0x80) {
                return 1;
                // nothing
            } else if (initial < 0xb8) {
                return 1 + initial - 0x80;
            } else if (initial < 0xc0) {
                lenLen = initial - 0xb7;
                // Continue below
            } else if (initial < 0xf8) {
                return 1 + initial - 0xc0;
            } else {
                lenLen = initial - 0xf7;
                // Continue below
            }
            len = uint256(b.unsafeLoadBytes32(1)) >> (8 * (32 - lenLen));
            return len + lenLen + 1;
        }
    }

    function asRLPItem(BytesView b) private pure returns (RLPItem) {
        return RLPItem.wrap(BytesView.unwrap(b));
    }

    function asRLPIterator(BytesView b) private pure returns (RLPIterator) {
        return RLPIterator.wrap(BytesView.unwrap(b));
    }
}

library TrieLib {
    using BytesViewLib for BytesView;
    using RLP for RLPItem;
    using RLP for RLPIterator;

    // RLP("") = "0x80"
    bytes32 private constant EMPTY_TRIE_HASH =
        0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421;

    error KeyTooLong();
    error ProofTooLong();
    error IncompleteProof();
    error InvalidProof();

    /// @dev Verify a proof of a key in a Merkle Patricia Trie, revert if the proof is invalid.
    /// @param key The key to verify.
    /// @param root The root hash of the trie. This is assumed to be from a trusted source (e.g. a block header)
    ///        and therefore represents a structurally valid tree.
    /// @param proof The proof of the key. Untrusted data.
    /// @return The value of the key if the key exists or empty if key doesn't exist.
    /// @notice The stored value is encoded as RLP and thus never empty, so empty means the key doesn't exist.
    ///         This is reasonably optimized for gas, it's around 25k gas per proof depending on the depth.
    function verify(
        bytes32 key,
        uint256 keyLength,
        bytes32 root,
        bytes memory proof
    ) internal pure returns (BytesView) {
        unchecked {
            if (keyLength > 32) revert KeyTooLong();
            uint256 nibblesLeft = keyLength * 2;
            RLPItem rlpListItem = RLP.requireRLPItem(BytesViewLib.fromBytes(proof));
            RLPIterator listIt = rlpListItem.requireRLPItemIterator();
            RLPItem child0;
            RLPItem child1;
            BytesView res = BytesViewLib.empty();
            while (listIt.hasNext()) {
                if (root == EMPTY_TRIE_HASH) revert ProofTooLong();
                RLPItem rlpItem;
                (rlpItem, listIt) = listIt.next();
                if (rlpItem.keccak() != root) revert InvalidProof();
                // Because it passed this cryptographic check, we know that the rlpItem is a well-formed
                // RLP encoded MPT node.

                RLPIterator childIt = rlpItem.toRLPItemIterator();
                FsUtils.Assert(childIt.hasNext());
                (child0, childIt) = childIt.unsafeNext();
                FsUtils.Assert(childIt.hasNext());
                (child1, childIt) = childIt.unsafeNext();

                RLPItem nextRoot;
                root = EMPTY_TRIE_HASH; // sentinel indicating end of proof
                if (childIt.hasNext()) {
                    // Branch node
                    uint nibble = nibblesLeft == 0 ? 16 : uint256(key) >> 252;

                    if (nibble < 2) {
                        nextRoot = nibble == 0 ? child0 : child1;
                    } else {
                        for (uint i = 2; i < nibble; i++) {
                            FsUtils.Assert(childIt.hasNext());
                            childIt = childIt.unsafeSkipNext();
                        }
                        FsUtils.Assert(childIt.hasNext());
                        (nextRoot, childIt) = childIt.unsafeNext();
                    }

                    if (nibblesLeft == 0) {
                        res = nextRoot.toBytesView();
                        continue;
                    }
                    key <<= 4;
                    nibblesLeft -= 1;
                } else {
                    // Extension or leaf nodes
                    BytesView partialKey = child0.toBytesView();
                    FsUtils.Assert(partialKey.length() > 0 && partialKey.length() <= 33);
                    uint256 tag = partialKey.unsafeLoadUInt8(0);
                    bytes32 partialKeyBytes = partialKey.unsafeLoadBytes32(1);
                    uint partialKeyLength = 2 * partialKey.length() - 2;
                    // Two most significant bits must be zero for a valid hex-prefix string
                    FsUtils.Assert(tag < 64);
                    if ((tag & 16) != 0) {
                        // Odd number of nibbles, low order nibble of tag is first nibble of key
                        partialKeyBytes = (partialKeyBytes >> 4) | bytes32(tag << 252);
                        partialKeyLength += 1;
                    } else {
                        // Even number of nibbles, low order nibble of tag is zero
                        FsUtils.Assert(tag & 0xF == 0);
                    }
                    // For a valid MPT, the partial key must be at least one nibble and will
                    // never be more then 32 bytes.
                    FsUtils.Assert(partialKeyLength > 0 && partialKeyLength <= 64);
                    // The partialKey must be a prefix of key
                    if (
                        partialKeyLength > nibblesLeft ||
                        (partialKeyBytes ^ key) >> (256 - 4 * partialKeyLength) != 0
                    ) {
                        // The partial key is not a prefix of the key, so the key doesn't exist
                        continue;
                    }
                    nibblesLeft -= partialKeyLength;
                    key <<= 4 * partialKeyLength;

                    if ((tag & 32) != 0) {
                        // Leaf node
                        if (nibblesLeft == 0) {
                            res = child1.toBytesView();
                        }
                        continue;
                    }
                    nextRoot = child1;
                }
                // Proof continue with child node
                if (nextRoot.isBytes()) {
                    BytesView childBytes = nextRoot.toBytesView();
                    if (childBytes.length() == 0) {
                        continue;
                    }
                    FsUtils.Assert(childBytes.length() == 32); // Invalid child hash
                    root = childBytes.unsafeLoadBytes32(0);
                } else {
                    FsUtils.Assert(nextRoot.isList());
                    // The next node is embedded directly in this node
                    // as it's RLP length is less than 32 bytes.
                    FsUtils.Assert(nextRoot.length() < 32); // "IP: child node too long";
                    root = nextRoot.keccak();
                }
            }
            if (root != EMPTY_TRIE_HASH) revert IncompleteProof();
            return res;
        }
    }

    function proofAccount(
        address account,
        bytes32 stateRoot,
        bytes memory proof
    )
        internal
        pure
        returns (uint256 nonce, uint256 balance, bytes32 storageHash, bytes32 codeHash)
    {
        BytesView accountRLP = verify(keccak256(abi.encodePacked(account)), 32, stateRoot, proof);
        if (accountRLP.length() == 0) {
            return (0, 0, bytes32(0), bytes32(0));
        }
        RLPItem item = RLP.requireRLPItem(accountRLP);
        RLPIterator it = item.requireRLPItemIterator();
        FsUtils.Assert(it.hasNext());
        (item, it) = it.next();
        nonce = item.requireBytesView().decodeScalar();
        FsUtils.Assert(it.hasNext());
        (item, it) = it.next();
        balance = item.requireBytesView().decodeScalar();
        FsUtils.Assert(it.hasNext());
        (item, it) = it.next();
        storageHash = item.requireBytesView().unsafeLoadBytes32(0);
        FsUtils.Assert(it.hasNext());
        (item, it) = it.next();
        codeHash = item.requireBytesView().unsafeLoadBytes32(0);
    }

    function proofStorageAt(
        bytes32 slot,
        bytes32 storageHash,
        bytes memory proof
    ) internal pure returns (uint256) {
        BytesView valueRLP = verify(keccak256(abi.encodePacked(slot)), 32, storageHash, proof);
        if (valueRLP.length() == 0) {
            return 0;
        }
        RLPItem item = RLP.requireRLPItem(valueRLP);
        BytesView storedAmount = item.requireBytesView();
        return storedAmount.decodeScalar();
    }
}
