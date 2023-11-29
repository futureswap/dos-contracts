// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Receiver.sol";
import "../lib/FsUtils.sol";
import "../lib/ImmutableGovernance.sol";
import "../lib/AccessControl.sol";
import "../tokens/HashNFT.sol";
import "../lib/Call.sol";

// This is a proxy contract representing governance. This allows a fixed
// ethereum address to be the indefinite owner of the system. This works
// nicely with ImmutableGovernance allowing owner to be stored in contract
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
    event BatchExecuted(CallWithoutValue[] calls);

    error OnlyGovernance();

    constructor(address _governance) {
        governance = FsUtils.nonNull(_governance);
    }

    /// @notice Execute a batch of contract calls.
    /// @param calls an array of calls.
    function executeBatch(CallWithoutValue[] calldata calls) external {
        if (msg.sender != governance) {
            // If the caller is not governance we only accept if the previous
            // governance has proposed it as the new governance account.
            if (msg.sender != proposedGovernance) revert OnlyGovernance();
            emit GovernanceChanged(governance, msg.sender);
            governance = msg.sender;
            proposedGovernance = address(0);
        }
        // Instead of monitoring each configuration change we opt for a
        // simpler approach where we just emit an event for each batch of
        // privileged calls.
        emit BatchExecuted(calls);
        CallLib.executeBatchWithoutValue(calls);
    }

    /// @notice Propose a new account as governance account. Note that this can
    /// only be called through the execute method above and hence only
    /// by the current governance.
    /// @param newGovernance address of the new governance account (or zero to revoke proposal)
    function proposeGovernance(address newGovernance) external {
        if (msg.sender != address(this)) revert OnlyGovernance();
        emit NewGovernanceProposed(newGovernance);
        proposedGovernance = newGovernance;
    }
}

contract Governance is AccessControl, ERC1155Receiver {
    address public voting;
    uint256 public maxSupportedGasCost = 8e6;
    mapping(address => mapping(bytes4 => uint256)) public bitmaskByAddressBySelector;

    event ExecutionFailed(uint256 indexed messageId, string reason);
    event ExecutionSucceeded(uint256 indexed messageId);
    event MaxSupportedGasCostSet(uint256 indexed newMaxSupportedGasCost);

    error AccessDenied(address account, uint8 accessLevel);
    error InvalidCall(address to, bytes callData);
    error CallDenied(address to, bytes callData, uint8 accessLevel);
    error PrivilagedMethod(address to, bytes4 selector);
    error OnlyHashNFT();
    error InsufficientGas();

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

        // For governance calls we do not want them to revert and be in limbo. Thus if the batch
        // reverts we should still burn the NFT. The only caveat is that we want to prevent
        // sabotage votes by executing with insufficient gas and provoking a spurious revert.
        bool failed = false;
        string memory reason = "";
        try governanceProxy().executeBatch(calls) {} catch Error(string memory _reason) {
            failed = true;
            reason = _reason;
        } catch {
            failed = true;
        }
        if (failed) {
            // 1/64th of the gas is left in case the execution fails because of OOG. We need to
            // require that this exceeds maxSupportedGasCost / 64 to ensure that in case it
            // reverted because of OOG the execution was given ample gas.
            if (gasleft() < maxSupportedGasCost / 64) revert InsufficientGas();
            emit ExecutionFailed(tokenId, reason);
        } else {
            emit ExecutionSucceeded(tokenId);
        }
    }

    function executeBatchWithClearance(
        CallWithoutValue[] memory calls,
        uint8 accessLevel
    ) external {
        if (!hasAccess(msg.sender, accessLevel)) revert AccessDenied(msg.sender, accessLevel);
        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].callData.length < 4) revert InvalidCall(calls[i].to, calls[i].callData);
            bytes4 selector = bytes4(calls[i].callData);
            if ((bitmaskByAddressBySelector[calls[i].to][selector] & (1 << accessLevel)) == 0) {
                revert CallDenied(calls[i].to, calls[i].callData, accessLevel);
            }
        }
        governanceProxy().executeBatch(calls);
    }

    function transferVoting(address newVoting) external onlyGovernance {
        voting = FsUtils.nonNull(newVoting);
    }

    function setAccessLevel(
        address addr,
        bytes4 selector,
        uint8 accessLevel,
        bool allowed
    ) external onlyGovernance {
        // We cannot allow setting access level for this contract, since that would enable a designated
        // caller to escalate their access level to include all privilaged functions in the system.
        // By disallowing access levels for this contract we ensure that only the voting system can
        // set access levels for other contracts. The same holds for proposeGovernance on the governance
        // proxy.
        if (
            (addr == address(this) && selector != this.revokeAccess.selector) ||
            addr == immutableGovernance
        ) {
            revert PrivilagedMethod(addr, selector);
        }
        if (allowed) {
            bitmaskByAddressBySelector[addr][selector] |= 1 << accessLevel;
        } else {
            bitmaskByAddressBySelector[addr][selector] &= ~(1 << accessLevel);
        }
    }

    function setMaxSupportedGasCost(uint256 _maxSupportedGasCost) external onlyGovernance {
        require(_maxSupportedGasCost > 0, "Governance: invalid gas cost");
        maxSupportedGasCost = _maxSupportedGasCost;
        emit MaxSupportedGasCostSet(_maxSupportedGasCost);
    }

    function onERC1155Received(
        address /* operator */,
        address /* from */,
        uint256 /* id */,
        uint256 /* value */,
        bytes calldata /* data */
    ) external view returns (bytes4) {
        if (msg.sender != address(hashNFT)) revert OnlyHashNFT();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address /* operator */,
        address /* from */,
        uint256[] calldata /* ids */,
        uint256[] calldata /* values */,
        bytes calldata /* data */
    ) external view returns (bytes4) {
        if (msg.sender != address(hashNFT)) revert OnlyHashNFT();
        return this.onERC1155BatchReceived.selector;
    }

    function governanceProxy() internal view returns (GovernanceProxy) {
        return GovernanceProxy(immutableGovernance);
    }
}
