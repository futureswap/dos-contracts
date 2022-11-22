//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../lib/ImmutableOwnable.sol";

contract HashNFT is ERC721Burnable, ImmutableOwnable, IERC721Receiver {
    uint256 public mintingNonce;
    mapping(address => bool) isValidBridgeNFT;

    constructor(
        string memory name,
        string memory symbol,
        address owner
    ) ERC721(name, symbol) ImmutableOwnable(owner) {}

    function mint(address to, bytes32 digest) external returns (uint256 tokenId, uint256 nonce) {
        nonce = mintingNonce++;
        tokenId = toTokenId(msg.sender, nonce, digest);
        _safeMint(to, tokenId);
    }

    function burnAsDigest(address minter, uint256 nonce, bytes32 digest) external {
        uint256 tokenId = toTokenId(minter, nonce, digest);
        require(_ownerOf(tokenId) != address(0), "Invalid NFT");
        require(_ownerOf(tokenId) == msg.sender, "Only owner can burn NFT");
        _burn(tokenId);
    }

    function setBridgeNFT(address operator, bool status) external onlyOwner {
        isValidBridgeNFT[operator] = status;
    }

    function onERC721Received(
        address operator,
        address /* from */,
        uint256 tokenId,
        bytes calldata /* data */
    ) external override returns (bytes4) {
        require(isValidBridgeNFT[msg.sender], "only approved NFTs");
        ERC721Burnable(msg.sender).burn(tokenId);
        _safeMint(operator, tokenId);
        return this.onERC721Received.selector;
    }

    // Crypto secure hash function, to ensure only valid digest are recognized
    function toTokenId(
        address minter,
        uint256 nonce,
        bytes32 digest
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(minter, nonce, digest)));
    }
}

contract BridgeNFT is ERC721Burnable, ImmutableOwnable, IERC721Receiver {
    ERC721Burnable immutable hashNFT;

    constructor(
        address _hashNFT,
        string memory name,
        string memory symbol,
        address owner
    ) ERC721(name, symbol) ImmutableOwnable(owner) {
        hashNFT = ERC721Burnable(FsUtils.nonNull(_hashNFT));
    }

    function mint(address to, uint256 tokenId) external onlyOwner {
        _safeMint(to, tokenId);
    }

    function onERC721Received(
        address operator,
        address /* from */,
        uint256 tokenId,
        bytes calldata /* data */
    ) external override returns (bytes4) {
        require(msg.sender == address(hashNFT), "only approved NFTs");
        hashNFT.burn(tokenId);
        _safeMint(operator, tokenId);
        return this.onERC721Received.selector;
    }
}
