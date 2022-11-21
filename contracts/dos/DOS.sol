//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../lib/FsUtils.sol";
import "../lib/FsMath.sol";
import "../interfaces/IDOS.sol";
import "../interfaces/IAssetValueOracle.sol";
import "../interfaces/INFTValueOracle.sol";
import "./PortfolioProxy.sol";
import "../dosERC20/DOSERC20.sol";

type AssetIdx is uint16;
type AssetShare is int256;

struct NFT {
    address nftContract;
    uint256 tokenId;
}

struct Balance {
    AssetShare shares;
    int256 fixedBalance;
}

struct Portfolio {
    address owner;
    mapping(AssetIdx => AssetShare) assetShares;
    NFT[] nfts;
    // nftPortfolioIdx is actually index + 1, in order to distinguish
    // default 0 value (no element) from the first element of the nfts array
    mapping(address => mapping(uint256 => uint256)) nftPortfolioIdxs;
    uint256[1] bitmask; // This can grow on updates
}

struct Shares {
    int256 totalAsset;
    int256 totalShares;
}

library PortfolioLib {
    function getAssets(Portfolio storage p) internal view returns (AssetIdx[] memory assets) {
        uint256 numAssets = 0;
        for (uint256 i = 0; i < p.bitmask.length; i++) {
            numAssets += FsMath.bitCount(p.bitmask[i]);
        }
        assets = new AssetIdx[](numAssets);
        uint256 idx = 0;
        for (uint256 i = 0; i < p.bitmask.length; i++) {
            uint256 mask = p.bitmask[i];
            for (uint256 j = 0; j < 256; j++) {
                uint256 x = mask >> j;
                if (x == 0) break;
                if ((x & 1) != 0) {
                    assets[idx++] = AssetIdx.wrap(uint16(i * 256 + j));
                }
            }
        }
    }

    function clearMask(Portfolio storage p, AssetIdx assetIdx) internal {
        uint16 idx = AssetIdx.unwrap(assetIdx);
        p.bitmask[idx >> 8] &= ~(1 << (idx & 255));
    }

    function setMask(Portfolio storage p, AssetIdx assetIdx) internal {
        uint16 idx = AssetIdx.unwrap(assetIdx);
        p.bitmask[idx >> 8] |= (1 << (idx & 255));
    }

    function extractPosition(
        Shares storage balance,
        AssetShare sharesAmount
    ) internal returns (int256 assetAmount) {
        assetAmount = computeAsset(balance, sharesAmount);
        balance.totalAsset -= assetAmount;
        balance.totalShares -= AssetShare.unwrap(sharesAmount);
    }

    function insertPosition(
        Shares storage balance,
        int256 assetAmount
    ) internal returns (AssetShare) {
        int256 sharesAmount;
        if (balance.totalShares == 0) {
            FsUtils.Assert(balance.totalAsset == 0);
            sharesAmount = assetAmount;
        } else {
            sharesAmount = (balance.totalShares * assetAmount) / balance.totalAsset;
        }
        balance.totalAsset += assetAmount;
        balance.totalShares += sharesAmount;
        return AssetShare.wrap(sharesAmount);
    }

    function extractNft(
        Portfolio storage p,
        uint256 nftPortfolioIdx
    ) internal returns (NFT memory) {
        FsUtils.Assert(nftPortfolioIdx < p.nfts.length);
        NFT memory extractedNft = p.nfts[nftPortfolioIdx];

        if (nftPortfolioIdx == p.nfts.length - 1) {
            p.nfts.pop();
        } else {
            p.nfts[nftPortfolioIdx] = p.nfts[p.nfts.length - 1];
            p.nfts.pop();

            NFT storage movedNft = p.nfts[nftPortfolioIdx];
            // `+ 1` below is to avoid setting 0 "no value" for an actual member of p.nfts array
            p.nftPortfolioIdxs[movedNft.nftContract][movedNft.tokenId] = nftPortfolioIdx + 1;
        }
        delete p.nftPortfolioIdxs[extractedNft.nftContract][extractedNft.tokenId];

        return extractedNft;
    }

    function insertNft(Portfolio storage p, NFT memory nft) internal {
        FsUtils.Assert(p.nftPortfolioIdxs[nft.nftContract][nft.tokenId] == 0);
        p.nfts.push(nft);
        // note below, the value is `length` i.e. `index + 1` - not `index`.
        // It is to avoid setting 0 "no value" for an actual member of p.nfts array
        p.nftPortfolioIdxs[nft.nftContract][nft.tokenId] = p.nfts.length;
    }

    function computeAsset(
        Shares storage balance,
        AssetShare sharesAmountWrapped
    ) internal view returns (int256 assetAmount) {
        int256 sharesAmount = AssetShare.unwrap(sharesAmountWrapped);
        if (sharesAmount == 0) return 0;
        FsUtils.Assert(balance.totalShares != 0);
        return (balance.totalAsset * sharesAmount) / balance.totalShares;
    }
}

