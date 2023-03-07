// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {FsUtils} from "./FsUtils.sol";

/// @title ImmutableGovernance
/// @dev This contract is meant to be inherited by other contracts, to make them ownable.
contract ImmutableGovernance {
    address public immutable immutableGovernance;

    /// @notice Only governance can call this function
    error OnlyGovernance();

    modifier onlyGovernance() {
        if (msg.sender != immutableGovernance) revert OnlyGovernance();
        _;
    }

    constructor(address governance) {
        // slither-disable-next-line missing-zero-check
        immutableGovernance = FsUtils.nonNull(governance);
    }
}
