// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";
import "../lib/FsUtils.sol";
import "../lib/ImmutableOwnable.sol";
import "../tokens/VoteNFT.sol";

// This is a proxy contract representing governance. This allows a fixed
// ethereum address to be the indefinite owner of the system. This works
// nicely with ImmutableOwnable allowing owner to be stored in contract
// code instead of storage. Note that a governance account only has to
// interact with the "execute" method. Proposing new governance or accepting
// governance is done through calls to "execute", simplifying voting
// contracts that govern this proxy.
contract GovernanceProxy {
    using Address for address;

    struct Call {
        address to;
        bytes callData;
    }
    // This address controls the proxy and is allowed to execute
    // contract calls from this contracts account.
    address public governance;
    // To avoid losing governance by accidentally transferring governance
    // to a wrong address we use a propose mechanism, where the proposed
    // governance can also execute and by this action finalize the
    // the transfer of governance. This prevents accidentally transferring
    // control to an invalid address.
    address public proposedGovernance;

    event NewGovernanceProposed(address newGovernance);
    event GovernanceChanged(address oldGovernance, address newGovernance);

    constructor() {
        governance = msg.sender;
    }

    /// @notice Execute a batch of contract calls.
    /// @param calls an array of calls.
    function execute(Call[] calldata calls) external {
        if (msg.sender != governance) {
            // If the caller is not governance we only accept if the previous
            // governance has proposed it as the new governance account.
            require(msg.sender == proposedGovernance, "Only governance");
            emit GovernanceChanged(governance, msg.sender);
            governance = msg.sender;
            proposedGovernance = address(0);
        }
        for (uint256 i = 0; i < calls.length; i++) {
            calls[i].to.functionCall(calls[i].callData);
        }
    }

    /// @notice Propose a new account as governance account. Note that this can
    /// only be called through the execute method above and hence only
    /// by the current governance.
    /// @param newGovernance address of the new governance account
    function proposeGovernance(address newGovernance) external {
        require(msg.sender == address(this), "Only governance");
        emit NewGovernanceProposed(newGovernance);
        proposedGovernance = newGovernance;
    }
}

contract Governance is ImmutableOwnable, IERC721Receiver {
    HashNFT immutable voteNFT;
    address public voting;

    constructor(
        address _governanceProxy,
        address _voteNFT,
        address _voting
    ) ImmutableOwnable(_governanceProxy) {
        voteNFT = HashNFT(FsUtils.nonNull(_voteNFT));
        voting = FsUtils.nonNull(_voting);
    }

    function execute(uint256 nonce, GovernanceProxy.Call[] memory calls) external {
        voteNFT.burnAsDigest(voting, nonce, keccak256(abi.encode(calls)));
        GovernanceProxy(owner).execute(calls);
    }

    function transferVoting(address newVoting) external onlyOwner {
        voting = newVoting;
    }

    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes calldata /* data */
    ) external view override returns (bytes4) {
        require(msg.sender == address(voteNFT), "only vote NFTs");
        return this.onERC721Received.selector;
    }
}
