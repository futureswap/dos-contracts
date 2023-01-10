// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Call} from "../lib/Call.sol";
import {IERC20ValueOracle} from "./IERC20ValueOracle.sol";

type ERC20Share is int256;

interface IDOSERC20 is IERC20 {
    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;
}

interface IDOSConfig {
    struct Config {
        int256 liqFraction; // Fraction for the user
        int256 fractionalReserveLeverage; // Ratio of debt to reserves
    }

    struct NFTData {
        address erc721;
        uint256 tokenId;
    }

    /// @notice Emitted when the implementation of a dSafe is upgraded
    /// @param dSafe The address of the dSafe
    /// @param version The new implementation version
    event DSafeImplementationUpgraded(address indexed dSafe, uint256 indexed version);

    /// @notice Emitted when a new ERC20 is added to the protocol
    /// @param erc20Idx The index of the ERC20 in the protocol
    /// @param erc20 The address of the ERC20 contract
    /// @param dosToken The address of the DOS token
    /// @param name The name of the ERC20
    /// @param symbol The symbol of the ERC20
    /// @param decimals The decimals of the ERC20
    /// @param valueOracle The address of the value oracle for the ERC20
    /// @param colFactor The collateral factor for the ERC20
    /// @param borrowFactor The borrow factor for the ERC20
    /// @param baseRate The interest rate at 0% utilization
    /// @param slope1 The interest rate slope at 0% to target utilization
    /// @param slope2 The interest rate slope at target utilization to 100% utilization
    /// @param targetUtilization The target utilization for the ERC20
    event ERC20Added(
        uint16 erc20Idx,
        address erc20,
        address dosToken,
        string name,
        string symbol,
        uint8 decimals,
        address valueOracle,
        int256 colFactor,
        int256 borrowFactor,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    );

    /// @notice Emitted when a new ERC721 is added to the protocol
    /// @param erc721Idx The index of the ERC721 in the protocol
    /// @param erc721Contract The address of the ERC721 contract
    /// @param valueOracleAddress The address of the value oracle for the ERC721
    /// @param collateralFactor The collateral factor for the ERC721
    event ERC721Added(
        uint256 indexed erc721Idx,
        address indexed erc721Contract,
        address valueOracleAddress,
        int256 collateralFactor
    );

    /// @notice Emitted when the config is set
    /// @param config The new config
    event ConfigSet(Config indexed config);

    /// @notice Emitted when the version manager address is set
    /// @param versionManager The version manager address
    event VersionManagerSet(address indexed versionManager);

    /// @notice Emitted when ERC20 Data is set
    /// @param erc20 The address of the erc20 token
    /// @param baseRate The new base interest rate
    /// @param slope1 The new slope1
    /// @param slope2 The new slope2
    /// @param targetUtilization The new target utilization
    /// @param borrowFactor The new borrow factor
    /// @param collateralFactor The new collateral factor
    event ERC20DataSet(
        address indexed erc20,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization,
        int256 borrowFactor,
        int256 collateralFactor
    );

    /// @notice Emitted when a dSafe is created
    /// @param dSafe The address of the dSafe
    /// @param owner The address of the owner
    event DSafeCreated(address dSafe, address owner);

    function upgradeDSafeImplementation(address dSafe, uint256 version) external;

    function addERC20Info(
        address erc20Contract,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address valueOracle,
        int256 colFactor,
        int256 borrowFactor,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    ) external returns (uint16);

    function addERC721Info(
        address nftContract,
        address valueOracleAddress,
        int256 collateralFactor
    ) external;

    function setERC20Data(
        address erc20,
        int256 borrowFactor,
        int256 collateralFactor,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    ) external;

    function setConfig(Config calldata _config) external;

    function createDSafe() external returns (address dSafe);

    function pause() external;

    function unpause() external;

    function getDAccountERC20(address dSafe, IERC20 erc20) external view returns (int256);

    function getDAccountERC721(address dSafe) external view returns (NFTData[] memory);
}

interface IDOSCore {
    /// @notice Emitted when ERC20 tokens are transferred between credit accounts
    /// @param erc20 The address of the ERC20 token
    /// @param from The address of the sender
    /// @param to The address of the receiver
    /// @param value The amount of tokens transferred
    event ERC20Transfer(
        address indexed erc20,
        address indexed from,
        address indexed to,
        int256 value
    );

