// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {ERC721, IERC721, IERC165} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {SupaState} from "./SupaState.sol";
import {WalletProxy} from "../wallet/WalletProxy.sol";
import {ISupaConfig, ERC20Pool, ERC20Share, ERC20Info, ERC721Info, ContractData, ContractKind} from "../interfaces/ISupa.sol";
import {IVersionManager} from "../interfaces/IVersionManager.sol";
import {IERC20ValueOracle} from "../interfaces/IERC20ValueOracle.sol";
import {INFTValueOracle} from "../interfaces/INFTValueOracle.sol";
import {ImmutableGovernance} from "../lib/ImmutableGovernance.sol";
import {WalletLib} from "../lib/WalletLib.sol";
import {ERC20PoolLib} from "../lib/ERC20PoolLib.sol";

/// @title Supa Config
contract SupaConfig is SupaState, ImmutableGovernance, ISupaConfig {
    using WalletLib for WalletLib.Wallet;
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

    /// @notice upgrades the version of walletLogic contract for the `wallet`
    /// @param version The new target version of walletLogic contract
    function upgradeWalletImplementation(
        string calldata version
    ) external override onlyWallet whenNotPaused {
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
        walletLogic[msg.sender] = implementation;
        emit ISupaConfig.WalletImplementationUpgraded(msg.sender, version, implementation);
    }

    /// @notice Proposes the ownership transfer of `wallet` to the `newOwner`
    /// @dev The ownership transfer must be executed by the `newOwner` to complete the transfer
    /// @dev emits `WalletOwnershipTransferProposed` event
    /// @param newOwner The new owner of the `wallet`
    function proposeTransferWalletOwnership(
        address newOwner
    ) external override onlyWallet whenNotPaused {
        walletProposedNewOwner[msg.sender] = newOwner;
        emit ISupaConfig.WalletOwnershipTransferProposed(msg.sender, newOwner);
    }

    /// @notice Executes the ownership transfer of `wallet` to the `newOwner`
    /// @dev The caller must be the `newOwner` and the `newOwner` must be the proposed new owner
    /// @dev emits `WalletOwnershipTransferred` event
    /// @param wallet The address of the wallet
    function executeTransferWalletOwnership(address wallet) external override whenNotPaused {
        if (msg.sender != walletProposedNewOwner[wallet]) {
            revert InvalidNewOwner(walletProposedNewOwner[wallet], msg.sender);
        }
        wallets[wallet].owner = msg.sender;
        delete walletProposedNewOwner[wallet];
        emit ISupaConfig.WalletOwnershipTransferred(wallet, msg.sender);
    }

    /// @notice Pause the contract
    function pause() external override onlyGovernance {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external override onlyGovernance {
        _unpause();
    }

    /// @notice add a new ERC20 to be used inside Supa
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
        emit ISupaConfig.ERC20Added(
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

    /// @notice Add a new ERC721 to be used inside Supa.
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
        emit ISupaConfig.ERC721Added(erc721Idx, erc721Contract, valueOracleAddress);
    }

    /// @notice Updates the config of Supa
    /// @dev for governance only.
    /// @param _config the Config of ISupaConfig. A struct with Supa parameters
    function setConfig(Config calldata _config) external override onlyGovernance {
        config = _config;
        emit ISupaConfig.ConfigSet(_config);
    }

    /// @notice Updates the configuration setttings for credit account token storage
    /// @dev for governance only.
    /// @param _tokenStorageConfig the TokenStorageconfig of ISupaConfig
    function setTokenStorageConfig(
        TokenStorageConfig calldata _tokenStorageConfig
    ) external override onlyGovernance {
        tokenStorageConfig = _tokenStorageConfig;
        emit ISupaConfig.TokenStorageConfigSet(_tokenStorageConfig);
    }

    /// @notice Set the address of Version Manager contract
    /// @dev for governance only.
    /// @param _versionManager The address of the Version Manager contract to be set
    function setVersionManager(address _versionManager) external override onlyGovernance {
        versionManager = IVersionManager(_versionManager);
        emit ISupaConfig.VersionManagerSet(_versionManager);
    }

    /// @notice Updates some of ERC20 config parameters
    /// @dev for governance only.
    /// @param erc20 The address of ERC20 contract for which Supa config parameters should be updated
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
        emit ISupaConfig.ERC20DataSet(
            erc20,
            erc20Idx,
            valueOracle,
            baseRate,
            slope1,
            slope2,
            targetUtilization
        );
    }

    /// @notice creates a new wallet with sender as the owner and returns the wallet address
    /// @return wallet The address of the created wallet
    function createWallet() external override whenNotPaused returns (address wallet) {
        address[] memory erc20s = new address[](erc20Infos.length);
        for (uint256 i = 0; i < erc20Infos.length; i++) {
            erc20s[i] = erc20Infos[i].erc20Contract;
        }
        address[] memory erc721s = new address[](erc721Infos.length);
        for (uint256 i = 0; i < erc721Infos.length; i++) {
            erc721s[i] = erc721Infos[i].erc721Contract;
        }

        wallet = address(new WalletProxy(address(this), erc20s, erc721s));
        wallets[wallet].owner = msg.sender;

        // add a version parameter if users should pick a specific version
        (, , , address implementation, ) = versionManager.getRecommendedVersion();
        walletLogic[wallet] = implementation;
        emit ISupaConfig.WalletCreated(wallet, msg.sender);
    }

    /// @notice Returns the amount of `erc20` tokens on creditAccount of wallet
    /// @param walletAddr The address of the wallet for which creditAccount the amount of `erc20` should
    /// be calculated
    /// @param erc20 The address of ERC20 which balance on creditAccount of `wallet` should be calculated
    /// @return the amount of `erc20` on the creditAccount of `wallet`
    function getCreditAccountERC20(
        address walletAddr,
        IERC20 erc20
    ) external view override returns (int256) {
        WalletLib.Wallet storage wallet = wallets[walletAddr];
        (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20);
        ERC20Share erc20Share = wallet.erc20Share[erc20Idx];
        return getBalance(erc20Share, erc20Info);
    }

    /// @notice returns the NFTs on creditAccount of `wallet`
    /// @param wallet The address of wallet which creditAccount NFTs should be returned
    /// @return The array of NFT deposited on the creditAccount of `wallet`
    function getCreditAccountERC721(
        address wallet
    ) external view override returns (NFTData[] memory) {
        NFTData[] memory nftData = new NFTData[](wallets[wallet].nfts.length);
        for (uint i = 0; i < nftData.length; i++) {
            (uint16 erc721Idx, uint256 tokenId) = getNFTData(wallets[wallet].nfts[i]);
            nftData[i] = NFTData(erc721Infos[erc721Idx].erc721Contract, tokenId);
        }
        return nftData;
    }

    /// @notice returns the amount of NFTs in creditAccount of `wallet`
    /// @param wallet The address of the wallet that owns the creditAccount
    /// @return The amount of NFTs in the creditAccount of `wallet`
    function getCreditAccountERC721Counter(address wallet) external view returns (uint256) {
        return wallets[wallet].nfts.length;
    }
}
