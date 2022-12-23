// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/Address.sol";
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
error ReceiverNotContract();
error ReceiverNoImplementation();
error WrongDataReturned();

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
    int256 interest;
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

library DOSLib {
    struct DOSState {
        IVersionManager versionManager;
        mapping(address => DSafe) dSafes;
        // Note: This could be a mapping to a version index instead of the implementation address
        mapping(address => address) dSafeLogic;
        /// @dev erc20 allowances
        mapping(address => mapping(address => mapping(address => uint256))) _allowances;
        /// @dev erc721 approvals
        mapping(address => mapping(uint256 => address)) _tokenApprovals;
        /// @dev erc721 & erc1155 operator approvals
        mapping(address => mapping(address => mapping(address => bool))) _operatorApprovals;
        mapping(NFTId => NFTTokenData) tokenDataByNFTId;
        ERC20Info[] erc20Infos;
        ERC721Info[] erc721Infos;
        mapping(address => ContractData) infoIdx;
        IDOSConfig.Config config;
    }

    function getBalance(ERC20Share shares, ERC20Info storage p) internal view returns (int256) {
        ERC20Pool storage s = ERC20Share.unwrap(shares) > 0 ? p.collateral : p.debt;
        return s.computeERC20(shares);
    }

    function getNFTData(NFTId nftId) internal view returns (uint16 erc721Idx, uint256 tokenId) {
        uint256 unwrappedId = NFTId.unwrap(nftId);
        erc721Idx = uint16(unwrappedId);
        tokenId = state().tokenDataByNFTId[nftId].tokenId | ((unwrappedId >> 240) << 240);
    }

    function getERC20Info(IERC20 erc20) internal view returns (ERC20Info storage, uint16) {
        require(state().infoIdx[address(erc20)].kind == ContractKind.ERC20, "ERC20 not registered");
        uint16 idx = state().infoIdx[address(erc20)].idx;
        return (state().erc20Infos[idx], idx);
    }

    function getERC721Info(IERC721 erc721) internal view returns (ERC721Info storage, uint16) {
        require(
            state().infoIdx[address(erc721)].kind == ContractKind.ERC721,
            "ERC721 not registered"
        );
        uint16 idx = state().infoIdx[address(erc721)].idx;
        return (state().erc721Infos[idx], idx);
    }

    function state() private pure returns (DOSState storage s) {
        assembly {
            s.slot := 0
        }
    }
}

using DSafeLib for DSafe;
using DSafeLib for ERC20Pool;
using SafeERC20 for IERC20;
using Address for address;

