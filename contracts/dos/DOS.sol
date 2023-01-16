// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "../lib/FsUtils.sol";
import "../lib/FsMath.sol";
import "../interfaces/IDOS.sol";
import "../interfaces/IERC20ValueOracle.sol";
import "../interfaces/INFTValueOracle.sol";
import {PERMIT2, IPermit2} from "../external/interfaces/IPermit2.sol";
import {DSafeProxy} from "./DSafeProxy.sol";
import "../dosERC20/DOSERC20.sol";
import {IVersionManager} from "../interfaces/IVersionManager.sol";
import "../lib/Call.sol";
import {IERC1363SpenderExtended, IERC1363ReceiverExtended} from "../interfaces/IERC1363-extended.sol";

/// @notice Sender is not approved to spend dSafe erc20
error NotApprovedOrOwner();
/// @notice Sender is not the owner of the dSafe;
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
/// @notice NFT must be in the user's dSafe
error NFTNotInDSafe();
/// @notice NFT must be owned the the user or user's dSafe
error NotNFTOwner();
/// @notice Asset is not registered
/// @param token The unregistered asset
error NotRegistered(address token);
/// @notice Only dSafe can call this function
error OnlyDSafe();
/// @notice Recipient is not a valid dSafe
error DSafeNonExistent();
/// @notice Operation leaves dSafe insolvent
error Insolvent();
/// @notice The address is not a registered ERC20
error NotERC20();

// ERC20 standard token
// ERC721 single non-fungible token support
// ERC677 transferAndCall (transferAndCall2 extension)
// ERC165 interface support (solidity IDOS.interfaceId)
// ERC777 token send
// ERC1155 multi-token support
// ERC1363 payable token (approveAndCall/transferAndCall)
// ERC1820 interface registry support
// EIP2612 permit support (uniswap permit2)
/*
 * NFTs are stored in an array of nfts owned by some dSafe. To prevent looping over arrays we need to
 * know the following information for each NFT in the system (erc721, tokenId, dSafe, array index).
 * Given the expensive nature of storage on the EVM we want to store all information as small as possible.
 * The pair (erc721, tokenId) is describes a particular NFT but would take two storage slots (as a token id)
 * is 256 bits. The erc721 address is 160 bits however we only allow pre-approved erc721 contracts, so in
 * practice 16 bits would be enough to store an index into the allowed erc721 contracts. We can hash (erc721 + tokenId)
 * to get a unique number but that requires storing both tokenId, erc721 and array index. Instead we hash into
 * 224 (256 - 32) bits which is still sufficiently large to avoid collisions. This leaves 32 bits for additional
 * information. The 16 LSB are used to store the index in the dSafe array. The 16 RSB are used to store
 * the 16 RSB of the tokenId. This allows us to store the tokenId + array index in a single storage slot as a map
 * from NFTId to NFTData. Note that the index in the dSafe array might change and thus cannot be part of
 * NFTId and thus has to be stored as part of NFTData, requiring the splitting of tokenId.
 */

struct NFTTokenData {
    uint240 tokenId; // 240 LSB of the tokenId of the NFT
    uint16 dSafeIdx; // index in dSafe NFT array
    address approvedSpender; // approved spender for ERC721
}

struct ERC20Pool {
    int256 tokens;
    int256 shares;
}

