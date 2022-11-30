import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import {
  DOS,
  DOS__factory,
  PortfolioLogic__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
  PortfolioLogic,
  TestNFT,
  MockNFTOracle,
  TestERC20,
  WETH9,
  UniV3Oracle__factory,
  VersionManager__factory,
} from "../../typechain-types";
import { toWei, toWeiUsdc } from "../../lib/Numbers";
import { getEventParams } from "../../lib/Events";
import { BigNumber, Signer, ContractTransaction, BigNumberish } from "ethers";
import { Chainlink, cleanResult, makeCall } from "../../lib/Calls";
import { deployUniswapFactory, deployUniswapPool } from "../../lib/deploy_uniswap";

const USDC_PRICE = 1;
const ETH_PRICE = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

describe("DOS swap integration", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployDOSFixture() {
    const [owner, user, user2, user3] = await getFixedGasSigners(10_000_000);

    let usdc;
    let weth;

    do {
      weth = await new WETH9__factory(owner).deploy();
      usdc = await new TestERC20__factory(owner).deploy(
        "USD Coin",
        "USDC",
        USDC_DECIMALS, // 6
      );
    } while (BigInt(weth.address) >= BigInt(usdc.address));

    const usdcChainlink = await Chainlink.deploy(
      owner,
      USDC_PRICE,
      8,
      USDC_DECIMALS,
      USDC_DECIMALS,
    );
    const ethChainlink = await Chainlink.deploy(owner, ETH_PRICE, 8, USDC_DECIMALS, WETH_DECIMALS);

    const versionManager = await new VersionManager__factory(owner).deploy(owner.address);
    const dos = await new DOS__factory(owner).deploy(owner.address, versionManager.address);
    const proxyLogic = await new PortfolioLogic__factory(owner).deploy(dos.address);
    await versionManager.addVersion("1.0.0", 2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    await dos.setConfig({
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    await dos.addERC20Asset(
      usdc.address,
      "USD Coin",
      "USDC",
      USDC_DECIMALS,
      usdcChainlink.assetOracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // No interest which would include time sensitive calculations
    );
    const usdcAssetIdx = 0; // index of the element created above in DOS.assetsInfo array

    await dos.addERC20Asset(
      weth.address,
      "Wrapped ETH",
      "WETH",
      WETH_DECIMALS,
      ethChainlink.assetOracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // No interest which would include time sensitive calculations
    );
    const wethAssetIdx = 1; // index of the element created above in DOS.assetsInfo array

    const { uniswapFactory, uniswapNFTManager } = await deployUniswapFactory(weth.address, owner);

    const uniswapWethUsdc = await deployUniswapPool(
      uniswapFactory,
      weth.address,
      usdc.address,
      (ETH_PRICE * 10 ** USDC_DECIMALS) / 10 ** WETH_DECIMALS,
    );
    console.log(cleanResult(await uniswapWethUsdc.slot0()));
    const uniswapNftOracle = await new UniV3Oracle__factory(owner).deploy(
      uniswapFactory.address,
      uniswapNFTManager.address,
      owner.address,
    );

    await uniswapNftOracle.setAssetValueOracle(usdc.address, usdcChainlink.assetOracle.address);
    await uniswapNftOracle.setAssetValueOracle(weth.address, ethChainlink.assetOracle.address);

    await dos.addNftInfo(uniswapNFTManager.address, uniswapNftOracle.address, toWei(0.9));

    const ownerPortfolio = await createPortfolio(dos, owner);
    const usdcAmount = toWei(2000000, USDC_DECIMALS);
    const wethAmount = toWei(1000);

    await usdc.mint(ownerPortfolio.address, usdcAmount);
    await ownerPortfolio.executeBatch(
      [
        makeCall(weth, "deposit", [], toWei(1000) /* value */),
        makeCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(dos, "depositAsset", [usdcAssetIdx, usdcAmount]),
        makeCall(dos, "depositAsset", [wethAssetIdx, wethAmount]),
      ],
      { value: wethAmount },
    );

    return {
      owner,
      user,
      user2,
      user3, // default provided by hardhat users (signers)
      usdc,
      weth,
      usdcChainlink,
      ethChainlink,
      dos,
      usdcAssetIdx,
      wethAssetIdx,
      uniswapNFTManager,
    };
  }

  describe("Dos tests", () => {
    it.only("User can leverage LP", async () => {
      const { owner, user, dos, usdc, weth, usdcAssetIdx, wethAssetIdx, uniswapNFTManager } =
        await loadFixture(deployDOSFixture);

      const portfolio = await createPortfolio(dos, user);
      await usdc.mint(portfolio.address, toWei(1600, USDC_DECIMALS));

      const mintParams = {
        token0: weth.address,
        token1: usdc.address,
        fee: 500,
        tickLower: -210000,
        tickUpper: -190000,
        amount0Desired: toWei(1),
        amount1Desired: toWei(2000, USDC_DECIMALS),
        amount0Min: 0,
        amount1Min: 0,
        recipient: portfolio.address,
        deadline: ethers.constants.MaxUint256,
      };
      await portfolio.executeBatch([
        makeCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(usdc, "approve", [uniswapNFTManager.address, ethers.constants.MaxUint256]),
        makeCall(weth, "approve", [uniswapNFTManager.address, ethers.constants.MaxUint256]),
        makeCall(uniswapNFTManager, "setApprovalForAll", [dos.address, true]),
        makeCall(dos, "depositAsset", [usdcAssetIdx, -toWei(400, USDC_DECIMALS)]),
        makeCall(dos, "depositAsset", [wethAssetIdx, -toWei(1)]),
        makeCall(uniswapNFTManager, "mint", [mintParams]),
        makeCall(dos, "depositNft", [uniswapNFTManager.address, 1 /* tokenId */]),
        makeCall(dos, "depositFull", [[usdcAssetIdx, wethAssetIdx]]),
      ]);
    });
  });
});

async function createPortfolio(dos: DOS, signer: Signer) {
  const { portfolio } = await getEventParams(
    await dos.connect(signer).createPortfolio(),
    dos,
    "PortfolioCreated",
  );
  return PortfolioLogic__factory.connect(portfolio as string, signer);
}

async function depositAsset(
  dos: DOS,
  portfolio: PortfolioLogic,
  asset: TestERC20,
  assetIdx: number,
  amount: number | bigint,
) {
  await asset.mint(portfolio.address, amount);

  const depositTx = await portfolio.executeBatch([
    makeCall(asset, "approve", [dos.address, amount]),
    makeCall(dos, "depositAsset", [assetIdx, amount]),
  ]);
  await depositTx.wait();
}

async function depositNft(
  dos: DOS,
  portfolio: PortfolioLogic,
  nft: TestNFT,
  priceOracle: MockNFTOracle,
  price: number,
): Promise<BigNumber> {
  const mintTx = await nft.mint(portfolio.address);
  const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
  const tokenId = mintEventArgs[0] as BigNumber;
  await priceOracle.setPrice(tokenId, toWeiUsdc(price));
  const depositNftTx = await portfolio.executeBatch([
    makeCall(nft, "approve", [dos.address, tokenId]),
    makeCall(dos, "depositNft", [nft.address, tokenId]),
  ]);
  await depositNftTx.wait();
  return tokenId;
}

// special case of depositNft function above.
// Used only in one test to show that this scenario is supported.
// In depositNft the NFT is minted to the portfolio and transferred from the
//   portfolio to DOS.
// In depositUserNft, nft is minted to the user and transferred from the user
//   to DOS
async function depositUserNft(
  dos: DOS,
  portfolio: PortfolioLogic,
  nft: TestNFT,
  priceOracle: MockNFTOracle,
  price: number,
): Promise<BigNumber> {
  const user = portfolio.signer;
  const mintTx = await nft.mint(await user.getAddress());
  const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
  const tokenId = mintEventArgs[0] as BigNumber;
  await priceOracle.setPrice(tokenId, toWeiUsdc(price));
  await (await nft.connect(user).approve(dos.address, tokenId)).wait();
  const depositNftTx = await portfolio.executeBatch([
    makeCall(dos, "depositNft", [nft.address, tokenId]),
  ]);
  await depositNftTx.wait();
  return tokenId;
}

async function getBalances(
  dos: DOS,
  portfolio: PortfolioLogic,
): Promise<{
  nfts: [nftContract: string, tokenId: BigNumber][];
  usdc: BigNumber;
  weth: BigNumber;
}> {
  const [nfts, usdc, weth] = await Promise.all([
    dos.viewNfts(portfolio.address),
    dos.viewBalance(portfolio.address, 0),
    dos.viewBalance(portfolio.address, 1),
  ]);
  return { nfts, usdc, weth };
}

async function transfer(
  dos: DOS,
  from: PortfolioLogic,
  to: PortfolioLogic,
  ...value: [assetIdx: number, amount: BigNumberish] | [nft: TestNFT, tokenId: BigNumberish]
): Promise<ContractTransaction> {
  if (typeof value[0] == "number") {
    // transfer asset
    const [assetIdx, amount] = value;
    return from.executeBatch([makeCall(dos, "transfer", [assetIdx, to.address, amount])]);
  } else {
    // transfer NFT
    const [nft, tokenId] = value;
    return from.executeBatch([makeCall(dos, "sendNft", [nft.address, tokenId, to.address])]);
  }
}

// This fixes random tests crash with
// "contract call run out of gas and made the transaction revert" error
// and, as a side effect, speeds tests in 2-3 times!
// https://github.com/NomicFoundation/hardhat/issues/1721
export const getFixedGasSigners = async function (gasLimit: number) {
  const signers: SignerWithAddress[] = await ethers.getSigners();
  for (const signer of signers) {
    const orig = signer.sendTransaction;
    signer.sendTransaction = transaction => {
      transaction.gasLimit = BigNumber.from(gasLimit.toString());
      return orig.apply(signer, [transaction]);
    };
  }
  return signers;
};
