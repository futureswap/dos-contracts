// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./FsUtils.sol";

contract ImmutableOwnable {
    address public immutable owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(address _owner) {
        // slither-disable-next-line missing-zero-check
        owner = FsUtils.nonNull(_owner);
    }
}
