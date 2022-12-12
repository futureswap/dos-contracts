// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

/**
 * @title A serialized contract method call.
 *
 * @notice A call to a contract with no native value transferred as part of the call.
 *
 * We often need to pass calls around, so this is a common representation to use.
 */
struct CallWithoutValue {
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
struct Call {
    address to;
    bytes callData;
    uint256 value;
}

library CallLib {
    bytes internal constant CALL_TYPESTRING = "Call(address to,bytes callData,uint256 value)";
    bytes32 constant CALL_TYPEHASH = keccak256(CALL_TYPESTRING);

    /**
     * @notice Execute a call.
     *
     * @param call The call to execute.
     */
    function executeWithoutValue(CallWithoutValue memory call) internal {
        (bool success, bytes memory returnData) = call.to.call(call.callData);
        require(success, string(returnData));
    }

    /**
     * @notice Execute a call with value.
     *
     * @param call The call to execute.
     */
    function execute(Call memory call) internal {
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
    function executeBatchWithoutValue(CallWithoutValue[] memory calls) internal {
        for (uint256 i = 0; i < calls.length; i++) {
            executeWithoutValue(calls[i]);
        }
    }

    function hashCall(Call memory call) internal pure returns (bytes32) {
        return keccak256(abi.encode(CALL_TYPEHASH, call.to, keccak256(call.callData), call.value));
    }

    function hashCallArray(Call[] memory calls) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            hashes[i] = hashCall(calls[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }
}
