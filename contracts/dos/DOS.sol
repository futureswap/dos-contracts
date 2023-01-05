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
/// @notice Asset is not an ERC20
error NotERC20();
/// @notice Asset is not an NFT
error NotNFT();
/// @notice Sender is not the owner
error NotOwner();

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
type NFTId is uint256; // 16 bits (tokenId) + 224 bits (hash) + 16 bits (erc721 index)

struct NFTTokenData {
    uint240 tokenId; // 240 LSB of the tokenId of the NFT
    uint16 dSafeIdx; // index in dSafe NFT array
}

struct DSafe {
    address owner;
    mapping(uint16 => ERC20Share) erc20Share;
    NFTId[] nfts;
    // bitmask of DOS indexes of ERC20 present in a dSafe. `1` can be increased on updates
    uint256[1] dAccountErc20Idxs;
}

struct ERC20Pool {
    int256 tokens;
    int256 shares;
}

struct Approval {
    address ercContract; // ERC20/ERC721 contract
    uint256 amountOrTokenId; // amount or tokenId
}

library DSafeLib {
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
        bool userOwnsNFT = dSafe.nfts.length > 0 &&
            NFTId.unwrap(dSafe.nfts[idx]) == NFTId.unwrap(nftId);
        require(userOwnsNFT, "NFT must be in the user's dSafe");
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
    int256 collateralFactor;
    int256 borrowFactor;
    uint256 baseRate;
    uint256 slope1;
    uint256 slope2;
    uint256 targetUtilization;
    uint256 timestamp;
}

struct ERC721Info {
    address erc721Contract;
    INFTValueOracle valueOracle;
    int256 collateralFactor;
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
    IVersionManager versionManager;
    /// @notice mapping between dSafe address and DOS-specific dSafe data
    mapping(address => DSafe) dSafes;

    /// @notice mapping between dSafe address and an instance of deployed dSafeLogic contract.
    /// It means that this specific dSafeLogic version is setup to operate the dSafe.
    // @dev this could be a mapping to a version index instead of the implementation address
    mapping(address => address) dSafeLogic;

    /// @notice mapping from
    /// dSafe owner address => ERC20 address => dSafe spender address => allowed amount of ERC20.
    /// It represent the allowance of `spender` to transfer up to `amount` of `erc20` balance of
    /// owner's dAccount to some other dAccount. E.g. 123 => abc => 456 => 1000, means that
    /// dSafe 456 can transfer up to 1000 of abc tokens from dAccount of dSafe 123 to some other dAccount.
    /// Note, that no ERC20 are actually getting transferred - dAccount is a DOS concept, and
    /// corresponding tokens are owned by DOS
    mapping(address => mapping(address => mapping(address => uint256))) _allowances;

    /// @notice mapping from ERC721 contract address => tokenId => dSafe spender address.
    /// It represents the allowance of the `spender` to send `tokenId` of ERC721 contract to
    /// whatever dAccount
    mapping(address => mapping(uint256 => address)) _tokenApprovals;

    /// todo - NatSpec after clarification on what it is
    /// @dev erc721 & erc1155 operator approvals
    mapping(address => mapping(address => mapping(address => bool))) _operatorApprovals;

    mapping(NFTId => NFTTokenData) tokenDataByNFTId;

    ERC20Info[] erc20Infos;
    ERC721Info[] erc721Infos;

    /// @notice mapping of ERC20 or ERC721 address => DOS asset idx and contract kind.
    /// idx is the index of the ERC20 in `erc20Infos` or ERC721 in `erc721Infos`
    /// kind is ContractKind enum, that here can be ERC20 or ERC721
    mapping(address => ContractData) infoIdx;

    IDOSConfig.Config config;

    function getBalance(
        ERC20Share shares,
        ERC20Info storage erc20Info
    ) internal view returns (int256) {
        ERC20Pool storage pool = ERC20Share.unwrap(shares) > 0
            ? erc20Info.collateral
            : erc20Info.debt;
        return pool.computeERC20(shares);
    }

