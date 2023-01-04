// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../interfaces/IDOS.sol";
import "../lib/FsUtils.sol";

/// @title the state part of the DSafeLogic. A parent to all contracts that form dSafe
/// @author Aleksey Bobyr
/// @dev the contract is abstract because it is not expected to be used separately from dSafe
abstract contract DSafeState {
    /// @dev DOS instance to be used by all other dSafe contracts
    IDOS public immutable dos;

    bool internal forwardNFT; // TODO: find better way to dedup between proxy / logic

    /// @param _dos - address of a deployed DOS contract
    constructor(address _dos) {
        // slither-disable-next-line missing-zero-check
        dos = IDOS(FsUtils.nonNull(_dos));
    }
}
