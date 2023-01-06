// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./FsUtils.sol";

type BytesView is uint256;

type RLPItem is uint256;

type RLPIterator is uint256;

library BytesViewLib {
    uint256 private constant WORD_SIZE = 32;

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

    function bytesFromBytes32(bytes32 x) internal pure returns (bytes memory res) {
        res = new bytes(32);
        mstore(memPtr(res), x);
    }

    function mCopy(uint256 src, uint256 dest, uint256 len) internal pure {
        if (len == 0) return;
        unchecked {
            // copy as many word sizes as possible
            for (; len > WORD_SIZE; len -= WORD_SIZE) {
                mstore(dest, mload(src));

                src += WORD_SIZE;
                dest += WORD_SIZE;
            }

            // left over bytes. Mask is used to remove unwanted bytes from the word
            FsUtils.Assert(len > 0 && len <= WORD_SIZE);
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

    function toBytesView(bytes memory b) internal pure returns (BytesView) {
        return BytesViewLib.wrap(memPtr(b), b.length);
    }

    function toBytes(BytesView b) internal pure returns (bytes memory res) {
        uint len = length(b);
        res = new bytes(len);
        mCopy(memPtr(b), BytesViewLib.memPtr(res), len);
    }

    function loadUInt8(BytesView b, uint256 offset) internal pure returns (uint256) {
        unchecked {
            FsUtils.Assert(offset + 1 <= length(b));
            return uint256(mload(memPtr(b) + offset)) >> 248;
        }
    }

    function loadBytes32(BytesView b, uint256 offset) internal pure returns (bytes32) {
        unchecked {
            //FsUtils.Assert(offset + 32 <= length(b));
            return mload(memPtr(b) + offset);
        }
    }

    // Decode scalar value (non-negative integer) as described in yellow paper
    function decodeScalar(BytesView b) internal pure returns (uint256) {
        unchecked {
            uint len = length(b);
            if (len == 0) return 0;
            require(len <= 32, "Invalid scalar representation");
            bytes32 data = mload(memPtr(b));
            require(data[0] != 0, "Invalid scalar representation");
            return uint256(data >> ((WORD_SIZE - len) << 3));
        }
    }

    function slice(BytesView b, uint256 offset, uint256 len) internal pure returns (BytesView) {
        unchecked {
            FsUtils.Assert(offset + len <= length(b));
            return BytesViewLib.wrap(memPtr(b) + offset, len);
        }
    }

    function skip(BytesView b, uint256 offset) internal pure returns (BytesView) {
        unchecked {
            FsUtils.Assert(offset <= length(b));
            return BytesViewLib.wrap(memPtr(b) + offset, length(b) - offset);
        }
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

    function isList(RLPItem item) internal pure returns (bool) {
        return buffer(item).loadUInt8(0) >= 0xc0;
    }

    function isBytes(RLPItem item) internal pure returns (bool) {
        return !isList(item);
    }

    function rlpLen(BytesView b) internal pure returns (uint256) {
        unchecked {
            require(b.length() > 0, "RLP: Empty buffer");
            uint256 len = 0;
            uint256 lenLen = 0;
            uint256 initial = b.loadUInt8(0);
            if (initial < 0x80) {
                // nothing
            } else if (initial < 0xb8) {
                len = initial - 0x80;
            } else if (initial < 0xc0) {
                lenLen = initial - 0xb7;
                // Continue below
            } else if (initial < 0xf8) {
                len = initial - 0xc0;
            } else {
                lenLen = initial - 0xf7;
                // Continue below
            }
            for (uint256 i = 0; i < lenLen; i++) {
                len = (len << 8) | b.loadUInt8(1 + i);
            }
            require(len + lenLen + 1 <= b.length(), "RLP: Invalid length rlpLen");
            return len + lenLen + 1;
        }
    }

    function unsafeRLPLen(BytesView b) internal pure returns (uint256) {
        unchecked {
            FsUtils.Assert(b.length() > 0); // "RLP: Empty buffer");
            uint256 len = 0;
            uint256 lenLen = 0;
            uint256 initial = b.loadUInt8(0);
            if (initial < 0x80) {
                // nothing
            } else if (initial < 0xb8) {
                len = initial - 0x80;
            } else if (initial < 0xc0) {
                lenLen = initial - 0xb7;
                // Continue below
            } else if (initial < 0xf8) {
                len = initial - 0xc0;
            } else {
                lenLen = initial - 0xf7;
                // Continue below
            }
            for (uint256 i = 0; i < lenLen; i++) {
                len = (len << 8) | b.loadUInt8(1 + i);
            }
            FsUtils.Assert(len + lenLen + 1 <= b.length()); // "RLP: Invalid length rlpLen");
            return len + lenLen + 1;
        }
    }

    function requireRLPItem(BytesView b) internal pure returns (RLPItem) {
        uint256 len = rlpLen(b);
        require(len == b.length(), "RLP: Invalid length");
        return asRLPItem(b);
    }

    function requireBytesView(RLPItem item) internal pure returns (BytesView) {
        require(isBytes(item), "RLP: Not bytes");
        return toBytesView(item);
    }

    function toBytesView(RLPItem item) internal pure returns (BytesView) {
        unchecked {
            FsUtils.Assert(isBytes(item));
            uint256 tag = buffer(item).loadUInt8(0);
            if (tag < 0x80) {
                return buffer(item).slice(0, 1);
            } else if (tag < 0xb8) {
                return buffer(item).slice(1, tag - 0x80);
            } else {
                uint256 lenLen = tag - 0xb7;
                uint256 len = 0;
                for (uint256 i = 0; i < lenLen; i++) {
                    len = (len << 8) | buffer(item).loadUInt8(1 + i);
                }
                return buffer(item).slice(1 + lenLen, len);
            }
        }
    }

    function requireRLPItemIterator(RLPItem item) internal pure returns (RLPIterator) {
        require(isList(item), "RLP: Not a list");
        return toRLPItemIterator(item);
    }

    function toRLPItemIterator(RLPItem item) internal pure returns (RLPIterator) {
        unchecked {
            FsUtils.Assert(isList(item));
            uint256 len = 0;
            uint256 lenLen = 0;
            uint256 initial = buffer(item).loadUInt8(0);
            if (initial < 0xf8) {
                len = initial - 0xc0;
            } else {
                lenLen = initial - 0xf7;
                for (uint256 i = 0; i < lenLen; i++) {
                    len = (len << 8) | buffer(item).loadUInt8(1 + i);
                }
            }
            FsUtils.Assert(len + lenLen + 1 == buffer(item).length()); // , "RLP: Invalid length it");
            BytesView b = buffer(item).slice(1 + lenLen, len);
            return RLPIterator.wrap(BytesView.unwrap(b));
        }
    }

    function next(RLPIterator it) internal pure returns (RLPItem item, RLPIterator nextIt) {
        uint256 len = unsafeRLPLen(buffer(it));
        item = asRLPItem(buffer(it).slice(0, len));
        nextIt = asRLPIterator(buffer(it).skip(len));
    }

    function requireNext(RLPIterator it) internal pure returns (RLPItem item, RLPIterator nextIt) {
        uint256 len = rlpLen(buffer(it));
        item = requireRLPItem(buffer(it).slice(0, len));
        nextIt = asRLPIterator(buffer(it).skip(len));
    }

    function skipNext(RLPIterator it) internal pure returns (RLPIterator nextIt) {
        FsUtils.Assert(buffer(it).length() > 0); // "RLP: Iterator out of bounds");
        uint256 len = rlpLen(buffer(it));
        FsUtils.Assert(len <= buffer(it).length()); // , "RLP: Iterator out of bounds");
        nextIt = asRLPIterator(buffer(it).skip(len));
    }

    function hasNext(RLPIterator it) internal pure returns (bool) {
        return buffer(it).length() > 0;
    }

    function buffer(RLPItem item) internal pure returns (BytesView) {
        return BytesView.wrap(RLPItem.unwrap(item));
    }

    function buffer(RLPIterator it) internal pure returns (BytesView) {
        return BytesView.wrap(RLPIterator.unwrap(it));
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

    /// @dev Verify a proof of a key in a Merkle Patricia Trie, revert if the proof is invalid.
    /// @param key The key to verify.
    /// @param root The root hash of the trie. This is assumed to be from a trusted source (e.g. a block header)
    ///        and therefore represents a structurally valid tree.
    /// @param proof The proof of the key. Untrusted data.
    /// @return The value of the key if the key exists or empty if key doesn't exist.
    /// @notice The stored value is encoded as RLP and thus never empty, so empty means the key doesn't exist.
    function verify(
        bytes memory key,
        bytes32 root,
        bytes memory proof
    ) internal pure returns (BytesView) {
        unchecked {
            require(key.length <= 32);
            uint256 nibblesLength = key.length * 2;
            bytes32 keyBytes = BytesViewLib.mload(BytesViewLib.memPtr(key));
            uint256 p = 0;
            RLPItem rlpListItem = RLP.requireRLPItem(BytesViewLib.toBytesView(proof));
            RLPIterator listIt = rlpListItem.requireRLPItemIterator();
            RLPItem[] memory children = new RLPItem[](2);
            BytesView res = BytesViewLib.empty();
            while (listIt.hasNext()) {
                RLPItem rlpItem;
                (rlpItem, listIt) = listIt.requireNext();
                require(rlpItem.buffer().keccak() == root, "IP: node mismatch");
                // Because it passed this the cryptographic check, we know that the RLP is well-formed.

                RLPIterator childIt = rlpItem.toRLPItemIterator();
                FsUtils.Assert(childIt.hasNext());
                (children[0], childIt) = childIt.next();
                FsUtils.Assert(childIt.hasNext());
                (children[1], childIt) = childIt.next();

                FsUtils.Assert(p <= nibblesLength);
                RLPItem nextRoot;
                root = EMPTY_TRIE_HASH; // sentinel indicating end of proof
                if (childIt.hasNext()) {
                    // Branch node
                    uint nibble = p == nibblesLength ? 16 : uint256(keyBytes) >> 252;

                    if (nibble < 2) {
                        nextRoot = children[nibble];
                    } else {
                        for (uint i = 2; i < nibble; i++) {
                            FsUtils.Assert(childIt.hasNext());
                            childIt = childIt.skipNext();
                        }
                        FsUtils.Assert(childIt.hasNext());
                        (nextRoot, childIt) = childIt.next();
                    }

                    if (p == nibblesLength) {
                        res = nextRoot.requireBytesView();
                        continue;
                    }
                    keyBytes <<= 4;
                    p++;
                } else {
                    // Extension or leaf nodes
                    BytesView partialKey = children[0].toBytesView();
                    FsUtils.Assert(partialKey.length() > 0);
                    uint256 tag = partialKey.loadUInt8(0);
                    bytes32 partialKeyBytes = partialKey.loadBytes32(1);
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
                    if (p + partialKeyLength > nibblesLength) {
                        continue;
                    }
                    if ((partialKeyBytes ^ keyBytes) >> (256 - 4 * partialKeyLength) != 0) {
                        continue;
                    }
                    p += partialKeyLength;
                    keyBytes <<= 4 * partialKeyLength;

                    if ((tag & 32) != 0) {
                        // Leaf node
                        if (p == nibblesLength) {
                            res = children[1].toBytesView();
                        }
                        continue;
                    }
                    nextRoot = children[1];
                }
                // Proof continue with child node
                if (nextRoot.isBytes()) {
                    BytesView childBytes = nextRoot.toBytesView();
                    if (childBytes.length() == 0) {
                        continue;
                    }
                    FsUtils.Assert(childBytes.length() == 32); // Invalid child hash
                    root = childBytes.loadBytes32(0);
                } else {
                    FsUtils.Assert(nextRoot.isList());
                    // The next node is embedded directly in this node
                    // as it's RLP length is less than 32 bytes.
                    FsUtils.Assert(nextRoot.buffer().length() < 32); // "IP: child node too long";
                    root = nextRoot.buffer().keccak();
                }
            }
            require(root == EMPTY_TRIE_HASH, "IP: incomplete proof");
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
        BytesView accountRLP = verify(
            BytesViewLib.bytesFromBytes32(keccak256(abi.encodePacked(account))),
            stateRoot,
            proof
        );
        if (accountRLP.length() == 0) {
            return (0, 0, bytes32(0), bytes32(0));
        }
        RLPItem item = RLP.requireRLPItem(accountRLP);
        RLPIterator it = item.requireRLPItemIterator();
        require(it.hasNext(), "Invalid account");
        (item, it) = it.next();
        nonce = item.requireBytesView().decodeScalar();
        require(it.hasNext(), "Invalid account");
        (item, it) = it.next();
        balance = item.requireBytesView().decodeScalar();
        require(it.hasNext(), "invalid account");
        (item, it) = it.next();
        storageHash = item.requireBytesView().loadBytes32(0);
        require(it.hasNext(), "invalid account");
        (item, it) = it.next();
        codeHash = item.requireBytesView().loadBytes32(0);
    }

    function proofStorageAt(
        bytes32 slot,
        bytes32 storageHash,
        bytes memory proof
    ) internal pure returns (uint256) {
        BytesView valueRLP = verify(
            BytesViewLib.bytesFromBytes32(keccak256(abi.encodePacked(slot))),
            storageHash,
            proof
        );
        if (valueRLP.length() == 0) {
            return 0;
        }
        RLPItem item = RLP.requireRLPItem(valueRLP);
        BytesView storedAmount = item.requireBytesView();
        return storedAmount.decodeScalar();
    }
}
