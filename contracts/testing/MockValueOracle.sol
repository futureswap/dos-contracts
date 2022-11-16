// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../interfaces/IAssetValueOracle.sol";

contract MockValueOracle is IAssetValueOracle {
    int256 price;

    function calcValue(int256 balance) external view override returns (int256) {
        return (balance * price) / 1 ether;
    }

    function setPrice(int256 _price) external {
        price = _price;
    }
}
