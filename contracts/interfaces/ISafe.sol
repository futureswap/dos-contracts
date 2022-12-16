// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IDOS} from "./IDOS.sol";

interface ISafe {
    function executeBatch(IDOS.Call[] memory calls) external payable;
}
