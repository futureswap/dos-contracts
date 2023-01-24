// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.4;

//solhint-disable reason-string

import {IDuoswapV2Pair} from "../interfaces/IDuoswapV2Pair.sol";

library DuoswapV2Library {
    // returns sorted token addresses, used to handle return values from pairs sorted in this order
    function sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address token0, address token1) {
        require(tokenA != tokenB, "UniswapV2Library: IDENTICAL_ADDRESSES");
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), "UniswapV2Library: ZERO_ADDRESS");
    }

    // calculates the CREATE2 address for a pair without making any external calls
    function pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) internal pure returns (address pair) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            factory,
                            keccak256(abi.encodePacked(token0, token1)),
                            hex"AF8BE07D4C488236B496BFD4E65DCAEA4194E0843BF0583BC690F54132A60BA0