contract DOS is IDOSCore, IERC721Receiver, Proxy {
    DOSLib.DOSState public state;
    address immutable dosConfig;

    modifier onlyDSafe() {
        require(state.dSafes[msg.sender].owner != address(0), "Only dSafe can execute");
        _;
    }

    modifier dSafeExists(address dSafe) {
        require(state.dSafes[dSafe].owner != address(0), "Recipient dSafe doesn't exist");
        _;
    }

    modifier onlyRegisteredNFT(address nftContract, uint256 tokenId) {
        // how can we be sure that Oracle would have a price for any possible tokenId?
        // maybe we should check first if Oracle can return a value for this specific NFT?
        require(
            state.infoIdx[nftContract].kind != ContractKind.Invalid,
            "Cannot add NFT of unknown NFT contract"
        );
        _;
    }

    modifier onlyNFTOwner(address nftContract, uint256 tokenId) {
        address _owner = ERC721(nftContract).ownerOf(tokenId);
        bool isOwner = _owner == msg.sender || _owner == state.dSafes[msg.sender].owner;
        require(isOwner, "NFT must be owned the the user or user's dSafe");
        _;
    }

    constructor(address _dosConfig, address _versionManager) {
        state.versionManager = IVersionManager(_versionManager);
        dosConfig = _dosConfig;
    }

    function depositERC20ForSafe(
        address erc20,
        address to,
        uint256 amount
    ) external dSafeExists(to) {
        (, uint16 erc20Idx) = DOSLib.getERC20Info(IERC20(erc20));
        if (amount > 0) {
            IERC20(erc20).safeTransferFrom(msg.sender, address(this), uint256(amount));
            dAccountERC20ChangeBy(to, erc20Idx, FsMath.safeCastToSigned(amount));
        }
    }

    function depositERC20(IERC20 erc20, int256 amount) external override onlyDSafe {
        (, uint16 erc20Idx) = DOSLib.getERC20Info(erc20);
        if (amount > 0) {
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            dAccountERC20ChangeBy(msg.sender, erc20Idx, amount);
        } else {
            erc20.safeTransfer(msg.sender, uint256(-amount));
            dAccountERC20ChangeBy(msg.sender, erc20Idx, amount);
        }
    }

    function depositFull(IERC20[] calldata erc20s) external override onlyDSafe {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = DOSLib.getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            uint256 amount = erc20.balanceOf(msg.sender);
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            dAccountERC20ChangeBy(msg.sender, erc20Idx, FsMath.safeCastToSigned(amount));
        }
    }

    function withdrawFull(IERC20[] calldata erc20s) external onlyDSafe {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = DOSLib.getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            int256 amount = dAccountERC20Clear(msg.sender, erc20Idx);
            require(amount >= 0, "Can't withdraw debt");
            erc20.safeTransfer(msg.sender, uint256(amount));
        }
    }

    function depositNFT(
        address nftContract,
        uint256 tokenId
    )
        external
        onlyDSafe
        onlyRegisteredNFT(nftContract, tokenId)
        onlyNFTOwner(nftContract, tokenId)
    {
        // NOTE: owner conflicts with the state variable. Should rename to nftOwner, owner_, or similar.
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

    function claimNFT(address erc721, uint256 tokenId) external onlyDSafe {
        NFTId nftId = getNFTId(erc721, tokenId);

        ERC721(erc721).safeTransferFrom(address(this), msg.sender, tokenId);

        state.dSafes[msg.sender].extractNFT(nftId, state.tokenDataByNFTId);
        delete state.tokenDataByNFTId[nftId];
    }

    function transfer(IERC20 erc20, address to, uint256 amount) external onlyDSafe dSafeExists(to) {
        if (amount == 0) return;
        transferERC20(erc20, msg.sender, to, FsMath.safeCastToSigned(amount));
    }

    function sendNFT(
        address erc721,
        uint256 tokenId,
        address to
    ) external onlyDSafe dSafeExists(to) {
        NFTId nftId = getNFTId(erc721, tokenId);
        transferNFT(nftId, msg.sender, to);
    }

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
    ) external dSafeExists(from) dSafeExists(to) returns (bool) {
        address spender = msg.sender;
        _spendAllowance(erc20, from, spender, amount);
        transferERC20(IERC20(erc20), from, to, FsMath.safeCastToSigned(amount));
        return true;
    }

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
    ) external onlyDSafe dSafeExists(to) {
        NFTId nftId = getNFTId(collection, tokenId);
        if (!_isApprovedOrOwner(msg.sender, nftId)) {
            revert NotApprovedOrOwner();
        }
        state._tokenApprovals[collection][tokenId] = address(0);
        transferNFT(nftId, from, to);
    }

    function liquidate(address dSafe) external override onlyDSafe dSafeExists(dSafe) {
        (int256 totalValue, int256 collateral, int256 debt) = computePosition(dSafe);
        require(collateral < debt, "DSafe is not liquidatable");
        uint16[] memory dSafeERC20s = state.dSafes[dSafe].getERC20s();
        for (uint256 i = 0; i < dSafeERC20s.length; i++) {
            uint16 erc20Idx = dSafeERC20s[i];
            transferAllERC20(erc20Idx, dSafe, msg.sender);
        }
        while (state.dSafes[dSafe].nfts.length > 0) {
            transferNFT(
                state.dSafes[dSafe].nfts[state.dSafes[dSafe].nfts.length - 1],
                dSafe,
                msg.sender
            );
        }
        // TODO(gerben) make formula dependent on risk
        if (totalValue > 0) {
            // totalValue of the liquidated dSafe is split between liquidatable and liquidator:
            // totalValue * (1 - liqFraction) - reward of the liquidator, and
            // totalValue * liqFraction - change, liquidator is sending back to liquidatable
            int256 leftover = (totalValue * state.config.liqFraction) / 1 ether;
            transferERC20(
                IERC20(state.erc20Infos[K_NUMERAIRE_IDX].erc20Contract),
                msg.sender,
                dSafe,
                leftover
            );
        }
    }

    function executeBatch(Call[] memory calls) external override onlyDSafe {
        DSafeProxy(payable(msg.sender)).executeBatch(calls);
        require(isSolvent(msg.sender), "Result of operation is not sufficient liquid");
    }

    function onERC721Received(
        address /* operator */,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        NFTId nftId = getNFTId(msg.sender, tokenId);
        if (data.length != 0) {
            from = abi.decode(data, (address));
        }
        require(state.dSafes[from].owner != address(0), "DSafe does not exist");
        state.tokenDataByNFTId[nftId].tokenId = uint240(tokenId);
        state.dSafes[from].insertNFT(nftId, state.tokenDataByNFTId);
        // TODO(call dSafe?)
        return this.onERC721Received.selector;
    }

    function getImplementation(address dSafe) external view override returns (address) {
        // not using msg.sender since this is an external view function
        return state.dSafeLogic[dSafe];
    }

    function getDSafeOwner(address dSafe) external view override returns (address) {
        return state.dSafes[dSafe].owner;
    }

    /// @notice Approve an array of tokens and then call `onApprovalReceived` on spender.
    /// @param approvals An array of erc20 tokens
    /// @param spender The address of the spender
    /// @param data Additional data with no specified format, sent in call to `spender`
    function approveAndCall(
        Approval[] calldata approvals,
        address spender,
        bytes calldata data
    ) public onlyDSafe {
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

    function computePosition(
        address dSafeAddress
    )
        public
        view
        dSafeExists(dSafeAddress)
        returns (int256 totalValue, int256 collateral, int256 debt)
    {
        DSafe storage dSafe = state.dSafes[dSafeAddress];
        uint16[] memory erc20Idxs = dSafe.getERC20s();
        totalValue = 0;
        collateral = 0;
        debt = 0;
        for (uint256 i = 0; i < erc20Idxs.length; i++) {
            uint16 erc20Idx = erc20Idxs[i];
            ERC20Info storage erc20Info = state.erc20Infos[erc20Idx];
            int256 balance = DOSLib.getBalance(dSafe.erc20Share[erc20Idx], erc20Info);
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
            (uint16 erc721Idx, uint256 tokenId) = DOSLib.getNFTData(nftId);
            ERC721Info storage nftInfo = state.erc721Infos[erc721Idx];
            int256 nftValue = int256(nftInfo.valueOracle.calcValue(tokenId));
            totalValue += nftValue;
            collateral += (nftValue * nftInfo.collateralFactor) / 1 ether;
        }
    }

    function isSolvent(address dSafe) public view returns (bool) {
        // todo track each erc20 on-change instead of iterating over all DOS stuff
        int256 leverage = state.config.fractionalReserveLeverage;
        for (uint256 i = 0; i < state.erc20Infos.length; i++) {
            int256 totalDebt = state.erc20Infos[i].debt.tokens;
            int256 reserve = state.erc20Infos[i].collateral.tokens + totalDebt;
            FsUtils.Assert(
                IERC20(state.erc20Infos[i].erc20Contract).balanceOf(address(this)) >=
                    uint256(reserve)
            );
            require(reserve >= -totalDebt / leverage, "Not enough reserve for debt");
        }
        (, int256 collateral, int256 debt) = computePosition(dSafe);
        return collateral >= debt;
    }

    /// @notice Returns the approved address for a token, or zero if no address set
    /// @param collection The address of the ERC721 token
    /// @param tokenId The id of the token to query
    function getApproved(address collection, uint256 tokenId) public view returns (address) {
        return state._tokenApprovals[collection][tokenId];
    }

    /// @notice Returns if the `operator` is allowed to manage all of the erc20s of `owner` on the `collection` contract
    /// @param collection The address of the collection contract
    /// @param _owner The address of the owner
    /// @param spender The address of the spender
    function isApprovedForAll(
        address collection,
        address _owner,
        address spender
    ) public view returns (bool) {
        return state._operatorApprovals[collection][_owner][spender];
    }

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
    ) public view override returns (uint256) {
        if (_owner == spender) return type(uint256).max;
        return state._allowances[_owner][erc20][spender];
    }

    function _approve(
        address _owner,
        address spender,
        address ercContract,
        uint256 amountOrTokenId,
        address erc721Spender
    ) internal returns (uint256 prev) {
        FsUtils.Assert(spender != address(0));
        ContractData memory data = state.infoIdx[ercContract];
        if (data.kind == ContractKind.ERC20) {
            prev = allowance(ercContract, _owner, spender);
            state._allowances[_owner][ercContract][spender] = amountOrTokenId;
        } else if (data.kind == ContractKind.ERC721) {
            prev = amountOrTokenId;
            state._tokenApprovals[ercContract][amountOrTokenId] = erc721Spender;
        } else {
            FsUtils.Assert(false);
        }
    }

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
                state._allowances[_owner][erc20][spender] = currentAllowance - amount;
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
    ) internal virtual returns (bool) {
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

    function transferERC20(IERC20 erc20, address from, address to, int256 amount) internal {
        (, uint16 erc20Idx) = DOSLib.getERC20Info(erc20);
        dAccountERC20ChangeBy(from, erc20Idx, -amount);
        dAccountERC20ChangeBy(to, erc20Idx, amount);
    }

    function transferNFT(NFTId nftId, address from, address to) internal {
        state.dSafes[from].extractNFT(nftId, state.tokenDataByNFTId);
        state.dSafes[to].insertNFT(nftId, state.tokenDataByNFTId);
    }

    // TODO @derek - add method for withdraw

    function transferAllERC20(uint16 erc20Idx, address from, address to) internal {
        int256 amount = dAccountERC20Clear(from, erc20Idx);
        dAccountERC20ChangeBy(to, erc20Idx, amount);
    }

    function dAccountERC20ChangeBy(address dSafeAddress, uint16 erc20Idx, int256 amount) internal {
        updateInterest(erc20Idx);
        DSafe storage dSafe = state.dSafes[dSafeAddress];
        ERC20Share shares = dSafe.erc20Share[erc20Idx];
        ERC20Info storage erc20Info = state.erc20Infos[erc20Idx];
        int256 currentAmount = extractPosition(shares, erc20Info);
        int256 newAmount = currentAmount + amount;
        dSafe.erc20Share[erc20Idx] = insertPosition(newAmount, dSafe, erc20Idx);
    }

    function dAccountERC20Clear(address dSafeAddress, uint16 erc20Idx) internal returns (int256) {
        updateInterest(erc20Idx);
        DSafe storage dSafe = state.dSafes[dSafeAddress];
        ERC20Share shares = dSafe.erc20Share[erc20Idx];
        int256 erc20Amount = extractPosition(shares, state.erc20Infos[erc20Idx]);
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
        ERC20Info storage erc20Info = state.erc20Infos[erc20Idx];
        ERC20Pool storage pool = amount > 0 ? erc20Info.collateral : erc20Info.debt;
        return pool.insertPosition(amount);
    }

    function updateInterest(uint16 erc20Idx) internal {
        ERC20Info storage erc20Info = state.erc20Infos[erc20Idx];
        if (erc20Info.timestamp == block.timestamp) return;
        int256 delta = FsMath.safeCastToSigned(block.timestamp - erc20Info.timestamp);
        erc20Info.timestamp = block.timestamp;
        int256 debt = -erc20Info.debt.tokens;
        int256 interest = (debt *
            (FsMath.exp(erc20Info.interest * delta) - FsMath.FIXED_POINT_SCALE)) /
            FsMath.FIXED_POINT_SCALE;
        erc20Info.debt.tokens -= interest;
        erc20Info.collateral.tokens += interest;
        // TODO(gerben) add to treasury
    }

    function getNFTId(address erc721, uint256 tokenId) internal view returns (NFTId) {
        require(state.infoIdx[erc721].kind == ContractKind.ERC721, "Not an NFT");
        uint16 erc721Idx = state.infoIdx[erc721].idx;
        uint256 tokenHash = uint256(keccak256(abi.encodePacked(tokenId))) >> 32;
        return NFTId.wrap(erc721Idx | (tokenHash << 16) | ((tokenId >> 240) << 240));
    }

    function _isApprovedOrOwner(address spender, NFTId nftId) internal view returns (bool) {
        DSafe storage p = state.dSafes[msg.sender];
        (uint16 infoIndex, uint256 tokenId) = DOSLib.getNFTData(nftId);
        address collection = state.erc721Infos[infoIndex].erc721Contract;
        uint16 idx = state.tokenDataByNFTId[nftId].dSafeIdx;
        bool isDepositNFTOwner = idx < p.nfts.length &&
            NFTId.unwrap(p.nfts[idx]) == NFTId.unwrap(nftId);
        return (isDepositNFTOwner ||
            getApproved(collection, tokenId) == spender ||
            isApprovedForAll(collection, address(0), spender)); // BUG
    }

    // Config functions are handled by DOSConfig
    function _implementation() internal view override returns (address) {
        return dosConfig;
    }
}

