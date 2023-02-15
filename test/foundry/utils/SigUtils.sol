// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Call, CallLib} from "contracts/lib/Call.sol";

contract SigUtils {
    bytes internal constant CALL_TYPESTRING = "Call(address to,bytes callData,uint256 value)";

    bytes private constant EXECUTEBATCH_TYPESTRING =
        "ExecuteBatch(Call[] calls,uint256 nonce,uint256 deadline)";

    bytes32 private constant EXECUTEBATCH_TYPEHASH =
        keccak256(abi.encodePacked(EXECUTEBATCH_TYPESTRING, CALL_TYPESTRING));


    // computes the hash of a permit
    function getStructHash(address dSafe, Call[] memory _calls, uint256 _nonce, uint256 _deadline)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    dSafeDomain(dSafe),
                    EXECUTEBATCH_TYPEHASH,
                    _calls,
                    _nonce,
                    _deadline
                )
            );
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getTypedDataHash(address dSafe, Call[] memory _calls, uint256 _nonce, uint256 _deadline)
        public
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    getStructHash(dSafe, _calls, _nonce, _deadline)
                )
            );
    }

    function dSafeDomain(address dSafe) internal pure returns (bytes memory) {
        return abi.encodePacked(
            "DSafe",
            "1.0.0",
            uint256(1),
            dSafe
        );
    }
}
