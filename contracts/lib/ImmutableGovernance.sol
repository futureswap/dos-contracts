// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./FsUtils.sol";

/// @title ImmutableGovernance
/// @dev This contract is meant to be inherited by other contracts, to make them ownable.
contract ImmutableGovernance {
    address public immutable immutableGovernance;

    modifier onlyGovernance() {
        require(msg.sender == immutableGovernance, "Only owner");
        _;
    }

    constructor(address governance) {
        // slither-disable-next-line missing-zero-check
        immutableGovernance = FsUtils.nonNull(governance);
    }
}
