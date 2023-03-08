// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {ISupa} from "../interfaces/ISupa.sol";
import {FsUtils} from "../lib/FsUtils.sol";

/// @title the state part of the WalletLogic. A parent to all contracts that form wallet
/// @dev the contract is abstract because it is not expected to be used separately from wallet
abstract contract WalletState {
    /// @dev Supa instance to be used by all other wallet contracts
    ISupa public immutable supa;

    /// @param _supa - address of a deployed Supa contract
    constructor(address _supa) {
        // slither-disable-next-line missing-zero-check
        supa = ISupa(FsUtils.nonNull(_supa));
    }
}
