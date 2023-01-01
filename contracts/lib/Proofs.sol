// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./FsUtils.sol";

struct BytesView {
    uint256 memPtr;
    uint256 len;
}

struct RLPItem {
    BytesView buffer;
}

struct RLPIterator {
    BytesView buffer;
}

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

    function empty() internal pure returns (BytesView memory) {
        return BytesView(0, 0);
    }

    function toBytesView(bytes memory b) internal pure returns (BytesView memory) {
        return BytesView(BytesViewLib.memPtr(b), b.length);
    }

    function toBytes(BytesView memory b) internal pure returns (bytes memory res) {
        res = new bytes(b.len);
        mCopy(b.memPtr, BytesViewLib.memPtr(res), b.len);
    }

    function loadUInt8(BytesView memory b, uint256 offset) internal pure returns (uint8) {
        FsUtils.Assert(offset + 1 <= b.len);
        return uint8(mload(b.memPtr + offset)[0]);
    }

    function loadBytes32(BytesView memory b, uint256 offset) internal pure returns (bytes32) {
        FsUtils.Assert(offset + 32 <= b.len);
        return mload(b.memPtr + offset);
    }

    // Decode scalar value (non-negative integer) as described in yellow paper
    function decodeScalar(BytesView memory b) internal pure returns (uint256) {
        if (b.len == 0) return 0;
        require(b.len <= 32, "Invalid scalar representation");
        bytes32 data = mload(b.memPtr);
        require(data[0] != 0, "Invalid scalar representation");
        return uint256(data >> ((WORD_SIZE - b.len) << 3));
    }

    function slice(
        BytesView memory b,
        uint256 offset,
        uint256 len
    ) internal pure returns (BytesView memory) {
        FsUtils.Assert(offset + len <= b.len);
        return BytesView(b.memPtr + offset, len);
    }

    function skip(BytesView memory b, uint256 offset) internal pure returns (BytesView memory) {
        FsUtils.Assert(offset <= b.len);
        return BytesView(b.memPtr + offset, b.len - offset);
    }

    function keccak(BytesView memory b) internal pure returns (bytes32 res) {
        uint256 ptr = b.memPtr;
        uint256 len = b.len;
        assembly {
            res := keccak256(ptr, len)
        }
    }
}

library RLP {
    using BytesViewLib for BytesView;

    function isList(RLPItem memory item) internal pure returns (bool) {
        return item.buffer.loadUInt8(0) >= 0xc0;
    }

    function isBytes(RLPItem memory item) internal pure returns (bool) {
        return !isList(item);
    }

    function rlpLen(BytesView memory b) internal pure returns (uint256) {
        require(b.len > 0, "RLP: Empty buffer");
        uint256 len = 0;
        uint256 lenLen = 0;
        uint8 initial = b.loadUInt8(0);
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
        require(len + lenLen + 1 <= b.len, "RLP: Invalid length rlpLen");
        return len + lenLen + 1;
    }

    function toRLPItem(BytesView memory b) internal pure returns (RLPItem memory) {
        uint256 len = rlpLen(b);
        require(len == b.len, "RLP: Invalid length");
        return RLPItem(b);
    }

    function requireBytesView(RLPItem memory item) internal pure returns (BytesView memory) {
        require(isBytes(item), "RLP: Not bytes");
        return toBytesView(item);
    }

    function toBytesView(RLPItem memory item) internal pure returns (BytesView memory) {
        FsUtils.Assert(isBytes(item));
        uint8 tag = item.buffer.loadUInt8(0);
        if (tag < 0x80) {
            return item.buffer.slice(0, 1);
        } else if (tag < 0xb8) {
            return item.buffer.slice(1, tag - 0x80);
        } else {
            uint256 lenLen = tag - 0xb7;
            uint256 len = 0;
            for (uint256 i = 0; i < lenLen; i++) {
                len = (len << 8) | item.buffer.loadUInt8(1 + i);
            }
            return item.buffer.slice(1 + lenLen, len);
        }
    }

    function requireRLPItemIterator(
        RLPItem memory item
    ) internal pure returns (RLPIterator memory) {
        require(isList(item), "RLP: Not a list");
        return toRLPItemIterator(item);
    }

    function toRLPItemIterator(RLPItem memory item) internal pure returns (RLPIterator memory) {
        FsUtils.Assert(isList(item));
        uint256 len = 0;
        uint256 lenLen = 0;
        uint8 initial = item.buffer.loadUInt8(0);
        if (initial < 0xf8) {
            len = initial - 0xc0;
        } else {
            lenLen = initial - 0xf7;
            for (uint256 i = 0; i < lenLen; i++) {
                len = (len << 8) | item.buffer.loadUInt8(1 + i);
            }
        }
        require(len + lenLen + 1 == item.buffer.len, "RLP: Invalid length it");
        BytesView memory b = BytesView(item.buffer.memPtr + 1 + lenLen, len);
        return RLPIterator(b);
    }

    function next(RLPIterator memory it) internal pure returns (RLPItem memory) {
        require(it.buffer.len > 0, "RLP: Iterator out of bounds");
        uint256 len = rlpLen(it.buffer);
        require(len <= it.buffer.len, "RLP: Iterator out of bounds");
        RLPItem memory item = RLPItem(it.buffer.slice(0, len));
        it.buffer = it.buffer.skip(len);
        return item;
    }

    function hasNext(RLPIterator memory it) internal pure returns (bool) {
        return it.buffer.len > 0;
    }
}

