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

library CallLib {
    /**
     * @notice Execute a call.
     *
     * @param call The call to execute.
     */
    function execute(Call memory call) internal {
        (bool success, bytes memory returnData) = call.to.call(call.callData);
        require(success, string(returnData));
    }

    /**
     * @notice Execute a call with value.
     *
     * @param call The call to execute.
     */
    function executeWithValue(CallWithValue memory call) internal {
        (bool success, bytes memory returnData) = call.to.call{value: call.value}(call.callData);
        require(success, string(returnData));
    }

    /**
     * @notice Execute a batch of calls.
     *
     * @param calls The calls to execute.
     */
    function executeBatch(Call[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            execute(calls[i]);
        }
    }

    /**
     * @notice Execute a batch of calls with value.
     *
     * @param calls The calls to execute.
     */
    function executeBatchWithValue(CallWithValue[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            executeWithValue(calls[i]);
        }
    }
}
