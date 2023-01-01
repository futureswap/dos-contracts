// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "../tokens/HashNFT.sol";
import "../lib/Proofs.sol";
import "../lib/Call.sol";
import "../lib/FsUtils.sol";

contract Voting is EIP712 {
    using BytesViewLib for BytesView;
    using RLP for RLPItem;
    using RLP for RLPIterator;

    struct Proposal {
        bytes32 digest;
        uint256 deadline;
        bytes32 storageHash;
        uint256 totalSupply;
        uint256 yesVotes;
        uint256 noVotes;
    }

    uint256 constant FRACTION = 10; // 10% must vote for quorum

    HashNFT public immutable hashNFT;
    address public immutable governanceToken;
    address public immutable governance;
    uint256 public immutable mappingSlot;
    uint256 public immutable totalSupplySlot;

    bytes constant VOTE_TYPESTRING = "Vote(uint256 proposalId,bool support)";
    bytes32 constant VOTE_TYPEHASH = keccak256(VOTE_TYPESTRING);

    Proposal[] public proposals;
    // proposal ids are assigned as consecutive integers starting from 0
    // therefore we pack the lowest 8 bits of the proposal id into a bit
    // field. This allows us to store 256 votes per mapping slot.
    mapping(address => mapping(uint248 => uint256)) public hasVoted;

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
        bytes calldata totalSupplyProof
    ) external {
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
    }

    function vote(uint256 proposalId, bool support, bytes calldata proof) external {
        require(
            proposalId < proposals.length && proposals[proposalId].deadline > 0,
            "proposal not found"
        );
        require(proposals[proposalId].deadline > block.timestamp, "voting ended");

        _vote(msg.sender, proposalId, support, proof);
    }

    // Allow multiple offchain votes to be verified in a single transaction
    function voteBatch(
        uint256 proposalId,
        bool support,
        address[] calldata voters,
        bytes[] calldata signatures,
        bytes[] calldata proofs
    ) external {
        require(
            proposalId < proposals.length && proposals[proposalId].deadline > 0,
            "proposal not found"
        );
        require(proposals[proposalId].deadline > block.timestamp, "voting ended");

        require(voters.length == signatures.length, "invalid length");
        require(signatures.length == proofs.length, "invalid length");
        for (uint256 i = 0; i < voters.length; i++) {
            bytes32 voteDigest = _hashTypedDataV4(
                keccak256(abi.encode(VOTE_TYPEHASH, proposalId, support))
            );
            address addr = voters[i];
            require(
                SignatureChecker.isValidSignatureNow(addr, voteDigest, signatures[i]),
                "invalid signature"
            );
            _vote(addr, proposalId, support, proofs[i]);
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
        // Vote passed;
        hashNFT.mint(governance, proposal.digest, "");
        delete proposals[proposalId];
    }

    function _vote(address addr, uint256 proposalId, bool support, bytes calldata proof) internal {
        require(
            (hasVoted[addr][uint248(proposalId >> 8)] & (1 << (proposalId & 7))) == 0,
            "already voted"
        );
        hasVoted[addr][uint248(proposalId >> 8)] |= (1 << (proposalId & 7));
        // Solidity mapping convention
        bytes32 addressMappingSlot = keccak256(abi.encode(addr, mappingSlot));
        uint256 amount = TrieLib.proofStorageAt(
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

    function getBlockHash(uint256 blockNumber) internal view virtual returns (bytes32 blockHash) {
        return blockhash(blockNumber);
    }
}