contract DOS is IDOS, ImmutableOwnable, IERC721Receiver {
    address public portfolioLogic;

    using PortfolioLib for Portfolio;
    using PortfolioLib for Shares;
    using SafeERC20 for IERC20;

    // We will initialize the system so that assetIdx 0 is the base currency
    // in which the system calculates value.
    AssetIdx constant kNumeraireIdx = AssetIdx.wrap(0);

    mapping(address => Portfolio) portfolios;

    struct ERC20Info {
        address assetContract;
        address dosContract;
        IAssetValueOracle valueOracle;
        Shares collateral;
        Shares debt;
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

    ERC20Info[] public assetInfos;
    mapping(address => NFTInfo) public nftInfos;
    Config public config;

    constructor(address governance) ImmutableOwnable(governance) {
        portfolioLogic = address(new PortfolioLogic(address(this)));
    }

    function getImplementation() external view override returns (address) {
        return portfolioLogic;
    }

    function isSolvent(address portfolio) public view returns (bool) {
        // todo track each asset on-change instead of iterating over all DOS stuff
        int256 leverage = config.fractionalReserveLeverage;
        for (uint256 i = 0; i < assetInfos.length; i++) {
            int256 totalDebt = assetInfos[i].debt.totalAsset;
            int256 reserve = assetInfos[i].collateral.totalAsset + totalDebt;
            FsUtils.Assert(
                IERC20(assetInfos[i].assetContract).balanceOf(address(this)) >= uint256(reserve)
            );
            // FsUtils.Log("reserve", reserve);
            // FsUtils.Log("debt", totalDebt);
            require(reserve >= -totalDebt / leverage, "Not enough reserve for debt");
        }
        (, int256 collateral, int256 debt) = computePosition(portfolio);
        return collateral >= debt;
    }

    function getMaximumWithdrawableOfAsset(uint256 i) public view returns (int256) {
        int256 leverage = config.fractionalReserveLeverage;
        int256 totalAsset = assetInfos[i].collateral.totalAsset;

        int256 minReserveAmount = totalAsset / (leverage + 1);
        int256 totalDebt = assetInfos[i].debt.totalAsset;
        int256 borrowable = assetInfos[i].collateral.totalAsset - minReserveAmount;

        int256 remainingAssetToBorrow = borrowable + totalDebt;

        return remainingAssetToBorrow;
    }

    function computePosition(
        address portfolio
    )
        public
        view
        portfolioExists(portfolio)
        returns (int256 totalValue, int256 collateral, int256 debt)
    {
        Portfolio storage p = portfolios[portfolio];
        AssetIdx[] memory assetIndices = p.getAssets();
        totalValue = 0;
        collateral = 0;
        debt = 0;
        for (uint256 i = 0; i < assetIndices.length; i++) {
            AssetIdx assetIdx = assetIndices[i];
            ERC20Info storage assetInfo = getERC20Info(assetIdx);
            int256 balance = getBalance(p.assetShares[assetIdx], assetInfo);
            int256 value = assetInfo.valueOracle.calcValue(balance);
            totalValue += value;
            if (balance >= 0) {
                collateral += (value * assetInfo.collateralFactor) / 1 ether;
            } else {
                debt += (-value * 1 ether) / assetInfo.borrowFactor;
            }
        }
        for (uint256 i = 0; i < p.nfts.length; i++) {
            NFT storage nft = p.nfts[i];
            NFTInfo storage nftInfo = nftInfos[nft.nftContract];
            int256 nftValue = int256(nftInfo.valueOracle.calcValue(nft.tokenId));
            totalValue += nftValue;
            collateral += (nftValue * nftInfo.collateralFactor) / 1 ether;
        }
    }

    function depositAsset(AssetIdx assetIdx, int256 amount) external onlyPortfolio {
        IERC20 erc20 = IERC20(getERC20Info(assetIdx).assetContract);
        if (amount > 0) {
            erc20.safeTransferFrom(msg.sender, address(this), uint256(amount));
            updateBalance(assetIdx, msg.sender, amount);
        } else {
            erc20.safeTransfer(msg.sender, uint256(-amount));
            updateBalance(assetIdx, msg.sender, amount);
        }
    }

    // TODO @derek - add method for withdraw

    function depositNft(
        address nftContract,
        uint256 tokenId
    )
        external
        onlyPortfolio
        onlyRegisteredNft(nftContract, tokenId)
        onlyNftOwner(nftContract, tokenId)
    {
        address owner = ERC721(nftContract).ownerOf(tokenId);
        ERC721(nftContract).safeTransferFrom(owner, address(this), tokenId);

        Portfolio storage p = portfolios[msg.sender];
        p.insertNft(NFT(nftContract, tokenId));
    }

    function depositDosAsset(AssetIdx assetIdx, int256 amount) external onlyPortfolio {
        ERC20Info storage assetInfo = getERC20Info(assetIdx);
        IDOSERC20 erc20 = IDOSERC20(assetInfo.dosContract);
        if (amount > 0) {
            erc20.burn(msg.sender, uint256(amount));
            updateBalance(assetIdx, msg.sender, amount);
        } else {
            erc20.mint(msg.sender, uint256(-amount));
            updateBalance(assetIdx, msg.sender, amount);
        }
    }

    function claim(AssetIdx assetIdx, uint256 amount) external onlyPortfolio {
        ERC20Info storage assetInfo = getERC20Info(assetIdx);
        IDOSERC20(assetInfo.dosContract).burn(msg.sender, amount);
        IERC20(assetInfo.assetContract).safeTransfer(msg.sender, amount);
        // TODO: require appropriate reserve
    }

    function claimNft(
        address nftContract,
        uint256 tokenId
    ) external onlyPortfolio onlyDepositNftOwner(nftContract, tokenId) {
        ERC721(nftContract).safeTransferFrom(address(this), msg.sender, tokenId);

        Portfolio storage p = portfolios[msg.sender];
        uint256 nftPortfolioIdx = p.nftPortfolioIdxs[nftContract][tokenId] - 1;
        p.extractNft(nftPortfolioIdx);
    }

    function transfer(
        AssetIdx asset,
        address to,
        uint256 amount
    ) external onlyPortfolio portfolioExists(to) {
        if (amount == 0) return;
        transferAsset(asset, msg.sender, to, FsMath.safeCastToSigned(amount));
    }

    function sendNft(
        address nftContract,
        uint256 tokenId,
        address to
    ) external onlyPortfolio onlyDepositNftOwner(nftContract, tokenId) portfolioExists(to) {
        Portfolio storage p = portfolios[msg.sender];
        uint256 nftPortfolioIdx = p.nftPortfolioIdxs[nftContract][tokenId] - 1;
        transferNft(nftPortfolioIdx, msg.sender, to);
    }

    function transferAsset(AssetIdx assetIdx, address from, address to, int256 amount) internal {
        updateBalance(assetIdx, from, -amount);
        updateBalance(assetIdx, to, amount);
    }

    function transferNft(uint256 nftPortfolioIdx, address from, address to) internal {
        NFT memory nft = portfolios[from].extractNft(nftPortfolioIdx);
        portfolios[to].insertNft(nft);
    }

    function transferAllAsset(AssetIdx assetIdx, address from, address to) internal {
        int256 amount = clearBalance(assetIdx, from);
        updateBalance(assetIdx, to, amount);
    }

    function updateBalance(AssetIdx assetIdx, address acct, int256 amount) internal {
        updateInterest(assetIdx);
        Portfolio storage p = portfolios[acct];
        AssetShare shares = p.assetShares[assetIdx];
        ERC20Info storage assetInfo = getERC20Info(assetIdx);
        int256 asset = extractPosition(shares, assetInfo);
        asset += amount;
        p.assetShares[assetIdx] = insertPosition(asset, assetInfo, portfolios[acct], assetIdx);
    }

    function clearBalance(AssetIdx assetIdx, address acct) internal returns (int256) {
        updateInterest(assetIdx);
        Portfolio storage p = portfolios[acct];
        AssetShare shares = p.assetShares[assetIdx];
        int256 asset = extractPosition(shares, getERC20Info(assetIdx));
        p.assetShares[assetIdx] = AssetShare.wrap(0);
        portfolios[acct].clearMask(assetIdx);
        return asset;
    }

    function liquidate(address portfolio) external onlyPortfolio portfolioExists(portfolio) {
        (int256 totalValue, int256 collateral, int256 debt) = computePosition(portfolio);
        require(collateral < debt, "Portfolio is not liquidatable");
        AssetIdx[] memory portfolioAssets = portfolios[portfolio].getAssets();
        for (uint256 i = 0; i < portfolioAssets.length; i++) {
            AssetIdx assetIdx = portfolioAssets[i];
            transferAllAsset(assetIdx, portfolio, msg.sender);
        }
        if (portfolios[portfolio].nfts.length > 0) {
            // traversing nfts array backwards because transferNft modifies it (extracting elements)
            for (uint256 i = portfolios[portfolio].nfts.length - 1; i >= 0; i--) {
                transferNft(i, portfolio, msg.sender);
            }
        }
        // TODO(gerben) make formula dependent on risk
        if (totalValue > 0) {
            int256 amount = (totalValue * config.liqFraction) / 1 ether;
            transferAsset(kNumeraireIdx, msg.sender, portfolio, amount);
        }
    }

    function setPortfolioLogic(address _portfolioLogic) external onlyOwner {
        portfolioLogic = FsUtils.nonNull(_portfolioLogic);
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

    event ERC20Added(
        AssetIdx assetIdx,
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

    function addERC20Asset(
        address erc20,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address valueOracle,
        int256 colFactor,
        int256 borrowFactor,
        int256 interest
    ) external onlyOwner returns (AssetIdx) {
        AssetIdx assetIdx = AssetIdx.wrap(uint16(assetInfos.length));
        DOSERC20 dosToken = new DOSERC20(name, symbol, decimals);
        assetInfos.push(
            ERC20Info(
                erc20,
                address(dosToken),
                IAssetValueOracle(valueOracle),
                Shares(0, 0),
                Shares(0, 0),
                colFactor,
                borrowFactor,
                interest,
                block.timestamp
            )
        );
        emit ERC20Added(
            assetIdx,
            erc20,
            address(dosToken),
            name,
            symbol,
            decimals,
            valueOracle,
            colFactor,
            borrowFactor,
            interest
        );
        return assetIdx;
    }

    function addNftInfo(
        address nftContract,
        address valueOracleAddress,
        int256 collateralFactor
    ) external onlyOwner {
        INFTValueOracle valueOracle = INFTValueOracle(valueOracleAddress);
        NFTInfo memory nftInfo = NFTInfo(true, valueOracle, collateralFactor);
        nftInfos[nftContract] = nftInfo;
    }

    function extractPosition(AssetShare shares, ERC20Info storage p) internal returns (int256) {
        Shares storage s = AssetShare.unwrap(shares) > 0 ? p.collateral : p.debt;
        return s.extractPosition(shares);
    }

    function insertPosition(
        int256 amount,
        ERC20Info storage p,
        Portfolio storage b,
        AssetIdx idx
    ) internal returns (AssetShare) {
        if (amount == 0) {
            b.clearMask(idx);
        } else {
            b.setMask(idx);
        }
        Shares storage s = amount > 0 ? p.collateral : p.debt;
        return s.insertPosition(amount);
    }

    function getBalance(AssetShare shares, ERC20Info storage p) internal view returns (int256) {
        Shares storage s = AssetShare.unwrap(shares) > 0 ? p.collateral : p.debt;
        return s.computeAsset(shares);
    }

    function updateInterest(AssetIdx assetIdx) internal {
        ERC20Info storage p = getERC20Info(assetIdx);
        if (p.timestamp == block.timestamp) return;
        int256 delta = FsMath.safeCastToSigned(block.timestamp - p.timestamp);
        p.timestamp = block.timestamp;
        int256 debt = -p.debt.totalAsset;
        int256 interest = (debt * (FsMath.exp(p.interest * delta) - FsMath.FIXED_POINT_SCALE)) /
            FsMath.FIXED_POINT_SCALE;
        p.debt.totalAsset -= interest;
        p.collateral.totalAsset += interest;
        // TODO(gerben) add to treasury
    }

    function getPortfolioOwner(address portfolio) external view override returns (address) {
        return portfolios[portfolio].owner;
    }

    event PortfolioCreated(address portfolio, address owner);

    function createPortfolio() external returns (address portfolio) {
        portfolio = address(new PortfolioProxy(address(this)));
        portfolios[portfolio].owner = msg.sender;
        emit PortfolioCreated(portfolio, msg.sender);
    }

    modifier onlyPortfolio() {
        require(portfolios[msg.sender].owner != address(0), "Only portfolio can execute");
        _;
    }

    modifier portfolioExists(address portfolio) {
        require(portfolios[portfolio].owner != address(0), "Recipient portfolio doesn't exist");
        _;
    }

    modifier onlyRegisteredNft(address nftContract, uint256 tokenId) {
        // how can we be sure that Oracle would have a price for any possible tokenId?
        // maybe we should check first if Oracle can return a value for this specific NFT?
        require(nftInfos[nftContract].exists, "Cannot add NFT of unknown NFT contract");
        _;
    }

    modifier onlyNftOwner(address nftContract, uint256 tokenId) {
        address owner = ERC721(nftContract).ownerOf(tokenId);
        bool isOwner = owner == msg.sender || owner == portfolios[msg.sender].owner;
        require(isOwner, "NFT must be owned the the user or user's portfolio");
        _;
    }

    modifier onlyDepositNftOwner(address nftContract, uint256 tokenId) {
        Portfolio storage p = portfolios[msg.sender];
        bool isDepositNftOwner = p.nftPortfolioIdxs[nftContract][tokenId] != 0;
        require(isDepositNftOwner, "NFT must be on the user's deposit");
        _;
    }

    function getERC20Info(AssetIdx assetIdx) internal view returns (ERC20Info storage p) {
        return assetInfos[AssetIdx.unwrap(assetIdx)];
    }

    function setConfig(Config calldata _config) external onlyOwner {
        config = _config;
    }

    function viewBalance(address portfolio, AssetIdx assetIdx) external view returns (int256) {
        // TODO(gerben) interest computation
        Portfolio storage p = portfolios[portfolio];
        AssetShare assetShares = p.assetShares[assetIdx];
        return getBalance(assetShares, getERC20Info(assetIdx));
    }

    function viewNfts(address portfolio) external view returns (NFT[] memory) {
        return portfolios[portfolio].nfts;
    }

    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes memory /* data */
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
