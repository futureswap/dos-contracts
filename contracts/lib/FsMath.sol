// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./FsUtils.sol";

/**
 * @title Utility methods basic math operations.
 *
 * NOTE In order for the fuzzing tests to be isolated, all functions in this library need to be
 * `internal`.  Otherwise a contract that uses this library has a dependency on the library.
 *
 * Our current Echidna setup requires contracts to be deployable in isolation, so make sure to keep
 * the functions `internal`, until we update our Echidna tests to support more complex setups.
 */
library FsMath {
    /**
     * @notice Size of `FIXED_POINT_SCALE` in bits.
     */
    int256 constant FIXED_POINT_SCALE_BITS = 64;

    /**
     * @notice Scaling factor used by our fixed-point integer representation.
     *
     * We chose `FIXED_POINT_SCALE` to be a power of 2 to make certain optimizations in the
     * calculation of `e^x` more efficient.  See `exp()` implementation for details.
     *
     * TODO Clarify that the above is indeed true.
     *
     * See https://en.wikipedia.org/wiki/Fixed-point_arithmetic
     */
    int256 constant FIXED_POINT_SCALE = int256(1) << uint256(FIXED_POINT_SCALE_BITS);

    uint256 constant UINT256_MAX = ~uint256(0);

    function abs(int256 value) internal pure returns (uint256) {
        if (value >= 0) {
            // slither-disable-next-line safe-cast
            return uint256(value);
        }
        // slither-disable-next-line safe-cast
        return uint256(-value);
    }

    function sabs(int256 value) internal pure returns (int256) {
        if (value >= 0) {
            return value;
        }
        return -value;
    }

    function sign(int256 value) internal pure returns (int256) {
        if (value < 0) {
            return -1;
        } else if (value > 0) {
            return 1;
        } else {
            return 0;
        }
    }

    function min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    function max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    // Clip val into interval [lower, upper]
    function clip(int256 val, int256 lower, int256 upper) internal pure returns (int256) {
        return min(max(val, lower), upper);
    }

    function safeCastToSigned(uint256 x) internal pure returns (int256) {
        // slither-disable-next-line safe-cast
        int256 ret = int256(x);
        require(ret >= 0, "Cast overflow");
        return ret;
    }

    function safeCastToUnsigned(int256 x) internal pure returns (uint256) {
        require(x >= 0, "Cast underflow");
        // slither-disable-next-line safe-cast
        return uint256(x);
    }

    /**
     * @notice Calculate `e^x`.
     *
     * @param x Is a fixed point decimals with the scale of `FIXED_POINT_SCALE`.
     * @return A fixed point decimals with the scale of `FIXED_POINT_SCALE`.
     */
    function exp(int256 x) internal pure returns (int256) {
        /*
         * Making fixed point representation explicit we want to compute
         *
         * result = e^(x / FIXED_POINT_SCALE) * FIXED_POINT_SCALE
         *
         * To efficiently and accurately calculate the above expression we decompose this into 3
         * parts where each part has an efficient and accurate method of calculation.
         *
         * First, we transform the exponentiation into base 2 so we can use shifts:
         *
         *   e^(x / FIXED_POINT_SCALE) * FIXED_POINT_SCALE
         * = 2^(x / FIXED_POINT_SCALE / ln(2)) * FIXED_POINT_SCALE
         * = 2^(x / ln2FixedPoint) * FIXED_POINT_SCALE
         * = 2^integerQuot * 2^(rem / ln2FixedPoint) * FIXED_POINT_SCALE
         */

        FsUtils.Assert(FIXED_POINT_SCALE_BITS == 64);
        /*
         * ln(2) * 2^FIXED_POINT_SCALE_BITS = ln(2) * 2^64
         */
        int256 ln2FixedPoint = 12786308645202655659;

        int256 shiftLeft = x / ln2FixedPoint;
        int256 remainder = x % ln2FixedPoint;
        if (shiftLeft <= -FIXED_POINT_SCALE_BITS) return 0;
        require(shiftLeft < (256 - FIXED_POINT_SCALE_BITS), "Exponentiation overflows");

        /*
         * At this point we have decomposed exp as a simple bitshift and a fractional power of 2. We
         * could express this as an integer power like
         *
         *      (2^(1/ln2FixedPoint))^remainder
         *
         * but `remainder` is very big, in the order of `10^19` resulting in ~60 (2log) iteration in
         * repeated squaring but more problematic also a lot of precision loss. It turns out that
         * `ln2FixedPoint` as an integer has a smallish factor.
         */
        int256 smallFactor = 4373;
        int256 bigFactor = ln2FixedPoint / smallFactor;

        /*
         * Split
         *
         *      2^(remainder/ln2FixedPoint)
         *
         * as
         *
         *      (2^(1/smallFactor)) ^ (remainder/bigFactor)
         */
        int256 integerPower = remainder / bigFactor;
        int256 smallRemainder = remainder % bigFactor;

        /*
         * So we can further decompose as follows:
         *
         * (2^(1/smallFactor))^(integerPower) * exp(smallRemainder/fixedPoint)
         *
         * where in the last factor base 2 is replaced with an ordinary e-power using ln2.
         *
         * At this point `0 <= integerPower < smallFactor` and `0 <= smallRemainder < bigFactor`.
         * The first range implies that repeated exponentiation of the first factor won't loop too
         * much and has rather good precision.  The second range implies that
         * `smallRemainder/FIXED_POINT_SCALE < 1/4373` so that the Taylor expansion rapidly
         * converges.
         */
        int256 taylorApprox = FIXED_POINT_SCALE +
            smallRemainder +
            (smallRemainder * smallRemainder) /
            (2 * FIXED_POINT_SCALE) +
            (smallRemainder * smallRemainder * smallRemainder) /
            (6 * FIXED_POINT_SCALE * FIXED_POINT_SCALE);

        int256 twoPowRecipSmallFactor = 18449668226934502855; // 2^(1/smallFactor) in fixed point
        int256 prod;
        if (integerPower >= 0) {
            /*
             * This implies shiftLeft >= 0 we don't want to lose precision by first dividing and
             * subsequent shifting left.
             */
            prod = pow(twoPowRecipSmallFactor, integerPower) * taylorApprox;
            shiftLeft -= FIXED_POINT_SCALE_BITS;
        } else {
            /*
             * This implies shiftLeft <= 0 so we're losing precision anyway.
             */
            prod = (FIXED_POINT_SCALE * taylorApprox) / pow(twoPowRecipSmallFactor, -integerPower);
        }

        return shiftLeft >= 0 ? (prod << uint256(shiftLeft)) : (prod >> uint256(-shiftLeft));
    }

    /**
     * @notice Calculates `x^n`
     *
     * Note we cannot use solidity `**` as we have to normalize fixed point after every
     * multiplication.
     *
     * @param x  a `FIXED_POINT_SCALE` fixed point decimal, with a scale of `FIXED_POINT_SCALE`.
     * @param n  an integer.
     */
    function pow(int256 x, int256 n) internal pure returns (int256) {
        if (n >= 0) {
            return powInternal(x, n);
        } else {
            return powInternal((FIXED_POINT_SCALE * FIXED_POINT_SCALE) / x, -n);
        }
    }

    /**
     * @notice Calculates square root of `x`, in fixed point decimal with a scale of
     * `FIXED_POINT_SCALE`.
     *
     * @param x  a `FIXED_POINT_SCALE` fixed point decimal, with a scale of `FIXED_POINT_SCALE`.
     */
    function sqrt(int256 x) internal pure returns (int256) {
        require(x >= 0, "Square root of negative number");
        int256 prevRes = 0;
        int256 res = x;
        while (res != prevRes) {
            prevRes = res;
            res = (res + (x * FIXED_POINT_SCALE) / res) / 2;
        }
        return res;
    }

    // See https://en.wikipedia.org/wiki/Hamming_weight#Efficient_implementation
    function bitCount(uint256 x) internal pure returns (uint256) {
        // In this routine we purposefully interpret x as a number in Z mod (2^256) in the
        // multiplication.
        unchecked {
            if (x == UINT256_MAX) return 256;

            // Count 1's in 128 2-bit groups
            uint256 mask = UINT256_MAX / 3; // 0x5555...
            // Special case (x & mask) + ((x >> 1) & mask) equals formula below with less
            // instructions.
            x = x - ((x >> 1) & mask);

            // Count 1's in 64 4-bit groups
            mask = UINT256_MAX / 5; // 0x3333....
            x = (x & mask) + ((x >> 2) & mask);

            // Count 1's in 32 8-bit groups. Note At this point there is no danger of overflowing
            // between count of groups so we can have
            // (x & mask) + ((x >> n) & mask) = (x + (x >> n)) & mask
            // which saves an instruction
            mask = UINT256_MAX / 17; // 0x0F0F...
            x = (x + (x >> 4)) & mask;

            // At this point we have the count of each of the 32 bytes. In 8 bits we can store
            // 0 to 255, so only UINT_MAX would overflow when represented in a single byte, which
            // is case we have excluded. So we can calculate the
            mask = UINT256_MAX / 255;
            x = (x * mask) >> (256 - 8);
        }
        return x;
    }

    /**
     * @notice A helper used by `pow`, that expects that `n` is positive.
     */
    function powInternal(int256 x, int256 n) private pure returns (int256) {
        int256 res = FIXED_POINT_SCALE;
        while (n > 0) {
            if ((n & 1) == 1) {
                res = (res * x) / FIXED_POINT_SCALE;
            }
            x = (x * x) / FIXED_POINT_SCALE;
            n /= 2;
        }
        return res;
    }
}
