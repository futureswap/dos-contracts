// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../interfaces/IERC20ValueOracle.sol";
import "../lib/ImmutableGovernance.sol";

contract MockERC20Oracle is IERC20ValueOracle, ImmutableGovernance {
    int256 public price;

    constructor(address owner) ImmutableGovernance(owner) {}

    function setPrice(
        int256 _price,
        uint256 baseDecimals,
        uint256 decimals
    ) external onlyGovernance {
        price = (_price * (int256(10) ** (18 + baseDecimals - decimals))) / 1 ether;
    }

    function calcValue(int256 amount) external view override returns (int256, int256) {
        int256 value = (amount * price) / 1 ether;
        int256 riskAdjustedValue;
        return (value, riskAdjustedValue);
    }
}
