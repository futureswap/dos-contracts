// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {FsMath} from "../lib/FsMath.sol";

contract TestFsMath {
    function abs(int256 value) external pure returns (uint256) {
        return FsMath.abs(value);
    }

    function sabs(int256 value) external pure returns (int256) {
        return FsMath.sabs(value);
    }

    function sign(int256 value) external pure returns (int256) {
        return FsMath.sign(value);
    }

    function min(int256 a, int256 b) external pure returns (int256) {
        return FsMath.min(a, b);
    }

    function max(int256 a, int256 b) external pure returns (int256) {
        return FsMath.max(a, b);
    }

    // Clip val into interval [lower, upper]
    function clip(int256 val, int256 lower, int256 upper) external pure returns (int256) {
        return FsMath.clip(val, lower, upper);
    }

    function safeCastToSigned(uint256 x) external pure returns (int256) {
        return FsMath.safeCastToSigned(x);
    }

    function safeCastToUnsigned(int256 x) external pure returns (uint256) {
        return FsMath.safeCastToUnsigned(x);
    }

    function exp(int256 x) external pure returns (int256) {
        return FsMath.exp(x);
    }

    function sqrt(int256 x) external pure returns (int256) {
        return FsMath.sqrt(x);
    }

    function bitCount(uint256 x) external pure returns (uint256) {
        return FsMath.bitCount(x);
    }
}