library DSafeLib {
    type NFTId is uint256; // 16 bits (tokenId) + 224 bits (hash) + 16 bits (erc721 index)

    struct DSafe {
        address owner;
        mapping(uint16 => ERC20Share) erc20Share;
        NFTId[] nfts;
        // bitmask of DOS indexes of ERC20 present in a dSafe. `1` can be increased on updates
        uint256[1] dAccountErc20Idxs;
    }

    function removeERC20IdxFromDAccount(DSafe storage dSafe, uint16 erc20Idx) internal {
        dSafe.dAccountErc20Idxs[erc20Idx >> 8] &= ~(1 << (erc20Idx & 255));
    }

    function accERC20IdxToDAccount(DSafe storage dSafe, uint16 erc20Idx) internal {
        dSafe.dAccountErc20Idxs[erc20Idx >> 8] |= (1 << (erc20Idx & 255));
    }

    function extractPosition(
        ERC20Pool storage pool,
        ERC20Share shares
    ) internal returns (int256 tokens) {
        tokens = computeERC20(pool, shares);
        pool.tokens -= tokens;
        pool.shares -= ERC20Share.unwrap(shares);
    }

    function insertPosition(ERC20Pool storage pool, int256 tokens) internal returns (ERC20Share) {
        int256 shares;
        if (pool.shares == 0) {
            FsUtils.Assert(pool.tokens == 0);
            shares = tokens;
        } else {
            shares = (pool.shares * tokens) / pool.tokens;
        }
        pool.tokens += tokens;
        pool.shares += shares;
        return ERC20Share.wrap(shares);
    }

    function extractNFT(
        DSafe storage dSafe,
        NFTId nftId,
        mapping(NFTId => NFTTokenData) storage map
    ) internal {
        uint16 idx = map[nftId].dSafeIdx;
        map[nftId].approvedSpender = address(0); // remove approval
        bool userOwnsNFT = dSafe.nfts.length > 0 &&
            NFTId.unwrap(dSafe.nfts[idx]) == NFTId.unwrap(nftId);
        if (!userOwnsNFT) {
            revert NFTNotInDSafe();
        }
        if (idx == dSafe.nfts.length - 1) {
            dSafe.nfts.pop();
        } else {
            NFTId lastNFTId = dSafe.nfts[dSafe.nfts.length - 1];
            map[lastNFTId].dSafeIdx = idx;
            dSafe.nfts.pop();
        }
    }

    function insertNFT(
        DSafe storage dSafe,
        NFTId nftId,
        mapping(NFTId => NFTTokenData) storage map
    ) internal {
        uint16 idx = uint16(dSafe.nfts.length);
        dSafe.nfts.push(nftId);
        map[nftId].dSafeIdx = idx;
    }

    function getERC20s(DSafe storage dSafe) internal view returns (uint16[] memory erc20s) {
        uint256 numberOfERC20 = 0;
        for (uint256 i = 0; i < dSafe.dAccountErc20Idxs.length; i++) {
            numberOfERC20 += FsMath.bitCount(dSafe.dAccountErc20Idxs[i]);
        }
        erc20s = new uint16[](numberOfERC20);
        uint256 idx = 0;
        for (uint256 i = 0; i < dSafe.dAccountErc20Idxs.length; i++) {
            uint256 mask = dSafe.dAccountErc20Idxs[i];
            for (uint256 j = 0; j < 256; j++) {
                uint256 x = mask >> j;
                if (x == 0) break;
                if ((x & 1) != 0) {
                    erc20s[idx++] = uint16(i * 256 + j);
                }
            }
        }
    }

    function computeERC20(
        ERC20Pool storage pool,
        ERC20Share sharesWrapped
    ) internal view returns (int256 tokens) {
        int256 shares = ERC20Share.unwrap(sharesWrapped);
        if (shares == 0) return 0;
        FsUtils.Assert(pool.shares != 0);
        return (pool.tokens * shares) / pool.shares;
    }
}

