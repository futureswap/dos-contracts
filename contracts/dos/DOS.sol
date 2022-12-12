//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

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
import {PortfolioProxy} from "./PortfolioProxy.sol";
import "../dosERC20/DOSERC20.sol";
import {IVersionManager} from "../interfaces/IVersionManager.sol";

/// @notice Sender is not approved to spend portfolio erc20
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

// NFT's are stored in an array of nfts owned by some portfolio. To prevent looping over arrays we need to
// know the following information for each NFT in the system (erc721, tokenId, portfolio, array index).
// Given the expensive nature of storage on the EVM we want to store all information as small as possible.
// The pair (erc721, tokenId) is describes a particular NFT but would take two storage slots (as a token id)
// is 256 bits. The erc721 address is 160 bits however we only allow pre-approved erc721 contracts, so in
// practice 16 bits would be enough to store an index into the allowed erc721 contracts. We can hash (erc721 + tokenId)
// to get a unique number but that requires storing both tokenId, erc721 and array index. Instead we hash into
// 224 (256 - 32) bits which is still sufficiently large to avoid collisions. This leaves 32 bits for additional
// information. The 16 lsb's are used to store the index in the portfolio array. The 16 msb's are used to store
// the 16 msb's of the tokenId. This allows us to store the tokenId + array index in a single storage slot as a map
// from NFTId to NFTData. Note that the index in the portfolio array might change and thus cannot be part of
// NFTId and thus has to be stored as part of NFTData, requiring the splitting of tokenId.

type NFTId is uint256; // 16 bits (tokenId) + 224 bits (hash) + 16 bits (erc721 index)

struct NFTTokenData {
    uint240 tokenId; // 240 LSB of the tokenId of the NFT
    uint16 portfolioIdx; // index in portfolio NFT array
}

struct Portfolio {
    address owner;
    mapping(uint16 => ERC20Share) erc20Share;
    NFTId[] nfts;
    uint256[1] bitmask; // This can grow on updates
}

struct ERC20Pool {
    int256 tokens;
    int256 shares;
}