    /// @notice Emitted when erc20 tokens are deposited or withdrawn from a credit account
    /// @param erc20 The address of the ERC20 token
    /// @param to The address of the dSafe
    /// @param amount The amount of tokens deposited or withdrawn
    event ERC20BalanceChanged(address indexed erc20, address indexed to, int256 indexed amount);

    /// @notice Emitted when a ERC721 is transferred between credit accounts
    /// @param nftId The nftId of the ERC721 token
    /// @param from The address of the sender
    /// @param to The address of the receiver
    event ERC721Transferred(uint256 indexed nftId, address indexed from, address indexed to);

    /// @notice Emitted when an ERC721 token is deposited to a credit account
    /// @param erc721 The address of the ERC721 token
    /// @param to The address of the dSafe
    /// @param tokenId The id of the token deposited
    event ERC721Deposited(address indexed erc721, address indexed to, uint256 indexed tokenId);

    /// @notice Emitted when an ERC721 token is withdrawn from a credit account
    /// @param erc721 The address of the ERC721 token
    /// @param from The address of the dSafe
    /// @param tokenId The id of the token withdrawn
    event ERC721Withdrawn(address indexed erc721, address indexed from, uint256 indexed tokenId);

    /// @dev Emitted when `owner` approves `spender` to spend `value` tokens on their behalf.
    /// @param erc20 The ERC20 token to approve
    /// @param owner The address of the token owner
    /// @param spender The address of the spender
    /// @param value The amount of tokens to approve
    event ERC20Approval(
        address indexed erc20,
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

    /// @notice Emitted when a dSafe is liquidated
    /// @param dSafe The address of the liquidated dSafe
    /// @param liquidator The address of the liquidator
    event SafeLiquidated(address indexed dSafe, address indexed liquidator);

    function liquidate(address dSafe) external;

    function depositERC20(IERC20 erc20, uint256 amount) external;

    function withdrawERC20(IERC20 erc20, uint256 amount) external;

    function depositERC20ForSafe(address erc20, address to, uint256 amount) external;

    function depositFull(IERC20[] calldata erc20s) external;

    function withdrawFull(IERC20[] calldata erc20s) external;

    function executeBatch(Call[] memory calls) external;

    function transferERC20(IERC20 erc20, address to, uint256 amount) external;

    function depositERC721(address nftContract, uint256 tokenId) external;

    function withdrawERC721(address erc721, uint256 tokenId) external;

    function transferERC721(address erc721, uint256 tokenId, address to) external;

    /// @notice Transfer ERC20 tokens from dSafe to another dSafe
    /// @dev Note: Allowance must be set with approveERC20
    /// @param erc20 The index of the ERC20 token in erc20Infos array
    /// @param from The address of the dSafe to transfer from
    /// @param to The address of the dSafe to transfer to
    /// @param amount The amount of tokens to transfer
    function transferFromERC20(
        address erc20,
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    /// @notice Transfer ERC721 tokens from dSafe to another dSafe
    /// @param collection The address of the ERC721 token
    /// @param from The address of the dSafe to transfer from
    /// @param to The address of the dSafe to transfer to
    /// @param tokenId The id of the token to transfer
    function transferFromERC721(
        address collection,
        address from,
        address to,
        uint256 tokenId
    ) external;

    /// @notice Returns the approved address for a token, or zero if no address set
    /// @param collection The address of the ERC721 token
    /// @param tokenId The id of the token to query
    function getApproved(address collection, uint256 tokenId) external view returns (address);

    function getRiskAdjustedPositionValues(
        address dSafeAddress
    ) external view returns (int256 totalValue, int256 collateral, int256 debt);

    /// @notice Returns if the `operator` is allowed to manage all of the erc20s of `owner` on the `collection` contract
    /// @param collection The address of the collection contract
    /// @param _owner The address of the owner
    /// @param spender The address of the spender
    function isApprovedForAll(
        address collection,
        address _owner,
        address spender
    ) external view returns (bool);

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

    function getImplementation(address dSafe) external view returns (address);

    function getDSafeOwner(address dSafe) external view returns (address);
}

interface IDOS is IDOSCore, IDOSConfig {}
