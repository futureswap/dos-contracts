// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Call} from "../lib/Call.sol";
import {IERC20ValueOracle} from "./IERC20ValueOracle.sol";
import {INFTValueOracle} from "./INFTValueOracle.sol";

type ERC20Share is int256;

struct NFTTokenData {
    uint240 tokenId; // 240 LSB of the tokenId of the NFT
    uint16 walletIdx; // index in wallet NFT array
    address approvedSpender; // approved spender for ERC721
}

struct ERC20Pool {
    int256 tokens;
    int256 shares;
}

struct ERC20Info {
    address erc20Contract;
    IERC20ValueOracle valueOracle;
    ERC20Pool collateral;
    ERC20Pool debt;
    uint256 baseRate;
    uint256 slope1;
    uint256 slope2;
    uint256 targetUtilization;
    uint256 timestamp;
}

struct ERC721Info {
    address erc721Contract;
    INFTValueOracle valueOracle;
}

struct ContractData {
    uint16 idx;
    ContractKind kind; // 0 invalid, 1 ERC20, 2 ERC721
}

enum ContractKind {
    Invalid,
    ERC20,
    ERC721
}

interface ISupaERC20 is IERC20 {
    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;
}

interface ISupaConfig {
    struct Config {
        address treasuryWallet; // The address of the treasury safe
        uint256 treasuryInterestFraction; // Fraction of interest to send to treasury
        uint256 maxSolvencyCheckGasCost;
        int256 liqFraction; // Fraction for the user
        int256 fractionalReserveLeverage; // Ratio of debt to reserves
    }

    struct TokenStorageConfig {
        uint256 maxTokenStorage;
        uint256 erc20Multiplier;
        uint256 erc721Multiplier;
    }

    struct NFTData {
        address erc721;
        uint256 tokenId;
    }

    /// @notice Emitted when the implementation of a wallet is upgraded
    /// @param wallet The address of the wallet
    /// @param version The new implementation version
    event WalletImplementationUpgraded(
        address indexed wallet,
        string indexed version,
        address implementation
    );

    /// @notice Emitted when the ownership of a wallet is proposed to be transferred
    /// @param wallet The address of the wallet
    /// @param newOwner The address of the new owner
    event WalletOwnershipTransferProposed(address indexed wallet, address indexed newOwner);

    /// @notice Emitted when the ownership of a wallet is transferred
    /// @param wallet The address of the wallet
    /// @param newOwner The address of the new owner
    event WalletOwnershipTransferred(address indexed wallet, address indexed newOwner);

    /// @notice Emitted when a new ERC20 is added to the protocol
    /// @param erc20Idx The index of the ERC20 in the protocol
    /// @param erc20 The address of the ERC20 contract
    /// @param name The name of the ERC20
    /// @param symbol The symbol of the ERC20
    /// @param decimals The decimals of the ERC20
    /// @param valueOracle The address of the value oracle for the ERC20
    /// @param baseRate The interest rate at 0% utilization
    /// @param slope1 The interest rate slope at 0% to target utilization
    /// @param slope2 The interest rate slope at target utilization to 100% utilization
    /// @param targetUtilization The target utilization for the ERC20
    event ERC20Added(
        uint16 erc20Idx,
        address erc20,
        string name,
        string symbol,
        uint8 decimals,
        address valueOracle,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    );

    /// @notice Emitted when a new ERC721 is added to the protocol
    /// @param erc721Idx The index of the ERC721 in the protocol
    /// @param erc721Contract The address of the ERC721 contract
    /// @param valueOracleAddress The address of the value oracle for the ERC721
    event ERC721Added(
        uint256 indexed erc721Idx,
        address indexed erc721Contract,
        address valueOracleAddress
    );

    /// @notice Emitted when the config is set
    /// @param config The new config
    event ConfigSet(Config config);

    /// @notice Emitted when the token storage config is set
    /// @param tokenStorageConfig The new token storage config
    event TokenStorageConfigSet(TokenStorageConfig tokenStorageConfig);