    function getNFTData(NFTId nftId) internal view returns (uint16 erc721Idx, uint256 tokenId) {
        uint256 unwrappedId = NFTId.unwrap(nftId);
        erc721Idx = uint16(unwrappedId);
        tokenId = tokenDataByNFTId[nftId].tokenId | ((unwrappedId >> 240) << 240);
    }

    function getERC20Info(IERC20 erc20) internal view returns (ERC20Info storage, uint16) {
        require(infoIdx[address(erc20)].kind == ContractKind.ERC20, "ERC20 not registered");
        uint16 idx = infoIdx[address(erc20)].idx;
        return (erc20Infos[idx], idx);
    }

    function getERC721Info(IERC721 erc721) internal view returns (ERC721Info storage, uint16) {
        require(infoIdx[address(erc721)].kind == ContractKind.ERC721, "ERC721 not registered");
        uint16 idx = infoIdx[address(erc721)].idx;
        return (erc721Infos[idx], idx);
    }
}

using DSafeLib for DSafe;
using DSafeLib for ERC20Pool;
using SafeERC20 for IERC20;
using Address for address;

/// @title DeFi OS (DOS)
contract DOS is DOSState, IDOSCore, IERC721Receiver, Proxy {
    address immutable dosConfigAddress;

    modifier onlyDSafe() {
        _requireNotPaused();
        require(dSafes[msg.sender].owner != address(0), "Only dSafe can execute");
        _;
    }

    modifier dSafeExists(address dSafe) {
        require(dSafes[dSafe].owner != address(0), "Recipient dSafe doesn't exist");
        _;
    }

    modifier onlyRegisteredNFT(address nftContract, uint256 tokenId) {
        // how can we be sure that Oracle would have a price for any possible tokenId?
        // maybe we should check first if Oracle can return a value for this specific NFT?
        require(
            infoIdx[nftContract].kind != ContractKind.Invalid,
            "Cannot add NFT of unknown NFT contract"
        );
        _;
    }

    modifier onlyNFTOwner(address nftContract, uint256 tokenId) {
        address _owner = ERC721(nftContract).ownerOf(tokenId);
        bool isOwner = _owner == msg.sender || _owner == dSafes[msg.sender].owner;
        require(isOwner, "NFT must be owned the the user or user's dSafe");
        _;
    }

    constructor(address _dosConfig, address _versionManager) {
        versionManager = IVersionManager(_versionManager);
        dosConfigAddress = _dosConfig;
    }

    /// @notice top up the dAccount owned by dSafe `to` with `amount` of `erc20`
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param to Address of the dSafe that dAccount should be top up
    /// @param amount The amount of `erc20` to be sent
    function depositERC20ForSafe(
        address erc20,
        address to,
        uint256 amount
    ) external dSafeExists(to) whenNotPaused {
        (, uint16 erc20Idx) = getERC20Info(IERC20(erc20));
        if (amount > 0) {
            IERC20(erc20).safeTransferFrom(msg.sender, address(this), uint256(amount));
            dAccountERC20ChangeBy(to, erc20Idx, FsMath.safeCastToSigned(amount));
        }
    }

    // TODO: split this function into two: deposit and withdraw - changeBalanceERC20
    /// @notice deposit or withdraw `amount` of `erc20` to/from dAccount to dSafe
    /// Positive amount to deposit.
    /// Negative amount to withdraw.
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param amount The amount of `erc20` to be transferred
    function depositERC20(IERC20 erc20, int256 amount) external override onlyDSafe {
        (, uint16 erc20Idx) = getERC20Info(erc20);
        if (amount > 0) {
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            dAccountERC20ChangeBy(msg.sender, erc20Idx, amount);
        } else {
            erc20.safeTransfer(msg.sender, uint256(-amount));
            dAccountERC20ChangeBy(msg.sender, erc20Idx, amount);
        }
    }

    /// @notice deposit all `erc20s` from dSafe to dAccount
    /// @param erc20s Array of addresses of ERC20 to be transferred
    function depositFull(IERC20[] calldata erc20s) external override onlyDSafe {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            uint256 amount = erc20.balanceOf(msg.sender);
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            dAccountERC20ChangeBy(msg.sender, erc20Idx, FsMath.safeCastToSigned(amount));
        }
    }

    /// @notice withdraw all `erc20s` from dAccount to dSafe
    /// @param erc20s Array of addresses of ERC20 to be transferred
    function withdrawFull(IERC20[] calldata erc20s) external onlyDSafe {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            int256 amount = dAccountERC20Clear(msg.sender, erc20Idx);
            require(amount >= 0, "Can't withdraw debt");
            erc20.safeTransfer(msg.sender, uint256(amount));
        }
    }

    // TODO: rename to depositERC721
    /// @notice deposit ERC721 `nftContract` token `tokenId` from dSafe to dAccount
    /// @dev the part when we track the ownership of deposit NFT to a specific dAccount is in
    /// `onERC721Received` function of this contract
    /// @param nftContract The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    function depositNFT(
        address nftContract,
        uint256 tokenId
    )
        external
        onlyDSafe
        onlyRegisteredNFT(nftContract, tokenId)
        onlyNFTOwner(nftContract, tokenId)
    {
        address _owner = ERC721(nftContract).ownerOf(tokenId);
        ERC721(nftContract).safeTransferFrom(
            _owner,
            address(this),
            tokenId,
            abi.encode(msg.sender)
        );
    }

    /*function depositDosERC20(uint16 erc20Idx, int256 amount) external onlyDSafe {
        ERC20Info storage erc20Info = getERC20Info(erc20Idx);
        IDOSERC20 erc20 = IDOSERC20(erc20Info.dosContract);
        if (amount > 0) {
            erc20.burn(msg.sender, uint256(amount));
            dAccountERC20ChangeBy(msg.sender, erc20Idx, amount);
        } else {
            erc20.mint(msg.sender, uint256(-amount));
            dAccountERC20ChangeBy(msg.sender, erc20Idx, amount);
        }
    }

    function claim(uint16 erc20Idx, uint256 amount) external onlyDSafe {
        ERC20Info storage erc20Info = getERC20Info(erc20Idx);
        IDOSERC20(erc20Info.dosContract).burn(msg.sender, amount);
        IERC20(erc20Info.erc20Contract).safeTransfer(msg.sender, amount);
        // TODO: require appropriate reserve
    }*/

    // TODO: rename to withdrawERC721
    /// @notice withdraw ERC721 `nftContract` token `tokenId` from dAccount to dSafe
    /// @param erc721 The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    function claimNFT(address erc721, uint256 tokenId) external onlyDSafe {
        NFTId nftId = getNFTId(erc721, tokenId);

        ERC721(erc721).safeTransferFrom(address(this), msg.sender, tokenId);

        dSafes[msg.sender].extractNFT(nftId, tokenDataByNFTId);
        delete tokenDataByNFTId[nftId];
    }

    // TODO: rename to transferERC20
    /// @notice transfer `amount` of `erc20` from dAccount of caller dSafe to dAccount of `to` dSafe
    /// @param erc20 Address of the ERC20 token to be transferred
    /// @param to dSafe address, whose dAccount is the transfer target
    /// @param amount The amount of `erc20` to be transferred
    function transfer(IERC20 erc20, address to, uint256 amount) external onlyDSafe dSafeExists(to) {
        if (amount == 0) return;
        transferERC20(erc20, msg.sender, to, FsMath.safeCastToSigned(amount));
    }

    // TODO: transferERC721
    /// @notice transfer NFT `erc721` token `tokenId` from dAccount of caller dSafe to dAccount of
    /// `to` dSafe
    /// @param erc721 The address of the ERC721 contract that the token belongs to
    /// @param tokenId The id of the token to be transferred
    /// @param to dSafe address, whose dAccount is the transfer target
    function sendNFT(
        address erc721,
        uint256 tokenId,
        address to
    ) external onlyDSafe dSafeExists(to) {
        NFTId nftId = getNFTId(erc721, tokenId);
        transferNFT(nftId, msg.sender, to);
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
    ) external onlyDSafe dSafeExists(from) dSafeExists(to) whenNotPaused returns (bool) {
        address spender = msg.sender;
        _spendAllowance(erc20, from, spender, amount);
        transferERC20(IERC20(erc20), from, to, FsMath.safeCastToSigned(amount));
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
    ) external onlyDSafe dSafeExists(to) {
        NFTId nftId = getNFTId(collection, tokenId);
        if (!_isApprovedOrOwner(msg.sender, nftId)) {
            revert NotApprovedOrOwner();
        }
        _tokenApprovals[collection][tokenId] = address(0);
        transferNFT(nftId, from, to);
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
    function liquidate(address dSafe) external override onlyDSafe dSafeExists(dSafe) {
        (int256 totalValue, int256 collateral, int256 debt) = computePosition(dSafe);
        require(collateral < debt, "DSafe is not liquidatable");
        uint16[] memory dSafeERC20s = dSafes[dSafe].getERC20s();
        for (uint256 i = 0; i < dSafeERC20s.length; i++) {
            uint16 erc20Idx = dSafeERC20s[i];
            transferAllERC20(erc20Idx, dSafe, msg.sender);
        }
        while (dSafes[dSafe].nfts.length > 0) {
            transferNFT(dSafes[dSafe].nfts[dSafes[dSafe].nfts.length - 1], dSafe, msg.sender);
        }
        // TODO(gerben) make formula dependent on risk
        if (totalValue > 0) {
            // totalValue of the liquidated dSafe is split between liquidatable and liquidator:
            // totalValue * (1 - liqFraction) - reward of the liquidator, and
            // totalValue * liqFraction - change, liquidator is sending back to liquidatable
            int256 leftover = (totalValue * config.liqFraction) / 1 ether;
            transferERC20(
                IERC20(erc20Infos[K_NUMERAIRE_IDX].erc20Contract),
                msg.sender,
                dSafe,
                leftover
            );
        }
    }

    /// @notice Execute a batch of calls
    /// @dev execute a batch of commands on DOS from the name of dSafe owner. Eventual state of
    /// dAccount and DOS must be solvent, i.e. debt on dAccount cannot exceed collateral
    /// and DOS reserve/debt must be sufficient
    /// @param calls An array of transaction calls
    function executeBatch(Call[] memory calls) external override onlyDSafe {
        DSafeProxy(payable(msg.sender)).executeBatch(calls);
        // TODO: convert to custom error
        require(isSolvent(msg.sender), "Result of operation is not sufficiently liquid");
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
        NFTId nftId = getNFTId(msg.sender, tokenId);
        if (data.length != 0) {
            from = abi.decode(data, (address));
        }
        require(dSafes[from].owner != address(0), "DSafe does not exist");
        tokenDataByNFTId[nftId].tokenId = uint240(tokenId);
        dSafes[from].insertNFT(nftId, tokenDataByNFTId);
        // TODO(call dSafe?)
        return this.onERC721Received.selector;
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

    /// @notice Approve an array of tokens and then call `onApprovalReceived` on spender
    /// @param approvals An array of ERC20 tokens with amounts, or ERC721 contracts with tokenIds
    /// @param spender The address of the spender dSafe
    /// @param data Additional data with no specified format, sent in call to `spender`
    function approveAndCall(
        Approval[] calldata approvals,
        address spender,
        bytes calldata data
    ) public onlyDSafe dSafeExists(spender) {
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

    // TODO: rename to getRiskAdjustedPositionValues
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
    function computePosition(
        address dSafeAddress
    )
        public
        view
        dSafeExists(dSafeAddress)
        returns (int256 totalValue, int256 collateral, int256 debt)
    {
        DSafe storage dSafe = dSafes[dSafeAddress];
        uint16[] memory erc20Idxs = dSafe.getERC20s();
        totalValue = 0;
        collateral = 0;
        debt = 0;
        for (uint256 i = 0; i < erc20Idxs.length; i++) {
            uint16 erc20Idx = erc20Idxs[i];
            ERC20Info storage erc20Info = erc20Infos[erc20Idx];
            int256 balance = getBalance(dSafe.erc20Share[erc20Idx], erc20Info);
            int256 value = erc20Info.valueOracle.calcValue(balance);
            totalValue += value;
            if (balance >= 0) {
                collateral += (value * erc20Info.collateralFactor) / 1 ether;
            } else {
                debt += (-value * 1 ether) / erc20Info.borrowFactor;
            }
        }
        for (uint256 i = 0; i < dSafe.nfts.length; i++) {
            NFTId nftId = dSafe.nfts[i];
            (uint16 erc721Idx, uint256 tokenId) = getNFTData(nftId);
            ERC721Info storage nftInfo = erc721Infos[erc721Idx];
            int256 nftValue = int256(nftInfo.valueOracle.calcValue(tokenId));
            totalValue += nftValue;
            collateral += (nftValue * nftInfo.collateralFactor) / 1 ether;
        }
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
    function isSolvent(address dSafe) public view returns (bool) {
        // todo track each erc20 on-change instead of iterating over all DOS stuff
        int256 leverage = config.fractionalReserveLeverage;
        for (uint256 i = 0; i < erc20Infos.length; i++) {
            int256 totalDebt = erc20Infos[i].debt.tokens;
            int256 reserve = erc20Infos[i].collateral.tokens + totalDebt;
            FsUtils.Assert(
                IERC20(erc20Infos[i].erc20Contract).balanceOf(address(this)) >= uint256(reserve)
            );
            require(reserve >= -totalDebt / leverage, "Not enough reserve for debt");
        }
        (, int256 collateral, int256 debt) = computePosition(dSafe);
        return collateral >= debt;
    }

    /// @notice Returns the approved address for a token, or zero if no address set
    /// @param collection The address of the ERC721 token
    /// @param tokenId The id of the token to query
    /// @return The dSafe address that is allowed to transfer the ERC721 token
    function getApproved(address collection, uint256 tokenId) public view returns (address) {
        return _tokenApprovals[collection][tokenId];
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
    ) public view returns (bool) {
        return _operatorApprovals[collection][_owner][spender];
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
        return _allowances[_owner][erc20][spender];
    }

    /// @notice Compute the interest rate of `underlying`
    /// @param erc20Idx The underlying asset
    /// @return The interest rate of `erc20Idx`
    function computeInterestRate(uint16 erc20Idx) public view returns (int96) {
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
            _allowances[_owner][ercContract][spender] = amountOrTokenId;
        } else if (data.kind == ContractKind.ERC721) {
            prev = amountOrTokenId;
            _tokenApprovals[ercContract][amountOrTokenId] = erc721Spender;
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
                _allowances[_owner][erc20][spender] = currentAllowance - amount;
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
                /// @solidity memory-safe-assembly
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            }
        }
    }

    // TODO: rename to _transferERC20
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
    function transferERC20(IERC20 erc20, address from, address to, int256 amount) internal {
        (, uint16 erc20Idx) = getERC20Info(erc20);
        dAccountERC20ChangeBy(from, erc20Idx, -amount);
        dAccountERC20ChangeBy(to, erc20Idx, amount);
    }

    /// @dev transfer ERC721 NFT ownership between dAccounts.
    /// Because all ERC721 NFTs on dAccounts are owned by DOS, no NFT is getting transferred - all
    /// changes are inside DOS contract state
    function transferNFT(NFTId nftId, address from, address to) internal {
        dSafes[from].extractNFT(nftId, tokenDataByNFTId);
        dSafes[to].insertNFT(nftId, tokenDataByNFTId);
    }

    function transferAllERC20(uint16 erc20Idx, address from, address to) internal {
        int256 amount = dAccountERC20Clear(from, erc20Idx);
        dAccountERC20ChangeBy(to, erc20Idx, amount);
    }

    function dAccountERC20ChangeBy(address dSafeAddress, uint16 erc20Idx, int256 amount) internal {
        updateInterest(erc20Idx);
        DSafe storage dSafe = dSafes[dSafeAddress];
        ERC20Share shares = dSafe.erc20Share[erc20Idx];
        ERC20Info storage erc20Info = erc20Infos[erc20Idx];
        int256 currentAmount = extractPosition(shares, erc20Info);
        int256 newAmount = currentAmount + amount;
        dSafe.erc20Share[erc20Idx] = insertPosition(newAmount, dSafe, erc20Idx);
    }

    function dAccountERC20Clear(address dSafeAddress, uint16 erc20Idx) internal returns (int256) {
        updateInterest(erc20Idx);
        DSafe storage dSafe = dSafes[dSafeAddress];
        ERC20Share shares = dSafe.erc20Share[erc20Idx];
        int256 erc20Amount = extractPosition(shares, erc20Infos[erc20Idx]);
        dSafe.erc20Share[erc20Idx] = ERC20Share.wrap(0);
        dSafe.removeERC20IdxFromDAccount(erc20Idx);
        return erc20Amount;
    }

    function extractPosition(
        ERC20Share sharesWrapped,
        ERC20Info storage erc20Info
    ) internal returns (int256) {
        int256 shares = ERC20Share.unwrap(sharesWrapped);
        ERC20Pool storage pool = shares > 0 ? erc20Info.collateral : erc20Info.debt;
        return pool.extractPosition(sharesWrapped);
    }

    function insertPosition(
        int256 amount,
        DSafe storage dSafe,
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

    function updateInterest(uint16 erc20Idx) internal {
        ERC20Info storage erc20Info = erc20Infos[erc20Idx]; // retrieve ERC20Info and store in memory
        if (erc20Info.timestamp == block.timestamp) return; // already updated this block
        int256 delta = FsMath.safeCastToSigned(block.timestamp - erc20Info.timestamp); // time passed since last update
        erc20Info.timestamp = block.timestamp; // update timestamp to current timestamp
        int256 debt = -erc20Info.debt.tokens; // get the debt
        int256 interestRate = computeInterestRate(erc20Idx);
        int256 interest = (debt * (FsMath.exp(interestRate * delta) - FsMath.FIXED_POINT_SCALE)) /
            FsMath.FIXED_POINT_SCALE; // Get the interest
        erc20Info.debt.tokens -= interest; // subtract interest from debt (increase)
        erc20Info.collateral.tokens += interest; // add interest to collateral (increase)
        // TODO(gerben) add to treasury
    }

    function getNFTId(address erc721, uint256 tokenId) internal view returns (NFTId) {
        if (infoIdx[erc721].kind != ContractKind.ERC721) {
            revert NotNFT();
        }
        uint16 erc721Idx = infoIdx[erc721].idx;
        uint256 tokenHash = uint256(keccak256(abi.encodePacked(tokenId))) >> 32;
        return NFTId.wrap(erc721Idx | (tokenHash << 16) | ((tokenId >> 240) << 240));
    }

    function _isApprovedOrOwner(address spender, NFTId nftId) internal view returns (bool) {
        DSafe storage p = dSafes[msg.sender];
        (uint16 infoIndex, uint256 tokenId) = getNFTData(nftId);
        address collection = erc721Infos[infoIndex].erc721Contract;
        uint16 idx = tokenDataByNFTId[nftId].dSafeIdx;
        bool isDepositNFTOwner = idx < p.nfts.length &&
            NFTId.unwrap(p.nfts[idx]) == NFTId.unwrap(nftId);
        return (isDepositNFTOwner ||
            getApproved(collection, tokenId) == spender ||
            isApprovedForAll(collection, address(0), spender)); // BUG
    }

    // Config functions are handled by DOSConfig
    function _implementation() internal view override returns (address) {
        return dosConfigAddress;
    }
}

/// @title DOS Config
contract DOSConfig is DOSState, ImmutableGovernance, IDOSConfig {
    constructor(address _owner) ImmutableGovernance(_owner) {}

    /// @notice upgrades the version of dSafeLogic contract for the `dSafe`
    /// @param dSafe The address of the dSafe to be upgraded
    /// @param version The new target version of dSafeLogic contract
    // todo - disallow downgrade
    function upgradeDSafeImplementation(address dSafe, uint256 version) external {
        address dSafeOwner = dSafes[dSafe].owner;
        if (msg.sender != dSafeOwner) {
            revert NotOwner();
        }
        dSafeLogic[dSafe] = versionManager.getVersionAddress(version);
    }

    /// @notice Pause the contract
    function pause() external onlyGovernance {
        _pause();
    }

    /// @notice Unpause the contract
    function unpause() external onlyGovernance {
        _unpause();
    }

    /// @notice add a new ERC20 to be used inside DOS
    /// @dev For governance only.
    /// @param erc20Contract The address of ERC20 to add
    /// @param name The name of the ERC20. E.g. "Wrapped ETH"
    /// @param symbol The symbol of the ERC20. E.g. "WETH"
    /// @param decimals Decimals of the ERC20. E.g. 18 for WETH and 6 for USDC
    /// @param valueOracle The address of the Value Oracle. Probably Uniswap one
    /// @param colFactor A number from 0 to 1 eth. collateral = value * colFactor / 1 eth. E.g.
    /// if colFactor for WETH is 0.8 eth it means that deposit of 1 WETH to dAccount would
    /// increase collateral of the position by equivalent of 0.8 WETH
    /// @param borrowFactor A number from 0 to 1 eth. debt = -value / borrowFactor * 1 eth. E.g.
    /// if borrowFactor if 0.8 eth it means that borrow of 1 WETH from dAccount would
    /// increase debt of the position by equivalent of 1.25 WETH (1 / 0.8 is 1.25)
    /// @param interest Controls the interest rate i.e. how fast the deposit generates income and
    /// borrowing generates new debt.
    /// 0 means deposit generates no income and borrowing is free. Todo - an example of non-zero value
    /// @return the index of the added ERC20 in the erc20Infos array
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
    ) external onlyGovernance returns (uint16) {
        uint16 erc20Idx = uint16(erc20Infos.length);
        DOSERC20 dosToken = new DOSERC20(name, symbol, decimals);
        erc20Infos.push(
            ERC20Info(
                erc20Contract,
                address(dosToken),
                IERC20ValueOracle(valueOracle),
                ERC20Pool(0, 0),
                ERC20Pool(0, 0),
                colFactor,
                borrowFactor,
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
            colFactor,
            borrowFactor,
            baseRate,
            slope1,
            slope2,
            targetUtilization
        );
        return erc20Idx;
    }

    // TODO: rename to addERC721Info
    /// @notice Add a new ERC721 to be used inside DOS.
    /// @dev For governance only.
    /// @param erc721Contract The address of the ERC721 to be added
    /// @param valueOracleAddress The address of the Uniswap Oracle to get the price of a token
    /// @param collateralFactor A number from 0 to 1 eth. collateral = value * colFactor / 1 eth. E.g.
    /// if collateralFactor is 0.8 then if valueOracle estimates the NFT on dAccount for 1 ETH it
    /// means that it increases the collateral of the position by an equivalent of 0.8 ETH
    function addNFTInfo(
        address erc721Contract,
        address valueOracleAddress,
        int256 collateralFactor
    ) external onlyGovernance {
        INFTValueOracle valueOracle = INFTValueOracle(valueOracleAddress);
        uint256 erc721Idx = erc721Infos.length;
        erc721Infos.push(ERC721Info(erc721Contract, valueOracle, collateralFactor));
        infoIdx[erc721Contract] = ContractData(uint16(erc721Idx), ContractKind.ERC721);
    }

    /// @notice Updates the config of DOS
    /// @dev for governance only.
    /// @param _config the Config of IDOSConfig. A struct with DOS parameters
    function setConfig(Config calldata _config) external onlyGovernance {
        config = _config;
        // TODO: emit an event
    }

    /// @notice Set the address of Version Manager contract
    /// @dev for governance only.
    /// @param _versionManager The address of the Version Manager contract to be set
    function setVersionManager(address _versionManager) external onlyGovernance {
        versionManager = IVersionManager(_versionManager);
        // TODO: emit an event
    }

    /// @notice Updates some of ERC20 config parameters
    /// @dev for governance only.
    /// @param erc20 The address of ERC20 contract for which DOS config parameters should be updated
    /// @param interestRate See `interest` parameter description of `addERC20Info` function
    /// @param borrowFactor See `borrowFactor` parameter description of `addERC20Info` function
    /// @param collateralFactor See `colFactor` parameter description of `addERC20Info` function
    function setERC20Data(
        address erc20,
        int256 borrowFactor,
        int256 collateralFactor,
        uint256 baseRate,
        uint256 slope1,
        uint256 slope2,
        uint256 targetUtilization
    ) external override onlyGovernance {
        uint16 erc20Idx = infoIdx[erc20].idx;
        if (infoIdx[erc20].kind != ContractKind.ERC20) {
            revert NotERC20();
        }
        erc20Infos[erc20Idx].borrowFactor = borrowFactor;
        erc20Infos[erc20Idx].collateralFactor = collateralFactor;
        erc20Infos[erc20Idx].baseRate = baseRate;
        erc20Infos[erc20Idx].slope1 = slope1;
        erc20Infos[erc20Idx].slope2 = slope2;
        erc20Infos[erc20Idx].targetUtilization = targetUtilization;
    }

    /// @notice creates a new dSafe with sender as the owner and returns the dSafe address
    /// @return dSafe The address of the created dSafe
    function createDSafe() external returns (address dSafe) {
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
    function getDAccountERC20(address dSafeAddr, IERC20 erc20) external view returns (int256) {
        // TODO(gerben) interest computation
        DSafe storage dSafe = dSafes[dSafeAddr];
        (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20);
        ERC20Share erc20Share = dSafe.erc20Share[erc20Idx];
        return getBalance(erc20Share, erc20Info);
    }

    // TODO: rename to getDAccountERC721
    /// @notice returns the NFTs on dAccount of `dSafe`
    /// @param dSafe The address of dSafe which dAccount NFTs should be returned
    /// @return The array of NFT deposited on the dAccount of `dSafe`
    function viewNFTs(address dSafe) external view returns (NFTData[] memory) {
        NFTData[] memory nftData = new NFTData[](dSafes[dSafe].nfts.length);
        for (uint i = 0; i < nftData.length; i++) {
            (uint16 erc721Idx, uint256 tokenId) = getNFTData(dSafes[dSafe].nfts[i]);
            nftData[i] = NFTData(erc721Infos[erc721Idx].erc721Contract, tokenId);
        }
        return nftData;
    }

    // TODO(gerben) remove this function (its for tests)
    function getMaximumWithdrawableOfERC20(IERC20 erc20) public view returns (int256) {
        (ERC20Info storage erc20Info, ) = getERC20Info(erc20);
        int256 leverage = config.fractionalReserveLeverage;
        // console.log("leverage:");
        // console.logInt(leverage);
        int256 tokens = erc20Info.collateral.tokens;

        int256 minReserveAmount = tokens / (leverage + 1);
        // console.log("minReserveAmount:");
        // console.logInt(minReserveAmount);
        int256 totalDebt = erc20Info.debt.tokens;
        int256 borrowable = erc20Info.collateral.tokens - minReserveAmount;

        int256 remainingERC20ToBorrow = borrowable + totalDebt;

        return remainingERC20ToBorrow;
    }
}
