// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {BytesViewLib, TrieLib} from "../lib/Proofs.sol";

contract TestTrie {
    function verify(
        bytes calldata key,
        bytes32 root,
        bytes calldata proof
    ) external pure returns (bytes memory) {
        return BytesViewLib.toBytes(TrieLib.verify(bytes32(key), key.length, root, proof));
    }
}
