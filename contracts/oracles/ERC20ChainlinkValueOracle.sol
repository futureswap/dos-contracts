// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../lib/FsUtils.sol";
import "../interfaces/IERC20ValueOracle.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract ERC20ChainlinkValueOracle is IERC20ValueOracle {
    AggregatorV3Interface priceOracle;
    int256 immutable base;

    constructor(address chainlink, uint8 baseDecimals, uint8 tokenDecimals) {
        priceOracle = AggregatorV3Interface(FsUtils.nonNull(chainlink));
        base = int256(10) ** (tokenDecimals + priceOracle.decimals() - baseDecimals);
    }

    function calcValue(int256 balance) external view override returns (int256) {
        (, int256 price, , , ) = priceOracle.latestRoundData();
        return (balance * price) / base;
    }
}
