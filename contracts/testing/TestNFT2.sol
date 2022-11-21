//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract TestNFT2 is ERC721 {
    using Counters for Counters.Counter;
    Counters.Counter private tokenIdCounter;

    event Mint(uint256 tokenId);

    constructor() ERC721("TestNFT2", "TN2") {
        tokenIdCounter._value = 200;
    }

    function mint(address to) public returns (uint256) {
        uint256 tokenId = tokenIdCounter.current();
        tokenIdCounter.increment();
        _mint(to, tokenId);
        emit Mint(tokenId);
        return tokenId;
    }
}
