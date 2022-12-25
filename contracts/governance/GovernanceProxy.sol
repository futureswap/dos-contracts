// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Receiver.sol";
import "../lib/FsUtils.sol";
import "../lib/ImmutableOwnable.sol";
import "../lib/AccessControl.sol";
import "../tokens/HashNFT.sol";
import "../lib/Call.sol";

// This is a proxy contract representing governance. This allows a fixed
// ethereum address to be the indefinite owner of the system. This works
// nicely with ImmutableOwnable allowing owner to be stored in contract
// code instead of storage. Note that a governance account only has to
// interact with the "execute" method. Proposing new governance or accepting
// governance is done through calls to "execute", simplifying voting
// contracts that govern this proxy.
contract GovernanceProxy {
    using Address for address;

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

    constructor(address _governance) {
        governance = FsUtils.nonNull(_governance);
    }

    /// @notice Execute a batch of contract calls.
    /// @param calls an array of calls.
    function executeBatch(CallWithoutValue[] calldata calls) external {
        if (msg.sender != governance) {
            // If the caller is not governance we only accept if the previous
            // governance has proposed it as the new governance account.
            require(msg.sender == proposedGovernance, "Only governance");
            emit GovernanceChanged(governance, msg.sender);
            governance = msg.sender;
            proposedGovernance = address(0);
        }
        CallLib.executeBatchWithoutValue(calls);
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

contract Governance is AccessControl, ERC1155Receiver {
    address public voting;
    mapping(address => mapping(bytes4 => uint256)) public accessLevelByAddressBySelector;

    constructor(
        address _governanceProxy,
        address _hashNFT,
        address _voting
    ) AccessControl(_governanceProxy, _hashNFT) {
        voting = FsUtils.nonNull(_voting);
    }

    function executeBatch(CallWithoutValue[] memory calls) external {
        uint256 tokenId = hashNFT.toTokenId(voting, CallLib.hashCallWithoutValueArray(calls));
        hashNFT.burn(address(this), tokenId, 1); // reverts if tokenId isn't owned.
        GovernanceProxy(immutableOwner).executeBatch(calls);
    }

    function executeBatchWithClearance(
        CallWithoutValue[] memory calls,
        uint256 accessLevel
    ) external onlyAccess(accessLevel) {
        for (uint256 i = 0; i < calls.length; i++) {
            require(calls[i].callData.length >= 4, "Invalid call data");
            bytes4 selector = bytes4(calls[i].callData);
            require(
                accessLevelByAddressBySelector[calls[i].to][selector] == accessLevel,
                "Call not allowed"
            );
        }
        GovernanceProxy(immutableOwner).executeBatch(calls);
    }

    function transferVoting(address newVoting) external onlyOwner {
        voting = newVoting;
    }

    function setAccessLevel(address addr, bytes4 selector, uint256 accessLevel) external onlyOwner {
        // We cannot allow setting access level for this contract, since that would enable a designated
        // caller to escalate their access level to include all privilaged functions in the system.
        // By disallowing access levels for this contract we ensure that only the voting system can
        // set access levels for other contracts.
        require(addr != address(this), "Cannot set access level for this contract");
        accessLevelByAddressBySelector[addr][selector] = accessLevel;
    }

    function onERC1155Received(
        address /* operator */,
        address /* from */,
        uint256 /* id */,
        uint256 /* value */,
        bytes calldata /* data */
    ) external view returns (bytes4) {
        require(msg.sender == address(hashNFT), "Only hashNFT");
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address /* operator */,
        address /* from */,
        uint256[] calldata /* ids */,
        uint256[] calldata /* values */,
        bytes calldata /* data */
    ) external view returns (bytes4) {
        require(msg.sender == address(hashNFT), "Only hashNFT");
        return this.onERC1155BatchReceived.selector;
    }
}
