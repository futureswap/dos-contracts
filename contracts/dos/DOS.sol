//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
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

// ERC20 standard token
// ERC721 single non-fungible token support
// ERC677 transferAndCall (transferAndCall2 extension)
// ERC165 interface support (solidity IDOS.interfaceId)
// ERC777 token send
// ERC1155 multi-token support
// ERC1820 interface registry support
// EIP2612 permit support

// First 16 bits are index in the portfolio NFT array
// Remaining 240 bits are the NFT ID
type NFTId is uint256;

struct Portfolio {
    address owner;
    mapping(ERC20Idx => ERC20Share) erc20Share;
    NFTId[] nfts;
    uint256[1] bitmask; // This can grow on updates
}

struct ERC20Pool {
    int256 tokens;
    int256 shares;
}

library PortfolioLib {
    function clearMask(Portfolio storage p, ERC20Idx erc20Idx) internal {
        uint16 idx = ERC20Idx.unwrap(erc20Idx);
        p.bitmask[idx >> 8] &= ~(1 << (idx & 255));
    }

    function setMask(Portfolio storage p, ERC20Idx erc20Idx) internal {
        uint16 idx = ERC20Idx.unwrap(erc20Idx);
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

    function extractNFT(Portfolio storage p, NFTId nftId) internal returns (uint256) {
        uint256 idx = NFTId.unwrap(nftId) >> 240;
        FsUtils.Assert(idx < p.nfts.length);
        uint256 strippedNFTId = uint240(NFTId.unwrap(nftId));

        if (idx == p.nfts.length - 1) {
            p.nfts.pop();
        } else {
            p.nfts[idx] = NFTId.wrap(
                uint256(uint240(NFTId.unwrap(p.nfts[p.nfts.length - 1]))) | (idx << 240)
            );
            p.nfts.pop();
        }
        return strippedNFTId;
    }

    function insertNFT(Portfolio storage p, uint256 strippedNFTId) internal returns (NFTId) {
        NFTId nftId = NFTId.wrap(strippedNFTId | (p.nfts.length << 240));
        p.nfts.push(nftId);
        return nftId;
    }

    function getERC20s(Portfolio storage p) internal view returns (ERC20Idx[] memory erc20s) {
        uint256 numberOfERC20 = 0;
        for (uint256 i = 0; i < p.bitmask.length; i++) {
            numberOfERC20 += FsMath.bitCount(p.bitmask[i]);
        }
        erc20s = new ERC20Idx[](numberOfERC20);
        uint256 idx = 0;
        for (uint256 i = 0; i < p.bitmask.length; i++) {
            uint256 mask = p.bitmask[i];
            for (uint256 j = 0; j < 256; j++) {
                uint256 x = mask >> j;
                if (x == 0) break;
                if ((x & 1) != 0) {
                    erc20s[idx++] = ERC20Idx.wrap(uint16(i * 256 + j));
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

    struct NFTInfo {
        bool exists;
        INFTValueOracle valueOracle;
        int256 collateralFactor;
    }

    struct Config {
        int256 liqFraction; // Fraction for the user
        int256 fractionalReserveLeverage; // Ratio of debt to reserves
    }

    // We will initialize the system so that ERC20Idx 0 is the base currency
    // in which the system calculates value.
    ERC20Idx constant kNumeraireIdx = ERC20Idx.wrap(0);

    IVersionManager public versionManager;

    mapping(address => Portfolio) portfolios;

    // Note: This could be a mapping to a version index instead of the implementation address
    mapping(address => address) public portfolioLogic;

    /// @dev erc20 allowances
    mapping(address => mapping(ERC20Idx => mapping(address => uint256))) private _allowances;
    /// @dev erc721 approvals
    mapping(address => mapping(uint256 => address)) private _tokenApprovals;
    /// @dev erc721 & erc1155 operator approvals
    mapping(address => mapping(address => mapping(address => bool))) private _operatorApprovals;

    // internal NFT identifier is address erc20 (160) + counter (80 bits) + index (16 bits) = 256 bits
    uint80 nftIdCounter;
    mapping(uint240 => uint256) public tokenIdByNFTId;

    ERC20Info[] public erc20Infos;
    mapping(address => NFTInfo) public nftInfos;
    Config public config;

    /// @dev Emitted when `owner` approves `spender` to spend `value` tokens on their behalf.
    /// @param erc20Idx The ERC20 token to approve
    /// @param owner The address of the token owner
    /// @param spender The address of the spender
    /// @param value The amount of tokens to approve
    event ERC20Approval(
        ERC20Idx indexed erc20Idx,
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
        ERC20Idx erc20Idx,
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
        require(nftInfos[nftContract].exists, "Cannot add NFT of unknown NFT contract");
        _;
    }

    modifier onlyNFTOwner(address nftContract, uint256 tokenId) {
        address owner = ERC721(nftContract).ownerOf(tokenId);
        bool isOwner = owner == msg.sender || owner == portfolios[msg.sender].owner;
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

    function depositERC20(ERC20Idx erc20Idx, int256 amount) external onlyPortfolio {
        IERC20 erc20 = IERC20(getERC20Info(erc20Idx).erc20Contract);
        if (amount > 0) {
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            updateBalance(erc20Idx, msg.sender, amount);
        } else {
            erc20.safeTransfer(msg.sender, uint256(-amount));
            updateBalance(erc20Idx, msg.sender, amount);
        }
    }

    function depositFull(ERC20Idx[] calldata erc20Idxs) external onlyPortfolio {
        for (uint256 i = 0; i < erc20Idxs.length; i++) {
            ERC20Info storage erc20Info = getERC20Info(erc20Idxs[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            uint256 amount = erc20.balanceOf(msg.sender);
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            updateBalance(erc20Idxs[i], msg.sender, FsMath.safeCastToSigned(amount));
        }
    }

    function withdrawFull(ERC20Idx[] calldata erc20Idxs) external onlyPortfolio {
        for (uint256 i = 0; i < erc20Idxs.length; i++) {
            ERC20Info storage erc20Info = getERC20Info(erc20Idxs[i]);
            IERC20 erc20 = IERC20(erc20Info.erc20Contract);
            int256 amount = clearBalance(erc20Idxs[i], msg.sender);
            require(amount >= 0, "Can't withdraw debt");
            erc20.safeTransfer(msg.sender, uint256(amount));
        }
    }

    function NFTHash(address nftContract, uint256 tokenId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(nftContract, tokenId))) >> 16;
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
        address owner = ERC721(nftContract).ownerOf(tokenId);
        ERC721(nftContract).safeTransferFrom(owner, address(this), tokenId);
    }

    function depositDosERC20(ERC20Idx erc20Idx, int256 amount) external onlyPortfolio {
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

    function claim(ERC20Idx erc20Idx, uint256 amount) external onlyPortfolio {
        ERC20Info storage erc20Info = getERC20Info(erc20Idx);
        IDOSERC20(erc20Info.dosContract).burn(msg.sender, amount);
        IERC20(erc20Info.erc20Contract).safeTransfer(msg.sender, amount);
        // TODO: require appropriate reserve
    }

    function claimNFT(uint256 nftId) external onlyPortfolio {
        (address erc721, uint256 tokenId) = getNFTData(nftId);

        ERC721(erc721).safeTransferFrom(address(this), msg.sender, tokenId);

        portfolios[msg.sender].extractNFT(NFTId.wrap(nftId));
        delete tokenIdByNFTId[uint240(nftId)];
    }

    function transfer(
        ERC20Idx erc20Idx,
        address to,
        uint256 amount
    ) external onlyPortfolio portfolioExists(to) {
        if (amount == 0) return;
        transferERC20(erc20Idx, msg.sender, to, FsMath.safeCastToSigned(amount));
    }

    function sendNFT(uint256 nftId, address to) external onlyPortfolio portfolioExists(to) {
        transferNFT(nftId, msg.sender, to);
    }

    /// @notice Approve a spender to transfer tokens on your behalf
    /// @param erc20Idx The index of the ERC20 token in erc20Infos array
    /// @param spender The address of the spender
    /// @param amount The amount of tokens to approve
    function approveERC20(
        ERC20Idx erc20Idx,
        address spender,
        uint256 amount
    ) external onlyPortfolio portfolioExists(spender) returns (bool) {
        _approveERC20(msg.sender, erc20Idx, spender, amount);
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
    /// @param erc20Idx The index of the ERC20 token in erc20Infos array
    /// @param from The address of the portfolio to transfer from
    /// @param to The address of the portfolio to transfer to
    /// @param amount The amount of tokens to transfer
    function transferFromERC20(
        ERC20Idx erc20Idx,
        address from,
        address to,
        uint256 amount
    ) external onlyPortfolio portfolioExists(from) portfolioExists(to) returns (bool) {
        address spender = msg.sender;
        _spendAllowance(erc20Idx, from, spender, amount);
        transferERC20(erc20Idx, from, to, FsMath.safeCastToSigned(amount));
        return true;
    }

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
    }

    /*
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
        uint256 nftPortfolioIdx = p.nftPortfolioIdxs[collection][tokenId] - 1;
        if (!_isApprovedOrOwner(msg.sender, collection, tokenId)) {
            revert NotApprovedOrOwner();
        }
        _tokenApprovals[collection][tokenId] = address(0);
        transferNFT(nftPortfolioIdx, from, to);
    }*/

    function liquidate(
        address portfolio
    ) external override onlyPortfolio portfolioExists(portfolio) {
        (int256 totalValue, int256 collateral, int256 debt) = computePosition(portfolio);
        require(collateral < debt, "Portfolio is not liquidatable");
        ERC20Idx[] memory portfolioERC20s = portfolios[portfolio].getERC20s();
        for (uint256 i = 0; i < portfolioERC20s.length; i++) {
            ERC20Idx erc20Idx = portfolioERC20s[i];
            transferAllERC20(erc20Idx, portfolio, msg.sender);
        }
        while (portfolios[portfolio].nfts.length > 0) {
            transferNFT(portfolios[portfolio].nfts.length - 1, portfolio, msg.sender);
        }
        // TODO(gerben) make formula dependent on risk
        if (totalValue > 0) {
            // totalValue of the liquidated portfolio is split between liquidatable and liquidator:
            // totalValue * (1 - liqFraction) - reward of the liquidator, and
            // totalValue * liqFraction - change, liquidator is sending back to liquidatable
            int256 leftover = (totalValue * config.liqFraction) / 1 ether;
            transferERC20(kNumeraireIdx, msg.sender, portfolio, leftover);
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
    ) external onlyOwner returns (ERC20Idx) {
        ERC20Idx erc20Idx = ERC20Idx.wrap(uint16(erc20Infos.length));
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
        NFTInfo memory nftInfo = NFTInfo(true, valueOracle, collateralFactor);
        nftInfos[nftContract] = nftInfo;
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

    function viewBalance(address portfolio, ERC20Idx erc20Idx) external view returns (int256) {
        // TODO(gerben) interest computation
        Portfolio storage p = portfolios[portfolio];
        ERC20Share erc20Share = p.erc20Share[erc20Idx];
        return getBalance(erc20Share, getERC20Info(erc20Idx));
    }

    /*function viewNFTs(address portfolio) external view returns (NFT[] memory) {
        return portfolios[portfolio].nfts;
    }*/

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
        uint256 nftId = mintNFTId(msg.sender, tokenId);
        require(data.length == 0);
        require(portfolios[from].owner != address(0));
        portfolios[from].insertNFT(nftId);
        return this.onERC721Received.selector;
    }

    function mintNFTId(address erc721, uint256 tokenId) internal returns (uint256) {
        uint256 nftId = nftIdCounter++;
        nftId = (nftId << 160) | uint160(erc721);
        tokenIdByNFTId[uint240(nftId)] = tokenId;
        return nftId;
    }

    function getNFTData(uint256 nftId) internal view returns (address erc721, uint256 tokenId) {
        erc721 = address(uint160(nftId));
        tokenId = tokenIdByNFTId[uint240(nftId)];
    }

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
        ERC20Idx[] memory erc20Idxs = portfolio.getERC20s();
        totalValue = 0;
        collateral = 0;
        debt = 0;
        for (uint256 i = 0; i < erc20Idxs.length; i++) {
            ERC20Idx erc20Idx = erc20Idxs[i];
            ERC20Info storage erc20Info = getERC20Info(erc20Idx);
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
            (address erc721, uint256 tokenId) = getNFTData(NFTId.unwrap(nftId));
            NFTInfo storage nftInfo = nftInfos[erc721];
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
        ERC20Idx erc20Idx,
        address _owner,
        address spender
    ) public view returns (uint256) {
        return _allowances[_owner][erc20Idx][spender];
    }

    function _approveERC20(
        address _owner,
        ERC20Idx erc20Idx,
        address spender,
        uint256 amount
    ) internal {
        spender = FsUtils.nonNull(spender);

        _allowances[_owner][erc20Idx][spender] = amount;
        emit ERC20Approval(erc20Idx, _owner, spender, amount);
    }

    function _approveERC721(address collection, address to, uint256 tokenId) internal {
        _tokenApprovals[collection][tokenId] = to;
        emit ERC721Approval(collection, owner, to, tokenId);
    }

    function _spendAllowance(
        ERC20Idx erc20Idx,
        address _owner,
        address spender,
        uint256 amount
    ) internal {
        uint256 currentAllowance = allowance(erc20Idx, _owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance();
            }
            unchecked {
                _approveERC20(_owner, erc20Idx, spender, currentAllowance - amount);
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

    function transferERC20(ERC20Idx erc20Idx, address from, address to, int256 amount) internal {
        updateBalance(erc20Idx, from, -amount);
        updateBalance(erc20Idx, to, amount);
    }

    function transferNFT(uint256 nftId, address from, address to) internal {
        uint256 strippedNFTId = portfolios[from].extractNFT(NFTId.wrap(nftId));
        portfolios[to].insertNFT(strippedNFTId);
    }

    // TODO @derek - add method for withdraw

    function transferAllERC20(ERC20Idx erc20Idx, address from, address to) internal {
        int256 amount = clearBalance(erc20Idx, from);
        updateBalance(erc20Idx, to, amount);
    }

    function updateBalance(ERC20Idx erc20Idx, address portfolioAddress, int256 amount) internal {
        updateInterest(erc20Idx);
        Portfolio storage portfolio = portfolios[portfolioAddress];
        ERC20Share shares = portfolio.erc20Share[erc20Idx];
        ERC20Info storage erc20Info = getERC20Info(erc20Idx);
        int256 currentAmount = extractPosition(shares, erc20Info);
        int256 newAmount = currentAmount + amount;
        portfolio.erc20Share[erc20Idx] = insertPosition(newAmount, portfolio, erc20Idx);
    }

    function clearBalance(ERC20Idx erc20Idx, address portfolioAddress) internal returns (int256) {
        updateInterest(erc20Idx);
        Portfolio storage portfolio = portfolios[portfolioAddress];
        ERC20Share shares = portfolio.erc20Share[erc20Idx];
        int256 erc20Amount = extractPosition(shares, getERC20Info(erc20Idx));
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
        ERC20Idx erc20Idx
    ) internal returns (ERC20Share) {
        if (amount == 0) {
            portfolio.clearMask(erc20Idx);
        } else {
            portfolio.setMask(erc20Idx);
        }
        ERC20Info storage erc20Info = getERC20Info(erc20Idx);
        ERC20Pool storage pool = amount > 0 ? erc20Info.collateral : erc20Info.debt;
        return pool.insertPosition(amount);
    }

    function updateInterest(ERC20Idx erc20Idx) internal {
        ERC20Info storage p = getERC20Info(erc20Idx);
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

    /*
    function _isApprovedOrOwner(
        address spender,
        address collection,
        uint256 tokenId
    ) internal view returns (bool) {
        Portfolio storage p = portfolios[msg.sender];
        bool isDepositNFTOwner = p.nftPortfolioIdxs[collection][tokenId] != 0;
        return (isDepositNFTOwner ||
            getApproved(collection, tokenId) == spender ||
            isApprovedForAll(collection, owner, spender));
    }*/

    function getBalance(ERC20Share shares, ERC20Info storage p) internal view returns (int256) {
        ERC20Pool storage s = ERC20Share.unwrap(shares) > 0 ? p.collateral : p.debt;
        return s.computeERC20(shares);
    }

    function getERC20Info(ERC20Idx erc20Idx) internal view returns (ERC20Info storage) {
        return erc20Infos[ERC20Idx.unwrap(erc20Idx)];
    }
}
