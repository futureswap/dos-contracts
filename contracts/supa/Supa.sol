// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC721, IERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

import {ISupa, ISupaConfig, ISupaCore, ERC20Share, NFTTokenData, ERC20Pool, ERC20Info, ERC721Info, ContractData, ContractKind} from "../interfaces/ISupa.sol";
import {SupaState} from "./SupaState.sol";
import {WalletProxy} from "../wallet/WalletProxy.sol";
import {IVersionManager} from "../interfaces/IVersionManager.sol";
import {IERC1363SpenderExtended} from "../interfaces/IERC1363-extended.sol";
import {WalletLib} from "../lib/WalletLib.sol";
import {ERC20PoolLib} from "../lib/ERC20PoolLib.sol";
import {Call} from "../lib/Call.sol";
import {FsUtils} from "../lib/FsUtils.sol";
import {FsMath} from "../lib/FsMath.sol";

import "../interfaces/IERC20ValueOracle.sol";
import "../interfaces/INFTValueOracle.sol";
import {PERMIT2, IPermit2} from "../external/interfaces/IPermit2.sol";

// ERC20 standard token
// ERC721 single non-fungible token support
// ERC677 transferAndCall (transferAndCall2 extension)
// ERC165 interface support (solidity ISupa.interfaceId)
// ERC777 token send
// ERC1155 multi-token support
// ERC1363 payable token (approveAndCall/transferAndCall)
// ERC1820 interface registry support
// EIP2612 permit support (uniswap permit2)
/*
 * NFTs are stored in an array of nfts owned by some wallet. To prevent looping over arrays we need to
 * know the following information for each NFT in the system (erc721, tokenId, wallet, array index).
 * Given the expensive nature of storage on the EVM we want to store all information as small as possible.
 * The pair (erc721, tokenId) is describes a particular NFT but would take two storage slots (as a token id)
 * is 256 bits. The erc721 address is 160 bits however we only allow pre-approved erc721 contracts, so in
 * practice 16 bits would be enough to store an index into the allowed erc721 contracts. We can hash (erc721 + tokenId)
 * to get a unique number but that requires storing both tokenId, erc721 and array index. Instead we hash into
 * 224 (256 - 32) bits which is still sufficiently large to avoid collisions. This leaves 32 bits for additional
 * information. The 16 LSB are used to store the index in the wallet array. The 16 RSB are used to store
 * the 16 RSB of the tokenId. This allows us to store the tokenId + array index in a single storage slot as a map
 * from NFTId to NFTData. Note that the index in the wallet array might change and thus cannot be part of
 * NFTId and thus has to be stored as part of NFTData, requiring the splitting of tokenId.
 */