    /// @notice Emitted when the version manager address is set
    /// @param versionManager The version manager address
    event VersionManagerSet(address indexed versionManager);

    /// @notice Emitted when ERC20 Data is set
    /// @param erc20 The address of the erc20 token
    /// @param erc20Idx The index of the erc20 token
    /// @param valueOracle The new value oracle
    /// @param baseRate The new base interest rate
    /// @param slope1 The new slope1
    /// @param slope2 The new slope2
    /// @param targetUtilization The new target utilization
    event ERC20DataSet(
        address indexed erc20,
        uint16 indexed erc20Idx,
        address valueOracle,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    );

    /// @notice Emitted when a wallet is created
    /// @param wallet The address of the wallet
    /// @param owner The address of the owner
    event WalletCreated(address wallet, address owner);

    function upgradeWalletImplementation(string calldata version) external;

    function proposeTransferWalletOwnership(address newOwner) external;

    function executeTransferWalletOwnership(address wallet) external;

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
    ) external returns (uint16);

    function addERC721Info(address nftContract, address valueOracleAddress) external;

    function setERC20Data(
        address erc20,
        address valueOracle,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    ) external;

    function setConfig(Config calldata _config) external;

    function setTokenStorageConfig(TokenStorageConfig calldata _tokenStorageConfig) external;

    function setVersionManager(address _versionManager) external;

    function createWallet() external returns (address wallet);

    function pause() external;

    function unpause() external;

    function getCreditAccountERC20(address wallet, IERC20 erc20) external view returns (int256);

    function getCreditAccountERC721(address wallet) external view returns (NFTData[] memory);
}

interface ISupaCore {
    struct Approval {
        address ercContract; // ERC20/ERC721 contract
        uint256 amountOrTokenId; // amount or tokenId
    }

    /// @notice Emitted when ERC20 tokens are transferred between credit accounts
    /// @param erc20 The address of the ERC20 token
    /// @param erc20Idx The index of the ERC20 in the protocol
    /// @param from The address of the sender
    /// @param to The address of the receiver
    /// @param value The amount of tokens transferred
    event ERC20Transfer(
        address indexed erc20,
        uint16 erc20Idx,
        address indexed from,
        address indexed to,
        int256 value
    );

    /// @notice Emitted when erc20 tokens are deposited or withdrawn from a credit account
    /// @param erc20 The address of the ERC20 token
    /// @param erc20Idx The index of the ERC20 in the protocol
    /// @param to The address of the wallet
    /// @param amount The amount of tokens deposited or withdrawn
    event ERC20BalanceChanged(
        address indexed erc20,
        uint16 erc20Idx,
        address indexed to,
        int256 amount
    );

    /// @notice Emitted when a ERC721 is transferred between credit accounts
    /// @param nftId The nftId of the ERC721 token
    /// @param from The address of the sender
    /// @param to The address of the receiver
    event ERC721Transferred(uint256 indexed nftId, address indexed from, address indexed to);

    /// @notice Emitted when an ERC721 token is deposited to a credit account
    /// @param erc721 The address of the ERC721 token
    /// @param to The address of the wallet
    /// @param tokenId The id of the token deposited
    event ERC721Deposited(address indexed erc721, address indexed to, uint256 indexed tokenId);

    /// @notice Emitted when an ERC721 token is withdrawn from a credit account
    /// @param erc721 The address of the ERC721 token
    /// @param from The address of the wallet
    /// @param tokenId The id of the token withdrawn
    event ERC721Withdrawn(address indexed erc721, address indexed from, uint256 indexed tokenId);

