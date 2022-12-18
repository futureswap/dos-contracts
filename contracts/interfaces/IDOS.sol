// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Call} from "../lib/Call.sol";

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

    event ERC20Added(
        uint16 erc20Idx,
        address erc20,
        address dosTokem,
        string name,
        string symbol,
        uint8 decimals,
        address valueOracle,
        int256 colFactor,
        int256 borrowFactor,
        int256 interest
    );

    event DSafeCreated(address dSafe, address owner);

    function upgradeImplementation(address dSafe, uint256 version) external;

    function addERC20Info(
        address erc20Contract,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address valueOracle,
        int256 colFactor,
        int256 borrowFactor,
        int256 interest
    ) external returns (uint16);

    function addNFTInfo(
        address nftContract,
        address valueOracleAddress,
        int256 collateralFactor
    ) external;

    function setConfig(Config calldata _config) external;

    function createDSafe() external returns (address dSafe);

    function getDAccountERC20(address dSafe, IERC20 erc20) external view returns (int256);

    function viewNFTs(address dSafe) external view returns (NFTData[] memory);

    function getMaximumWithdrawableOfERC20(IERC20 erc20) external view returns (int256);
}

interface IDOSCore {
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

    function liquidate(address dSafe) external;

    function depositERC20(IERC20 erc20, int256 amount) external;

    function depositERC20ForSafe(address erc20, address to, uint256 amount) external;

    function depositFull(IERC20[] calldata erc20s) external;

    function withdrawFull(IERC20[] calldata erc20s) external;

    function executeBatch(Call[] memory calls) external;

    function transfer(IERC20 erc20, address to, uint256 amount) external;

    function depositNFT(address nftContract, uint256 tokenId) external;

    function claimNFT(address erc721, uint256 tokenId) external;

    function sendNFT(address erc721, uint256 tokenId, address to) external;

    /// @notice Approve a spender to transfer tokens on your behalf
    /// @param erc20 The index of the ERC20 token in erc20Infos array
    /// @param spender The address of the spender
    /// @param amount The amount of tokens to approve
    function approveERC20(IERC20 erc20, address spender, uint256 amount) external returns (bool);

    /// @notice Approve a spender to transfer ERC721 tokens on your behalf
    /// @param collection The address of the ERC721 token
    /// @param to The address of the spender
    /// @param tokenId The id of the token to approve
    function approveERC721(address collection, address to, uint256 tokenId) external;

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

    function computePosition(
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
        IERC20 erc20,
        address _owner,
        address spender
    ) external view returns (uint256);

    function getImplementation(address dSafe) external view returns (address);

    function getDSafeOwner(address dSafe) external view returns (address);
}

interface IDOS is IDOSCore, IDOSConfig {}