/// @title Supa
contract Supa is SupaState, ISupaCore, IERC721Receiver, Proxy {
    using WalletLib for WalletLib.Wallet;
    using ERC20PoolLib for ERC20Pool;
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice Sender is not approved to spend wallet erc20
    error NotApprovedOrOwner();
    /// @notice Sender is not the owner of the wallet;
    /// @param sender The address of the sender
    /// @param owner The address of the owner
    error NotOwner(address sender, address owner);
    /// @notice Transfer amount exceeds allowance
    error InsufficientAllowance();
    /// @notice Cannot approve self as spender
    error SelfApproval();
    /// @notice The receiving address is not a contract
    error ReceiverNotContract();
    /// @notice The receiver does not implement the required interface
    error ReceiverNoImplementation();
    /// @notice The receiver did not return the correct value - transaction failed
    error WrongDataReturned();
    /// @notice Asset is not an NFT
    error NotNFT();
    /// @notice NFT must be owned the the user or user's wallet
    error NotNFTOwner();
    /// @notice Operation leaves wallet insolvent
    error Insolvent();
    /// @notice Cannot withdraw debt
    error CannotWithdrawDebt();
    /// @notice Wallet is not liquidatable
    error NotLiquidatable();
    /// @notice There are insufficient reserves in the protocol for the debt
    error InsufficientReserves();
    /// @notice This operation would add too many tokens to the credit account
    error TokenStorageExceeded();

    // We will initialize the system so that 0 is the base currency
    // in which the system calculates value.
    uint16 constant K_NUMERAIRE_IDX = 0;

    uint256 constant POOL_ASSETS_CUTOFF = 100; // Wei amounts to prevent division by zero

    address immutable supaConfigAddress;

    modifier onlyRegisteredNFT(address nftContract, uint256 tokenId) {
        // how can we be sure that Oracle would have a price for any possible tokenId?
        // maybe we should check first if Oracle can return a value for this specific NFT?
        if (infoIdx[nftContract].kind == ContractKind.Invalid) {
            revert NotRegistered(nftContract);
        }
        _;
    }

    modifier onlyNFTOwner(address nftContract, uint256 tokenId) {
        address _owner = ERC721(nftContract).ownerOf(tokenId);
        bool isOwner = _owner == msg.sender || _owner == wallets[msg.sender].owner;
        if (!isOwner) {
            revert NotNFTOwner();
        }
        _;
    }

    constructor(address supaConfig, address versionManagerAddress) {
        versionManager = IVersionManager(FsUtils.nonNull(versionManagerAddress));
        supaConfigAddress = FsUtils.nonNull(supaConfig);
    }

    /// @notice top up the creditAccount owned by wallet `to` with `amount` of `erc20`
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param to Address of the wallet that creditAccount should be top up
    /// @param amount The amount of `erc20` to be sent
    function depositERC20ForWallet(
        address erc20,
        address to,
        uint256 amount
    ) external override walletExists(to) whenNotPaused {
        if (amount == 0) return;
        (, uint16 erc20Idx) = getERC20Info(IERC20(erc20));
        int256 signedAmount = FsMath.safeCastToSigned(amount);
        _creditAccountERC20ChangeBy(to, erc20Idx, signedAmount);
        emit ISupaCore.ERC20BalanceChanged(erc20, erc20Idx, to, signedAmount);
        IERC20(erc20).safeTransferFrom(msg.sender, address(this), amount);
        _tokenStorageCheck(to);
    }

    /// @notice deposit `amount` of `erc20` to creditAccount from wallet
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param amount The amount of `erc20` to be transferred
    function depositERC20(IERC20 erc20, uint256 amount) external override onlyWallet whenNotPaused {
        if (amount == 0) return;
        (, uint16 erc20Idx) = getERC20Info(erc20);
        int256 signedAmount = FsMath.safeCastToSigned(amount);
        _creditAccountERC20ChangeBy(msg.sender, erc20Idx, signedAmount);
        emit ISupaCore.ERC20BalanceChanged(address(erc20), erc20Idx, msg.sender, signedAmount);
        erc20.safeTransferFrom(msg.sender, address(this), amount);
        _tokenStorageCheck(msg.sender);
    }

    /// @notice deposit `amount` of `erc20` from creditAccount tp wallet
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param amount The amount of `erc20` to be transferred
    function withdrawERC20(
        IERC20 erc20,
        uint256 amount
    ) external override onlyWallet whenNotPaused {
        (, uint16 erc20Idx) = getERC20Info(erc20);
        int256 signedAmount = FsMath.safeCastToSigned(amount);
        _creditAccountERC20ChangeBy(msg.sender, erc20Idx, -signedAmount);
        emit ISupaCore.ERC20BalanceChanged(address(erc20), erc20Idx, msg.sender, -signedAmount);
        erc20.safeTransfer(msg.sender, amount);
    }

    /// @notice deposit all `erc20s` from wallet to creditAccount
    /// @param erc20s Array of addresses of ERC20 to be transferred
    function depositFull(IERC20[] calldata erc20s) external override onlyWallet whenNotPaused {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            uint256 amount = erc20.balanceOf(msg.sender);
            int256 signedAmount = FsMath.safeCastToSigned(amount);
            _creditAccountERC20ChangeBy(msg.sender, erc20Idx, signedAmount);
            emit ISupaCore.ERC20BalanceChanged(address(erc20), erc20Idx, msg.sender, signedAmount);
            erc20.safeTransferFrom(msg.sender, address(this), amount);
        }
        _tokenStorageCheck(msg.sender);
    }

    /// @notice withdraw all `erc20s` from creditAccount to wallet
    /// @param erc20s Array of addresses of ERC20 to be transferred
    function withdrawFull(IERC20[] calldata erc20s) external onlyWallet whenNotPaused {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            int256 amount = _creditAccountERC20Clear(msg.sender, erc20Idx);
            if (amount < 0) {
                revert CannotWithdrawDebt();
            }
            emit ISupaCore.ERC20BalanceChanged(address(erc20), erc20Idx, msg.sender, amount);
            erc20.safeTransfer(msg.sender, uint256(amount));
        }
    }

    /// @notice deposit ERC721 `erc721Contract` token `tokenId` from wallet to creditAccount
    /// @dev the part when we track the ownership of deposit NFT to a specific creditAccount is in
    /// `onERC721Received` function of this contract
    /// @param erc721Contract The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    function depositERC721(
        address erc721Contract,
        uint256 tokenId
    )
        external
        override
        onlyWallet
        whenNotPaused
        onlyRegisteredNFT(erc721Contract, tokenId)
        onlyNFTOwner(erc721Contract, tokenId)
    {
        address _owner = ERC721(erc721Contract).ownerOf(tokenId);
        emit ISupaCore.ERC721Deposited(erc721Contract, msg.sender, tokenId);
        ERC721(erc721Contract).safeTransferFrom(
            _owner,
            address(this),
            tokenId,
            abi.encode(msg.sender)
        );
    }

    /// @notice deposit ERC721 `erc721Contract` token `tokenId` from wallet to creditAccount
    /// @dev the part when we track the ownership of deposit NFT to a specific creditAccount is in
    /// `onERC721Received` function of this contract
    /// @param erc721Contract The address of the ERC721 contract that the token belongs to
    /// @param to The wallet address for which the NFT will be deposited
    /// @param tokenId The id of the token to be transferred
    function depositERC721ForWallet(
        address erc721Contract,
        address to,
        uint256 tokenId
    )
        external
        override
        walletExists(to)
        whenNotPaused
        onlyRegisteredNFT(erc721Contract, tokenId)
        onlyNFTOwner(erc721Contract, tokenId)
    {
        address _owner = ERC721(erc721Contract).ownerOf(tokenId);
        emit ISupaCore.ERC721Deposited(erc721Contract, to, tokenId);
        ERC721(erc721Contract).safeTransferFrom(_owner, address(this), tokenId, abi.encode(to));
    }

    /// @notice withdraw ERC721 `nftContract` token `tokenId` from creditAccount to wallet
    /// @param erc721 The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    function withdrawERC721(
        address erc721,
        uint256 tokenId
    ) external override onlyWallet whenNotPaused {
        WalletLib.NFTId nftId = _getNFTId(erc721, tokenId);

        wallets[msg.sender].extractNFT(nftId, tokenDataByNFTId);
        delete tokenDataByNFTId[nftId];
        emit ISupaCore.ERC721Withdrawn(erc721, msg.sender, tokenId);

        ERC721(erc721).safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /// @notice transfer `amount` of `erc20` from creditAccount of caller wallet to creditAccount of `to` wallet
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param to wallet address, whose creditAccount is the transfer target
    /// @param amount The amount of `erc20` to be transferred
    function transferERC20(
        IERC20 erc20,
        address to,
        uint256 amount
    ) external override onlyWallet whenNotPaused walletExists(to) {
        if (amount == 0) return;
        _transferERC20(erc20, msg.sender, to, FsMath.safeCastToSigned(amount));
    }

    /// @notice transfer NFT `erc721` token `tokenId` from creditAccount of caller wallet to creditAccount of
    /// `to` wallet
    /// @param erc721 The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    /// @param to wallet address, whose creditAccount is the transfer target
    function transferERC721(
        address erc721,
        uint256 tokenId,
        address to
    ) external override onlyWallet whenNotPaused walletExists(to) {
        WalletLib.NFTId nftId = _getNFTId(erc721, tokenId);
        _transferNFT(nftId, msg.sender, to);
    }

    /// @notice Transfer ERC20 tokens from creditAccount to another creditAccount
    /// @dev Note: Allowance must be set with approveERC20
    /// @param erc20 The index of the ERC20 token in erc20Infos array
    /// @param from The address of the wallet to transfer from
    /// @param to The address of the wallet to transfer to
    /// @param amount The amount of tokens to transfer
    /// @return true, when the transfer has been successfully finished without been reverted
    function transferFromERC20(
        address erc20,
        address from,
        address to,
        uint256 amount
    ) external override whenNotPaused walletExists(from) walletExists(to) returns (bool) {
        address spender = msg.sender;
        _spendAllowance(erc20, from, spender, amount);
        _transferERC20(IERC20(erc20), from, to, FsMath.safeCastToSigned(amount));
        return true;
    }

    /// @notice Transfer ERC721 tokens from creditAccount to another creditAccount
    /// @param collection The address of the ERC721 token
    /// @param from The address of the wallet to transfer from
    /// @param to The address of the wallet to transfer to
    /// @param tokenId The id of the token to transfer
    function transferFromERC721(
        address collection,
        address from,
        address to,
        uint256 tokenId
    ) external override onlyWallet whenNotPaused walletExists(to) {
        WalletLib.NFTId nftId = _getNFTId(collection, tokenId);
        if (!_isApprovedOrOwner(msg.sender, nftId)) {
            revert NotApprovedOrOwner();
        }
        _transferNFT(nftId, from, to);
    }

    /// @notice Liquidate an undercollateralized position
    /// @dev if creditAccount of `wallet` has more debt then collateral then this function will
    /// transfer all debt and collateral ERC20s and ERC721 from creditAccount of `wallet` to creditAccount of
    /// caller. Considering that market price of collateral is higher then market price of debt,
    /// a friction of that difference would be sent back to liquidated creditAccount in Supa base currency.
    ///   More specific - "some fraction" is `liqFraction` parameter of Supa.
    ///   Considering that call to this function would create debt on caller (debt is less then
    /// gains, yet still), consider using `liquify` instead, that would liquidate and use
    /// obtained assets to cover all created debt
    ///   If creditAccount of `wallet` has less debt then collateral then the transaction will be reverted
    /// @param wallet The address of wallet whose creditAccount to be liquidate
    function liquidate(
        address wallet
    ) external override onlyWallet whenNotPaused walletExists(wallet) {
        (int256 totalValue, int256 collateral, int256 debt) = getRiskAdjustedPositionValues(wallet);
        if (collateral >= debt) {
            revert NotLiquidatable();
        }
        uint16[] memory walletERC20s = wallets[wallet].getERC20s();
        for (uint256 i = 0; i < walletERC20s.length; i++) {
            uint16 erc20Idx = walletERC20s[i];
            _transferAllERC20(erc20Idx, wallet, msg.sender);
        }
        while (wallets[wallet].nfts.length > 0) {
            _transferNFT(wallets[wallet].nfts[wallets[wallet].nfts.length - 1], wallet, msg.sender);
        }
        if (totalValue > 0) {
            // totalValue of the liquidated wallet is split between liquidatable and liquidator:
            // totalValue * (1 - liqFraction) - reward of the liquidator, and
            // totalValue * liqFraction - change, liquidator is sending back to liquidatable
            int256 percentUnderwater = (collateral * 1 ether) / debt;
            int256 leftover = ((totalValue * config.liqFraction * percentUnderwater) / 1 ether) /
                1 ether;
            _transferERC20(
                IERC20(erc20Infos[K_NUMERAIRE_IDX].erc20Contract),
                msg.sender,
                wallet,
                leftover
            );
        }
        emit ISupaCore.WalletLiquidated(wallet, msg.sender, collateral, debt);
    }

    /// @notice Add an operator for wallet
    /// @param operator The address of the operator to add
    /// @dev Operator can execute batch of transactions on behalf of wallet owner
    function addOperator(address operator) external override onlyWallet {
        operatorApprovals[msg.sender][operator] = true;
        emit OperatorAdded(msg.sender, operator);
    }

    /// @notice Remove an operator for wallet
    /// @param operator The address of the operator to remove
    /// @dev Operator can execute batch of transactions on behalf of wallet owner
    function removeOperator(address operator) external override onlyWallet {
        operatorApprovals[msg.sender][operator] = false;
        emit OperatorRemoved(msg.sender, operator);
    }

    /// @notice Execute a batch of calls
    /// @dev execute a batch of commands on Supa from the name of wallet owner. Eventual state of
    /// creditAccount and Supa must be solvent, i.e. debt on creditAccount cannot exceed collateral
    /// and Supa reserve/debt must be sufficient
    /// @param calls An array of transaction calls
    function executeBatch(Call[] memory calls) external override onlyWallet whenNotPaused {
        WalletProxy(payable(msg.sender)).executeBatch(calls);
        if (!isSolvent(msg.sender)) {
            revert Insolvent();
        }
    }

    /// @notice ERC721 transfer callback
    /// @dev it's a callback, required to be implemented by IERC721Receiver interface for the
    /// contract to be able to receive ERC721 NFTs.
    /// We are using it to track what creditAccount owns what NFT.
    /// `return this.onERC721Received.selector;` is mandatory part for the NFT transfer to work -
    /// not a part of our business logic
    /// @param - operator The address which called `safeTransferFrom` function
    /// @param from The address which previously owned the token
    /// @param tokenId The NFT identifier which is being transferred
    /// @param data Additional data with no specified format
    /// @return `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
    function onERC721Received(
        address /* operator */,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override whenNotPaused returns (bytes4) {
        WalletLib.NFTId nftId = _getNFTId(msg.sender, tokenId);
        if (data.length != 0) {
            from = abi.decode(data, (address));
        }
        if (wallets[from].owner == address(0)) {
            revert WalletNonExistent();
        }
        tokenDataByNFTId[nftId].tokenId = uint240(tokenId);
        wallets[from].insertNFT(nftId, tokenDataByNFTId);
        _tokenStorageCheck(from);
        return this.onERC721Received.selector;
    }

    /// @notice Approve an array of tokens and then call `onApprovalReceived` on msg.sender
    /// @param approvals An array of ERC20 tokens with amounts, or ERC721 contracts with tokenIds
    /// @param spender The address of the spender
    /// @param data Additional data with no specified format, sent in call to `spender`
    function approveAndCall(
        Approval[] calldata approvals,
        address spender,
        bytes calldata data
    ) external override onlyWallet whenNotPaused {
        uint256[] memory prev = new uint256[](approvals.length);
        for (uint256 i = 0; i < approvals.length; i++) {
            prev[i] = _approve(
                msg.sender,
                spender,
                approvals[i].ercContract,
                approvals[i].amountOrTokenId,
                spender
            );
        }
        if (!_checkOnApprovalReceived(msg.sender, 0, spender, data)) {
            revert WrongDataReturned();
        }
        for (uint256 i = 0; i < approvals.length; i++) {
            _approve(msg.sender, spender, approvals[i].ercContract, prev[i], address(0)); // reset allowance
        }
    }

    /// @notice provides the specific version of walletLogic contract that is associated with `wallet`
    /// @param wallet Address of wallet whose walletLogic contract should be returned
    /// @return the address of the walletLogic contract that is associated with the `wallet`
    function getImplementation(address wallet) external view override returns (address) {
        // not using msg.sender since this is an external view function
        return walletLogic[wallet];
    }

    /// @notice provides the owner of `wallet`. Owner of the wallet is the address who created the wallet
    /// @param wallet The address of wallet whose owner should be returned
    /// @return the owner address of the `wallet`. Owner is the one who created the `wallet`
    function getWalletOwner(address wallet) external view override returns (address) {
        return wallets[wallet].owner;
    }

    /// @notice returns the collateral, debt and total value of `walletAddress`.
    /// @dev Notice that both collateral and debt has some coefficients on the actual amount of deposit
    /// and loan assets! E.g.
    /// for a deposit of 1 ETH the collateral would be equivalent to like 0.8 ETH, and
    /// for a loan of 1 ETH the debt would be equivalent to like 1.2 ETH.
    /// At the same time, totalValue is the unmodified difference between deposits and loans.
    /// @param walletAddress The address of wallet whose collateral, debt and total value would be returned
    /// @return totalValue The difference between equivalents of deposit and loan assets
    /// @return collateral The sum of deposited assets multiplied by their collateral factors
    /// @return debt The sum of borrowed assets multiplied by their borrow factors
    function getRiskAdjustedPositionValues(
        address walletAddress
    )
        public
        view
        override
        walletExists(walletAddress)
        returns (int256 totalValue, int256 collateral, int256 debt)
    {
        WalletLib.Wallet storage wallet = wallets[walletAddress];
        uint16[] memory erc20Idxs = wallet.getERC20s();
        totalValue = 0;
        collateral = 0;
        debt = 0;
        for (uint256 i = 0; i < erc20Idxs.length; i++) {
            uint16 erc20Idx = erc20Idxs[i];
            ERC20Info storage erc20Info = erc20Infos[erc20Idx];
            int256 balance = getBalance(wallet.erc20Share[erc20Idx], erc20Info);
            (int256 value, int256 riskAdjustedValue) = erc20Info.valueOracle.calcValue(balance);
            totalValue += value;
            if (balance >= 0) {
                collateral += riskAdjustedValue;
            } else {
                debt -= riskAdjustedValue;
            }
        }
        for (uint256 i = 0; i < wallet.nfts.length; i++) {
            WalletLib.NFTId nftId = wallet.nfts[i];
            (uint16 erc721Idx, uint256 tokenId) = getNFTData(nftId);
            ERC721Info storage nftInfo = erc721Infos[erc721Idx];
            (int256 nftValue, int256 nftRiskAdjustedValue) = nftInfo.valueOracle.calcValue(tokenId);
            totalValue += nftValue;
            collateral += nftRiskAdjustedValue;
        }
    }

    /// @notice Returns the approved address for a token, or zero if no address set
    /// @param collection The address of the ERC721 token
    /// @param tokenId The id of the token to query
    /// @return The wallet address that is allowed to transfer the ERC721 token
    function getApproved(
        address collection,
        uint256 tokenId
    ) public view override returns (address) {
        WalletLib.NFTId nftId = _getNFTId(collection, tokenId);
        return tokenDataByNFTId[nftId].approvedSpender;
    }

    /// @notice Returns if the 'spender' is an operator for the '_owner'
    function isOperator(address _owner, address spender) public view override returns (bool) {
        return operatorApprovals[_owner][spender];
    }

    /// @notice Returns the remaining amount of tokens that `spender` will be allowed to spend on
    /// behalf of `owner` through {transferFrom}
    /// @dev This value changes when {approve} or {transferFrom} are called
    /// @param erc20 The address of the ERC20 to be checked
    /// @param _owner The wallet address whose `erc20` are allowed to be transferred by `spender`
    /// @param spender The wallet address who is allowed to spend `erc20` of `_owner`
    /// @return the remaining amount of tokens that `spender` will be allowed to spend on
    /// behalf of `owner` through {transferFrom}
    function allowance(
        address erc20,
        address _owner,
        address spender
    ) public view override returns (uint256) {
        if (_owner == spender) return type(uint256).max;
        return allowances[_owner][erc20][spender];
    }

    /// @notice Compute the interest rate of `underlying`
    /// @param erc20Idx The underlying asset
    /// @return The interest rate of `erc20Idx`
    function computeInterestRate(uint16 erc20Idx) public view override returns (int96) {
        ERC20Info memory erc20Info = erc20Infos[erc20Idx];
        uint256 debt = FsMath.safeCastToUnsigned(-erc20Info.debt.tokens); // question: is debt ever positive?
        uint256 collateral = FsMath.safeCastToUnsigned(erc20Info.collateral.tokens); // question: is collateral ever negative?
        uint256 leverage = FsMath.safeCastToUnsigned(config.fractionalReserveLeverage);
        uint256 poolAssets = debt + collateral;

        uint256 ir = erc20Info.baseRate;
        uint256 utilization; // utilization of the pool
        if (poolAssets <= POOL_ASSETS_CUTOFF)
            utilization = 0; // if there are no assets, utilization is 0
        else utilization = uint256((debt * 1e18) / ((collateral - debt) / leverage));

        if (utilization <= erc20Info.targetUtilization) {
            ir += (utilization * erc20Info.slope1) / 1e15;
        } else {
            ir += (erc20Info.targetUtilization * erc20Info.slope1) / 1e15;
            ir += ((erc20Info.slope2 * (utilization - erc20Info.targetUtilization)) / 1e15);
        }

        return int96(int256(ir));
    }

    /// @notice Checks if the account's positions are overcollateralized
    /// @dev checks the eventual state of `executeBatch` function execution:
    /// * `wallet` must have collateral >= debt
    /// * Supa must have sufficient balance of deposits and loans for each ERC20 token
    /// @dev when called by the end of `executeBatch`, isSolvent checks the potential target state
    /// of Supa. Calling this function separately would check current state of Supa, that is always
    /// solvable, and so the return value would always be `true`, unless the `wallet` is liquidatable
    /// @param wallet The address of a wallet who performed the `executeBatch`
    /// @return Whether the position is solvent.
    function isSolvent(address wallet) public view returns (bool) {
        uint gasBefore = gasleft();
        int256 leverage = config.fractionalReserveLeverage;
        for (uint256 i = 0; i < erc20Infos.length; i++) {
            int256 totalDebt = erc20Infos[i].debt.tokens;
            int256 reserve = erc20Infos[i].collateral.tokens + totalDebt;
            FsUtils.Assert(
                IERC20(erc20Infos[i].erc20Contract).balanceOf(address(this)) >= uint256(reserve)
            );
            if (reserve < -totalDebt / leverage) {
                revert InsufficientReserves();
            }
        }
        (, int256 collateral, int256 debt) = getRiskAdjustedPositionValues(wallet);
        if (gasBefore - gasleft() > config.maxSolvencyCheckGasCost)
            revert SolvencyCheckTooExpensive();
        return collateral >= debt;
    }

    function _approve(
        address _owner,
        address spender,
        address ercContract,
        uint256 amountOrTokenId,
        address erc721Spender
    ) internal returns (uint256 prev) {
        FsUtils.Assert(spender != address(0));
        ContractData memory data = infoIdx[ercContract];
        if (data.kind == ContractKind.ERC20) {
            prev = allowance(ercContract, _owner, spender);
            allowances[_owner][ercContract][spender] = amountOrTokenId;
        } else if (data.kind == ContractKind.ERC721) {
            prev = amountOrTokenId;
            tokenDataByNFTId[_getNFTId(ercContract, amountOrTokenId)]
                .approvedSpender = erc721Spender;
        } else {
            FsUtils.Assert(false);
        }
    }

    /// @dev changes the quantity of `erc20` by `amount` that are allowed to transfer from creditAccount
    /// of wallet `_owner` by wallet `spender`
    function _spendAllowance(
        address erc20,
        address _owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = allowance(erc20, _owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance();
            }
            unchecked {
                allowances[_owner][erc20][spender] = currentAllowance - amount;
            }
        }
    }

    /**
     * @dev Internal function to invoke {IERC1363Receiver-onApprovalReceived} on a target address
     *  The call is not executed if the target address is not a contract
     * @param spender address The address which will spend the funds
     * @param amount uint256 The amount of tokens to be spent
     * @param data bytes Optional data to send along with the call
     * @return whether the call correctly returned the expected magic value
     */
    function _checkOnApprovalReceived(
        address spender, // safe
        uint256 amount,
        address target, // router
        bytes memory data
    ) internal returns (bool) {
        if (!spender.isContract()) {
            revert ReceiverNotContract();
        }

        Call memory call = Call({to: target, callData: data, value: msg.value});

        try IERC1363SpenderExtended(spender).onApprovalReceived(msg.sender, amount, call) returns (
            bytes4 retval
        ) {
            return retval == IERC1363SpenderExtended.onApprovalReceived.selector;
        } catch (bytes memory reason) {
            if (reason.length == 0) {
                revert ReceiverNoImplementation();
            } else {
                FsUtils.revertBytes(reason);
            }
        }
    }

    /// @dev transfer ERC20 balances between creditAccounts.
    /// Because all ERC20 tokens on creditAccounts are owned by Supa, no tokens are getting transferred -
    /// all changes are inside Supa contract state
    /// @param erc20 The address of ERC20 token balance to transfer
    /// @param from The address of wallet whose creditAccount balance should be decreased by `amount`
    /// @param to The address of wallet whose creditAccount balance should be increased by `amount`
    /// @param amount The amount of `erc20` by witch the balance of
    /// creditAccount of wallet `from` should be decreased and
    /// creditAccount of wallet `to` should be increased.
    /// Note that amount it can be negative
    function _transferERC20(IERC20 erc20, address from, address to, int256 amount) internal {
        (, uint16 erc20Idx) = getERC20Info(erc20);
        _creditAccountERC20ChangeBy(from, erc20Idx, -amount);
        _creditAccountERC20ChangeBy(to, erc20Idx, amount);
        _tokenStorageCheck(to);
        emit ISupaCore.ERC20Transfer(address(erc20), erc20Idx, from, to, amount);
    }

    /// @dev transfer ERC721 NFT ownership between creditAccounts.
    /// Because all ERC721 NFTs on creditAccounts are owned by Supa, no NFT is getting transferred - all
    /// changes are inside Supa contract state
    function _transferNFT(WalletLib.NFTId nftId, address from, address to) internal {
        wallets[from].extractNFT(nftId, tokenDataByNFTId);
        wallets[to].insertNFT(nftId, tokenDataByNFTId);
        _tokenStorageCheck(to);
        emit ERC721Transferred(WalletLib.NFTId.unwrap(nftId), from, to);
    }

    /// @dev transfer all `erc20Idx` from `from` to `to`
    function _transferAllERC20(uint16 erc20Idx, address from, address to) internal {
        int256 amount = _creditAccountERC20Clear(from, erc20Idx);
        _creditAccountERC20ChangeBy(to, erc20Idx, amount);
        address erc20 = erc20Infos[erc20Idx].erc20Contract;
        emit ISupaCore.ERC20Transfer(erc20, erc20Idx, from, to, amount);
    }

    function _creditAccountERC20ChangeBy(
        address walletAddress,
        uint16 erc20Idx,
        int256 amount
    ) internal {
        _updateInterest(erc20Idx);
        WalletLib.Wallet storage wallet = wallets[walletAddress];
        ERC20Share shares = wallet.erc20Share[erc20Idx];
        ERC20Info storage erc20Info = erc20Infos[erc20Idx];
        int256 currentAmount = _extractPosition(shares, erc20Info);
        int256 newAmount = currentAmount + amount;
        wallet.erc20Share[erc20Idx] = _insertPosition(newAmount, wallet, erc20Idx);
    }

    function _creditAccountERC20Clear(
        address walletAddress,
        uint16 erc20Idx
    ) internal returns (int256) {
        _updateInterest(erc20Idx);
        WalletLib.Wallet storage wallet = wallets[walletAddress];
        ERC20Share shares = wallet.erc20Share[erc20Idx];
        int256 erc20Amount = _extractPosition(shares, erc20Infos[erc20Idx]);
        wallet.erc20Share[erc20Idx] = ERC20Share.wrap(0);
        wallet.removeERC20IdxFromCreditAccount(erc20Idx);
        return erc20Amount;
    }

    function _extractPosition(
        ERC20Share sharesWrapped,
        ERC20Info storage erc20Info
    ) internal returns (int256 position) {
        int256 shares = ERC20Share.unwrap(sharesWrapped);
        ERC20Pool storage pool = shares > 0 ? erc20Info.collateral : erc20Info.debt;
        position = pool.extractPosition(sharesWrapped);
        return position;
    }

    function _insertPosition(
        int256 amount,
        WalletLib.Wallet storage wallet,
        uint16 erc20Idx
    ) internal returns (ERC20Share) {
        if (amount == 0) {
            wallet.removeERC20IdxFromCreditAccount(erc20Idx);
        } else {
            wallet.addERC20IdxToCreditAccount(erc20Idx);
        }
        ERC20Info storage erc20Info = erc20Infos[erc20Idx];
        ERC20Pool storage pool = amount > 0 ? erc20Info.collateral : erc20Info.debt;
        return pool.insertPosition(amount);
    }

    function _updateInterest(uint16 erc20Idx) internal {
        ERC20Info storage erc20Info = erc20Infos[erc20Idx]; // retrieve ERC20Info and store in memory
        if (erc20Info.timestamp == block.timestamp) return; // already updated this block
        int256 delta = FsMath.safeCastToSigned(block.timestamp - erc20Info.timestamp); // time passed since last update
        erc20Info.timestamp = block.timestamp; // update timestamp to current timestamp
        int256 debt = -erc20Info.debt.tokens; // get the debt
        int256 interestRate = computeInterestRate(erc20Idx);
        int256 interest = (debt * (FsMath.exp(interestRate * delta) - FsMath.FIXED_POINT_SCALE)) /
            FsMath.FIXED_POINT_SCALE; // Get the interest
        int256 treasuryInterest = (interest *
            FsMath.safeCastToSigned(config.treasuryInterestFraction)) / 1 ether; // Get the treasury interest
        erc20Info.debt.tokens -= interest; // subtract interest from debt (increase)
        erc20Info.collateral.tokens += interest - treasuryInterest; // add interest to collateral (increase)

        _creditAccountERC20ChangeBy(config.treasuryWallet, erc20Idx, treasuryInterest); // add treasury interest to treasury
    }

    function _tokenStorageCheck(address walletAddress) internal view {
        WalletLib.Wallet storage wallet = wallets[walletAddress];
        uint256 tokenCounter;
        uint256 nftCounter = wallet.nfts.length;
        if (wallet.tokenCounter < 0) {
            tokenCounter = 0;
        } else {
            tokenCounter = FsMath.safeCastToUnsigned(wallet.tokenCounter);
        }
        uint256 tokenStorage = (tokenCounter * tokenStorageConfig.erc20Multiplier) +
            (nftCounter * tokenStorageConfig.erc721Multiplier);
        if (tokenStorage > tokenStorageConfig.maxTokenStorage) {
            revert TokenStorageExceeded();
        }
    }

    function _getNFTId(address erc721, uint256 tokenId) internal view returns (WalletLib.NFTId) {
        if (infoIdx[erc721].kind != ContractKind.ERC721) {
            revert NotNFT();
        }
        uint16 erc721Idx = infoIdx[erc721].idx;
        uint256 tokenHash = uint256(keccak256(abi.encodePacked(tokenId))) >> 32;
        return WalletLib.NFTId.wrap(erc721Idx | (tokenHash << 16) | ((tokenId >> 240) << 240));
    }

    function _isApprovedOrOwner(
        address spender,
        WalletLib.NFTId nftId
    ) internal view returns (bool) {
        WalletLib.Wallet storage p = wallets[msg.sender];
        (uint16 infoIndex, uint256 tokenId) = getNFTData(nftId);
        address collection = erc721Infos[infoIndex].erc721Contract;
        uint16 idx = tokenDataByNFTId[nftId].walletIdx;
        bool isdepositERC721Owner = idx < p.nfts.length &&
            WalletLib.NFTId.unwrap(p.nfts[idx]) == WalletLib.NFTId.unwrap(nftId);
        return (isdepositERC721Owner || getApproved(collection, tokenId) == spender);
    }

    // Config functions are handled by SupaConfig
    function _implementation() internal view override returns (address) {
        return supaConfigAddress;
    }
}