library TrieLib {
    using BytesViewLib for BytesView;
    using RLP for RLPItem;
    using RLP for RLPIterator;

    // RLP("") = "0x80"
    bytes32 private constant EMPTY_TRIE_HASH = keccak256("0x80");

    /// @dev Verify a proof of a key in a Merkle Patricia Trie, revert if the proof is invalid.
    /// @param key The key to verify.
    /// @param root The root hash of the trie.
    /// @param proof The proof of the key.
    /// @return The value of the key if the key exists or empty if key doesn't exist.
    /// @notice The stored value is encoded as RLP and thus never empty, so empty means the key doesn't exist.
    function verify(
        bytes memory key,
        bytes32 root,
        bytes memory proof
    ) internal view returns (BytesView memory) {
        require(key.length <= 32, "Invalid key");
        bytes memory nibbles = new bytes(key.length * 2);
        for (uint256 i = 0; i < key.length; i++) {
            nibbles[i * 2] = key[i] >> 4;
            nibbles[i * 2 + 1] = key[i] & bytes1(uint8(0xf));
        }
        uint256 p = 0;
        RLPItem memory rlpListItem = RLP.toRLPItem(BytesViewLib.toBytesView(proof));
        RLPIterator memory listIt = rlpListItem.requireRLPItemIterator();
        RLPItem[] memory children = new RLPItem[](17);
        BytesView memory res = BytesViewLib.empty();
        console.logBytes(key);
        while (listIt.hasNext()) {
            RLPItem memory rlpItem = listIt.next();
            console.logBytes32(root);
            console.logBytes32(rlpItem.buffer.keccak());
            require(rlpItem.buffer.keccak() == root, "Invalid proof");

            RLPIterator memory childIt = rlpItem.requireRLPItemIterator();
            uint256 count = 0;
            while (childIt.hasNext()) {
                children[count] = childIt.next();
                count++;
                require(count <= 17, "Invalid proof");
            }
            FsUtils.Assert(p <= nibbles.length);
            RLPItem memory nextRoot;
            root = EMPTY_TRIE_HASH; // sentinel indicating end of proof
            if (count == 17) {
                // Branch node
                if (p == nibbles.length) {
                    res = children[16].requireBytesView();
                    continue;
                }
                uint8 nibble = uint8(nibbles[p++]);
                nextRoot = children[nibble];
            } else if (count == 2) {
                // Extension or leaf nodes
                BytesView memory partialKey = children[0].requireBytesView();
                require(partialKey.len > 0, "Invalid proof");
                uint8 tag = partialKey.loadUInt8(0);
                if ((tag & 16) != 0) {
                    // Odd number of nibbles
                    if (p == nibbles.length || bytes1(tag & 0xF) != nibbles[p++]) {
                        continue;
                    }
                }
                if (p + 2 * (partialKey.len - 1) > nibbles.length) {
                    continue;
                }
                for (uint256 i = 1; i < partialKey.len; i++) {
                    uint8 bite = partialKey.loadUInt8(i);
                    if (bite != uint8((nibbles[p] << 4) | nibbles[p + 1])) {
                        continue;
                    }
                    p += 2;
                }
                if ((tag & 32) != 0) {
                    // Leaf node
                    if (p == nibbles.length) {
                        res = children[1].requireBytesView();
                    }
                    continue;
                }
                nextRoot = children[1];
            } else {
                revert("Invalid proof");
            }
            // Proof continue with child node
            if (nextRoot.isBytes()) {
                BytesView memory childBytes = nextRoot.toBytesView();
                if (childBytes.len == 0) {
                    continue;
                }
                require(childBytes.len == 32, "Invalid proof");
                root = childBytes.loadBytes32(0);
            } else {
                FsUtils.Assert(nextRoot.isList());
                // The next node is embedded directly in this node
                // as it's RLP length is less than 32 bytes.
                require(nextRoot.buffer.len < 32, "Invalid proof");
                root = nextRoot.buffer.keccak();
            }
        }
        require(root == EMPTY_TRIE_HASH, "Invalid proof");
        return res;
    }

    function proofAccount(
        address account,
        bytes32 stateRoot,
        bytes memory proof
    )
        internal
        view
        returns (uint256 nonce, uint256 balance, bytes32 storageHash, bytes32 codeHash)
    {
        BytesView memory accountRLP = verify(
            BytesViewLib.bytesFromBytes32(keccak256(abi.encodePacked(account))),
            stateRoot,
            proof
        );
        if (accountRLP.len == 0) {
            return (0, 0, bytes32(0), bytes32(0));
        }
        RLPItem memory item = RLP.toRLPItem(accountRLP);
        RLPIterator memory it = item.requireRLPItemIterator();
        require(it.hasNext(), "Invalid account");
        nonce = it.next().requireBytesView().decodeScalar();
        require(it.hasNext(), "Invalid account");
        balance = it.next().requireBytesView().decodeScalar();
        require(it.hasNext(), "invalid account");
        storageHash = it.next().requireBytesView().loadBytes32(0);
        require(it.hasNext(), "invalid account");
        codeHash = it.next().requireBytesView().loadBytes32(0);
    }

    function proofStorageAt(
        bytes32 slot,
        bytes32 storageHash,
        bytes memory proof
    ) internal view returns (uint256) {
        BytesView memory valueRLP = verify(
            BytesViewLib.bytesFromBytes32(keccak256(abi.encodePacked(slot))),
            storageHash,
            proof
        );
        if (valueRLP.len == 0) {
            return 0;
        }
        RLPItem memory item = RLP.toRLPItem(valueRLP);
        BytesView memory storedAmount = item.requireBytesView();
        return storedAmount.decodeScalar();
    }
}
