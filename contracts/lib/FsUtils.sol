// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

// BEGIN STRIP
// Used in `FsUtils.log` which is a debugging tool.
import "hardhat/console.sol";

// END STRIP

library FsUtils {
    // BEGIN STRIP
    // This method is only mean to be used in local testing.  See `preprocess` property in
    // `packages/contracts/hardhat.config.ts`.
    // Slither sees this function is not used, but it is convenient to have it around for debugging
    // purposes.
    // slither-disable-next-line dead-code
    function log(string memory s) internal view {
        console.log(s);
    }

    // This method is only mean to be used in local testing.  See `preprocess` property in
    // `packages/contracts/hardhat.config.ts`.
    // Slither sees this function is not used, but it is convenient to have it around for debugging
    // purposes.
    // slither-disable-next-line dead-code
    function log(string memory s, int256 x) internal view {
        console.log(s);
        console.logInt(x);
    }

    function log(string memory s, address x) internal view {
        console.log(s, x);
    }

    // END STRIP

    function toBytes32(bytes memory b) internal pure returns (bytes32) {
        require(b.length < 32, "Byte array to long");
        bytes32 out = bytes32(b);
        out = (out & (~(bytes32(type(uint256).max) >> (8 * b.length)))) | bytes32(b.length);
        return out;
    }

    function fromBytes32(bytes32 b) internal pure returns (bytes memory) {
        uint256 len = uint256(b) & 0xff;
        bytes memory out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = b[i];
        }
        return out;
    }

    function nonNull(address _address) internal pure returns (address) {
        require(_address != address(0), "Zero address");
        return _address;
    }

    // Slither sees this function is not used, but it is convenient to have it around, as it
    // actually provides better error messages than `nonNull` above.
    // slither-disable-next-line dead-code
    function nonNull(address _address, string memory message) internal pure returns (address) {
        require(_address != address(0), message);
        return _address;
    }

    // assert a condition. Assert should be used to assert an invariant that should be true
    // logically.
    // This is useful for readability and debugability. A failing assert is always a bug.
    //
    // In production builds (non-hardhat, and non-localhost deployments) this method is a noop.
    //
    // Use "require" to enforce requirements on data coming from outside of a contract. Ie.,
    //
    // ```solidity
    // function nonNegativeX(int x) external { require(x >= 0, "non-negative"); }
    // ```
    //
    // But
    // ```solidity
    // function nonNegativeX(int x) private { assert(x >= 0); }
    // ```
    //
    // If a private function has a pre-condition that it should only be called with non-negative
    // values it's a bug in the contract if it's called with a negative value.
    // solhint-disable-next-line func-name-mixedcase
    function Assert(bool cond) internal pure {
        // BEGIN STRIP
        assert(cond);
        // END STRIP
    }
}

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

    function memPtr(bytes memory b) internal pure returns (uint256 res) {
        assembly {
            res := add(b, 0x20)
        }
    }

    function mCopy(
        uint256 src,
        uint256 dest,
        uint256 len
    ) internal pure {
        if (len == 0) return;
        unchecked {
            // copy as many word sizes as possible
            for (; len > WORD_SIZE; len -= WORD_SIZE) {
                assembly {
                    mstore(dest, mload(src))
                }

                src += WORD_SIZE;
                dest += WORD_SIZE;
            }

            // left over bytes. Mask is used to remove unwanted bytes from the word
            FsUtils.Assert(len > 0 && len <= WORD_SIZE);
            uint256 mask = (1 << ((WORD_SIZE - len) << 3)) - 1;
            assembly {
                let srcpart := and(mload(src), not(mask)) // zero out src
                let destpart := and(mload(dest), mask) // retrieve the bytes
                mstore(dest, or(destpart, srcpart))
            }
        }
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

    function slice(
        BytesView memory b,
        uint256 offset,
        uint256 len
    ) internal pure returns (BytesView memory) {
        FsUtils.Assert(offset + len < b.len);
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

    function isNull(RLPItem memory item) internal pure returns (bool) {
        return item.buffer.len == 0;
    }

    function isList(RLPItem memory item) internal pure returns (bool) {
        return !isNull(item) && item.buffer.loadUInt8(0) >= 0xc0;
    }

    function isBytes(RLPItem memory item) internal pure returns (bool) {
        return !isNull(item) && item.buffer.loadUInt8(1) < 0xc0;
    }

    function rlpLen(BytesView memory b) internal pure returns (uint256) {
        require(b.len > 0, "RLP: Empty buffer");
        uint256 lenLen;
        uint8 initial = b.loadUInt8(0);
        if (initial < 0x80) {
            return 1;
        } else if (initial < 0xb8) {
            return initial - 0x80 + 1;
        } else if (initial < 0xc0) {
            lenLen = initial - 0xb7;
            // Continue below
        } else if (initial < 0xf8) {
            return initial - 0xc0 + 1;
        } else {
            lenLen = initial - 0xf7;
            // Continue below
        }
        uint256 len = 0;
        for (uint256 i = 0; i < lenLen; i++) {
            len = (len << 8) | b.loadUInt8(1 + i);
        }
        require(len + lenLen + 1 <= b.len, "RLP: Invalid length");
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

    function requireRLPItemIterator(RLPItem memory item)
        internal
        pure
        returns (RLPIterator memory)
    {
        require(isList(item), "RLP: Not a list");
        return toRLPItemIterator(item);
    }

    function toRLPItemIterator(RLPItem memory item) internal pure returns (RLPIterator memory) {
        FsUtils.Assert(isList(item));
        uint256 len = 0;
        uint256 lenLen = 0;
        uint8 initial = item.buffer.loadUInt8(0);
        if (initial < 0xf8) {
            len = initial - 0xc0 + 1;
        } else {
            lenLen = initial - 0xf7;
            for (uint256 i = 0; i < lenLen; i++) {
                len = (len << 8) | item.buffer.loadUInt8(1 + i);
            }
        }
        require(len + lenLen + 1 == item.buffer.len, "RLP: Invalid length");
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

    function verify(
        bytes memory key,
        bytes32 root,
        bytes memory proof
    ) internal pure returns (bytes memory) {
        require(key.length <= 32, "Invalid key");
        require(root != bytes32(0), "Invalid proof");
        bytes memory nibbles = new bytes(key.length * 2);
        for (uint256 i = 0; i < key.length; i++) {
            nibbles[i * 2] = key[i] >> 4;
            nibbles[i * 2 + 1] = key[i] & bytes1(uint8(0xf));
        }
        uint256 p = 0;
        RLPItem memory rlpListItem = RLP.toRLPItem(BytesViewLib.toBytesView(proof));
        require(rlpListItem.isList(), "Invalid proof");
        RLPIterator memory listIt = rlpListItem.toRLPItemIterator();
        while (listIt.hasNext()) {
            RLPItem memory rlpItem = listIt.next();
            require(root == bytes32(0) || rlpItem.buffer.keccak() == root, "Invalid proof");
            require(rlpItem.isList(), "Invalid proof");

            uint256 count = 0;
            RLPItem[] memory children = new RLPItem[](17);
            RLPIterator memory childIt = rlpItem.toRLPItemIterator();
            while (childIt.hasNext()) {
                children[count] = childIt.next();
                count++;
                require(count <= 17, "Invalid proof");
            }
            if (count == 17) {
                // Branch node
                if (p == nibbles.length) {
                    return children[16].toBytesView().toBytes();
                }
                uint8 nibble = uint8(nibbles[p++]);
                require(p <= nibbles.length, "Invalid proof");
                require(children[nibble].isBytes(), "Invalid proof");
                BytesView memory child = children[nibble].toBytesView();
                if (child.len == 32) {
                    root = child.loadBytes32(0);
                } else if (child.len < 32) {
                    // Tree is encoded directly
                    revert("Not implemented");
                } else {
                    revert("Invalid proof");
                }
            } else if (count == 2) {
                // Extension or leaf nodes
                require(!children[0].isList(), "Invalid proof");
                BytesView memory partialKey = children[0].toBytesView();
                require(partialKey.len > 0, "Invalid proof");
                uint8 tag = partialKey.loadUInt8(0);
                bool terminal = (tag & 32) != 0;
                if ((tag & 16) != 0) {
                    // Odd number of nibbles
                    require(bytes1(tag & 0xF) == nibbles[p++], "Invalid proof");
                    require(p <= nibbles.length, "Invalid proof");
                }
                for (uint256 i = 1; i < partialKey.len; i++) {
                    require(bytes1(tag >> 4) == nibbles[p++], "Invalid proof");
                    require(p <= nibbles.length, "Invalid proof");
                    require(bytes1(tag & 0xF) == nibbles[p++], "Invalid proof");
                    require(p <= nibbles.length, "Invalid proof");
                }
                if (p == nibbles.length) {
                    require(terminal, "Invalid proof");
                    require(children[1].isBytes(), "Invalid proof");
                    return children[1].toBytesView().toBytes();
                } else {
                    require(!terminal, "Invalid proof");
                    require(children[1].isBytes(), "Invalid proof");

                    revert("Invalid proof");
                }
            } else {
                revert("Invalid proof");
            }
        }
    }
}

/*
library RLP {
    struct RLPItem {
        uint256 len;
        uint256 memPtr;
    }

    function rlpDecode(bytes memory buffer) internal pure returns (RLPItem[] memory) {
        if (buffer.length == 0) {
            return new RLPItem[](0);
        }
        uint memPtr = buffer.memPtr();

        // for (uint i = 0; i <)
    }
}

library VerifyStorage {
    function verifyStorage(bytes32[] memory proof, bytes32 root, bytes32 key) internal pure {
        bytes32 value = 0;
        bytes32 computedHash = keccak256(abi.encodePacked(key, value));
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement) {
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        require(computedHash == root, "Invalid storage proof");
    }
}
*/