    /// @dev Emitted when `owner` approves `spender` to spend `value` tokens on their behalf.
    /// @param erc20 The ERC20 token to approve
    /// @param owner The address of the token owner
    /// @param spender The address of the spender
    /// @param value The amount of tokens to approve
    event ERC20Approval(
        address indexed erc20,
        uint16 erc20Idx,
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    /// @dev Emitted when `owner` enables `approved` to manage the `tokenId` token on collection `collection`.
    /// @param collection The address of the ERC721 collection
    /// @param owner The address of the token owner
    /// @param approved The address of the approved operator
    /// @param tokenId The ID of the approved token
    event ERC721Approval(
        address indexed collection,
        address indexed owner,
        address indexed approved,
        uint256 tokenId
    );

    /// @dev Emitted when `owner` enables or disables (`approved`) `operator` to manage all of its erc20s.
    /// @param collection The address of the collection
    /// @param owner The address of the owner
    /// @param operator The address of the operator
    /// @param approved True if the operator is approved, false to revoke approval
    event ApprovalForAll(
        address indexed collection,
        address indexed owner,
        address indexed operator,
        bool approved
    );

    /// @dev Emitted when an operator is added to a wallet
    /// @param wallet The address of the wallet
    /// @param operator The address of the operator
    event OperatorAdded(address indexed wallet, address indexed operator);

    /// @dev Emitted when an operator is removed from a wallet
    /// @param wallet The address of the wallet
    /// @param operator The address of the operator
    event OperatorRemoved(address indexed wallet, address indexed operator);

    /// @notice Emitted when a wallet is liquidated
    /// @param wallet The address of the liquidated wallet
    /// @param liquidator The address of the liquidator
    event WalletLiquidated(
        address indexed wallet,
        address indexed liquidator,
        int256 collateral,
        int256 debt
    );

    /// @notice Error thrown if a wallet accumulates too many assets
    error SolvencyCheckTooExpensive();

    function liquidate(address wallet) external;

    function depositERC20(IERC20 erc20, uint256 amount) external;

    function withdrawERC20(IERC20 erc20, uint256 amount) external;

    function depositERC20ForWallet(address erc20, address to, uint256 amount) external;

    function depositFull(IERC20[] calldata erc20s) external;

    function withdrawFull(IERC20[] calldata erc20s) external;

    function executeBatch(Call[] memory calls) external;

    function transferERC20(IERC20 erc20, address to, uint256 amount) external;

    function depositERC721(address nftContract, uint256 tokenId) external;

    function depositERC721ForWallet(address nftContract, address to, uint256 tokenId) external;

    function withdrawERC721(address erc721, uint256 tokenId) external;

    function transferERC721(address erc721, uint256 tokenId, address to) external;

    /// @notice Transfer ERC20 tokens from wallet to another wallet
    /// @dev Note: Allowance must be set with approveERC20
    /// @param erc20 The index of the ERC20 token in erc20Infos array
    /// @param from The address of the wallet to transfer from
    /// @param to The address of the wallet to transfer to
    /// @param amount The amount of tokens to transfer
    function transferFromERC20(
        address erc20,
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    /// @notice Transfer ERC721 tokens from wallet to another wallet
    /// @param collection The address of the ERC721 token
    /// @param from The address of the wallet to transfer from
    /// @param to The address of the wallet to transfer to
    /// @param tokenId The id of the token to transfer
    function transferFromERC721(
        address collection,
        address from,
        address to,
        uint256 tokenId
    ) external;

    function approveAndCall(
        Approval[] calldata approvals,
        address spender,
        bytes calldata data
    ) external;

    function addOperator(address operator) external;

    function removeOperator(address operator) external;

    /// @notice Returns the approved address for a token, or zero if no address set
    /// @param collection The address of the ERC721 token
    /// @param tokenId The id of the token to query
    function getApproved(address collection, uint256 tokenId) external view returns (address);

    function getRiskAdjustedPositionValues(
        address walletAddress
    ) external view returns (int256 totalValue, int256 collateral, int256 debt);

    /// @notice Returns if '_spender' is an operator of '_owner'
    /// @param _owner The address of the owner
    /// @param _spender The address of the spender
    function isOperator(address _owner, address _spender) external view returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(
        address erc20,
        address _owner,
        address spender
    ) external view returns (uint256);

    function computeInterestRate(uint16 erc20Idx) external view returns (int96);

    function getImplementation(address wallet) external view returns (address);

    function getWalletOwner(address wallet) external view returns (address);

    function isSolvent(address wallet) external view returns (bool);
}

interface ISupa is ISupaCore, ISupaConfig {}
