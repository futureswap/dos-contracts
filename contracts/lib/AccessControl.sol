// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../tokens/HashNFT.sol";
import "../lib/FsUtils.sol";
import "./ImmutableOwnable.sol";

/// @title AccessControl
/// @notice Access control based on HashNFT ownership.
/// @dev The owner can grant access rights to an address by minting a HashNFT token
/// to the address with digest the EIP712 hash of the access level.
contract AccessControl is ImmutableOwnable, EIP712 {
    enum AccessLevel {
        INVALID, // 0 is invalid as it's default for empty storage slots
        SECURITY, // Can operate immediately on pausing exchange
        FINANCIAL_RISK // Can set fees, risk factors and interest rates
    }

    HashNFT internal immutable hashNFT;

    bytes constant ACCESSLEVEL_TYPESTRING = "AccessLevel(uint256 accessLevel)";
    bytes32 constant ACCESSLEVEL_TYPEHASH = keccak256(ACCESSLEVEL_TYPESTRING);

    modifier onlyAccess(uint256 accessLevel) {
        require(accessLevel != uint256(AccessLevel.INVALID), "AccessControl: invalid access level");
        require(hasAccess(msg.sender, accessLevel), "AccessControl: access denied");
        _;
    }

    constructor(
        address owner,
        address hashNFT_
    ) ImmutableOwnable(owner) EIP712("AccessControl", "1") {
        hashNFT = HashNFT(FsUtils.nonNull(hashNFT_));
    }

    function hasAccess(address account, uint256 accessLevel) public view returns (bool) {
        return
            hashNFT.balanceOf(account, hashNFT.toTokenId(immutableOwner, digest(accessLevel))) > 0;
    }

    function digest(uint256 accessLevel) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(ACCESSLEVEL_TYPEHASH, accessLevel)));
    }
}
