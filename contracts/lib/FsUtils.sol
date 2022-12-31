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

    function encodeToBytes32(bytes memory b) internal pure returns (bytes32) {
        require(b.length < 32, "Byte array to long");
        bytes32 out = bytes32(b);
        out = (out & (~(bytes32(type(uint256).max) >> (8 * b.length)))) | bytes32(b.length);
        return out;
    }

    function decodeFromBytes32(bytes32 b) internal pure returns (bytes memory) {
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
