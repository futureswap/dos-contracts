// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/**
 * @title A serialized contract method call.
 *
 * @notice A call to a contract with no native value transferred as part of the call.
 *
 * We often need to pass calls around, so this is a common representation to use.
 */
struct Call {
    address to;
    bytes callData;
}

/**
 * @title A serialized contract method call, with value.
 *
 * @notice A call to a contract that may also have native value transferred as part of the call.
 *
 * We often need to pass calls around, so this is a common representation to use.
 */
struct CallWithValue {
    address to;
    bytes callData;
    uint256 value;
}
