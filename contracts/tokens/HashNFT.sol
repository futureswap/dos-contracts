// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {ERC1155Burnable, ERC1155} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";

/// @title HashNFT a NFT for cryptographic proof of ownership.
/// @notice A generic ownerless contract that allows fine grained access control,
/// voting and other use cases build on top of.
/// @dev The 256 bit tokenId of ERC1155 is used to store cryptographic hash of the
/// an arbitrary digest and minter address. The cryptographic security of the hash
/// provides the guarantees of the contract.
/// 1) Each token id is associated with only one minter and digest.
/// 2) Ownership of a token id implies the minter has granted (directly or indirectly)
///    the ownership to the owner. (The minter can revoke the token at any time.
/// 3) A minter (and only the minter) can revoke tokens it issued itself.
/// 4) Everyone can burn tokens they own.
contract HashNFT is ERC1155Burnable {
    bytes constant HASHNFT_TYPESTRING = "HashNFT(address minter,bytes32 digest)";
    bytes32 constant HASHNFT_TYPEHASH = keccak256(HASHNFT_TYPESTRING);

    event Minted(uint256 indexed tokenId, address indexed minter, bytes32 indexed digest);

    constructor(string memory uri) ERC1155(uri) {}

    function mint(
        address to,
        bytes32 digest,
        bytes calldata data
    ) external returns (uint256 tokenId) {
        tokenId = toTokenId(msg.sender, digest);
        _mint(to, tokenId, 1, data);
        emit Minted(tokenId, msg.sender, digest);
    }

    // The minter can revoke tokens it minted.
    function revoke(address from, bytes32 digest) external {
        uint256 tokenId = toTokenId(msg.sender, digest);
        _burn(from, tokenId, 1);
    }

    // Crypto secure hash function, to ensure only valid digest are recognized
    function toTokenId(address minter, bytes32 digest) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(HASHNFT_TYPEHASH, minter, digest)));
    }
}