struct ERC20Info {
    address erc20Contract;
    address dosContract;
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

enum ContractKind {
    Invalid,
    ERC20,
    ERC721
}

struct ContractData {
    uint16 idx;
    ContractKind kind; // 0 invalid, 1 ERC20, 2 ERC721
}

// We will initialize the system so that 0 is the base currency
// in which the system calculates value.
uint16 constant K_NUMERAIRE_IDX = 0;

/// @title DOS State
/// @notice Contract holds the configuration state for DOS
contract DOSState is Pausable {
    using DSafeLib for ERC20Pool;

    IVersionManager public versionManager;
    /// @notice mapping between dSafe address and DOS-specific dSafe data
    mapping(address => DSafeLib.DSafe) public dSafes;

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

    /// @notice Whether a spender is approved to operate a dSafe's NFTs for a specific collection
    /// @dev Mapping from dSafe owner address => NFT address => spender address => bool
    /// @dev erc721 & erc1155 operator approvals
    mapping(address => mapping(address => mapping(address => bool))) public operatorApprovals;

    mapping(DSafeLib.NFTId => NFTTokenData) public tokenDataByNFTId;

    ERC20Info[] public erc20Infos;
    ERC721Info[] public erc721Infos;

    /// @notice mapping of ERC20 or ERC721 address => DOS asset idx and contract kind.
    /// idx is the index of the ERC20 in `erc20Infos` or ERC721 in `erc721Infos`
    /// kind is ContractKind enum, that here can be ERC20 or ERC721
    mapping(address => ContractData) public infoIdx;

    IDOSConfig.Config public config;

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

/// @title DeFi OS (DOS)
contract DOS is DOSState, IDOSCore, IERC721Receiver, Proxy {
    using DSafeLib for DSafeLib.DSafe;
    using DSafeLib for ERC20Pool;
    using SafeERC20 for IERC20;
    using Address for address;

    address immutable dosConfigAddress;

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
        bool isOwner = _owner == msg.sender || _owner == dSafes[msg.sender].owner;
        if (!isOwner) {
            revert NotNFTOwner();
        }
        _;
    }

    constructor(address _dosConfig, address _versionManager) {
        versionManager = IVersionManager(FsUtils.nonNull(_versionManager));
        dosConfigAddress = FsUtils.nonNull(_dosConfig);
    }

    /// @notice top up the dAccount owned by dSafe `to` with `amount` of `erc20`
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param to Address of the dSafe that dAccount should be top up
    /// @param amount The amount of `erc20` to be sent
    function depositERC20ForSafe(
        address erc20,
        address to,
        uint256 amount
    ) external override dSafeExists(to) whenNotPaused {
        if (amount == 0) return;
        (, uint16 erc20Idx) = getERC20Info(IERC20(erc20));
        int256 signedAmount = FsMath.safeCastToSigned(amount);
        _dAccountERC20ChangeBy(to, erc20Idx, signedAmount);
        emit IDOSCore.ERC20BalanceChanged(erc20, to, signedAmount);
        IERC20(erc20).safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice deposit `amount` of `erc20` to dAccount from dSafe
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param amount The amount of `erc20` to be transferred
    function depositERC20(IERC20 erc20, uint256 amount) external override onlyDSafe whenNotPaused {
        if (amount == 0) return;
        (, uint16 erc20Idx) = getERC20Info(erc20);
        int256 signedAmount = FsMath.safeCastToSigned(amount);
        _dAccountERC20ChangeBy(msg.sender, erc20Idx, signedAmount);
        emit IDOSCore.ERC20BalanceChanged(address(erc20), msg.sender, signedAmount);
        erc20.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice deposit `amount` of `erc20` from dAccount tp dSafe
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param amount The amount of `erc20` to be transferred
    function withdrawERC20(IERC20 erc20, uint256 amount) external override onlyDSafe whenNotPaused {
        (, uint16 erc20Idx) = getERC20Info(erc20);
        int256 signedAmount = FsMath.safeCastToSigned(amount);
        _dAccountERC20ChangeBy(msg.sender, erc20Idx, -signedAmount);
        emit IDOSCore.ERC20BalanceChanged(address(erc20), msg.sender, -signedAmount);
        erc20.safeTransfer(msg.sender, amount);
    }

    /// @notice deposit all `erc20s` from dSafe to dAccount
    /// @param erc20s Array of addresses of ERC20 to be transferred
    function depositFull(IERC20[] calldata erc20s) external override onlyDSafe whenNotPaused {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            uint256 amount = erc20.balanceOf(msg.sender);
            int256 signedAmount = FsMath.safeCastToSigned(amount);
            _dAccountERC20ChangeBy(msg.sender, erc20Idx, signedAmount);
            emit IDOSCore.ERC20BalanceChanged(address(erc20), msg.sender, signedAmount);
            erc20.safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    /// @notice withdraw all `erc20s` from dAccount to dSafe
    /// @param erc20s Array of addresses of ERC20 to be transferred
    function withdrawFull(IERC20[] calldata erc20s) external onlyDSafe whenNotPaused {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            int256 amount = _dAccountERC20Clear(msg.sender, erc20Idx);
            require(amount >= 0, "Can't withdraw debt");
            emit IDOSCore.ERC20BalanceChanged(address(erc20), msg.sender, amount);
            erc20.safeTransfer(msg.sender, uint256(amount));
        }
    }

    /// @notice deposit ERC721 `erc721Contract` token `tokenId` from dSafe to dAccount
    /// @dev the part when we track the ownership of deposit NFT to a specific dAccount is in
    /// `onERC721Received` function of this contract
    /// @param erc721Contract The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    function depositERC721(
        address erc721Contract,
        uint256 tokenId
    )
        external
        override
        onlyDSafe
        whenNotPaused
        onlyRegisteredNFT(erc721Contract, tokenId)
        onlyNFTOwner(erc721Contract, tokenId)
    {
        address _owner = ERC721(erc721Contract).ownerOf(tokenId);
        emit IDOSCore.ERC721Deposited(erc721Contract, msg.sender, tokenId);
        ERC721(erc721Contract).safeTransferFrom(
            _owner,
            address(this),
            tokenId,
            abi.encode(msg.sender)
        );
    }

    /// @notice withdraw ERC721 `nftContract` token `tokenId` from dAccount to dSafe
    /// @param erc721 The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    function withdrawERC721(
        address erc721,
        uint256 tokenId
    ) external override onlyDSafe whenNotPaused {
        DSafeLib.NFTId nftId = _getNFTId(erc721, tokenId);

        dSafes[msg.sender].extractNFT(nftId, tokenDataByNFTId);
        delete tokenDataByNFTId[nftId];
        emit IDOSCore.ERC721Withdrawn(erc721, msg.sender, tokenId);

        ERC721(erc721).safeTransferFrom(address(this), msg.sender, tokenId);
    }

    /// @notice transfer `amount` of `erc20` from dAccount of caller dSafe to dAccount of `to` dSafe
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param to dSafe address, whose dAccount is the transfer target
    /// @param amount The amount of `erc20` to be transferred
    function transferERC20(
        IERC20 erc20,
        address to,
        uint256 amount
    ) external override onlyDSafe whenNotPaused dSafeExists(to) {
        if (amount == 0) return;
        _transferERC20(erc20, msg.sender, to, FsMath.safeCastToSigned(amount));
    }

    /// @notice transfer NFT `erc721` token `tokenId` from dAccount of caller dSafe to dAccount of
    /// `to` dSafe
    /// @param erc721 The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    /// @param to dSafe address, whose dAccount is the transfer target
    function transferERC721(
        address erc721,
        uint256 tokenId,
        address to
    ) external override onlyDSafe whenNotPaused dSafeExists(to) {
        DSafeLib.NFTId nftId = _getNFTId(erc721, tokenId);
        _transferNFT(nftId, msg.sender, to);
    }

    /// @notice Transfer ERC20 tokens from dAccount to another dAccount
    /// @dev Note: Allowance must be set with approveERC20
    /// @param erc20 The index of the ERC20 token in erc20Infos array
    /// @param from The address of the dSafe to transfer from
    /// @param to The address of the dSafe to transfer to
    /// @param amount The amount of tokens to transfer
    /// @return true, when the transfer has been successfully finished without been reverted
    function transferFromERC20(
        address erc20,
        address from,
        address to,
        uint256 amount
    ) external override onlyDSafe whenNotPaused dSafeExists(from) dSafeExists(to) returns (bool) {
        address spender = msg.sender;
        _spendAllowance(erc20, from, spender, amount);
        _transferERC20(IERC20(erc20), from, to, FsMath.safeCastToSigned(amount));
        return true;
    }

    /// @notice Transfer ERC721 tokens from dAccount to another dAccount
    /// @param collection The address of the ERC721 token
    /// @param from The address of the dSafe to transfer from
    /// @param to The address of the dSafe to transfer to
    /// @param tokenId The id of the token to transfer
    function transferFromERC721(
        address collection,
        address from,
        address to,
        uint256 tokenId
    ) external override onlyDSafe whenNotPaused dSafeExists(to) {
        DSafeLib.NFTId nftId = _getNFTId(collection, tokenId);
        if (!_isApprovedOrOwner(msg.sender, from, nftId)) {
            revert NotApprovedOrOwner();
        }
        _transferNFT(nftId, from, to);
    }

    /// @notice Liquidate an undercollateralized position
    /// @dev if dAccount of `dSafe` has more debt then collateral then this function will
    /// transfer all debt and collateral ERC20s and ERC721 from dAccount of `dSafe` to dAccount of
    /// caller. Considering that market price of collateral is higher then market price of debt,
    /// a friction of that difference would be sent back to liquidated dAccount in DOS base currency.
    ///   More specific - "some fraction" is `liqFraction` parameter of DOS.
    ///   Considering that call to this function would create debt on caller (debt is less then
    /// gains, yet still), consider using `liquify` instead, that would liquidate and use
    /// obtained assets to cover all created debt
    ///   If dAccount of `dSafe` has less debt then collateral then the transaction will be reverted
    /// @param dSafe The address of dSafe whose dAccount to be liquidate
    function liquidate(address dSafe) external override onlyDSafe whenNotPaused dSafeExists(dSafe) {
        (int256 totalValue, int256 collateral, int256 debt) = getRiskAdjustedPositionValues(dSafe);
        require(collateral < debt, "DSafe is not liquidatable");
        uint16[] memory dSafeERC20s = dSafes[dSafe].getERC20s();
        for (uint256 i = 0; i < dSafeERC20s.length; i++) {
            uint16 erc20Idx = dSafeERC20s[i];
            _transferAllERC20(erc20Idx, dSafe, msg.sender);
        }
        while (dSafes[dSafe].nfts.length > 0) {
            _transferNFT(dSafes[dSafe].nfts[dSafes[dSafe].nfts.length - 1], dSafe, msg.sender);
        }
        // TODO(gerben) #102 make formula dependent on risk
        if (totalValue > 0) {
            // totalValue of the liquidated dSafe is split between liquidatable and liquidator:
            // totalValue * (1 - liqFraction) - reward of the liquidator, and
            // totalValue * liqFraction - change, liquidator is sending back to liquidatable
            int256 leftover = (totalValue * config.liqFraction) / 1 ether;
            _transferERC20(
                IERC20(erc20Infos[K_NUMERAIRE_IDX].erc20Contract),
                msg.sender,
                dSafe,
                leftover
            );
        }
        emit IDOSCore.SafeLiquidated(dSafe, msg.sender);
    }

    /// @notice Execute a batch of calls
    /// @dev execute a batch of commands on DOS from the name of dSafe owner. Eventual state of
    /// dAccount and DOS must be solvent, i.e. debt on dAccount cannot exceed collateral
    /// and DOS reserve/debt must be sufficient
    /// @param calls An array of transaction calls
    function executeBatch(Call[] memory calls) external override onlyDSafe whenNotPaused {
        DSafeProxy(payable(msg.sender)).executeBatch(calls);
        if (!isSolvent(msg.sender)) {
            revert Insolvent();
        }
    }

    /// @notice ERC721 transfer callback
    /// @dev it's a callback, required to be implemented by IERC721Receiver interface for the
    /// contract to be able to receive ERC721 NFTs.
    /// We are using it to track what dAccount owns what NFT.
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
        DSafeLib.NFTId nftId = _getNFTId(msg.sender, tokenId);
        if (data.length != 0) {
            from = abi.decode(data, (address));
        }
        require(dSafes[from].owner != address(0), "DSafe does not exist");
        tokenDataByNFTId[nftId].tokenId = uint240(tokenId);
        dSafes[from].insertNFT(nftId, tokenDataByNFTId);
        return this.onERC721Received.selector;
    }

