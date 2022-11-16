// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../interfaces/INFTValueOracle.sol";

contract MockNFTOracle is INFTValueOracle {
    mapping(uint256 => int256) prices;

    function calcValue(uint256 tokenId) external view override returns (int256) {
        return prices[tokenId] / 1 ether;
    }

    function setPrice(uint256 tokenId, int256 price) external {
        prices[tokenId] = price;
    }
}
