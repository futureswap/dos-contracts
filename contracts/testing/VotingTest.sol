// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {Voting} from "../governance/Voting.sol";

contract VotingTest is Voting {
    bytes32 public mockBlockHash;

    constructor(
        address hashNFT_,
        address governanceToken_,
        uint256 mappingSlot_,
        uint256 totalSupplySlot_,
        address governance_
    ) Voting(hashNFT_, governanceToken_, mappingSlot_, totalSupplySlot_, governance_) {}

    function setMockBlockHash(bytes32 blockHash) external {
        mockBlockHash = blockHash;
    }

    function getBlockHash(uint256) internal view override returns (bytes32) {
        return mockBlockHash;
    }
}