    /// @notice Approve an array of tokens and then call `onApprovalReceived` on spender
    /// @param approvals An array of ERC20 tokens with amounts, or ERC721 contracts with tokenIds
    /// @param spender The address of the spender dSafe
    /// @param data Additional data with no specified format, sent in call to `spender`
    function approveAndCall(
        Approval[] calldata approvals,
        address spender,
        bytes calldata data
    ) external override onlyDSafe whenNotPaused dSafeExists(spender) {
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

    /// @notice provides the specific version of dSafeLogic contract that is associated with `dSafe`
    /// @param dSafe Address of dSafe whose dSafeLogic contract should be returned
    /// @return the address of the dSafeLogic contract that is associated with the `dSafe`
    function getImplementation(address dSafe) external view override returns (address) {
        // not using msg.sender since this is an external view function
        return dSafeLogic[dSafe];
    }

    /// @notice provides the owner of `dSafe`. Owner of the dSafe is the address who created the dSafe
    /// @param dSafe The address of dSafe whose owner should be returned
    /// @return the owner address of the `dSafe`. Owner is the one who created the `dSafe`
    function getDSafeOwner(address dSafe) external view override returns (address) {
        return dSafes[dSafe].owner;
    }

    /// @notice returns the collateral, debt and total value of `dSafeAddress`.
    /// @dev Notice that both collateral and debt has some coefficients on the actual amount of deposit
    /// and loan assets! E.g.
    /// for a deposit of 1 ETH the collateral would be equivalent to like 0.8 ETH, and
    /// for a loan of 1 ETH the debt would be equivalent to like 1.2 ETH.
    /// At the same time, totalValue is the unmodified difference between deposits and loans.
    /// @param dSafeAddress The address of dSafe whose collateral, debt and total value would be returned
    /// @return totalValue The difference between equivalents of deposit and loan assets
    /// @return collateral The sum of deposited assets multiplied by their collateral factors
    /// @return debt The sum of borrowed assets multiplied by their borrow factors
    function getRiskAdjustedPositionValues(
        address dSafeAddress
    )
        public
        view
        override
        dSafeExists(dSafeAddress)
        returns (int256 totalValue, int256 collateral, int256 debt)
    {
        DSafeLib.DSafe storage dSafe = dSafes[dSafeAddress];
        uint16[] memory erc20Idxs = dSafe.getERC20s();
        totalValue = 0;
        collateral = 0;
        debt = 0;
        for (uint256 i = 0; i < erc20Idxs.length; i++) {
            uint16 erc20Idx = erc20Idxs[i];
            ERC20Info storage erc20Info = erc20Infos[erc20Idx];
            int256 balance = getBalance(dSafe.erc20Share[erc20Idx], erc20Info);
            (int256 value, int256 riskAdjustedValue) = erc20Info.valueOracle.calcValue(balance);
            totalValue += value;
            if (balance >= 0) {
                collateral += riskAdjustedValue;
            } else {
                debt -= riskAdjustedValue;
            }
        }
        for (uint256 i = 0; i < dSafe.nfts.length; i++) {
            DSafeLib.NFTId nftId = dSafe.nfts[i];
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
    /// @return The dSafe address that is allowed to transfer the ERC721 token
    function getApproved(
        address collection,
        uint256 tokenId
    ) public view override returns (address) {
        DSafeLib.NFTId nftId = _getNFTId(collection, tokenId);
        return tokenDataByNFTId[nftId].approvedSpender;
    }

    /// @notice Returns if the `operator` is allowed to manage all of the erc721s of `owner` on the `collection` contract
    /// @param collection The address of the collection contract
    /// @param _owner The address of the dSafe owner
    /// @param spender The address of the dSafe spender
    /// @return if the `spender` is allowed to operate the assets of `collection` of `_owner`
    function isApprovedForAll(
        address collection,
        address _owner,
        address spender
    ) public view override returns (bool) {
        return operatorApprovals[collection][_owner][spender];
    }

    /// @notice Returns the remaining amount of tokens that `spender` will be allowed to spend on
    /// behalf of `owner` through {transferFrom}
    /// @dev This value changes when {approve} or {transferFrom} are called
    /// @param erc20 The address of the ERC20 to be checked
    /// @param _owner The dSafe address whose `erc20` are allowed to be transferred by `spender`
    /// @param spender The dSafe address who is allowed to spend `erc20` of `_owner`
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
        if (poolAssets == 0)
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

    /// @dev changes the quantity of `erc20` by `amount` that are allowed to transfer from dAccount
    /// of dSafe `_owner` by dSafe `spender`
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

    /// @dev transfer ERC20 balances between dAccounts.
    /// Because all ERC20 tokens on dAccounts are owned by DOS, no tokens are getting transferred -
    /// all changes are inside DOS contract state
    /// @param erc20 The address of ERC20 token balance to transfer
    /// @param from The address of dSafe whose dAccount balance should be decreased by `amount`
    /// @param to The address of dSafe whose dAccount balance should be increased by `amount`
    /// @param amount The amount of `erc20` by witch the balance of
    /// dAccount of dSafe `from` should be decreased and
    /// dAccount of dSafe `to` should be increased.
    /// Note that amount it can be negative
    function _transferERC20(IERC20 erc20, address from, address to, int256 amount) internal {
        (, uint16 erc20Idx) = getERC20Info(erc20);
        _dAccountERC20ChangeBy(from, erc20Idx, -amount);
        _dAccountERC20ChangeBy(to, erc20Idx, amount);
        emit IDOSCore.ERC20Transfer(address(erc20), from, to, amount);
    }

    /// @dev transfer ERC721 NFT ownership between dAccounts.
    /// Because all ERC721 NFTs on dAccounts are owned by DOS, no NFT is getting transferred - all
    /// changes are inside DOS contract state
    function _transferNFT(DSafeLib.NFTId nftId, address from, address to) internal {
        dSafes[from].extractNFT(nftId, tokenDataByNFTId);
        dSafes[to].insertNFT(nftId, tokenDataByNFTId);
        emit ERC721Transferred(DSafeLib.NFTId.unwrap(nftId), from, to);
    }

    /// @dev transfer all `erc20Idx` from `from` to `to`
    function _transferAllERC20(uint16 erc20Idx, address from, address to) internal {
        int256 amount = _dAccountERC20Clear(from, erc20Idx);
        _dAccountERC20ChangeBy(to, erc20Idx, amount);
        address erc20 = erc20Infos[erc20Idx].erc20Contract;
        emit IDOSCore.ERC20Transfer(erc20, from, to, amount);
    }

    function _dAccountERC20ChangeBy(address dSafeAddress, uint16 erc20Idx, int256 amount) internal {
        _updateInterest(erc20Idx);
        DSafeLib.DSafe storage dSafe = dSafes[dSafeAddress];
        ERC20Share shares = dSafe.erc20Share[erc20Idx];
        ERC20Info storage erc20Info = erc20Infos[erc20Idx];
        int256 currentAmount = _extractPosition(shares, erc20Info);
        int256 newAmount = currentAmount + amount;
        dSafe.erc20Share[erc20Idx] = _insertPosition(newAmount, dSafe, erc20Idx);
    }

    function _dAccountERC20Clear(address dSafeAddress, uint16 erc20Idx) internal returns (int256) {
        _updateInterest(erc20Idx);
        DSafeLib.DSafe storage dSafe = dSafes[dSafeAddress];
        ERC20Share shares = dSafe.erc20Share[erc20Idx];
        int256 erc20Amount = _extractPosition(shares, erc20Infos[erc20Idx]);
        dSafe.erc20Share[erc20Idx] = ERC20Share.wrap(0);
        dSafe.removeERC20IdxFromDAccount(erc20Idx);
        return erc20Amount;
    }

    function _extractPosition(
        ERC20Share sharesWrapped,
        ERC20Info storage erc20Info
    ) internal returns (int256) {
        int256 shares = ERC20Share.unwrap(sharesWrapped);
        ERC20Pool storage pool = shares > 0 ? erc20Info.collateral : erc20Info.debt;
        return pool.extractPosition(sharesWrapped);
    }

    function _insertPosition(
        int256 amount,
        DSafeLib.DSafe storage dSafe,
        uint16 erc20Idx
    ) internal returns (ERC20Share) {
        if (amount == 0) {
            dSafe.removeERC20IdxFromDAccount(erc20Idx);
        } else {
            dSafe.accERC20IdxToDAccount(erc20Idx);
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

        _dAccountERC20ChangeBy(config.treasurySafe, erc20Idx, treasuryInterest); // add treasury interest to treasury
    }

    /// @notice Checks if the account's positions are overcollateralized
    /// @dev checks the eventual state of `executeBatch` function execution:
    /// * `dSafe` must have collateral >= debt
    /// * DOS must have sufficient balance of deposits and loans for each ERC20 token
    /// @dev when called by the end of `executeBatch`, isSolvent checks the potential target state
    /// of DOS. Calling this function separately would check current state of DOS, that is always
    /// solvable, and so the return value would always be `true`, unless the `dSafe` is liquidatable
    /// @param dSafe The address of a dSafe who performed the `executeBatch`
    /// @return Whether the position is solvent.
    function isSolvent(address dSafe) internal view returns (bool) {
        uint gasBefore = gasleft();
        int256 leverage = config.fractionalReserveLeverage;
        for (uint256 i = 0; i < erc20Infos.length; i++) {
            int256 totalDebt = erc20Infos[i].debt.tokens;
            int256 reserve = erc20Infos[i].collateral.tokens + totalDebt;
            FsUtils.Assert(
                IERC20(erc20Infos[i].erc20Contract).balanceOf(address(this)) >= uint256(reserve)
            );
            require(reserve >= -totalDebt / leverage, "Not enough reserve for debt");
        }
        (, int256 collateral, int256 debt) = getRiskAdjustedPositionValues(dSafe);
        if (gasBefore - gasleft() > config.maxSolvencyCheckGasCost)
            revert SolvencyCheckTooExpensive();
        return collateral >= debt;
    }

    function _getNFTId(address erc721, uint256 tokenId) internal view returns (DSafeLib.NFTId) {
        if (infoIdx[erc721].kind != ContractKind.ERC721) {
            revert NotNFT();
        }
        uint16 erc721Idx = infoIdx[erc721].idx;
        uint256 tokenHash = uint256(keccak256(abi.encodePacked(tokenId))) >> 32;
        return DSafeLib.NFTId.wrap(erc721Idx | (tokenHash << 16) | ((tokenId >> 240) << 240));
    }

    function _isApprovedOrOwner(
        address spender,
        address _owner,
        DSafeLib.NFTId nftId
    ) internal view returns (bool) {
        DSafeLib.DSafe storage p = dSafes[msg.sender];
        (uint16 infoIndex, uint256 tokenId) = getNFTData(nftId);
        address collection = erc721Infos[infoIndex].erc721Contract;
        uint16 idx = tokenDataByNFTId[nftId].dSafeIdx;
        bool isdepositERC721Owner = idx < p.nfts.length &&
            DSafeLib.NFTId.unwrap(p.nfts[idx]) == DSafeLib.NFTId.unwrap(nftId);
        return (isdepositERC721Owner ||
            getApproved(collection, tokenId) == spender ||
            isApprovedForAll(collection, _owner, spender));
    }

    // Config functions are handled by DOSConfig
    function _implementation() internal view override returns (address) {
        return dosConfigAddress;
    }
}

/// @title DOS Config
contract DOSConfig is DOSState, ImmutableGovernance, IDOSConfig {
    using DSafeLib for DSafeLib.DSafe;
    using DSafeLib for ERC20Pool;
    using SafeERC20 for IERC20;
    using Address for address;

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
        require(status != IVersionManager.Status.DEPRECATED, "Version is deprecated");
        require(bugLevel == IVersionManager.BugLevel.NONE, "Version has bugs");
        dSafeLogic[msg.sender] = implementation;
        emit IDOSConfig.DSafeImplementationUpgraded(msg.sender, version, implementation);
    }

    /// @notice transfers the ownership of the `dSafe` to the `newOwner`
    /// @param newOwner The new owner of the `dSafe`
    function transferDSafeOwnership(address newOwner) external override onlyDSafe whenNotPaused {
        dSafes[msg.sender].owner = newOwner;
        emit IDOSConfig.DSafeOwnershipTransferred(msg.sender, newOwner);
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
        DOSERC20 dosToken = new DOSERC20(name, symbol, decimals);
        erc20Infos.push(
            ERC20Info(
                erc20Contract,
                address(dosToken),
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
            address(dosToken),
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
        if (IERC165(erc721Contract).supportsInterface(type(IERC721).interfaceId) == false) {
            revert NotNFT(); // todo: create unit test
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
    /// @param baseRate The interest rate when utilization is 0
    /// @param slope1 The interest rate slope when utilization is less than the targetUtilization
    /// @param slope2 The interest rate slope when utilization is more than the targetUtilization
    /// @param targetUtilization The target utilization for the asset
    function setERC20Data(
        address erc20,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    ) external override onlyGovernance {
        uint16 erc20Idx = infoIdx[erc20].idx;
        if (infoIdx[erc20].kind != ContractKind.ERC20) {
            revert NotERC20();
        }
        erc20Infos[erc20Idx].baseRate = baseRate;
        erc20Infos[erc20Idx].slope1 = slope1;
        erc20Infos[erc20Idx].slope2 = slope2;
        erc20Infos[erc20Idx].targetUtilization = targetUtilization;
        emit IDOSConfig.ERC20DataSet(erc20, baseRate, slope1, slope2, targetUtilization);
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