contract DOSConfig is ImmutableOwnable, IDOSConfig {
    DOSLib.DOSState state;

    constructor(address _owner) ImmutableOwnable(_owner) {}

    function upgradeImplementation(address dSafe, uint256 version) external {
        address dSafeOwner = state.dSafes[dSafe].owner;
        require(msg.sender == dSafeOwner, "DOS: not owner");
        state.dSafeLogic[dSafe] = state.versionManager.getVersionAddress(version);
    }

    function addERC20Info(
        address erc20Contract,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address valueOracle,
        int256 colFactor,
        int256 borrowFactor,
        int256 interest
    ) external onlyOwner returns (uint16) {
        uint16 erc20Idx = uint16(state.erc20Infos.length);
        DOSERC20 dosToken = new DOSERC20(name, symbol, decimals);
        state.erc20Infos.push(
            ERC20Info(
                erc20Contract,
                address(dosToken),
                IERC20ValueOracle(valueOracle),
                ERC20Pool(0, 0),
                ERC20Pool(0, 0),
                colFactor,
                borrowFactor,
                interest,
                block.timestamp
            )
        );
        state.infoIdx[erc20Contract] = ContractData(erc20Idx, ContractKind.ERC20);
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
            interest
        );
        return erc20Idx;
    }

    function addNFTInfo(
        address nftContract,
        address valueOracleAddress,
        int256 collateralFactor
    ) external onlyOwner {
        INFTValueOracle valueOracle = INFTValueOracle(valueOracleAddress);
        uint256 erc721Idx = state.erc721Infos.length;
        state.erc721Infos.push(ERC721Info(nftContract, valueOracle, collateralFactor));
        state.infoIdx[nftContract] = ContractData(uint16(erc721Idx), ContractKind.ERC721);
    }

    function setConfig(Config calldata _config) external onlyOwner {
        state.config = _config;
    }

    function createDSafe() external returns (address dSafe) {
        address[] memory erc20s = new address[](state.erc20Infos.length);
        for (uint256 i = 0; i < state.erc20Infos.length; i++) {
            erc20s[i] = state.erc20Infos[i].erc20Contract;
        }
        address[] memory erc721s = new address[](state.erc721Infos.length);
        for (uint256 i = 0; i < state.erc721Infos.length; i++) {
            erc721s[i] = state.erc721Infos[i].erc721Contract;
        }

        dSafe = address(new DSafeProxy(address(this), erc20s, erc721s));
        state.dSafes[dSafe].owner = msg.sender;

        // add a version parameter if users should pick a specific version
        (, , , address implementation, ) = state.versionManager.getRecommendedVersion();
        state.dSafeLogic[dSafe] = implementation;
        emit IDOSConfig.DSafeCreated(dSafe, msg.sender);
    }

    function getDAccountERC20(address dSafe, IERC20 erc20) external view returns (int256) {
        // TODO(gerben) interest computation
        DSafe storage p = state.dSafes[dSafe];
        (ERC20Info storage info, uint16 erc20Idx) = DOSLib.getERC20Info(erc20);
        ERC20Share erc20Share = p.erc20Share[erc20Idx];
        return DOSLib.getBalance(erc20Share, info);
    }

    function viewNFTs(address dSafe) external view returns (NFTData[] memory) {
        NFTData[] memory nftData = new NFTData[](state.dSafes[dSafe].nfts.length);
        for (uint i = 0; i < nftData.length; i++) {
            (uint16 erc721Idx, uint256 tokenId) = DOSLib.getNFTData(state.dSafes[dSafe].nfts[i]);
            nftData[i] = NFTData(state.erc721Infos[erc721Idx].erc721Contract, tokenId);
        }
        return nftData;
    }

    // TODO(gerben) remove this function (its for tests)
    function getMaximumWithdrawableOfERC20(IERC20 erc20) public view returns (int256) {
        (ERC20Info storage erc20Info, ) = DOSLib.getERC20Info(erc20);
        int256 leverage = state.config.fractionalReserveLeverage;
        int256 tokens = erc20Info.collateral.tokens;

        int256 minReserveAmount = tokens / (leverage + 1);
        int256 totalDebt = erc20Info.debt.tokens;
        int256 borrowable = erc20Info.collateral.tokens - minReserveAmount;

        int256 remainingERC20ToBorrow = borrowable + totalDebt;

        return remainingERC20ToBorrow;
    }
}
