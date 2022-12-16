// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";

contract HashNFT is ERC721Burnable {
    bytes constant HASHNFT_TYPESTRING = "HashNFT(address minter,uint256 nonce,bytes32 digest)";
    bytes32 constant HASHNFT_TYPEHASH = keccak256(HASHNFT_TYPESTRING);

    uint256 public mintingNonce;

    event Minted(uint256 indexed tokenId, address indexed minter, uint256 nonce, bytes32 digest);

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}

    function mint(address to, bytes32 digest) external returns (uint256 tokenId, uint256 nonce) {
        nonce = mintingNonce++;
        tokenId = toTokenId(msg.sender, nonce, digest);
        _safeMint(to, tokenId);
        emit Minted(tokenId, msg.sender, nonce, digest);
    }

    // Crypto secure hash function, to ensure only valid digest are recognized
    function toTokenId(
        address minter,
        uint256 nonce,
        bytes32 digest
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(HASHNFT_TYPEHASH, minter, nonce, digest)));
    }
}
