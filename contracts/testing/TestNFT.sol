// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Counters} from "@openzeppelin/contracts/utils/Counters.sol";

contract TestNFT is ERC721 {
    using Counters for Counters.Counter;
    Counters.Counter private tokenIdCounter;

    event Mint(uint256 tokenId);

    constructor(
        string memory name,
        string memory symbol,
        uint256 initTokenId
    ) ERC721(name, symbol) {
        tokenIdCounter._value = initTokenId;
    }

    function mint(address to) public returns (uint256) {
        uint256 tokenId = tokenIdCounter.current();
        tokenIdCounter.increment();
        _mint(to, tokenId);
        emit Mint(tokenId);
        return tokenId;
    }
}
