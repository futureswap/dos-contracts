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

library TrieLib {
    function verify(
        bytes32 key,
        bytes memory value,
        bytes32 root,
        bytes[] memory proof
    ) internal pure {
        bytes memory nibbles = new bytes(64);
        bytes32 keyBytes = bytes32(uint256(uint160(key)));
        for (uint256 i = 0; i < 32; i++) {
            nibbles[i * 2] = keyBytes[12 + i] >> 4;
            nibbles[i * 2 + 1] = keyBytes[12 + i] & bytes1(uint8(0xf));
        }
        uint256 p = 0;
        for (uint256 i = 0; i < proof.length; i++) {
            require(keccak256(proof[i]) == root, "Invalid proof");
            rlpDecode(proof[i]);
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
