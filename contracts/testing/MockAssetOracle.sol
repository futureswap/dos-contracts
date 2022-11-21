// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Strings.sol";
import "../interfaces/IAssetValueOracle.sol";

contract MockAssetOracle is IAssetValueOracle {
    uint8 immutable decimals;
    int256 public price;

    constructor(uint8 _decimals) {
        require(
            _decimals < 77,
            string.concat(
                "Cannot create a mock asset oracle with base currency decimals above 77, while provided is ",
                Strings.toString(_decimals),
                ". int256 has 77 digits, so having decimals above that value cannot be represented"
            )
        );
        decimals = _decimals;
    }

    function calcValue(int256 balance) external view override returns (int256) {
        return (balance * price) / int256(10 ** decimals);
    }

    function setPrice(int256 _price) external {
        price = _price;
    }

    function getPrice() external view returns (int) {
        return price;
    }
}
