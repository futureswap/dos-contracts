// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../interfaces/IERC20ValueOracle.sol";
import "../lib/ImmutableOwnable.sol";

contract MockERC20Oracle is IERC20ValueOracle, ImmutableOwnable {
    int256 public price;

    constructor(address owner) ImmutableOwnable(owner) {}

    function setPrice(int256 _price, uint256 baseDecimals, uint256 decimals) external onlyOwner {
        price = (_price * (int256(10) ** (18 + baseDecimals - decimals))) / 1 ether;
    }

    function calcValue(int256 amount) external view override returns (int256) {
        return (amount * price) / 1 ether;
    }
}
