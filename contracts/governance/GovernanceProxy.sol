// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {FsUtils} from "../lib/FsUtils.sol";
import {ImmutableGovernance} from "../lib/ImmutableGovernance.sol";
import {CallLib, CallWithoutValue} from "../lib/Call.sol";

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
