// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "../tokens/HashNFT.sol";
import "../lib/Call.sol";
import "../lib/FsUtils.sol";

contract Voting is EIP712 {
    struct Proposal {
        bytes32 digest;
        uint256 deadline;
        bytes32 storageRoot;
        uint256 totalSupply;
        uint256[2] votes;
    }

    uint256 constant VOTE_YES = 0;
    uint256 constant VOTE_NO = 1;
    uint256 constant FRACTION = 10; // 10% must vote for quorum

    HashNFT public immutable hashNFT;
    IERC20 public immutable governanceToken;
    address public immutable governance;
    uint256 public immutable mappingSlot;

    bytes constant VOTE_TYPESTRING = "Vote(uint256 index,bool vote)";
    bytes32 constant VOTE_TYPEHASH = abi.keccak256(VOTE_TYPESTRING);

    Proposal[] public proposals;

    event ProposalCreated(
        uint256 index,
        string title,
        string description,
        CallWithoutValue[] calls,
        uint256 deadline,
        bytes32 digest,
        uint256 blockNumber
    );

    constructor(
        address hashNFT_,
        address governanceToken_,
        address governance_
    ) EIP712("Voting", "1") {
        hashNFT = HashNFT(FsUtils.nonNull(hashNFT_));
        governanceToken = FsUtils.nonNull(governanceToken_);
        governance = FsUtils.nonNull(governance_);
    }

    function proposeVote(
        string calldata title,
        string calldata description,
        CallWithoutValue[] calldata calls,
        uint256 blockNumber,
        bytes calldata governanceTokenAccount,
        bytes calldata blockHeader,
        bytes calldata proof
    ) external {
        {
            bytes32 blockHash = blockhash(blockNumber);
            require(keccak256(blockHeader) == blockHash, "invalid block header");
            // RLP of block header 1 list tag + 2 length bytes + 33 bytes of parent hash + 33 bytes of ommers + 21 bytes of coinbase + 1 byte tag
            bytes32 stateRoot = bytes32(blockHeader[91:]);
            TrieLib.verify(governanceToken, governanceTokenAccount, stateRoot, proof);
        }

        // proof storageRoot is correct for blockhash(blockNumber) governanceTokenAddress
        Proposal storage proposal = proposals.push();
        proposal.digest = CallLib.hashCallWithoutValueArray(calls);
        proposal.deadline = block.timestamp + 7 days;
        proposal.storageRoot = storageRoot;
        proposal.totalSupply = governanceToken.totalSupply();

        emit ProposalCreated(
            proposals.length - 1,
            title,
            description,
            calls,
            proposal.deadline,
            proposal.digest,
            blockNumber
        );
    }

    function vote(
        uint256 idx,
        uint256 amount,
        bool support,
        bytes calldata signature,
        bytes calldata proof
    ) external {
        require(amount > 0, "amount must be positive");
        require(proposals[idx].deadline > 0, "proposal not found");
        require(proposals[idx].deadline > block.timestamp, "voting ended");
        bytes32 voteDigest = _hashTypedDataV4(keccak256(abi.encode(VOTE_TYPEHASH, idx, support)));
        address addr = ECDSA.recover(voteDigest, signature);
        TrieLib.verify(addr, bytes32(amount), proposals[idx].storageRoot, proof);

        proposals[idx].votes[support ? VOTE_YES : VOTE_NO] += amount;
    }

    function resolve(uint256 idx) external {
        Proposal storage proposal = proposals[idx];
        require(proposal.deadline > 0, "proposal not found");
        require(proposal.deadline < block.timestamp, "voting not ended");
        if (proposal.votes[VOTE_YES] <= proposal.votes[VOTE_NO]) {
            delete proposal;
            return;
        }
        if (proposal.votes[VOTE_YES] + proposal.votes[VOTE_NO] < proposal.totalSupply / FRACTION) {
            delete proposal;
            return;
        }
        // Vote passed;
        hashNFT.mint(governance, proposal.digest, "");
        delete proposal;
    }
}
