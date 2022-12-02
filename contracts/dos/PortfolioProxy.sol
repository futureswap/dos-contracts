//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { FsUtils } from "../lib/FsUtils.sol";
import { IDOS } from "../interfaces/IDOS.sol";

// Inspired by TransparantUpdateableProxy
contract PortfolioProxy is Proxy {
    using Address for address;

    address public immutable dos;

    modifier ifDos() {
        if (msg.sender == dos) {
            _;
        } else {
            _fallback();
        }
    }

    constructor(address _dos) {
        // slither-disable-next-line missing-zero-check
        dos = FsUtils.nonNull(_dos);
    }

    // The implementation of the delegate is controlled by DOS
    function _implementation() internal view override returns (address) {
        return IDOS(dos).getImplementation(address(this));
    }

    // Allow DOS to make arbitrary calls in lieu of this portfolio
    function doCall(
        address to,
        bytes calldata callData,
        uint256 value
    ) external ifDos returns (bytes memory) {
        return to.functionCallWithValue(callData, value);
    }
}

// Calls to the contract not coming from DOS itself are routed to this logic
// contract. This allows for flexible extra addition to your portfolio.
contract PortfolioLogic is IERC721Receiver, IERC1271 {
    address public immutable dos;

    constructor(address _dos) {
        // slither-disable-next-line missing-zero-check
        dos = FsUtils.nonNull(_dos);
    }

    function owner() external view returns (address) {
        return IDOS(dos).getPortfolioOwner(address(this));
    }

    modifier onlyOwner() {
        require(IDOS(dos).getPortfolioOwner(address(this)) == msg.sender, "");
        _;
    }

    function executeBatch(IDOS.Call[] memory calls) external onlyOwner {
        IDOS(dos).executeBatch(calls);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) public view returns (bytes4 magicValue) {
        // TODO: need an implementation in order to use permit2
    }

    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes memory /* data */
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
