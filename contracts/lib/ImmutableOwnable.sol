// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./FsUtils.sol";

/// @title ImmutableOwnable
/// @dev This contract is meant to be inherited by other contracts, to make them ownable.
contract ImmutableOwnable {
    address public immutable immutableOwner;

    modifier onlyOwner() {
        require(msg.sender == immutableOwner, "Only owner");
        _;
    }

    constructor(address _owner) {
        // slither-disable-next-line missing-zero-check
        immutableOwner = FsUtils.nonNull(_owner);
    }
}
