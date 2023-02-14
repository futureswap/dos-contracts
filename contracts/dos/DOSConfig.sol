// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import {DOSState} from "./DOSState.sol";
import {DSafeProxy} from "../dsafe/DSafeProxy.sol";
import {IDOSConfig, ERC20Pool, ERC20Share, ERC20Info, ERC721Info, ContractData, ContractKind} from "../interfaces/IDOS.sol";
import {IVersionManager} from "../interfaces/IVersionManager.sol";
import {IERC20ValueOracle} from "../interfaces/IERC20ValueOracle.sol";
import {INFTValueOracle} from "../interfaces/INFTValueOracle.sol";
import {ImmutableGovernance} from "../lib/ImmutableGovernance.sol";
import {DSafeLib} from "../lib/DSafeLib.sol";
import {ERC20PoolLib} from "../lib/ERC20PoolLib.sol";

/// @title DOS Config
contract DOSConfig is DOSState, ImmutableGovernance, IDOSConfig {
    using DSafeLib for DSafeLib.DSafe;
    using ERC20PoolLib for ERC20Pool;
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Asset is not an NFT
    error NotNFT();
    /// @notice The address is not a registered ERC20
    error NotERC20();
    /// @notice The implementation is not a contract
    error InvalidImplementation();
    /// @notice The version is deprecated
    error DeprecatedVersion();
    /// @notice The bug level is too high
    error BugLevelTooHigh();
    /// @notice `newOwner` is not the proposed new owner
    /// @param proposedOwner The address of the proposed new owner
    /// @param newOwner The address of the attempted new owner
    error InvalidNewOwner(address proposedOwner, address newOwner);

    constructor(address _owner) ImmutableGovernance(_owner) {}

    /// @notice upgrades the version of dSafeLogic contract for the `dSafe`
    /// @param version The new target version of dSafeLogic contract
    function upgradeDSafeImplementation(
        string calldata version
    ) external override onlyDSafe whenNotPaused {
        (
            ,
            IVersionManager.Status status,
            IVersionManager.BugLevel bugLevel,
            address implementation,

        ) = versionManager.getVersionDetails(version);
        if (implementation == address(0) || !implementation.isContract()) {
            revert InvalidImplementation();
        }
        if (status == IVersionManager.Status.DEPRECATED) {
            revert DeprecatedVersion();
        }
        if (bugLevel != IVersionManager.BugLevel.NONE) {
            revert BugLevelTooHigh();
        }
        dSafeLogic[msg.sender] = implementation;
        emit IDOSConfig.DSafeImplementationUpgraded(msg.sender, version, implementation);
    }

    /// @notice Proposes the ownership transfer of `dSafe` to the `newOwner`
    /// @dev The ownership transfer must be executed by the `newOwner` to complete the transfer
    /// @dev emits `DSafeOwnershipTransferProposed` event
    /// @param newOwner The new owner of the `dSafe`
    function proposeTransferDSafeOwnership(
        address newOwner
    ) external override onlyDSafe whenNotPaused {
        dSafeProposedNewOwner[msg.sender] = newOwner;
        emit IDOSConfig.DSafeOwnershipTransferProposed(msg.sender, newOwner);
    }

    /// @notice Executes the ownership transfer of `dSafe` to the `newOwner`
    /// @dev The caller must be the `newOwner` and the `newOwner` must be the proposed new owner
    /// @dev emits `DSafeOwnershipTransferred` event
    /// @param dSafe The address of the dSafe
    function executeTransferDSafeOwnership(address dSafe) external override whenNotPaused {
        if (msg.sender != dSafeProposedNewOwner[dSafe]) {
            revert InvalidNewOwner(dSafeProposedNewOwner[dSafe], msg.sender);
        }
        dSafes[dSafe].owner = msg.sender;
        delete dSafeProposedNewOwner[dSafe];
        emit IDOSConfig.DSafeOwnershipTransferred(dSafe, msg.sender);
    }

    /// @notice Pause the contract
    function pause() external override onlyGovernance {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external override onlyGovernance {
        _unpause();
    }

    /// @notice add a new ERC20 to be used inside DOS
    /// @dev For governance only.
    /// @param erc20Contract The address of ERC20 to add
    /// @param name The name of the ERC20. E.g. "Wrapped ETH"
    /// @param symbol The symbol of the ERC20. E.g. "WETH"
    /// @param decimals Decimals of the ERC20. E.g. 18 for WETH and 6 for USDC
    /// @param valueOracle The address of the Value Oracle. Probably Uniswap one
    /// @param baseRate The interest rate when utilization is 0
    /// @param slope1 The interest rate slope when utilization is less than the targetUtilization
    /// @param slope2 The interest rate slope when utilization is more than the targetUtilization
    /// @param targetUtilization The target utilization for the asset
    /// @return the index of the added ERC20 in the erc20Infos array
    function addERC20Info(
        address erc20Contract,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address valueOracle,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    ) external override onlyGovernance returns (uint16) {
        uint16 erc20Idx = uint16(erc20Infos.length);
        erc20Infos.push(
            ERC20Info(
                erc20Contract,
                IERC20ValueOracle(valueOracle),
                ERC20Pool(0, 0),
                ERC20Pool(0, 0),
                baseRate,
                slope1,
                slope2,
                targetUtilization,
                block.timestamp
            )
        );
        infoIdx[erc20Contract] = ContractData(erc20Idx, ContractKind.ERC20);
        emit IDOSConfig.ERC20Added(
            erc20Idx,
            erc20Contract,
            name,
            symbol,
            decimals,
            valueOracle,
            baseRate,
            slope1,
            slope2,
            targetUtilization
        );
        return erc20Idx;
    }

    /// @notice Add a new ERC721 to be used inside DOS.
    /// @dev For governance only.
    /// @param erc721Contract The address of the ERC721 to be added
    /// @param valueOracleAddress The address of the Uniswap Oracle to get the price of a token
    function addERC721Info(
        address erc721Contract,
        address valueOracleAddress
    ) external override onlyGovernance {
        if (!IERC165(erc721Contract).supportsInterface(type(IERC721).interfaceId)) {
            revert NotNFT();
        }
        INFTValueOracle valueOracle = INFTValueOracle(valueOracleAddress);
        uint256 erc721Idx = erc721Infos.length;
        erc721Infos.push(ERC721Info(erc721Contract, valueOracle));
        infoIdx[erc721Contract] = ContractData(uint16(erc721Idx), ContractKind.ERC721);
        emit IDOSConfig.ERC721Added(erc721Idx, erc721Contract, valueOracleAddress);
    }

    /// @notice Updates the config of DOS
    /// @dev for governance only.
    /// @param _config the Config of IDOSConfig. A struct with DOS parameters
    function setConfig(Config calldata _config) external override onlyGovernance {
        config = _config;
        emit IDOSConfig.ConfigSet(_config);
    }

    /// @notice Set the address of Version Manager contract
    /// @dev for governance only.
    /// @param _versionManager The address of the Version Manager contract to be set
    function setVersionManager(address _versionManager) external override onlyGovernance {
        versionManager = IVersionManager(_versionManager);
        emit IDOSConfig.VersionManagerSet(_versionManager);
    }

    /// @notice Updates some of ERC20 config parameters
    /// @dev for governance only.
    /// @param erc20 The address of ERC20 contract for which DOS config parameters should be updated
    /// @param valueOracle The address of the erc20 value oracle
    /// @param baseRate The interest rate when utilization is 0
    /// @param slope1 The interest rate slope when utilization is less than the targetUtilization
    /// @param slope2 The interest rate slope when utilization is more than the targetUtilization
    /// @param targetUtilization The target utilization for the asset
    function setERC20Data(
        address erc20,
        address valueOracle,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    ) external override onlyGovernance {
        uint16 erc20Idx = infoIdx[erc20].idx;
        if (infoIdx[erc20].kind != ContractKind.ERC20) {
            revert NotERC20();
        }
        erc20Infos[erc20Idx].valueOracle = IERC20ValueOracle(valueOracle);
        erc20Infos[erc20Idx].baseRate = baseRate;
        erc20Infos[erc20Idx].slope1 = slope1;
        erc20Infos[erc20Idx].slope2 = slope2;
        erc20Infos[erc20Idx].targetUtilization = targetUtilization;
        emit IDOSConfig.ERC20DataSet(
            erc20,
            erc20Idx,
            valueOracle,
            baseRate,
            slope1,
            slope2,
            targetUtilization
        );
    }

    /// @notice creates a new dSafe with sender as the owner and returns the dSafe address
    /// @return dSafe The address of the created dSafe
    function createDSafe() external override whenNotPaused returns (address dSafe) {
        address[] memory erc20s = new address[](erc20Infos.length);
        for (uint256 i = 0; i < erc20Infos.length; i++) {
            erc20s[i] = erc20Infos[i].erc20Contract;
        }
        address[] memory erc721s = new address[](erc721Infos.length);
        for (uint256 i = 0; i < erc721Infos.length; i++) {
            erc721s[i] = erc721Infos[i].erc721Contract;
        }

        dSafe = address(new DSafeProxy(address(this), erc20s, erc721s));
        dSafes[dSafe].owner = msg.sender;

        // add a version parameter if users should pick a specific version
        (, , , address implementation, ) = versionManager.getRecommendedVersion();
        dSafeLogic[dSafe] = implementation;
        emit IDOSConfig.DSafeCreated(dSafe, msg.sender);
    }

    /// @notice Returns the amount of `erc20` tokens on dAccount of dSafe
    /// @param dSafeAddr The address of the dSafe for which dAccount the amount of `erc20` should
    /// be calculated
    /// @param erc20 The address of ERC20 which balance on dAccount of `dSafe` should be calculated
    /// @return the amount of `erc20` on the dAccount of `dSafe`
    function getDAccountERC20(
        address dSafeAddr,
        IERC20 erc20
    ) external view override returns (int256) {
        DSafeLib.DSafe storage dSafe = dSafes[dSafeAddr];
        (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20);
        ERC20Share erc20Share = dSafe.erc20Share[erc20Idx];
        return getBalance(erc20Share, erc20Info);
    }

    /// @notice returns the NFTs on dAccount of `dSafe`
    /// @param dSafe The address of dSafe which dAccount NFTs should be returned
    /// @return The array of NFT deposited on the dAccount of `dSafe`
    function getDAccountERC721(address dSafe) external view override returns (NFTData[] memory) {
        NFTData[] memory nftData = new NFTData[](dSafes[dSafe].nfts.length);
        for (uint i = 0; i < nftData.length; i++) {
            (uint16 erc721Idx, uint256 tokenId) = getNFTData(dSafes[dSafe].nfts[i]);
            nftData[i] = NFTData(erc721Infos[erc721Idx].erc721Contract, tokenId);
        }
        return nftData;
    }
}
