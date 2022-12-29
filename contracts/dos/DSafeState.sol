// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../interfaces/IDOS.sol";
import "../lib/FsUtils.sol";

abstract contract DSafeState {
    IDOS public immutable dos;

    bool internal forwardNFT; // TODO: find better way to dedup between proxy / logic

    constructor(address _dos) {
        // slither-disable-next-line missing-zero-check
        dos = IDOS(FsUtils.nonNull(_dos));
    }
}
