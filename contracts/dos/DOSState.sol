// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import {IDOSConfig, ERC20Pool, ERC20Share, NFTTokenData, ERC20Info, ERC721Info, ContractData, ContractKind} from "../interfaces/IDOS.sol";
import {IVersionManager} from "../interfaces/IVersionManager.sol";
import {DSafeLib} from "../lib/DSafeLib.sol";
import {ERC20PoolLib} from "../lib/ERC20PoolLib.sol";

/// @title DOS State
/// @notice Contract holds the configuration state for DOS
contract DOSState is Pausable {
    using ERC20PoolLib for ERC20Pool;

    /// @notice Only dSafe can call this function
    error OnlyDSafe();
    /// @notice Recipient is not a valid dSafe
    error DSafeNonExistent();
    /// @notice Asset is not registered
    /// @param token The unregistered asset
    error NotRegistered(address token);

    IVersionManager public versionManager;
    /// @notice mapping between dSafe address and DOS-specific dSafe data
    mapping(address => DSafeLib.DSafe) public dSafes;

    /// @notice mapping between dSafe address and the proposed new owner
    /// @dev `proposedNewOwner` is address(0) when there is no pending change
    mapping(address => address) public dSafeProposedNewOwner;

    /// @notice mapping between dSafe address and an instance of deployed dSafeLogic contract.
    /// It means that this specific dSafeLogic version is setup to operate the dSafe.
    // @dev this could be a mapping to a version index instead of the implementation address
    mapping(address => address) public dSafeLogic;

    /// @notice mapping from
    /// dSafe owner address => ERC20 address => dSafe spender address => allowed amount of ERC20.
    /// It represent the allowance of `spender` to transfer up to `amount` of `erc20` balance of
    /// owner's dAccount to some other dAccount. E.g. 123 => abc => 456 => 1000, means that
    /// dSafe 456 can transfer up to 1000 of abc tokens from dAccount of dSafe 123 to some other dAccount.
    /// Note, that no ERC20 are actually getting transferred - dAccount is a DOS concept, and
    /// corresponding tokens are owned by DOS
    mapping(address => mapping(address => mapping(address => uint256))) public allowances;

    /// @notice Whether a spender is approved to operate on behalf of an owner
    /// @dev Mapping from dSafe owner address => spender address => bool
    mapping(address => mapping(address => bool)) public operatorApprovals;

    mapping(DSafeLib.NFTId => NFTTokenData) public tokenDataByNFTId;

    ERC20Info[] public erc20Infos;
    ERC721Info[] public erc721Infos;

    /// @notice mapping of ERC20 or ERC721 address => DOS asset idx and contract kind.
    /// idx is the index of the ERC20 in `erc20Infos` or ERC721 in `erc721Infos`
    /// kind is ContractKind enum, that here can be ERC20 or ERC721
    mapping(address => ContractData) public infoIdx;

    IDOSConfig.Config public config;
    IDOSConfig.TokenStorageConfig public tokenStorageConfig;

    modifier onlyDSafe() {
        if (dSafes[msg.sender].owner == address(0)) {
            revert OnlyDSafe();
        }
        _;
    }

    modifier dSafeExists(address dSafe) {
        if (dSafes[dSafe].owner == address(0)) {
            revert DSafeNonExistent();
        }
        _;
    }

    function getBalance(
        ERC20Share shares,
        ERC20Info storage erc20Info
    ) internal view returns (int256) {
        ERC20Pool storage pool = ERC20Share.unwrap(shares) > 0
            ? erc20Info.collateral
            : erc20Info.debt;
        return pool.computeERC20(shares);
    }

    function getNFTData(
        DSafeLib.NFTId nftId
    ) internal view returns (uint16 erc721Idx, uint256 tokenId) {
        uint256 unwrappedId = DSafeLib.NFTId.unwrap(nftId);
        erc721Idx = uint16(unwrappedId);
        tokenId = tokenDataByNFTId[nftId].tokenId | ((unwrappedId >> 240) << 240);
    }

    function getERC20Info(IERC20 erc20) internal view returns (ERC20Info storage, uint16) {
        if (infoIdx[address(erc20)].kind != ContractKind.ERC20) {
            revert NotRegistered(address(erc20));
        }
        uint16 idx = infoIdx[address(erc20)].idx;
        return (erc20Infos[idx], idx);
    }

    function getERC721Info(IERC721 erc721) internal view returns (ERC721Info storage, uint16) {
        if (infoIdx[address(erc721)].kind != ContractKind.ERC721) {
            revert NotRegistered(address(erc721));
        }
        uint16 idx = infoIdx[address(erc721)].idx;
        return (erc721Infos[idx], idx);
    }
}
