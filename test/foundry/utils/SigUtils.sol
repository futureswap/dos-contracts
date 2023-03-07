// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Call, CallLib} from "contracts/lib/Call.sol";
import {DSafeLogic} from "contracts/dsafe/DSafeLogic.sol";

contract SigUtils {
    bytes32 private constant _TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
    bytes internal constant CALL_TYPESTRING = "Call(address to,bytes callData,uint256 value)";

    bytes private constant EXECUTEBATCH_TYPESTRING =
        "ExecuteBatch(Call[] calls,uint256 nonce,uint256 deadline)";

    bytes32 private constant EXECUTEBATCH_TYPEHASH =
        keccak256(abi.encodePacked(EXECUTEBATCH_TYPESTRING, CALL_TYPESTRING));

    // computes the hash of a permit
    function getStructHash(
        Call[] memory _calls,
        uint256 _nonce,
        uint256 _deadline
    ) internal pure returns (bytes32 structHash) {
        structHash = keccak256(
            abi.encode(EXECUTEBATCH_TYPEHASH, CallLib.hashCallArray(_calls), _nonce, _deadline)
        );
        return structHash;
    }

    // computes the hash of the fully encoded EIP-712 message for the domain, which can be used to recover the signer
    function getTypedDataHash(
        address dSafe,
        Call[] memory _calls,
        uint256 _nonce,
        uint256 _deadline
    ) public view returns (bytes32) {
        return ECDSA.toTypedDataHash(dSafeDomain(dSafe), getStructHash(_calls, _nonce, _deadline));
    }

    function dSafeDomain(address dSafe) internal view returns (bytes32) {
        bytes32 _hashedName = keccak256(bytes("DOS dSafe"));
        bytes32 _hashedVersion = keccak256(bytes("1.0.0"));
        bytes32 _domainSeparatorV4 = keccak256(
            abi.encode(_TYPE_HASH, _hashedName, _hashedVersion, block.chainid, dSafe)
        );
        console.log("_domainSeparatorV4");
        console.logBytes32(_domainSeparatorV4);
        return _domainSeparatorV4;
    }
}
