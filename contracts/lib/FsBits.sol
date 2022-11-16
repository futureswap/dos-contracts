// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/**
 * @title Shared bit manipulation functions.
 *
 * NOTE In order for the fuzzing tests to be isolated, all functions in this library need to be
 * `internal`.  Otherwise a contract that uses this library has a dependency on the library.
 *
 * Our current Echidna setup requires contracts to be deployable in isolation, so make sure to keep
 * the functions `internal`, until we update our Echidna tests to support more complex setups.
 */
library FsBits {
    /**
     * @notice Computes the number of bits set in `x`.
     *
     * Computes result in a constant time, much faster than iterating over all the 256 bits of `x`.
     *
     * TODO Would be great to specify exact gas cost here as well.
     *
     * For a detailed explanation of the algorithm see:
     *
     *   See https://en.wikipedia.org/wiki/Hamming_weight#Efficient_implementation
     */
    function bitCount(uint256 x) internal pure returns (uint256) {
        uint256 uint256_max = type(uint256).max;

        /*
         * We sum bits into a single byte, and `UINT256_MAX` would overflow that.  So we handle this
         * particular case separately.
         */
        if (x == uint256_max) return 256;

        /*
         * We use an implementation that we know either does not overflow (for `-` and `+`) or
         * actually relies on the operations to be in the `mod 256` field (for `*`).
         */
        unchecked {
            // Count 1's in 128 2-bit groups
            uint256 mask = uint256_max / 3; // 0x5555...
            // Special case (x & mask) + ((x >> 1) & mask) equals formula below with less
            // instructions.
            x = x - ((x >> 1) & mask);

            // Count 1's in 64 4-bit groups
            mask = uint256_max / 5; // 0x3333....
            x = (x & mask) + ((x >> 2) & mask);

            // Count 1's in 32 8-bit groups. Note At this point there is no danger of overflowing
            // between count of groups so we can have
            // (x & mask) + ((x >> n) & mask) = (x + (x >> n)) & mask
            // which saves an instruction
            mask = uint256_max / 17; // 0x0F0F...
            x = (x + (x >> 4)) & mask;

            // At this point we have the count of each of the 32 bytes. In 8 bits we can store
            // 0 to 255, so only UINT_MAX would overflow when represented in a single byte, which
            // is case we have excluded. So we can calculate the
            mask = uint256_max / 255;
            x = (x * mask) >> (256 - 8);
        }

        return x;
    }
}
