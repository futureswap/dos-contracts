// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../interfaces/IERC20ValueOracle.sol";
import "../lib/ImmutableGovernance.sol";

contract MockERC20Oracle is IERC20ValueOracle, ImmutableGovernance {
    int256 public price;
    int256 collateralFactor = 1 ether;
    int256 borrowFactor = 1 ether;

    constructor(address owner) ImmutableGovernance(owner) {}

    function setPrice(
        int256 _price,
        uint256 baseDecimals,
        uint256 decimals
    ) external onlyGovernance {
        price = (_price * (int256(10) ** (18 + baseDecimals - decimals))) / 1 ether;
    }

    function setRiskFactors(
        int256 _collateralFactor,
        int256 _borrowFactor
    ) external onlyGovernance {
        collateralFactor = _collateralFactor;
        borrowFactor = _borrowFactor;
        emit RiskFactorsSet(_collateralFactor, _borrowFactor);
    }

    function calcValue(
        int256 amount
    ) external view override returns (int256 value, int256 riskAdjustedValue) {
        value = (amount * price) / 1 ether;
        riskAdjustedValue = (value * collateralFactor) / 1 ether;
        return (value, riskAdjustedValue);
    }
}
