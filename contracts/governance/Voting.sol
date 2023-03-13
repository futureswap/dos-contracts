// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {HashNFT} from "../tokens/HashNFT.sol";
import {TrieLib} from "../lib/Proofs.sol";
import {CallLib, CallWithoutValue} from "../lib/Call.sol";
import {FsUtils} from "../lib/FsUtils.sol";
import {NonceMapLib, NonceMap} from "../lib/NonceMap.sol";

contract Voting is EIP712 {
    using NonceMapLib for NonceMap;
    using Address for address;

    struct Proposal {
        bytes32 digest;
        uint256 deadline;
        bytes32 storageHash;
        uint256 totalSupply;
        uint256 yesVotes;
        uint256 noVotes;
    }

    struct Vote {
        address voter;
        bool support;
        bytes signature;
        bytes proof;
    }

    bytes private constant VOTE_TYPESTRING = "Vote(uint256 proposalId,bool support)";
    bytes32 private constant VOTE_TYPEHASH = keccak256(VOTE_TYPESTRING);

    uint256 public constant FRACTION = 10; // 10% must vote for quorum
    uint256 public constant MIN_VOTING_POWER = 100 ether;

    HashNFT public immutable hashNFT;
    address public immutable governanceToken;
    address public immutable governance;
    uint256 public immutable mappingSlot;
    uint256 public immutable totalSupplySlot;

    Proposal[] public proposals;
    mapping(address => NonceMap) private votesByAddress;
    mapping(address => address) public delegates;

    event ProposalCreated(
        uint256 proposalId,
        string title,
        string description,
        CallWithoutValue[] calls,
        uint256 deadline,
        bytes32 digest,
        uint256 blockNumber
    );

    event VoteCasted(address voter, uint256 proposalId, bool support, uint256 votes);

    modifier requireValidProposal(uint256 proposalId) {
        require(
            proposalId < proposals.length && proposals[proposalId].deadline > 0,
            "proposal not found"
        );
        require(proposals[proposalId].deadline >= block.timestamp, "voting ended");
        _;
    }

    constructor(
        address hashNFT_,
        address governanceToken_,
        uint256 mappingSlot_,
        uint256 totalSupplySlot_,
        address governance_
    ) EIP712("Voting", "1") {
        hashNFT = HashNFT(FsUtils.nonNull(hashNFT_));
        governanceToken = FsUtils.nonNull(governanceToken_);
        mappingSlot = mappingSlot_;
        totalSupplySlot = totalSupplySlot_;
        governance = FsUtils.nonNull(governance_);
    }

    function proposeVote(
        string calldata title,
        string calldata description,
        CallWithoutValue[] calldata calls,
        uint256 blockNumber,
        bytes calldata blockHeader,
        bytes calldata stateProof,
        bytes calldata totalSupplyProof,
        address voter,
        bytes calldata proof
    ) external {
        require(msg.sender == voter || delegates[voter] == msg.sender, "not authorized");
        require(calls.length > 0, "Empty proposal");
        for (uint256 i = 0; i < calls.length; i++) {
            require(calls[i].to.isContract(), "target not a contract");
            require(calls[i].callData.length >= 4, "Invalid callData");
        }
        bytes32 storageHash;
        {
            bytes32 blockHash = getBlockHash(blockNumber);
            require(block.number <= blockNumber + 256, "block too old");
            require(keccak256(blockHeader) == blockHash, "invalid block header");
            // RLP of block header 1 list tag + 2 length bytes + 33 bytes of parent hash + 33 bytes of ommers + 21 bytes of coinbase + 1 byte tag
            bytes32 stateHash = bytes32(blockHeader[91:]);

            (, , storageHash, ) = TrieLib.proofAccount(governanceToken, stateHash, stateProof);
        }

        // proof storageHash is correct for blockhash(blockNumber) governanceTokenAddress
        Proposal storage proposal = proposals.push();
        proposal.digest = CallLib.hashCallWithoutValueArray(calls);
        proposal.deadline = block.timestamp + 2 days;
        proposal.storageHash = storageHash;
        proposal.totalSupply = TrieLib.proofStorageAt(
            bytes32(totalSupplySlot),
            storageHash,
            totalSupplyProof
        );

        emit ProposalCreated(
            proposals.length - 1,
            title,
            description,
            calls,
            proposal.deadline,
            proposal.digest,
            blockNumber
        );

        uint256 amount = _vote(voter, proposals.length - 1, true, proof);
        require(amount >= MIN_VOTING_POWER, "insufficient voting power");
    }

    function vote(
        address voter,
        uint256 proposalId,
        bool support,
        bytes calldata proof
    ) external requireValidProposal(proposalId) {
        if (voter == address(0)) {
            voter = msg.sender;
        } else {
            require(voter == msg.sender || msg.sender == delegates[voter], "invalid voter");
        }
        _vote(voter, proposalId, support, proof);
    }

    // Allow multiple offchain votes to be verified in a single transaction
    function voteBatch(
        uint256 proposalId,
        Vote[] calldata votes
    ) external requireValidProposal(proposalId) {
        bytes32 yesVoteDigest = _hashTypedDataV4(
            keccak256(abi.encode(VOTE_TYPEHASH, proposalId, true))
        );
        bytes32 noVoteDigest = _hashTypedDataV4(
            keccak256(abi.encode(VOTE_TYPEHASH, proposalId, false))
        );
        for (uint256 i = 0; i < votes.length; i++) {
            address addr = votes[i].voter;
            if (delegates[addr] != address(0)) {
                addr = delegates[addr];
            }
            require(
                SignatureChecker.isValidSignatureNow(
                    addr,
                    votes[i].support ? yesVoteDigest : noVoteDigest,
                    votes[i].signature
                ),
                "invalid signature"
            );
            _vote(votes[i].voter, proposalId, votes[i].support, votes[i].proof);
        }
    }

    function resolve(uint256 proposalId) external {
        Proposal storage proposal = proposals[proposalId];
        require(proposal.deadline > 0, "proposal not found");
        require(proposal.deadline < block.timestamp, "voting not ended");
        if (proposal.yesVotes <= proposal.noVotes) {
            delete proposals[proposalId];
            return;
        }
        if (proposal.yesVotes + proposal.noVotes < proposal.totalSupply / FRACTION) {
            delete proposals[proposalId];
            return;
        }
        bytes32 digest = proposal.digest;
        delete proposals[proposalId];
        // Vote passed;
        hashNFT.mint(governance, digest, "");
    }

    function setDelegate(address delegate) external {
        delegates[msg.sender] = delegate;
    }

    function hasVoted(address voter, uint256 proposalId) external view returns (bool) {
        return votesByAddress[voter].getNonce(proposalId);
    }

    function _vote(
        address addr,
        uint256 proposalId,
        bool support,
        bytes calldata proof
    ) internal returns (uint256 amount) {
        votesByAddress[addr].validateAndUseNonce(proposalId);
        // Solidity mapping convention
        bytes32 addressMappingSlot = keccak256(abi.encode(addr, mappingSlot));
        amount = TrieLib.proofStorageAt(
            addressMappingSlot,
            proposals[proposalId].storageHash,
            proof
        );
        require(amount > 0, "no balance");
        if (support) {
            proposals[proposalId].yesVotes += amount;
        } else {
            proposals[proposalId].noVotes += amount;
        }
        emit VoteCasted(addr, proposalId, support, amount);
    }

    /// @dev Override this function for testing to return handcrafted blockhashes
    function getBlockHash(uint256 blockNumber) internal view virtual returns (bytes32 blockHash) {
        return blockhash(blockNumber);
    }
}
