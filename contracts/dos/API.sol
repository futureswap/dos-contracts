// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import { SignatureVerification } from "../lib/SignatureVerification.sol";
import { PermitHash } from "../lib/PermitHash.sol";

import { FsUtils } from "../lib/FsUtils.sol";

error NotApprovedOrOwner();
/// @notice Transfer amount exceeds allowance
error InsufficientAllowance();

/// @dev create primitives for projects to integrate with DOS
contract API {
    using PermitHash for PermitTransferFromAssets;

    /// @dev erc20 allowances
    mapping(address => mapping(address => mapping(address => uint256))) private _allowances;
    /// @dev erc721 approvals
    mapping(address => mapping(uint256 => address)) private _tokenApprovals;
    /// @dev erc721 & erc1155 operator approvals
    mapping(address => mapping(address => mapping(address => bool))) private _operatorApprovals;

    /// @dev Emitted when `owner` approves `spender` to spend `value` tokens on their behalf.
    /// @param asset The address of the ERC20 token
    /// @param owner The address of the token owner
    /// @param spender The address of the spender
    /// @param value The amount of tokens to approve
    event ERC20Approval(
        address indexed asset,
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

    /// @notice Approve a spender to transfer tokens on your behalf
    /// @param asset The address of the ERC20 token
    /// @param spender The address of the spender
    /// @param amount The amount of tokens to approve
    function approveERC20(
        address asset,
        address spender,
        uint256 amount
    ) external onlyPortfolio portfolioExists(spender) returns (bool) {
        _approve(msg.sender, asset, spender, amount);
        return true;
    }

    /// @notice Approve a spender to transfer ERC721 tokens on your behalf
    /// @param collection The address of the ERC721 token
    /// @param to The address of the spender
    /// @param tokenId The id of the token to approve
    function approveERC721(
        address collection,
        address to,
        uint256 tokenId
    ) external onlyPortfolio portfolioExists(to) {
        _approveNft(collection, to, tokenId);
    }

    /// @notice Transfer ERC20 tokens from portfolio to another portfolio
    /// @dev Note: Allowance must be set with approveERC20
    /// @param asset The address of the ERC20 token
    /// @param from The address of the portfolio to transfer from
    /// @param to The address of the portfolio to transfer to
    /// @param amount The amount of tokens to transfer
    function transferFromERC20(
        address asset,
        address from,
        address to,
        uint256 amount
    ) external onlyPortfolio portfolioExists(from) portfolioExists(to) returns (bool) {
        address spender = msg.sender;
        _spendAllowance(asset, from, spender, amount);
        transferAsset(asset, from, to, amount);
        return true;
    }

    /// @notice Transfer ERC721 tokens from portfolio to another portfolio
    /// @param collection The address of the ERC721 token
    /// @param from The address of the portfolio to transfer from
    /// @param to The address of the portfolio to transfer to
    /// @param tokenId The id of the token to transfer
    function transferFromERC721(
        address collection,
        address from,
        address to,
        uint256 tokenId
    ) external onlyPortfolio portfolioExists(to) {
        Portfolio storage p = portfolios[from];
        uint256 nftPortfolioIdx = p.nftPortfolioIdxs[nftContract][tokenId] - 1;
        address spender = msg.sender;
        if (!_isApprovedOrOwner(msg.sender, collection, tokenId)) {
            revert NotApprovedOrOwner();
        }
        transferNft(nftPortfolioIdx, from, to);
    }

    /// @notice Returns the approved address for a token, or zero if no address set
    /// @param collection The address of the ERC721 token
    /// @param tokenId The id of the token to query
    function getApproved(address collection, uint256 tokenId) external view returns (address) {
        return _tokenApprovals[collection][tokenId];
    }

    /// @notice Returns if the `operator` is allowed to manage all of the assets of `owner` on the `collection` contract.
    /// @param collection The address of the collection contract
    /// @param owner The address of the owner
    /// @param spender The address of the spender
    function isApprovedForAll(
        address collection,
        address owner,
        address spender
    ) public view returns (bool) {
        return _operatorApprovals[collection][owner][spender];
    }

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(
        address asset,
        address owner,
        address spender
    ) external view returns (uint256) {
        return _allowances[owner][asset][spender];
    }

    function _approveAsset(address owner, address asset, address spender, uint256 amount) internal {
        spender = FsUtils.nonNull(spender);

        _allowances[owner][asset][spender] = amount;
        emit ERC20Approval(asset, owner, spender, amount);
    }

    function _approveNft(address collection, address to, uint256 tokenId) internal {
        _tokenApprovals[collection][tokenId] = to;
        emit ERC721Approval(collection, owner, to, tokenId);
    }

    function _spendAllowance(
        address asset,
        address owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = allowance(asset, owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance();
            }
            unchecked {
                _approveAsset(owner, asset, spender, currentAllowance - amount);
            }
        }
    }

    function _isApprovedOrOwner(
        address spender,
        address collection,
        uint256 tokenId
    ) internal view returns (bool) {
        Portfolio storage p = portfolios[msg.sender];
        bool isDepositNftOwner = p.nftPortfolioIdxs[nftContract][tokenId] != 0;
        return (isDepositNftOwner ||
            getApproved(collection, tokenId) == spender ||
            isApprovedForAll(collection, owner, spender));
    }
}
