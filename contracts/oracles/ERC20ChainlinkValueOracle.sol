// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "../lib/FsUtils.sol";
import "../interfaces/IERC20ValueOracle.sol";

import {ImmutableGovernance} from "../lib/ImmutableGovernance.sol";

contract ERC20ChainlinkValueOracle is ImmutableGovernance, IERC20ValueOracle {
    AggregatorV3Interface priceOracle;
    int256 immutable base;
    int256 collateralFactor = 1 ether;
    int256 borrowFactor = 1 ether;

    modifier checkDecimals(string memory label, uint8 decimals) {
        if (decimals < 3 || 18 < decimals) {
            // prettier-ignore
            revert(string.concat(
                "Invalid ", label, ": must be within [3, 18] range while provided is ",
                Strings.toString(decimals)
            ));
        }
        _;
    }

    constructor(
        address chainlink,
        uint8 baseDecimals,
        uint8 tokenDecimals,
        int256 _collateralFactor,
        int256 _borrowFactor,
        address _owner
    )
        ImmutableGovernance(_owner)
        checkDecimals("baseDecimals", baseDecimals)
        checkDecimals("tokenDecimals", tokenDecimals)
    {
        priceOracle = AggregatorV3Interface(FsUtils.nonNull(chainlink));
        base = int256(10) ** (tokenDecimals + priceOracle.decimals() - baseDecimals);
        collateralFactor = _collateralFactor;
        borrowFactor = _borrowFactor;
    }

    function setRiskFactors(
        int256 _collateralFactor,
        int256 _borrowFactor
    ) external onlyGovernance {
        collateralFactor = _collateralFactor;
        borrowFactor = _borrowFactor;
    }

    function calcValue(
        int256 balance
    ) external view override returns (int256 value, int256 riskAdjustedValue) {
        (, int256 price, , , ) = priceOracle.latestRoundData();
        value = (balance * price) / base;
        if (balance >= 0) {
            riskAdjustedValue = (value * collateralFactor) / 1 ether;
        } else {
            riskAdjustedValue = (value * 1 ether) / borrowFactor;
        }
        return (value, riskAdjustedValue);
    }
}
