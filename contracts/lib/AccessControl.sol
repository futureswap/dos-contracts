// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {ERC1155Burnable, IERC1155} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";

import {HashNFT} from "../tokens/HashNFT.sol";
import {FsUtils} from "./FsUtils.sol";
import {ImmutableGovernance} from "../lib/ImmutableGovernance.sol";

/// @title AccessControl
/// @notice Access control based on HashNFT ownership.
/// @dev The owner can grant access rights to an address by minting a HashNFT token
/// to the address with the given access level.
contract AccessControl is ImmutableGovernance {
    enum AccessLevel {
        SECURITY, // Can operate immediately on pausing exchange
        FINANCIAL_RISK // Can set fees, risk factors and interest rates
    }

    HashNFT internal immutable hashNFT;

    constructor(address owner, address hashNFT_) ImmutableGovernance(owner) {
        hashNFT = HashNFT(FsUtils.nonNull(hashNFT_));
        require(
            hashNFT.supportsInterface(type(IERC1155).interfaceId),
            "AccessControl: not HashNFT"
        );
    }

    function mintAccess(
        address to,
        uint256 accessLevel,
        bytes calldata data
    ) external onlyGovernance {
        hashNFT.mint(to, bytes32(accessLevel), data);
    }

    function revokeAccess(address from, uint256 accessLevel) external onlyGovernance {
        hashNFT.revoke(from, bytes32(accessLevel));
    }

    function hasAccess(address account, uint256 accessLevel) public view returns (bool) {
        return
            hashNFT.balanceOf(account, hashNFT.toTokenId(address(this), bytes32(accessLevel))) > 0;
    }
}
