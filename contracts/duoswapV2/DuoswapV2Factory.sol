// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.7;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import {IDuoswapV2Pair, DuoswapV2Pair} from "./DuoswapV2Pair.sol";

contract DuoswapV2Factory is IUniswapV2Factory {
    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();

    bytes32 public constant PAIR_HASH = keccak256(type(DuoswapV2Pair).creationCode);

    address public dos;
    address public override feeTo;
    address public override feeToSetter;

    mapping(address => mapping(address => address)) public override getPair;
    address[] public override allPairs;

    constructor(address _dos, address _feeToSetter) {
        dos = _dos;
        feeToSetter = _feeToSetter;
    }

    function createPair(address tokenA, address tokenB) external override returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        pair = address(new DuoswapV2Pair{salt: keccak256(abi.encodePacked(token0, token1))}());
        IDuoswapV2Pair(pair).initialize(dos, token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external override {
        if (msg.sender != feeToSetter) revert Forbidden();
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external override {
        if (msg.sender != feeToSetter) revert Forbidden();
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view override returns (uint256) {
        return allPairs.length;
    }
}
