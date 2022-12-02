// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../interfaces/INFTValueOracle.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract MockNFTOracle is INFTValueOracle {
    mapping(uint256 => int256) prices;

    function setPrice(uint256 tokenId, int256 price) external {
        require(
            price != -1,
            "Please, don't use -1 as NFT price - it's a reserved value used for early error detection"
        );
        prices[tokenId] = price + 1;
    }

    function calcValue(uint256 tokenId) external view override returns (int256) {
        require(
            prices[tokenId] > 0,
            string.concat(
                "Price for the NFT with tokenId ",
                Strings.toString(tokenId),
                " is not set"
            )
        );
        return prices[tokenId] - 1;
    }
}
