// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Script.sol";

import {DuoswapV2Pair} from "../contracts/duoswapV2/DuoswapV2Pair.sol";

contract PairHashCodeScript is Script {
    function setUp() public {}

    function run() public view {
        // get bytecode for DuoswapV2Pair
        bytes memory bytecode = type(DuoswapV2Pair).creationCode;
        bytes32 hash = keccak256(bytes(bytecode));

        console2.logBytes32(hash);
    }
}

// forge script script/PairHashCode.s.sol:PairHashCodeScript
