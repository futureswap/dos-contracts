// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../lib/Call.sol";

// For multichain support we want fixed addresses for our contracts, to facilitate multichain management.
// We use a private key-less deployment pattern to deploy a create2 contract at a fixed address on any
// EVM compatible chain. This way we can deploy the same systems on multiple chains. For ownerless contracts
// this works perfect, but for contracts that require an owner we need a public key as part of the deploy
// bytecode information (anyone can deploy the contract on that address). To facilitate this we want to
// deploy a single contract at a fixed address on all chain that represents FutureSwap. This contract can
// subsequently be owned by a multisig wallet, and can be used to deploy other contracts to fixed addresses
// that need to be under control by FutureSwap.
// Note: we could deploy this contract with a dedicated deployer key. However this means we must guarantee
// that deployment of this contract is always the first action on the chain for this deployment. Instead we
// opt for a pattern that only needs to sign offchain.
contract FutureSwapProxy is Ownable, EIP712 {
    bytes32 constant TAKEOWNERSHIP_TYPEHASH =
        keccak256("TakeOwnership(address newOwner,uint256 nonce)");

    uint256 public nonce;

    constructor(address newOwner) EIP712("FutureSwapProxy", "1") {
        _transferOwnership(newOwner);
    }

    function takeOwnership(bytes calldata signature) external {
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(TAKEOWNERSHIP_TYPEHASH, msg.sender, nonce++))
        );

        address signer = ECDSA.recover(digest, signature);
        require(signer == owner(), "Invalid signature");

        _transferOwnership(msg.sender);
    }

    function execute(Call[] memory calls) external onlyGovernance {
        CallLib.executeBatch(calls);
    }
}