library PortfolioLib {
    function clearMask(Portfolio storage p, uint16 idx) internal {
        p.bitmask[idx >> 8] &= ~(1 << (idx & 255));
    }

    function setMask(Portfolio storage p, uint16 idx) internal {
        p.bitmask[idx >> 8] |= (1 << (idx & 255));
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
        Portfolio storage p,
        NFTId nftId,
        mapping(NFTId => NFTTokenData) storage map
    ) internal {
        uint16 idx = map[nftId].portfolioIdx;
        require(idx < p.nfts.length, "NFT must be on the user's deposit");
        require(
            NFTId.unwrap(p.nfts[idx]) == NFTId.unwrap(nftId),
            "NFT must be on the user's deposit"
        );
        if (idx == p.nfts.length - 1) {
            p.nfts.pop();
        } else {
            NFTId lastNFTId = p.nfts[p.nfts.length - 1];
            map[lastNFTId].portfolioIdx = idx;
            p.nfts.pop();
        }
        map[nftId].portfolioIdx = 0;
    }

    function insertNFT(
        Portfolio storage p,
        NFTId nftId,
        mapping(NFTId => NFTTokenData) storage map
    ) internal {
        uint16 idx = uint16(p.nfts.length);
        p.nfts.push(nftId);
        map[nftId].portfolioIdx = idx;
    }

    function getERC20s(Portfolio storage p) internal view returns (uint16[] memory erc20s) {
        uint256 numberOfERC20 = 0;
        for (uint256 i = 0; i < p.bitmask.length; i++) {
            numberOfERC20 += FsMath.bitCount(p.bitmask[i]);
        }
        erc20s = new uint16[](numberOfERC20);
        uint256 idx = 0;
        for (uint256 i = 0; i < p.bitmask.length; i++) {
            uint256 mask = p.bitmask[i];
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

contract DOS is IDOS, ImmutableOwnable, IERC721Receiver {
    using PortfolioLib for Portfolio;
    using PortfolioLib for ERC20Pool;
    using SafeERC20 for IERC20;
    using Address for address;

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

    struct Config {
        int256 liqFraction; // Fraction for the user
        int256 fractionalReserveLeverage; // Ratio of debt to reserves
    }

    // We will initialize the system so that 0 is the base currency
    // in which the system calculates value.
    uint16 constant kNumeraireIdx = 0;

    IVersionManager public versionManager;

    mapping(address => Portfolio) portfolios;

    // Note: This could be a mapping to a version index instead of the implementation address
    mapping(address => address) public portfolioLogic;

    /// @dev erc20 allowances
    mapping(address => mapping(IERC20 => mapping(address => uint256))) private _allowances;
    /// @dev erc721 approvals
    mapping(address => mapping(uint256 => address)) private _tokenApprovals;
    /// @dev erc721 & erc1155 operator approvals
    mapping(address => mapping(address => mapping(address => bool))) private _operatorApprovals;

    mapping(NFTId => NFTTokenData) public tokenDataByNFTId;

    ERC20Info[] public erc20Infos;
    ERC721Info[] public erc721Infos;
    struct ContractData {
        uint16 idx;
        uint240 kind; // 0 invalid, 1 ERC20, 2 ERC721
    }
    mapping(address => ContractData) public infoIdx;

    Config public config;

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

    event PortfolioCreated(address portfolio, address owner);

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

    modifier onlyPortfolio() {
        require(portfolios[msg.sender].owner != address(0), "Only portfolio can execute");
        _;
    }

    modifier portfolioExists(address portfolio) {
        require(portfolios[portfolio].owner != address(0), "Recipient portfolio doesn't exist");
        _;
    }

    modifier onlyRegisteredNFT(address nftContract, uint256 tokenId) {
        // how can we be sure that Oracle would have a price for any possible tokenId?
        // maybe we should check first if Oracle can return a value for this specific NFT?
        require(infoIdx[nftContract].kind != 0, "Cannot add NFT of unknown NFT contract");
        _;
    }

    modifier onlyNFTOwner(address nftContract, uint256 tokenId) {
        address _owner = ERC721(nftContract).ownerOf(tokenId);
        bool isOwner = _owner == msg.sender || _owner == portfolios[msg.sender].owner;
        require(isOwner, "NFT must be owned the the user or user's portfolio");
        _;
    }

    constructor(address governance, address _versionManager) ImmutableOwnable(governance) {
        versionManager = IVersionManager(_versionManager);
    }

    function upgradeImplementation(address portfolio, uint256 version) external {
        address portfolioOwner = getPortfolioOwner(portfolio);
        require(msg.sender == portfolioOwner, "DOS: not owner");
        portfolioLogic[portfolio] = versionManager.getVersionAddress(version);
    }

    function depositERC20(IERC20 erc20, int256 amount) external onlyPortfolio {
        (, uint16 erc20Idx) = getERC20Info(erc20);
        if (amount > 0) {
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            updateBalance(erc20Idx, msg.sender, amount);
        } else {
            erc20.safeTransfer(msg.sender, uint256(-amount));
            updateBalance(erc20Idx, msg.sender, amount);
        }
    }

    function depositFull(IERC20[] calldata erc20s) external onlyPortfolio {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            uint256 amount = erc20.balanceOf(msg.sender);
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            updateBalance(erc20Idx, msg.sender, FsMath.safeCastToSigned(amount));
        }
    }

    function withdrawFull(IERC20[] calldata erc20s) external onlyPortfolio {
        for (uint256 i = 0; i < erc20s.length; i++) {
            (ERC20Info storage erc20Info, uint16 erc20Idx) = getERC20Info(erc20s[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            int256 amount = clearBalance(erc20Idx, msg.sender);
            require(amount >= 0, "Can't withdraw debt");
            erc20.safeTransfer(msg.sender, uint256(amount));
        }
    }

    function depositNFT(
        address nftContract,
        uint256 tokenId
    )
        external
        onlyPortfolio
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

    /*function depositDosERC20(uint16 erc20Idx, int256 amount) external onlyPortfolio {
        ERC20Info storage erc20Info = getERC20Info(erc20Idx);
        IDOSERC20 erc20 = IDOSERC20(erc20Info.dosContract);
        if (amount > 0) {
            erc20.burn(msg.sender, uint256(amount));
            updateBalance(erc20Idx, msg.sender, amount);
        } else {
            erc20.mint(msg.sender, uint256(-amount));
            updateBalance(erc20Idx, msg.sender, amount);
        }
    }

    function claim(uint16 erc20Idx, uint256 amount) external onlyPortfolio {
        ERC20Info storage erc20Info = getERC20Info(erc20Idx);
        IDOSERC20(erc20Info.dosContract).burn(msg.sender, amount);
        IERC20(erc20Info.erc20Contract).safeTransfer(msg.sender, amount);
        // TODO: require appropriate reserve
    }*/

    function claimNFT(address erc721, uint256 tokenId) external onlyPortfolio {
        NFTId nftId = getNFTId(erc721, tokenId);

        ERC721(erc721).safeTransferFrom(address(this), msg.sender, tokenId);

        portfolios[msg.sender].extractNFT(nftId, tokenDataByNFTId);
        delete tokenDataByNFTId[nftId];
    }

    function transfer(
        IERC20 erc20,
        address to,
        uint256 amount
    ) external onlyPortfolio portfolioExists(to) {
        if (amount == 0) return;
        (, uint16 erc20Idx) = getERC20Info(erc20);
        transferERC20(erc20, msg.sender, to, FsMath.safeCastToSigned(amount));
    }

    function sendNFT(
        address erc721,
        uint256 tokenId,
        address to
    ) external onlyPortfolio portfolioExists(to) {
        NFTId nftId = getNFTId(erc721, tokenId);
        transferNFT(nftId, msg.sender, to);
    }

    /// @notice Approve a spender to transfer tokens on your behalf
    /// @param erc20 The index of the ERC20 token in erc20Infos array
    /// @param spender The address of the spender
    /// @param amount The amount of tokens to approve
    function approveERC20(
        IERC20 erc20,
        address spender,
        uint256 amount
    ) external onlyPortfolio portfolioExists(spender) returns (bool) {
        _approveERC20(msg.sender, erc20, spender, amount);
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
        _approveERC721(collection, to, tokenId);
    }

    /// @notice Approve a spender for all tokens in a collection on your behalf
    /// @param collection The address of the collection
    /// @param operator The address of the operator
    /// @param approved Whether the operator is approved
    function setApprovalForAll(
        address collection,
        address operator,
        bool approved
    ) external onlyPortfolio portfolioExists(operator) {
        _setApprovalForAll(collection, msg.sender, operator, approved);
    }

    /// @notice Transfer ERC20 tokens from portfolio to another portfolio
    /// @dev Note: Allowance must be set with approveERC20
    /// @param erc20 The index of the ERC20 token in erc20Infos array
    /// @param from The address of the portfolio to transfer from
    /// @param to The address of the portfolio to transfer to
    /// @param amount The amount of tokens to transfer
    function transferFromERC20(
        IERC20 erc20,
        address from,
        address to,
        uint256 amount
    ) external onlyPortfolio portfolioExists(from) portfolioExists(to) returns (bool) {
        address spender = msg.sender;
        _spendAllowance(erc20, from, spender, amount);
        transferERC20(erc20, from, to, FsMath.safeCastToSigned(amount));
        return true;
    }

    /*
    /// @notice Transfers a token using a signed permit message
    /// @dev Reverts if the requested amount is greater than the permitted signed amount
    /// @param _owner The owner of the tokens to transfer
    /// @param _to The address to transfer the tokens to
    /// @param amount The amount of tokens to transfer
    /// @param permit The permit data signed over by the owner
    /// @param signature The signature to verify
    function permitTransferFromERC20(
        address _owner,
        address _to,
        uint256 amount,
        IPermit2.PermitTransferFrom memory permit,
        bytes calldata signature
    ) external onlyPortfolio portfolioExists(_to) {
        PERMIT2.permitTransferFrom(
            permit,
            IPermit2.SignatureTransferDetails({to: _to, requestedAmount: amount}),
            _owner,
            signature
        );
    }*/

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
        NFTId nftId = getNFTId(collection, tokenId);
        if (!_isApprovedOrOwner(msg.sender, nftId)) {
            revert NotApprovedOrOwner();
        }
        _tokenApprovals[collection][tokenId] = address(0);
        transferNFT(nftId, from, to);
    }

    // TODO: update approval to only cover this call
    /**
     * @notice Approve the passed address to spend the specified amount of tokens on behalf of msg.sender
     * and then call `onApprovalReceived` on spender.
     * Beware that changing an allowance with this method brings the risk that someone may use both the old
     * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
     * race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     * @param erc20 The erc20 token to approve
     * @param spender address The address which will spend the funds
     * @param amount uint256 The amount of tokens to be spent
     */
    function approveAndCall(IERC20 erc20, address spender, uint256 amount) external returns (bool) {
        return approveAndCall(erc20, spender, amount, "");
    }

    /**
     * @notice Transfer tokens from `msg.sender` to another address and then call `onTransferReceived` on receiver
     * @param erc20 The erc20 token to transfer
     * @param to address The address which you want to transfer to
     * @param amount uint256 The amount of tokens to be transferred
     * @return true unless throwing
     */
    function transferAndCall(IERC20 erc20, address to, uint256 amount) external returns (bool) {
        return transferAndCall(erc20, to, amount, "");
    }

    // /**
    //  * @notice Transfer tokens from one address to another and then call `onTransferReceived` on receiver
    //  * @param from address The address which you want to send tokens from
    //  * @param to address The address which you want to transfer to
    //  * @param amount uint256 The amount of tokens to be transferred
    //  * @return true unless throwing
    //  */
    // function transferFromAndCall(
    //     address from,
    //     address to,
    //     uint256 amount
    // ) external returns (bool) {}

    function liquidate(
        address portfolio
    ) external override onlyPortfolio portfolioExists(portfolio) {
        (int256 totalValue, int256 collateral, int256 debt) = computePosition(portfolio);
        require(collateral < debt, "Portfolio is not liquidatable");
        uint16[] memory portfolioERC20s = portfolios[portfolio].getERC20s();
        for (uint256 i = 0; i < portfolioERC20s.length; i++) {
            uint16 erc20Idx = portfolioERC20s[i];
            transferAllERC20(erc20Idx, portfolio, msg.sender);
        }
        while (portfolios[portfolio].nfts.length > 0) {
            transferNFT(
                portfolios[portfolio].nfts[portfolios[portfolio].nfts.length - 1],
                portfolio,
                msg.sender
            );
        }
        // TODO(gerben) make formula dependent on risk
        if (totalValue > 0) {
            // totalValue of the liquidated portfolio is split between liquidatable and liquidator:
            // totalValue * (1 - liqFraction) - reward of the liquidator, and
            // totalValue * liqFraction - change, liquidator is sending back to liquidatable
            int256 leftover = (totalValue * config.liqFraction) / 1 ether;
            transferERC20(
                IERC20(erc20Infos[kNumeraireIdx].erc20Contract),
                msg.sender,
                portfolio,
                leftover
            );
        }
    }

    function executeBatch(Call[] memory calls) external override onlyPortfolio {
        for (uint256 i = 0; i < calls.length; i++) {
            PortfolioProxy(payable(msg.sender)).doCall(
                calls[i].to,
                calls[i].callData,
                calls[i].value
            );
        }
        require(isSolvent(msg.sender), "Result of operation is not sufficient liquid");
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
                interest,
                block.timestamp
            )
        );
        infoIdx[erc20Contract] = ContractData(erc20Idx, 1);
        emit ERC20Added(
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
        uint256 erc721Idx = erc721Infos.length;
        erc721Infos.push(ERC721Info(nftContract, valueOracle, collateralFactor));
        infoIdx[nftContract] = ContractData(uint16(erc721Idx), 2);
    }

    function setConfig(Config calldata _config) external onlyOwner {
        config = _config;
    }

    function createPortfolio() external returns (address portfolio) {
        address[] memory erc20s = new address[](erc20Infos.length);
        address[] memory nfts = new address[](0);
        for (uint256 i = 0; i < erc20Infos.length; i++) {
            erc20s[i] = erc20Infos[i].erc20Contract;
        }
        portfolio = address(new PortfolioProxy(address(this), erc20s, nfts));
        portfolios[portfolio].owner = msg.sender;

        // add a version parameter if users should pick a specific version
        (, , , address implementation, ) = versionManager.getRecommendedVersion();
        portfolioLogic[portfolio] = implementation;
        emit PortfolioCreated(portfolio, msg.sender);
    }

    function viewBalance(address portfolio, IERC20 erc20) external view returns (int256) {
        // TODO(gerben) interest computation
        Portfolio storage p = portfolios[portfolio];
        (ERC20Info storage info, uint16 erc20Idx) = getERC20Info(erc20);
        ERC20Share erc20Share = p.erc20Share[erc20Idx];
        return getBalance(erc20Share, info);
    }

    struct NFTData {
        address erc721;
        uint256 tokenId;
    }

    function viewNFTs(address portfolio) external view returns (NFTData[] memory) {
        NFTData[] memory nftData = new NFTData[](portfolios[portfolio].nfts.length);
        for (uint i = 0; i < nftData.length; i++) {
            (uint16 erc721Idx, uint256 tokenId) = getNFTData(portfolios[portfolio].nfts[i]);
            nftData[i] = NFTData(erc721Infos[erc721Idx].erc721Contract, tokenId);
        }
        return nftData;
    }

    function getImplementation(address portfolio) external view override returns (address) {
        // not using msg.sender since this is an external view function
        return portfolioLogic[portfolio];
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        NFTId nftId = getNFTId(msg.sender, tokenId);
        if (data.length != 0) {
            from = abi.decode(data, (address));
        }
        require(portfolios[from].owner != address(0), "Portfolio does not exist");
        tokenDataByNFTId[nftId].tokenId = uint240(tokenId);
        portfolios[from].insertNFT(nftId, tokenDataByNFTId);
        // TODO(call portfolio?)
        return this.onERC721Received.selector;
    }

    /**
     * @notice Approve the passed address to spend the specified amount of tokens on behalf of msg.sender
     * and then call `onApprovalReceived` on spender.
     * Beware that changing an allowance with this method brings the risk that someone may use both the old
     * and the new allowance by unfortunate transaction ordering. One possible solution to mitigate this
     * race condition is to first reduce the spender's allowance to 0 and set the desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     * @param erc20 address The address of the ERC20 token
     * @param spender address The address which will spend the funds
     * @param amount uint256 The amount of tokens to be spent
     * @param data bytes Additional data with no specified format, sent in call to `spender`
     * @return true unless throwing
     */
    function approveAndCall(
        IERC20 erc20,
        address spender,
        uint256 amount,
        bytes memory data
    ) public returns (bool) {
        _approveERC20(msg.sender, erc20, spender, amount);
        if (!_checkOnApprovalReceived(spender, amount, data)) {
            revert WrongDataReturned();
        }
        _approveERC20(msg.sender, erc20, spender, 0); // reset allowance
        return true;
    }

    /// @notice Approve an array of tokens and then call `onApprovalREceived` on spender.
    /// @param erc20s An array of erc20 tokens
    /// @param spender The address of the spender
    /// @param amounts An array of the amounts of tokens to be spent
    /// @param data Additional data with no specified format, sent in call to `spender`
    /// @return true unless throwing
    function approveBatchAndCall(
        IERC20[] calldata erc20s,
        address spender,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bool) {
        require(erc20s.length == amounts.length, "Lengths do not match");
        for (uint256 i = 0; i < erc20s.length; i++) {
            _approveERC20(msg.sender, erc20s[i], spender, amounts[i]);
        }
        if (!_checkOnApprovalReceived(spender, 0, data)) {
            revert WrongDataReturned();
        }
        for (uint256 i = 0; i < erc20s.length; i++) {
            _approveERC20(msg.sender, erc20s[i], spender, 0); // reset allowance
        }
        return true;
    }

    /**
     * @notice Transfer tokens from `msg.sender` to another address and then call `onTransferReceived` on receiver
     * @param erc20 address The address of the ERC20 token
     * @param to address The address which you want to transfer to
     * @param amount uint256 The amount of tokens to be transferred
     * @param data bytes Additional data with no specified format, sent in call to `to`
     * @return true unless throwing
     */
    function transferAndCall(
        IERC20 erc20,
        address to,
        uint256 amount,
        bytes memory data
    ) public returns (bool) {
        transferERC20(erc20, msg.sender, to, FsMath.safeCastToSigned(amount));
        if (!_checkOnTransferReceived(msg.sender, to, amount, data)) {
            revert WrongDataReturned();
        }
        return true;
    }

    /// @notice Transfer an array of tokens from `msg.sender` to another address and then call `onTransferReceived` on receiver
    /// @param erc20s An array of ERC20 tokens
    /// @param to The address which you want to transfer to
    /// @param amounts An array of amounts of tokens to be transferred
    /// @param data Additional data with no specified format, sent in call to `to`
    /// @return true unless throwing
    function transferBatchAndCall(
        IERC20[] calldata erc20s,
        address to,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bool) {
        require(erc20s.length == amounts.length, "Lengths do not match");
        for (uint256 i = 0; i < erc20s.length; i++) {
            transferERC20(erc20s[i], msg.sender, to, FsMath.safeCastToSigned(amounts[i]));
        }
        if (!_checkOnTransferReceived(msg.sender, to, 0, data)) {
            revert WrongDataReturned();
        }
        return true;
    }

    // /**
    //  * @notice Transfer tokens from one address to another and then call `onTransferReceived` on receiver
    //  * @param from address The address which you want to send tokens from
    //  * @param to address The address which you want to transfer to
    //  * @param amount uint256 The amount of tokens to be transferred
    //  * @param data bytes Additional data with no specified format, sent in call to `to`
    //  * @return true unless throwing
    //  */
    // function transferFromAndCall(
    //     address from,
    //     address to,
    //     uint256 amount,
    //     bytes calldata data
    // ) public returns (bool) {}

    function getPortfolioOwner(address portfolio) public view override returns (address) {
        return portfolios[portfolio].owner;
    }

    function computePosition(
        address portfolioAddress
    )
        public
        view
        portfolioExists(portfolioAddress)
        returns (int256 totalValue, int256 collateral, int256 debt)
    {
        Portfolio storage portfolio = portfolios[portfolioAddress];
        uint16[] memory erc20Idxs = portfolio.getERC20s();
        totalValue = 0;
        collateral = 0;
        debt = 0;
        for (uint256 i = 0; i < erc20Idxs.length; i++) {
            uint16 erc20Idx = erc20Idxs[i];
            ERC20Info storage erc20Info = erc20Infos[erc20Idx];
            int256 balance = getBalance(portfolio.erc20Share[erc20Idx], erc20Info);
            int256 value = erc20Info.valueOracle.calcValue(balance);
            totalValue += value;
            if (balance >= 0) {
                collateral += (value * erc20Info.collateralFactor) / 1 ether;
            } else {
                debt += (-value * 1 ether) / erc20Info.borrowFactor;
            }
        }
        for (uint256 i = 0; i < portfolio.nfts.length; i++) {
            NFTId nftId = portfolio.nfts[i];
            (uint16 erc721Idx, uint256 tokenId) = getNFTData(nftId);
            ERC721Info storage nftInfo = erc721Infos[erc721Idx];
            int256 nftValue = int256(nftInfo.valueOracle.calcValue(tokenId));
            totalValue += nftValue;
            collateral += (nftValue * nftInfo.collateralFactor) / 1 ether;
        }
    }

    function getMaximumWithdrawableOfERC20(uint256 erc20Idx) public view returns (int256) {
        int256 leverage = config.fractionalReserveLeverage;
        int256 tokens = erc20Infos[erc20Idx].collateral.tokens;

        int256 minReserveAmount = tokens / (leverage + 1);
        int256 totalDebt = erc20Infos[erc20Idx].debt.tokens;
        int256 borrowable = erc20Infos[erc20Idx].collateral.tokens - minReserveAmount;

        int256 remainingERC20ToBorrow = borrowable + totalDebt;

        return remainingERC20ToBorrow;
    }

    function isSolvent(address portfolio) public view returns (bool) {
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
        (, int256 collateral, int256 debt) = computePosition(portfolio);
        return collateral >= debt;
    }

    /// @notice Returns the approved address for a token, or zero if no address set
    /// @param collection The address of the ERC721 token
    /// @param tokenId The id of the token to query
    function getApproved(address collection, uint256 tokenId) public view returns (address) {
        return _tokenApprovals[collection][tokenId];
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
        return _operatorApprovals[collection][_owner][spender];
    }

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
    ) public view returns (uint256) {
        return _allowances[_owner][erc20][spender];
    }

    function _approveERC20(address _owner, IERC20 erc20, address spender, uint256 amount) internal {
        spender = FsUtils.nonNull(spender);

        _allowances[_owner][erc20][spender] = amount;
        emit ERC20Approval(address(erc20), _owner, spender, amount);
    }

    function _approveERC721(address collection, address to, uint256 tokenId) internal {
        _tokenApprovals[collection][tokenId] = to;
        emit ERC721Approval(collection, owner, to, tokenId);
    }

    function _spendAllowance(
        IERC20 erc20,
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
                _approveERC20(_owner, erc20, spender, currentAllowance - amount);
            }
        }
    }

    function _setApprovalForAll(
        address collection,
        address _owner,
        address operator,
        bool approved
    ) internal {
        if (_owner == operator) {
            revert SelfApproval();
        }
        _operatorApprovals[collection][_owner][operator] = approved;
        emit ApprovalForAll(collection, _owner, operator, approved);
    }

    /**
     * @dev Internal function to invoke {IERC1363Receiver-onTransferReceived} on a target address
     *  The call is not executed if the target address is not a contract
     * @param sender address Representing the previous owner of the given token amount
     * @param recipient address Target address that will receive the tokens
     * @param amount uint256 The amount mount of tokens to be transferred
     * @param data bytes Optional data to send along with the call
     * @return whether the call correctly returned the expected magic value
     */
    function _checkOnTransferReceived(
        address sender,
        address recipient,
        uint256 amount,
        bytes memory data
    ) internal virtual returns (bool) {
        if (!recipient.isContract()) {
            revert ReceiverNotContract();
        }

        try
            IERC1363Receiver(recipient).onTransferReceived(msg.sender, sender, amount, data)
        returns (bytes4 retval) {
            return retval == IERC1363Receiver.onTransferReceived.selector;
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

    /**
     * @dev Internal function to invoke {IERC1363Receiver-onApprovalReceived} on a target address
     *  The call is not executed if the target address is not a contract
     * @param spender address The address which will spend the funds
     * @param amount uint256 The amount of tokens to be spent
     * @param data bytes Optional data to send along with the call
     * @return whether the call correctly returned the expected magic value
     */
    function _checkOnApprovalReceived(
        address spender,
        uint256 amount,
        bytes memory data
    ) internal virtual returns (bool) {
        if (!spender.isContract()) {
            revert ReceiverNotContract();
        }

        try IERC1363Spender(spender).onApprovalReceived(msg.sender, amount, data) returns (
            bytes4 retval
        ) {
            return retval == IERC1363Spender.onApprovalReceived.selector;
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
        (, uint16 erc20Idx) = getERC20Info(erc20);
        updateBalance(erc20Idx, from, -amount);
        updateBalance(erc20Idx, to, amount);
    }

    function transferNFT(NFTId nftId, address from, address to) internal {
        portfolios[from].extractNFT(nftId, tokenDataByNFTId);
        portfolios[to].insertNFT(nftId, tokenDataByNFTId);
    }

    // TODO @derek - add method for withdraw

    function transferAllERC20(uint16 erc20Idx, address from, address to) internal {
        int256 amount = clearBalance(erc20Idx, from);
        updateBalance(erc20Idx, to, amount);
    }

    function updateBalance(uint16 erc20Idx, address portfolioAddress, int256 amount) internal {
        updateInterest(erc20Idx);
        Portfolio storage portfolio = portfolios[portfolioAddress];
        ERC20Share shares = portfolio.erc20Share[erc20Idx];
        ERC20Info storage erc20Info = erc20Infos[erc20Idx];
        int256 currentAmount = extractPosition(shares, erc20Info);
        int256 newAmount = currentAmount + amount;
        portfolio.erc20Share[erc20Idx] = insertPosition(newAmount, portfolio, erc20Idx);
    }

    function clearBalance(uint16 erc20Idx, address portfolioAddress) internal returns (int256) {
        updateInterest(erc20Idx);
        Portfolio storage portfolio = portfolios[portfolioAddress];
        ERC20Share shares = portfolio.erc20Share[erc20Idx];
        int256 erc20Amount = extractPosition(shares, erc20Infos[erc20Idx]);
        portfolio.erc20Share[erc20Idx] = ERC20Share.wrap(0);
        portfolio.clearMask(erc20Idx);
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
        Portfolio storage portfolio,
        uint16 erc20Idx
    ) internal returns (ERC20Share) {
        if (amount == 0) {
            portfolio.clearMask(erc20Idx);
        } else {
            portfolio.setMask(erc20Idx);
        }
        ERC20Info storage erc20Info = erc20Infos[erc20Idx];
        ERC20Pool storage pool = amount > 0 ? erc20Info.collateral : erc20Info.debt;
        return pool.insertPosition(amount);
    }

    function updateInterest(uint16 erc20Idx) internal {
        ERC20Info storage p = erc20Infos[erc20Idx];
        if (p.timestamp == block.timestamp) return;
        int256 delta = FsMath.safeCastToSigned(block.timestamp - p.timestamp);
        p.timestamp = block.timestamp;
        int256 debt = -p.debt.tokens;
        int256 interest = (debt * (FsMath.exp(p.interest * delta) - FsMath.FIXED_POINT_SCALE)) /
            FsMath.FIXED_POINT_SCALE;
        p.debt.tokens -= interest;
        p.collateral.tokens += interest;
        // TODO(gerben) add to treasury
    }

    function getNFTId(address erc721, uint256 tokenId) internal view returns (NFTId) {
        require(infoIdx[erc721].kind == 2, "Not an NFT");
        uint16 erc721Idx = infoIdx[erc721].idx;
        uint256 tokenHash = uint256(keccak256(abi.encodePacked(tokenId))) >> 32;
        return NFTId.wrap(erc721Idx | (tokenHash << 16) | ((tokenId >> 240) << 240));
    }

    function getNFTData(NFTId nftId) internal view returns (uint16 erc721Idx, uint256 tokenId) {
        uint256 unwrappedId = NFTId.unwrap(nftId);
        erc721Idx = uint16(unwrappedId);
        tokenId = tokenDataByNFTId[nftId].tokenId | ((unwrappedId >> 240) << 240);
    }

    function _isApprovedOrOwner(address spender, NFTId nftId) internal view returns (bool) {
        Portfolio storage p = portfolios[msg.sender];
        (uint16 infoIndex, uint256 tokenId) = getNFTData(nftId);
        address collection = erc721Infos[infoIndex].erc721Contract;
        uint16 idx = tokenDataByNFTId[nftId].portfolioIdx;
        bool isDepositNFTOwner = idx < p.nfts.length &&
            NFTId.unwrap(p.nfts[idx]) == NFTId.unwrap(nftId);
        return (isDepositNFTOwner ||
            getApproved(collection, tokenId) == spender ||
            isApprovedForAll(collection, owner, spender));
    }

    function getBalance(ERC20Share shares, ERC20Info storage p) internal view returns (int256) {
        ERC20Pool storage s = ERC20Share.unwrap(shares) > 0 ? p.collateral : p.debt;
        return s.computeERC20(shares);
    }

    function getERC20Info(IERC20 erc20) internal view returns (ERC20Info storage, uint16) {
        require(infoIdx[address(erc20)].kind == 1, "ERC20 not registered");
        uint16 idx = infoIdx[address(erc20)].idx;
        return (erc20Infos[idx], idx);
    }

    function getERC721Info(IERC721 erc721) internal view returns (ERC721Info storage, uint16) {
        require(infoIdx[address(erc721)].kind == 2, "ERC721 not registered");
        uint16 idx = infoIdx[address(erc721)].idx;
        return (erc721Infos[idx], idx);
    }
}
