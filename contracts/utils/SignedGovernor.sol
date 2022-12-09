// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../governance/GovernanceProxy.sol";

contract SignedGovernor is Ownable, EIP712 {
    bytes32 constant TAKEOWNERSHIP_TYPEHASH = keccak256("TakeOwnership(address newOwner)");

    constructor(address newOwner) EIP712("SignedGovernor", "1") {
        _transferOwnership(newOwner);
    }

    function takeOwnership(bytes calldata signature) external {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(TAKEOWNERSHIP_TYPEHASH, msg.sender))
        );

        address signer = ECDSA.recover(digest, signature);
        require(signer == owner(), "Invalid signature");

        _transferOwnership(msg.sender);
    }

    function execute(address governanceProxy, GovernanceProxy.Call[] memory calls)
        external
        onlyOwner
    {
        GovernanceProxy(governanceProxy).execute(calls);
    }
}
