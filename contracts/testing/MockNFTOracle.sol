// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {INFTValueOracle} from "../interfaces/INFTValueOracle.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract MockNFTOracle is INFTValueOracle {
    mapping(uint256 => int256) prices;
    int256 collateralFactor = 1 ether;

    function setPrice(uint256 tokenId, int256 price) external {
        require(
            price != -1,
            "Please, don't use -1 as NFT price - it's a reserved value used for early error detection"
        );
        prices[tokenId] = price + 1;
    }

    function setCollateralFactor(int256 _collateralFactor) external {
        collateralFactor = _collateralFactor;
    }

    function calcValue(uint256 tokenId) external view override returns (int256, int256) {
        require(
            prices[tokenId] > 0,
            string.concat(
                "Price for the NFT with tokenId ",
                Strings.toString(tokenId),
                " is not set"
            )
        );
        int256 value = prices[tokenId] - 1;
        int256 riskAdjustedValue = (value * collateralFactor) / 1 ether;
        return (value, riskAdjustedValue);
    }
}
