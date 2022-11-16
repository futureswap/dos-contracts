//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "../dosERC20/DOSERC20.sol";

contract TestERC20 is DOSERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint8 decimals
    ) DOSERC20(name, symbol, decimals) {}
}
