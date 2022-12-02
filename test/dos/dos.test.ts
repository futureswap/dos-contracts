import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import {
  DOS,
  DOS__factory,
  PortfolioLogic__factory,
  VersionManager__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
  PortfolioLogic,
  TestNFT,
  MockNFTOracle,
  TestERC20,
  WETH9,
} from "../../typechain-types";
import { toWei, toWeiUsdc } from "../../lib/Numbers";
import { getEventParams } from "../../lib/Events";
import { BigNumber, Signer, ContractTransaction, BigNumberish } from "ethers";
import { Chainlink, makeCall } from "../../lib/Calls";

const USDC_PRICE = 1;
const ETH_PRICE = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

const NFT_PRICE = 200;

const tenThousandUsdc = toWeiUsdc(10_000);
const oneEth = toWei(1);

describe("DOS", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployDOSFixture() {
    const [owner, user, user2, user3] = await getFixedGasSigners(10_000_000);

    const usdc = await new TestERC20__factory(owner).deploy(
      "USD Coin",
      "USDC",
      USDC_DECIMALS, // 6
    );

    const weth = await new WETH9__factory(owner).deploy();
    const nft = await new TestNFT__factory(owner).deploy("Test NFT1", "NF1", 100);
    const unregisteredNft = await new TestNFT__factory(owner).deploy("Test NFT2", "NF2", 200);

    const usdcChainlink = await Chainlink.deploy(
      owner,
      USDC_PRICE,
      8,
      USDC_DECIMALS,
      USDC_DECIMALS,
    );
    const ethChainlink = await Chainlink.deploy(owner, ETH_PRICE, 8, USDC_DECIMALS, WETH_DECIMALS);

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    const versionManager = await new VersionManager__factory(owner).deploy();
    const dos = await new DOS__factory(owner).deploy(owner.address, versionManager.address);
    const portfolioLogic = await new PortfolioLogic__factory(owner).deploy(dos.address);
    await (
      await versionManager.addVersion("defaultVersionForTests", 2, portfolioLogic.address)
    ).wait();
    await (await versionManager.markRecommendedVersion("defaultVersionForTests")).wait();

    // const DosDeployData = await ethers.getContractFactory("DOS");
    // const dos = await DosDeployData.deploy(unlockTime, { value: lockedAmount });

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

    await dos.addNftInfo(nft.address, nftOracle.address, toWei(0.5));

    return {
      owner,
      user,
      user2,
      user3, // default provided by hardhat users (signers)
      usdc,
      weth,
      usdcChainlink,
      ethChainlink,
      nft,
      nftOracle, // some registered nft
      unregisteredNft, // some unregistered nft
      dos,
      usdcAssetIdx,
      wethAssetIdx,
    };
  }

  describe("Dos tests", () => {
    it("User can create portfolio", async () => {
      const { user, dos } = await loadFixture(deployDOSFixture);

      const portfolio = await CreatePortfolio(dos, user);
      expect(await portfolio.owner()).to.equal(user.address);
    });

    it("User can deposit money", async () => {
      const { user, dos, usdc, usdcAssetIdx } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      await depositAsset(dos, portfolio, usdc, usdcAssetIdx, tenThousandUsdc);

      expect((await getBalances(dos, portfolio)).usdc).to.equal(tenThousandUsdc);
      expect(await usdc.balanceOf(dos.address)).to.equal(tenThousandUsdc);
    });

    it("User can transfer money", async () => {
      const { user, user2, dos, usdc, usdcAssetIdx } = await loadFixture(deployDOSFixture);
      const sender = await CreatePortfolio(dos, user);
      const receiver = await CreatePortfolio(dos, user2);
      await depositAsset(dos, sender, usdc, usdcAssetIdx, tenThousandUsdc);

      const tx = transfer(dos, sender, receiver, usdcAssetIdx, tenThousandUsdc);
      await (await tx).wait();

      expect((await getBalances(dos, sender)).usdc).to.equal(0);
      expect((await getBalances(dos, receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User can deposit and transfer money in arbitrary order", async () => {
      const { user, user2, dos, usdc, usdcAssetIdx } = await loadFixture(deployDOSFixture);
      const sender = await CreatePortfolio(dos, user);
      const receiver = await CreatePortfolio(dos, user2);
      await usdc.mint(sender.address, tenThousandUsdc);

      await sender.executeBatch([
        makeCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(dos, "transfer", [usdcAssetIdx, receiver.address, tenThousandUsdc]),
        makeCall(dos, "depositAsset", [usdcAssetIdx, tenThousandUsdc]),
      ]);

      expect((await getBalances(dos, sender)).usdc).to.equal(0);
      expect((await getBalances(dos, receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User cannot send more then they own", async () => {
      const { user, user2, dos, usdc, usdcAssetIdx } = await loadFixture(deployDOSFixture);
      const sender = await CreatePortfolio(dos, user);
      const receiver = await CreatePortfolio(dos, user2);
      await depositAsset(dos, sender, usdc, usdcAssetIdx, toWeiUsdc(10_000));

      const tx = transfer(dos, sender, receiver, usdcAssetIdx, toWeiUsdc(20_000));

      await expect(tx).to.be.revertedWith("Result of operation is not sufficient liquid");
    });

    it("User can send more asset then they have", async () => {
      const { user, user2, dos, usdc, weth, wethAssetIdx, usdcAssetIdx } = await loadFixture(
        deployDOSFixture,
      );
      const sender = await CreatePortfolio(dos, user);
      await depositAsset(dos, sender, usdc, usdcAssetIdx, tenThousandUsdc);
      const receiver = await CreatePortfolio(dos, user2);
      // Put weth in system so we can borrow weth
      const someOther = await CreatePortfolio(dos, user);
      await depositAsset(dos, someOther, weth, wethAssetIdx, toWei(2));

      const tx = await transfer(dos, sender, receiver, wethAssetIdx, oneEth);
      await tx.wait();

      const senderBalances = await getBalances(dos, sender);
      const receiverBalances = await getBalances(dos, receiver);
      expect(senderBalances.usdc).to.equal(tenThousandUsdc);
      expect(senderBalances.weth).to.equal(-oneEth);
      expect(receiverBalances.usdc).to.equal(0);
      expect(receiverBalances.weth).to.equal(oneEth);
    });

    it("Non-solvent position can be liquidated", async () => {
      // prettier-ignore
      const {
        user, user2,
        dos,
        usdc, usdcAssetIdx,
        weth, wethAssetIdx,
        ethChainlink,
      } = await loadFixture(deployDOSFixture);
      const liquidatable = await CreatePortfolio(dos, user);
      await depositAsset(dos, liquidatable, usdc, usdcAssetIdx, tenThousandUsdc);
      const liquidator = await CreatePortfolio(dos, user2);
      // ensure that liquidator would have enough collateral to compensate
      // negative balance of collateral/debt obtained from liquidatable
      await depositAsset(dos, liquidator, usdc, usdcAssetIdx, tenThousandUsdc);
      // Put WETH in system so we can borrow weth
      const someOther = await CreatePortfolio(dos, user);
      await depositAsset(dos, someOther, weth, wethAssetIdx, toWei(2));
      await ethChainlink.setPrice(2_000);

      // generate a debt on liquidatable
      const tx = transfer(dos, liquidatable, someOther, wethAssetIdx, oneEth);
      await (await tx).wait();
      // make liquidatable debt overcome collateral. Now it can be liquidated
      await ethChainlink.setPrice(9_000);
      await liquidator.executeBatch([makeCall(dos, "liquidate", [liquidatable.address])]);

      const liquidatableBalances = await getBalances(dos, liquidatable);
      const liquidatorBalances = await getBalances(dos, liquidator);
      // 10_000 - balance in USDC; 9_000 - debt of 1 ETH; 0.8 - liqFraction
      const liquidationOddMoney = toWei((10_000 - 9_000) * 0.8, USDC_DECIMALS); // 800 USDC in ETH
      expect(liquidatableBalances.weth).to.equal(0);
      expect(liquidatableBalances.usdc).to.be.approximately(liquidationOddMoney, 1000);
      expect(liquidatorBalances.weth).to.equal(-oneEth); // own 10k + 10k of liquidatable
      expect(liquidatorBalances.usdc).to.be.approximately(
        tenThousandUsdc + tenThousandUsdc - liquidationOddMoney,
        1000,
      );
    });

    it("Solvent position can not be liquidated", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2,
        usdc, usdcAssetIdx,
        weth, wethAssetIdx
      } = await loadFixture(
        deployDOSFixture,
      );
      const nonLiquidatable = await CreatePortfolio(dos, user);
      const liquidator = await CreatePortfolio(dos, user2);
      // Put WETH in system so we can borrow weth
      const other = await CreatePortfolio(dos, user);
      await depositAsset(dos, other, weth, wethAssetIdx, toWei(0.25));
      await depositAsset(dos, nonLiquidatable, usdc, usdcAssetIdx, tenThousandUsdc);
      const tx = transfer(dos, nonLiquidatable, other, wethAssetIdx, oneEth);
      await (await tx).wait();

      const liquidationTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [nonLiquidatable.address]),
      ]);

      await expect(liquidationTx).to.be.revertedWith("Portfolio is not liquidatable");
    });
  });

  describe("#computePosition", () => {
    it("when portfolio doesn't exist should return 0", async () => {
      const { dos } = await loadFixture(deployDOSFixture);
      const nonPortfolioAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const computeTx = dos.computePosition(nonPortfolioAddress);

      expect(computeTx).to.be.revertedWith("Recipient portfolio doesn't exist");
    });

    it("when portfolio is empty should return 0", async () => {
      const { dos, user } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      const [totalValue, collateral, debt] = await dos.computePosition(portfolio.address);

      expect(totalValue).to.equal(0);
      expect(collateral).to.equal(0);
      expect(debt).to.equal(0);
    });

    it("when portfolio has an asset should return the asset value", async () => {
      const { dos, user, usdc, usdcAssetIdx } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);
      await depositAsset(dos, portfolio, usdc, usdcAssetIdx, toWei(10_000, USDC_DECIMALS));

      const position = await dos.computePosition(portfolio.address);

      const [total, collateral, debt] = position;
      expect(total).to.be.approximately(await toWei(10_000, USDC_DECIMALS), 1000);
      // collateral factor is defined in setupDos, and it's 0.9
      expect(collateral).to.be.approximately(await toWei(9000, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("when portfolio has multiple assets should return total assets value", async () => {
      const { dos, user, usdc, weth, usdcAssetIdx, wethAssetIdx } = await loadFixture(
        deployDOSFixture,
      );
      const portfolio = await CreatePortfolio(dos, user);

      await Promise.all([
        depositAsset(dos, portfolio, usdc, usdcAssetIdx, toWeiUsdc(10_000)),
        depositAsset(dos, portfolio, weth, wethAssetIdx, toWei(1)),
      ]);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(await toWei(12_000, USDC_DECIMALS));
      // collateral factor is defined in setupDos, and it's 0.9. 12 * 0.9 = 10.8
      expect(collateral).to.be.approximately(await toWei(10_800, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("when portfolio has an NFT should return the NFT value", async () => {
      const { dos, user, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWeiUsdc(NFT_PRICE));
      // collateral factor is defined in setupDos, and it's 0.5
      expect(collateral).to.equal(toWeiUsdc(NFT_PRICE / 2));
      expect(debt).to.equal(0);
    });

    it("when portfolio has a few NFTs should return the total NFTs value", async () => {
      const { dos, user, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      await Promise.all([
        depositNft(dos, portfolio, nft, nftOracle, 1),
        depositNft(dos, portfolio, nft, nftOracle, 2),
        depositNft(dos, portfolio, nft, nftOracle, 3),
      ]);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWeiUsdc(6)); // 1 + 2 + 3
      // collateral factor is defined in setupDos, and it's 0.5
      expect(collateral).to.be.approximately(toWeiUsdc(3), 1000);
      expect(debt).to.equal(0);
    });

    it("when portfolio has assets and NFTs should return their total value", async () => {
      // prettier-ignore
      const {
        dos,
        user,
        usdc, usdcAssetIdx,
        weth, wethAssetIdx,
        nft, nftOracle
      } =
        await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      await Promise.all([
        depositNft(dos, portfolio, nft, nftOracle, 100),
        depositNft(dos, portfolio, nft, nftOracle, 200),
        depositNft(dos, portfolio, nft, nftOracle, 300),
        depositAsset(dos, portfolio, usdc, usdcAssetIdx, toWeiUsdc(10_000)),
        depositAsset(dos, portfolio, weth, wethAssetIdx, toWei(1)),
      ]);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWei(12_600, USDC_DECIMALS));
      // collateral factor is defined in setupDos,
      // and it's 0.5 for nft and 0.9 for assets.
      expect(collateral).to.be.approximately(toWei(12_000 * 0.9 + 600 * 0.5, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("tests with debt");
  });

  describe("#liquidate", () => {
    it("when called directly on DOS should revert", async () => {
      const { user, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);
      await depositNft(dos, portfolio, nft, nftOracle, 1600);

      const depositNftTx = dos.liquidate(portfolio.address);

      await expect(depositNftTx).to.be.revertedWith("Only portfolio can execute");
    });

    it("when portfolio to liquidate doesn't exist should revert", async () => {
      const { dos, user, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const liquidator = await CreatePortfolio(dos, user);
      await depositNft(dos, liquidator, nft, nftOracle, NFT_PRICE);
      const nonPortfolioAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const liquidateTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [nonPortfolioAddress]),
      ]);

      await expect(liquidateTx).to.be.revertedWith("Recipient portfolio doesn't exist");
    });

    it("when portfolio to liquidate is empty should revert", async () => {
      const { dos, user, user2, usdc, usdcAssetIdx } = await loadFixture(deployDOSFixture);
      const emptyPortfolio = await CreatePortfolio(dos, user);
      const liquidator = await CreatePortfolio(dos, user2);
      await depositAsset(dos, liquidator, usdc, usdcAssetIdx, toWeiUsdc(1000));

      const liquidateTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [emptyPortfolio.address]),
      ]);

      await expect(liquidateTx).to.be.revertedWith("Portfolio is not liquidatable");
    });

    it("when debt is zero should revert", async () => {
      const { dos, user, user2, usdc, usdcAssetIdx } = await loadFixture(deployDOSFixture);
      const nonLiquidatable = await CreatePortfolio(dos, user);
      await depositAsset(dos, nonLiquidatable, usdc, usdcAssetIdx, toWeiUsdc(1000));
      const liquidator = await CreatePortfolio(dos, user2);
      await depositAsset(dos, liquidator, usdc, usdcAssetIdx, toWeiUsdc(1000));

      const liquidateTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [nonLiquidatable.address]),
      ]);

      await expect(liquidateTx).to.be.revertedWith("Portfolio is not liquidatable");
    });

    it("when collateral is above some debt should revert", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc, usdcAssetIdx,
        weth, wethAssetIdx
      } = await loadFixture(
        deployDOSFixture
      );
      const nonLiquidatable = await CreatePortfolio(dos, user);
      await depositAsset(dos, nonLiquidatable, usdc, usdcAssetIdx, toWeiUsdc(1000));
      const liquidator = await CreatePortfolio(dos, user2);
      await depositAsset(dos, liquidator, usdc, usdcAssetIdx, toWeiUsdc(1000));
      const other = await CreatePortfolio(dos, user3);
      await depositAsset(dos, other, weth, wethAssetIdx, toWei(1));
      const tx = transfer(dos, nonLiquidatable, other, wethAssetIdx, toWei(0.1));
      await (await tx).wait();

      const liquidateTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [nonLiquidatable.address]),
      ]);

      await expect(liquidateTx).to.be.revertedWith("Portfolio is not liquidatable");
    });

    it("when liquidator doesn't have enough collateral to cover the debt difference should revert", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc, usdcAssetIdx,
        weth, wethAssetIdx,
        ethChainlink
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await CreatePortfolio(dos, user);
      await depositAsset(dos, liquidatable, usdc, usdcAssetIdx, toWeiUsdc(10_000));
      const liquidator = await CreatePortfolio(dos, user2);
      const other = await CreatePortfolio(dos, user3);
      await depositAsset(dos, other, weth, wethAssetIdx, toWei(10));
      const tx = transfer(dos, liquidatable, other, wethAssetIdx, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [liquidatable.address]),
      ]);

      await expect(liquidateTx).to.revertedWith("Result of operation is not sufficient liquid");
    });

    it("when a portfolio trys to liquidate itself should revert", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2,
        usdc, usdcAssetIdx,
        weth, wethAssetIdx,
        ethChainlink
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await CreatePortfolio(dos, user);
      await depositAsset(dos, liquidatable, usdc, usdcAssetIdx, toWeiUsdc(10_000));
      const other = await CreatePortfolio(dos, user2);
      await depositAsset(dos, other, weth, wethAssetIdx, toWei(10));
      const tx = transfer(dos, liquidatable, other, wethAssetIdx, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = liquidatable.executeBatch([
        makeCall(dos, "liquidate", [liquidatable.address]),
      ]);

      await expect(liquidateTx).to.revertedWith("Result of operation is not sufficient liquid");
    });

    it("when collateral is smaller then debt should transfer all assets of the portfolio to the caller", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc, usdcAssetIdx,
        weth, wethAssetIdx,
        ethChainlink
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await CreatePortfolio(dos, user);
      await depositAsset(dos, liquidatable, usdc, usdcAssetIdx, toWeiUsdc(10_000));
      const liquidator = await CreatePortfolio(dos, user2);
      await depositAsset(dos, liquidator, usdc, usdcAssetIdx, toWeiUsdc(10_000));
      const other = await CreatePortfolio(dos, user3);
      await depositAsset(dos, other, weth, wethAssetIdx, toWei(10));
      const tx = transfer(dos, liquidatable, other, wethAssetIdx, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = await liquidator.executeBatch([
        makeCall(dos, "liquidate", [liquidatable.address]),
      ]);
      await liquidateTx.wait();

      const liquidatableBalance = await getBalances(dos, liquidatable);
      // 10k - positive in USDC. 2_100 - current WETH price in USDC. 4 - debt
      const liquidatableTotal = 10_000 - 4 * 2_100;
      // 0.8 - liqFraction, defined in deployDOSFixture
      const liquidationOddMoney = toWei(liquidatableTotal * 0.8, USDC_DECIMALS);
      expect(liquidatableBalance.weth).to.equal(0);
      expect(liquidatableBalance.usdc).to.be.approximately(liquidationOddMoney, 2000);
      const liquidatorBalance = await getBalances(dos, liquidator);
      // 10k initial USDC, 10k liquidated USDC - returned money to liquidated account
      expect(liquidatorBalance.usdc).to.be.approximately(
        toWei(10_000 + 10_000 - liquidatableTotal * 0.8, USDC_DECIMALS),
        2000,
      );
      expect(liquidatorBalance.weth).to.equal(-toWei(4));
    });

    it("when collateral is smaller then debt should transfer all NFTs of the portfolio to the caller", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        nft, nftOracle,
        usdc, weth, usdcAssetIdx, wethAssetIdx
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await CreatePortfolio(dos, user);
      const tokenId = await depositNft(dos, liquidatable, nft, nftOracle, 2000);
      const liquidator = await CreatePortfolio(dos, user2);
      await depositAsset(dos, liquidator, usdc, usdcAssetIdx, toWeiUsdc(2000));
      const other = await CreatePortfolio(dos, user3);
      await depositAsset(dos, other, weth, wethAssetIdx, toWei(1));
      const tx = transfer(dos, liquidatable, other, wethAssetIdx, toWei(0.4));
      await (await tx).wait();

      // drop the price of the NFT from 2000 Eth to 1600 Eth. Now portfolio should become liquidatable
      await (await nftOracle.setPrice(tokenId, toWeiUsdc(1600))).wait();
      console.log("liq");
      const liquidateTx = await liquidator.executeBatch([
        makeCall(dos, "liquidate", [liquidatable.address]),
      ]);
      await liquidateTx.wait();

      const liquidatableBalance = await getBalances(dos, liquidatable);
      // 1600 - current price of the owned NFT. 0.4 eth - debt
      const liquidatableTotal = 1600 - 0.4 * 2000;
      // 0.8 - liqFraction, defined in deployDOSFixture
      const liquidationOddMoney = toWeiUsdc(liquidatableTotal * 0.8);
      expect(liquidatableBalance.usdc).to.be.approximately(liquidationOddMoney, 2000);
      expect(liquidatableBalance.weth).to.be.equal(0);
      expect(liquidatableBalance.nfts).to.eql([]);
      const liquidatorBalance = await getBalances(dos, liquidator);
      expect(liquidatorBalance.usdc).to.be.approximately(
        // 1 - initial balance; -0.4 transferred debt; 0.8 - liqFactor defined in deployDOSFixture
        toWeiUsdc(2000) - liquidationOddMoney,
        2000,
      );
      expect(liquidatorBalance.weth).to.be.approximately(
        // 1 - initial balance; -0.4 transferred debt; 0.8 - liqFactor defined in deployDOSFixture
        toWei(-0.4),
        2000,
      );
      expect(liquidatorBalance.nfts).to.eql([[nft.address, tokenId, BigNumber.from("1"), 0]]);
    });

    it("when collateral is smaller then debt should transfer all assets and all NFTs of the portfolio to the caller", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc, usdcAssetIdx,
        weth, wethAssetIdx,
        nft, nftOracle,
        ethChainlink,
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await CreatePortfolio(dos, user);
      const tokenId = await depositNft(dos, liquidatable, nft, nftOracle, 2000);
      await depositAsset(dos, liquidatable, usdc, usdcAssetIdx, toWeiUsdc(1_500));
      const liquidator = await CreatePortfolio(dos, user2);
      await depositAsset(dos, liquidator, weth, wethAssetIdx, toWei(1));
      const other = await CreatePortfolio(dos, user3);
      await depositAsset(dos, other, weth, wethAssetIdx, toWei(1));
      const tx = transfer(dos, liquidatable, other, wethAssetIdx, toWei(1));
      await (await tx).wait();

      // With Eth price 2,000 -> 2,500 the collateral (in USDC) would become
      // nft 2,500 * 0.5 + USDC 1,500 * 0.9 = 2,650
      // and the debt would become 2,500 / 0.9 = 2,777
      // So the debt would exceed the collateral and the portfolio becomes liquidatable
      await ethChainlink.setPrice(2_500);
      const liquidateTx = await liquidator.executeBatch([
        makeCall(dos, "liquidate", [liquidatable.address]),
      ]);
      await liquidateTx.wait();

      // 2_500 - NFT; 1_500 - USDC; 2_500 - debt; 2_500 - ETH price, so the result is in ETH
      const liquidatableTotal = 2_000 + 1_500 - 2_500;
      const liquidatableBalance = await getBalances(dos, liquidatable);
      expect(liquidatableBalance.weth).to.equal(0);
      // 0.8 - liqFraction, defined in deployDOSFixture
      expect(liquidatableBalance.usdc).to.be.approximately(
        toWeiUsdc(liquidatableTotal * 0.8),
        2000,
      );
      expect(liquidatableBalance.nfts).to.eql([]);
      const liquidatorBalance = await getBalances(dos, liquidator);
      expect(liquidatorBalance.usdc).to.equal(toWeiUsdc(1_500 - liquidatableTotal * 0.8));
      // 1 - initial balance; -1 transferred debt; 0.8 - liqFactor defined in deployDOSFixture
      expect(liquidatorBalance.weth).to.be.approximately(toWei(0), 2000);
      expect(liquidatorBalance.nfts).to.eql([[nft.address, tokenId, BigNumber.from("1"), 0]]);
    });
  });

  describe("#depositNft", () => {
    it(
      "when user owns the NFT " +
        "should change ownership of the NFT from the user to DOS " +
        "and add NFT to the user DOS portfolio",
      async () => {
        const { user, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
        const portfolio = await CreatePortfolio(dos, user);
        const tokenId = await depositUserNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

        expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
        const userNfts = await dos.viewNfts(portfolio.address);
        expect(userNfts).to.eql([[nft.address, tokenId, BigNumber.from("1"), 0]]);
      },
    );

    it(
      "when portfolio owns the NFT " +
        "should change ownership of the NFT from portfolio to DOS " +
        "and add NFT to the user DOS portfolio",
      async () => {
        const { user, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
        const portfolio = await CreatePortfolio(dos, user);

        const tokenId = await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

        expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
        const userNfts = await dos.viewNfts(portfolio.address);
        expect(userNfts).to.eql([[nft.address, tokenId, BigNumber.from("1"), 0]]);
      },
    );

    it("when NFT contract is not registered should revert the deposit", async () => {
      const { user, dos, unregisteredNft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      const txRevert = depositNft(dos, portfolio, unregisteredNft, nftOracle, NFT_PRICE);

      await expect(txRevert).to.be.revertedWith("Cannot add NFT of unknown NFT contract");
    });

    it("when user is not an owner of NFT should revert the deposit", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);
      const portfolio2 = await CreatePortfolio(dos, user2);
      const tokenId = await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

      const depositNftTx = portfolio2.executeBatch([
        makeCall(dos, "depositNft(address,uint256)", [nft.address, tokenId]),
      ]);

      await expect(depositNftTx).to.be.revertedWith(
        "NFT must be owned the the user or user's portfolio",
      );
    });

    it("when called directly on DOS should revert the deposit", async () => {
      const { user, dos, nft } = await loadFixture(deployDOSFixture);
      const mintTx = await nft.mint(user.address);
      const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
      const tokenId = mintEventArgs[0] as BigNumber;
      await (await nft.connect(user).approve(dos.address, tokenId)).wait();

      const depositNftTx = dos["depositNft(address,uint256)"](nft.address, tokenId);

      await expect(depositNftTx).to.be.revertedWith("Only portfolio can execute");
    });
  });

  describe("#claimNft", () => {
    it("when called not with portfolio should revert", async () => {
      const { user, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);
      const tokenId = await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

      const claimNftTx = dos.connect(user)["claimNft(address,uint256)"](nft.address, tokenId);

      await expect(claimNftTx).to.be.revertedWith("Only portfolio can execute");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const ownerPortfolio = await CreatePortfolio(dos, user);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle, NFT_PRICE);
      const nonOwnerPortfolio = await CreatePortfolio(dos, user2);

      const claimNftTx = nonOwnerPortfolio.executeBatch([
        makeCall(dos, "claimNft(address,uint256)", [nft.address, tokenId]),
      ]);

      await expect(claimNftTx).to.be.revertedWith("NFT must be on the user's deposit");
    });

    it(
      "when user owns the deposited NFT " +
        "should change ownership of the NFT from DOS to user's portfolio " +
        "and remove NFT from the user DOS portfolio",
      async () => {
        const { user, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
        const portfolio = await CreatePortfolio(dos, user);
        const tokenId = await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

        const claimNftTx = await portfolio.executeBatch([
          makeCall(dos, "claimNft(address,uint256)", [nft.address, tokenId]),
        ]);
        await claimNftTx.wait();

        await expect(await nft.ownerOf(tokenId)).to.eql(portfolio.address);
        await expect(await dos.viewNfts(portfolio.address)).to.eql([]);
      },
    );
  });

  describe("#sendNft", () => {
    it("when called not with portfolio should revert", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const ownerPortfolio = await CreatePortfolio(dos, user);
      const receiverPortfolio = await CreatePortfolio(dos, user2);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle, NFT_PRICE);

      const sendNftTx = dos.connect(user).sendNft(nft.address, tokenId, receiverPortfolio.address);

      await expect(sendNftTx).to.be.revertedWith("Only portfolio can execute");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const { user, user2, user3, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const ownerPortfolio = await CreatePortfolio(dos, user);
      const nonOwnerPortfolio = await CreatePortfolio(dos, user2);
      const receiverPortfolio = await CreatePortfolio(dos, user3);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle, NFT_PRICE);

      const tx = transfer(dos, nonOwnerPortfolio, receiverPortfolio, nft, tokenId);

      await expect(tx).to.be.revertedWith("NFT must be on the user's deposit");
    });

    it("when receiver is not a portfolio should revert", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const ownerPortfolio = await CreatePortfolio(dos, user);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle, NFT_PRICE);

      // @ts-ignore - bypass `transfer` type that forbids this invariant in TS
      const tx = transfer(dos, ownerPortfolio, user2, nft, tokenId);

      await expect(tx).to.be.revertedWith("Recipient portfolio doesn't exist");
    });

    it("when user owns the deposited NFT should be able to move the NFT to another portfolio", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const sender = await CreatePortfolio(dos, user);
      const receiver = await CreatePortfolio(dos, user2);
      const tokenId = await depositNft(dos, sender, nft, nftOracle, NFT_PRICE);

      const tx = await transfer(dos, sender, receiver, nft, tokenId);
      await tx.wait();

      await expect(await dos.viewNfts(sender.address)).to.eql([]);
      const receiverNfts = await dos.viewNfts(receiver.address);
      await expect(receiverNfts).to.eql([[nft.address, tokenId, BigNumber.from("1"), 0]]);
    });
  });
});

async function CreatePortfolio(dos: DOS, signer: Signer) {
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
  asset: TestERC20 | WETH9,
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
    makeCall(dos, "depositNft(address,uint256)", [nft.address, tokenId]),
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
    makeCall(dos, "depositNft(address,uint256)", [nft.address, tokenId]),
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
