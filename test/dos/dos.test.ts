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
} from "../../typechain-types";
import { toWei, toWeiUsdc } from "../../lib/Numbers";
import { getEventParams } from "../../lib/Events";
import { BigNumber, Signer } from "ethers";
import { Chainlink, makeCallWithValue } from "../../lib/Calls";

const usdcPrice = 1;
const ethPrice = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

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
      USDC_DECIMALS // 6
    );

    const weth = await new WETH9__factory(owner).deploy();
    const nft = await new TestNFT__factory(owner).deploy(
      "Test NFT1",
      "NF1",
      100
    );
    const unregisteredNft = await new TestNFT__factory(owner).deploy(
      "Test NFT2",
      "NF2",
      200
    );

    const usdcChainlink = await Chainlink.deploy(
      owner,
      1,
      8,
      USDC_DECIMALS,
      USDC_DECIMALS
    );
    const ethChainlink = await Chainlink.deploy(
      owner,
      2000,
      8,
      USDC_DECIMALS,
      WETH_DECIMALS
    );

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    await nftOracle.setPrice(1, toWei(100));

    const dos = await new DOS__factory(owner).deploy(owner.address);

    // const DosDeployData = await ethers.getContractFactory("DOS");
    // const dos = await DosDeployData.deploy(unlockTime, { value: lockedAmount });

    await dos.setConfig({
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    // No interest which would include time sensitive calculations
    await dos.addERC20Asset(
      usdc.address,
      "USD Coin",
      "USDC",
      USDC_DECIMALS,
      usdcChainlink.assetOracle.address,
      toWei(0.9),
      toWei(0.9),
      0
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
      0 // No interest which would include time sensitive calculations
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
      const { user, dos, usdc, usdcAssetIdx } = await loadFixture(
        deployDOSFixture
      );
      const portfolio = await CreatePortfolio(dos, user);

      await depositAsset(dos, portfolio, usdc, usdcAssetIdx, tenThousandUsdc);

      expect((await getBalances(dos, portfolio)).usdc).to.equal(
        tenThousandUsdc
      );
      expect(await usdc.balanceOf(dos.address)).to.equal(tenThousandUsdc);
    });

    it("User can transfer money", async () => {
      const { user, user2, dos, usdc, usdcAssetIdx } = await loadFixture(
        deployDOSFixture
      );
      const sender = await CreatePortfolio(dos, user);
      const receiver = await CreatePortfolio(dos, user2);
      await depositAsset(dos, sender, usdc, usdcAssetIdx, tenThousandUsdc);

      await sender.executeBatch([
        makeCallWithValue(dos, "transfer", [
          usdcAssetIdx,
          receiver.address,
          tenThousandUsdc,
        ]),
      ]);

      expect((await getBalances(dos, sender)).usdc).to.equal(0);
      expect((await getBalances(dos, receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User can deposit and transfer money in arbitrary order", async () => {
      const { user, user2, dos, usdc, usdcAssetIdx } = await loadFixture(
        deployDOSFixture
      );
      const sender = await CreatePortfolio(dos, user);
      const receiver = await CreatePortfolio(dos, user2);
      await usdc.mint(sender.address, tenThousandUsdc);

      await sender.executeBatch([
        makeCallWithValue(usdc, "approve", [
          dos.address,
          ethers.constants.MaxUint256,
        ]),
        makeCallWithValue(dos, "transfer", [
          usdcAssetIdx,
          receiver.address,
          tenThousandUsdc,
        ]),
        makeCallWithValue(dos, "depositAsset", [usdcAssetIdx, tenThousandUsdc]),
      ]);

      expect((await getBalances(dos, sender)).usdc).to.equal(0);
      expect((await getBalances(dos, receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User cannot send more then they own", async () => {
      const { user, user2, dos, usdc, usdcAssetIdx } = await loadFixture(
        deployDOSFixture
      );
      const sender = await CreatePortfolio(dos, user);
      const receiver = await CreatePortfolio(dos, user2);
      await depositAsset(dos, sender, usdc, usdcAssetIdx, toWeiUsdc(10_000));

      const transferTx = sender.executeBatch([
        makeCallWithValue(dos, "transfer", [
          usdcAssetIdx,
          receiver.address,
          toWeiUsdc(20_000),
        ]),
      ]);

      await expect(transferTx).to.be.revertedWith(
        "Result of operation is not sufficient liquid"
      );
    });

    it("User can send more asset then they have", async () => {
      const { user, user2, dos, usdc, weth, wethAssetIdx, usdcAssetIdx } =
        await loadFixture(deployDOSFixture);
      const sender = await CreatePortfolio(dos, user);
      await depositAsset(dos, sender, usdc, usdcAssetIdx, tenThousandUsdc);
      const receiver = await CreatePortfolio(dos, user2);
      // Put weth in system so we can borrow weth
      const someOther = await CreatePortfolio(dos, user);
      await depositAsset(dos, someOther, weth, wethAssetIdx, toWei(2));

      await sender.executeBatch([
        makeCallWithValue(dos, "transfer", [
          wethAssetIdx,
          receiver.address,
          oneEth,
        ]),
      ]);

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
      await depositAsset(
        dos,
        liquidatable,
        usdc,
        usdcAssetIdx,
        tenThousandUsdc
      );
      const liquidator = await CreatePortfolio(dos, user2);
      // ensure that liquidator would have enough collateral to compensate
      // negative balance of collateral/debt obtained from liquidatable
      await depositAsset(dos, liquidator, usdc, usdcAssetIdx, tenThousandUsdc);
      // Put WETH in system so we can borrow weth
      const someOther = await CreatePortfolio(dos, user);
      await depositAsset(dos, someOther, weth, wethAssetIdx, toWei(2));
      await ethChainlink.setPrice(2_000);

      // generate a debt on liquidatable
      await liquidatable.executeBatch([
        makeCallWithValue(dos, "transfer", [
          wethAssetIdx,
          someOther.address,
          oneEth,
        ]),
      ]);
      // make liquidatable debt overcome collateral. Now it can be liquidated
      await ethChainlink.setPrice(9_000);
      await liquidator.executeBatch([
        makeCallWithValue(dos, "liquidate", [liquidatable.address]),
      ]);

      const liquidatableBalances = await getBalances(dos, liquidatable);
      const liquidatorBalances = await getBalances(dos, liquidator);
      // 10_000 - balance in USDC; 9_000 - debt of 1 ETH; 0.8 - liqFraction
      const liquidationOddMoney = toWei((10_000 - 9_000) * 0.8, USDC_DECIMALS); // 800 USDC in ETH
      expect(liquidatableBalances.weth).to.equal(0);
      expect(liquidatableBalances.usdc).to.be.approximately(
        liquidationOddMoney,
        1000
      );
      expect(liquidatorBalances.weth).to.equal(-oneEth); // own 10k + 10k of liquidatable
      expect(liquidatorBalances.usdc).to.be.approximately(
        tenThousandUsdc + tenThousandUsdc - liquidationOddMoney,
        1000
      );
    });

    it("Solvent position can not be liquidated", async () => {
      const { user, user2, dos, usdc, weth, usdcAssetIdx, wethAssetIdx } =
        await loadFixture(deployDOSFixture);
      const nonLiquidatable = await CreatePortfolio(dos, user);
      const liquidator = await CreatePortfolio(dos, user2);
      // Put WETH in system so we can borrow weth
      const other = await CreatePortfolio(dos, user);
      await depositAsset(dos, other, weth, wethAssetIdx, toWei(0.25));
      await depositAsset(
        dos,
        nonLiquidatable,
        usdc,
        usdcAssetIdx,
        tenThousandUsdc
      );
      await nonLiquidatable.executeBatch([
        makeCallWithValue(dos, "transfer", [
          wethAssetIdx,
          other.address,
          oneEth,
        ]),
      ]);

      const liquidationTx = liquidator.executeBatch([
        makeCallWithValue(dos, "liquidate", [nonLiquidatable.address]),
      ]);

      await expect(liquidationTx).to.be.revertedWith(
        "Portfolio is not liquidatable"
      );
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

      const [totalValue, collateral, debt] = await dos.computePosition(
        portfolio.address
      );

      expect(totalValue).to.equal(0);
      expect(collateral).to.equal(0);
      expect(debt).to.equal(0);
    });

    it("when portfolio has an asset should return the asset value", async () => {
      const { dos, user, usdc, usdcAssetIdx } = await loadFixture(
        deployDOSFixture
      );
      const portfolio = await CreatePortfolio(dos, user);
      await depositAsset(
        dos,
        portfolio,
        usdc,
        usdcAssetIdx,
        toWei(10_000, USDC_DECIMALS)
      );

      const position = await dos.computePosition(portfolio.address);

      const [total, collateral, debt] = position;
      expect(total).to.be.approximately(
        await toWei(10_000, USDC_DECIMALS),
        1000
      );
      // collateral factor is defined in setupDos, and it's 0.9
      expect(collateral).to.be.approximately(
        await toWei(9000, USDC_DECIMALS),
        1000
      );
      expect(debt).to.equal(0);
    });

    it("when portfolio has multiple assets should return total assets value", async () => {
      const { dos, user, usdc, weth, usdcAssetIdx, wethAssetIdx } =
        await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      await Promise.all([
        depositAsset(dos, portfolio, usdc, usdcAssetIdx, toWeiUsdc(10_000)),
        depositAsset(dos, portfolio, weth, wethAssetIdx, toWei(1)),
      ]);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(await toWei(12_000, USDC_DECIMALS));
      // collateral factor is defined in setupDos, and it's 0.9. 12 * 0.9 = 10.8
      expect(collateral).to.be.approximately(
        await toWei(10_800, USDC_DECIMALS),
        1000
      );
      expect(debt).to.equal(0);
    });

    it("when portfolio has an NFT should return the NFT value", async () => {
      const { dos, user, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      await depositNft(dos, portfolio, nft, nftOracle, toWei(10));

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWei(10));
      // collateral factor is defined in setupDos, and it's 0.5
      expect(collateral).to.equal(toWei(5));
      expect(debt).to.equal(0);
    });

    it("when portfolio has a few NFTs should return the total NFTs value", async () => {
      const { dos, user, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      await Promise.all([
        depositNft(dos, portfolio, nft, nftOracle, toWei(1)),
        depositNft(dos, portfolio, nft, nftOracle, toWei(2)),
        depositNft(dos, portfolio, nft, nftOracle, toWei(3)),
      ]);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWei(6)); // 1 + 2 + 3
      // collateral factor is defined in setupDos, and it's 0.5
      expect(collateral).to.be.approximately(toWei(3), 1000);
      expect(debt).to.equal(0);
    });

    it("when portfolio has assets and NFTs should return their total value", async () => {
      const {
        dos,
        user,
        usdc,
        usdcAssetIdx,
        weth,
        wethAssetIdx,
        nft,
        nftOracle,
      } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);

      await Promise.all([
        depositNft(dos, portfolio, nft, nftOracle, toWei(100, USDC_DECIMALS)),
        depositNft(dos, portfolio, nft, nftOracle, toWei(200, USDC_DECIMALS)),
        depositNft(dos, portfolio, nft, nftOracle, toWei(300, USDC_DECIMALS)),
        depositAsset(dos, portfolio, usdc, usdcAssetIdx, toWeiUsdc(10_000)),
        depositAsset(dos, portfolio, weth, wethAssetIdx, toWei(1)),
      ]);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWei(12_600, USDC_DECIMALS));
      // collateral factor is defined in setupDos,
      // and it's 0.5 for nft and 0.9 for assets.
      expect(collateral).to.be.approximately(
        toWei(12_000 * 0.9 + 600 * 0.5, USDC_DECIMALS),
        1000
      );
      expect(debt).to.equal(0);
    });

    it("tests with debt");
  });

  describe("#liquidate", () => {
    it("when called directly on DOS should revert", async () => {
      const { user, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);
      await depositNft(dos, portfolio, nft, nftOracle);

      const depositNftTx = dos.liquidate(portfolio.address);

      await expect(depositNftTx).to.be.revertedWith(
        "Only portfolio can execute"
      );
    });

    it("when portfolio to liquidate doesn't exist should revert", async () => {
      const { dos, user, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);
      await depositNft(dos, portfolio, nft, nftOracle);
      const nonPortfolioAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const liquidateTx = portfolio.executeBatch([
        makeCallWithValue(dos, "liquidate", [nonPortfolioAddress]),
      ]);

      await expect(liquidateTx).to.be.revertedWith(
        "Recipient portfolio doesn't exist"
      );
    });

    it("when portfolio to liquidate is empty should revert");

    it("when collateral is below debt should revert");

    it("when collateral is equal to debt should revert");

    it(
      "when collateral is smaller then debt should transfer all assets and all NFTs of the portfolio to the caller"
    );
  });

  describe("#depositNft", () => {
    it(
      "when user owns the NFT " +
        "should change ownership of the NFT from the user to DOS " +
        "and add NFT to the user DOS portfolio",
      async () => {
        const { user, dos, nft, nftOracle } = await loadFixture(
          deployDOSFixture
        );
        const portfolio = await CreatePortfolio(dos, user);
        const tokenId = await depositUserNft(dos, portfolio, nft, nftOracle);

        expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
        const userNfts = await dos.viewNfts(portfolio.address);
        expect(userNfts).to.eql([[nft.address, tokenId]]);
      }
    );

    it(
      "when portfolio owns the NFT " +
        "should change ownership of the NFT from portfolio to DOS " +
        "and add NFT to the user DOS portfolio",
      async () => {
        const { user, dos, nft, nftOracle } = await loadFixture(
          deployDOSFixture
        );
        const portfolio = await CreatePortfolio(dos, user);

        const tokenId = await depositNft(dos, portfolio, nft, nftOracle);

        expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
        const userNfts = await dos.viewNfts(portfolio.address);
        expect(userNfts).to.eql([[nft.address, tokenId]]);
      }
    );

    it("when NFT contract is not registered should revert the deposit", async () => {
      const { user, dos, unregisteredNft, nftOracle } = await loadFixture(
        deployDOSFixture
      );
      const portfolio = await CreatePortfolio(dos, user);

      const txRevert = depositNft(dos, portfolio, unregisteredNft, nftOracle);

      await expect(txRevert).to.be.revertedWith(
        "Cannot add NFT of unknown NFT contract"
      );
    });

    it("when user is not an owner of NFT should revert the deposit", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(
        deployDOSFixture
      );
      const portfolio = await CreatePortfolio(dos, user);
      const portfolio2 = await CreatePortfolio(dos, user2);
      const tokenId = await depositNft(dos, portfolio, nft, nftOracle);

      const depositNftTx = portfolio2.executeBatch([
        makeCallWithValue(dos, "depositNft", [nft.address, tokenId]),
      ]);

      await expect(depositNftTx).to.be.revertedWith(
        "NFT must be owned the the user or user's portfolio"
      );
    });

    it("when called directly on DOS should revert the deposit", async () => {
      const { user, dos, nft } = await loadFixture(deployDOSFixture);
      const mintTx = await nft.mint(user.address);
      const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
      const tokenId = mintEventArgs[0] as BigNumber;
      await (await nft.connect(user).approve(dos.address, tokenId)).wait();

      const depositNftTx = dos.depositNft(nft.address, tokenId);

      await expect(depositNftTx).to.be.revertedWith(
        "Only portfolio can execute"
      );
    });
  });

  describe("#claimNft", () => {
    it("when called not with portfolio should revert", async () => {
      const { user, dos, nft, nftOracle } = await loadFixture(deployDOSFixture);
      const portfolio = await CreatePortfolio(dos, user);
      const tokenId = await depositNft(dos, portfolio, nft, nftOracle);

      const claimNftTx = dos.connect(user).claimNft(nft.address, tokenId);

      await expect(claimNftTx).to.be.revertedWith("Only portfolio can execute");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(
        deployDOSFixture
      );
      const ownerPortfolio = await CreatePortfolio(dos, user);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle);
      const nonOwnerPortfolio = await CreatePortfolio(dos, user2);

      const claimNftTx = nonOwnerPortfolio.executeBatch([
        makeCallWithValue(dos, "claimNft", [nft.address, tokenId]),
      ]);

      await expect(claimNftTx).to.be.revertedWith(
        "NFT must be on the user's deposit"
      );
    });

    it(
      "when user owns the deposited NFT " +
        "should change ownership of the NFT from DOS to user's portfolio " +
        "and remove NFT from the user DOS portfolio",
      async () => {
        const { user, dos, nft, nftOracle } = await loadFixture(
          deployDOSFixture
        );
        const portfolio = await CreatePortfolio(dos, user);
        const tokenId = await depositNft(dos, portfolio, nft, nftOracle);

        const claimNftTx = await portfolio.executeBatch([
          makeCallWithValue(dos, "claimNft", [nft.address, tokenId]),
        ]);
        await claimNftTx.wait();

        await expect(await nft.ownerOf(tokenId)).to.eql(portfolio.address);
        await expect(await dos.viewNfts(portfolio.address)).to.eql([]);
      }
    );
  });

  describe("#sendNft", () => {
    it("when called not with portfolio should revert", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(
        deployDOSFixture
      );
      const ownerPortfolio = await CreatePortfolio(dos, user);
      const receiverPortfolio = await CreatePortfolio(dos, user2);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle);

      const sendNftTx = dos
        .connect(user)
        .sendNft(nft.address, tokenId, receiverPortfolio.address);

      await expect(sendNftTx).to.be.revertedWith("Only portfolio can execute");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const { user, user2, user3, dos, nft, nftOracle } = await loadFixture(
        deployDOSFixture
      );
      const ownerPortfolio = await CreatePortfolio(dos, user);
      const nonOwnerPortfolio = await CreatePortfolio(dos, user2);
      const receiverPortfolio = await CreatePortfolio(dos, user3);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle);

      const sendNftCall = makeCallWithValue(dos, "sendNft", [
        nft.address,
        tokenId,
        receiverPortfolio.address,
      ]);
      const sendNftTx = nonOwnerPortfolio.executeBatch([sendNftCall]);

      await expect(sendNftTx).to.be.revertedWith(
        "NFT must be on the user's deposit"
      );
    });

    it("when receiver is not a portfolio should revert", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(
        deployDOSFixture
      );
      const ownerPortfolio = await CreatePortfolio(dos, user);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle);

      const sendNftTx = ownerPortfolio.executeBatch([
        makeCallWithValue(dos, "sendNft", [
          nft.address,
          tokenId,
          user2.address,
        ]),
      ]);

      await expect(sendNftTx).to.be.revertedWith(
        "Recipient portfolio doesn't exist"
      );
    });

    it("when user owns the deposited NFT should be able to move the NFT to another portfolio", async () => {
      const { user, user2, dos, nft, nftOracle } = await loadFixture(
        deployDOSFixture
      );
      const senderPortfolio = await CreatePortfolio(dos, user);
      const receiverPortfolio = await CreatePortfolio(dos, user2);
      const tokenId = await depositNft(dos, senderPortfolio, nft, nftOracle);

      const sendNftCall = makeCallWithValue(dos, "sendNft", [
        nft.address,
        tokenId,
        receiverPortfolio.address,
      ]);
      const sendNftTx = await senderPortfolio.executeBatch([sendNftCall]);
      await sendNftTx.wait();

      await expect(await dos.viewNfts(senderPortfolio.address)).to.eql([]);
      const receiverNfts = await dos.viewNfts(receiverPortfolio.address);
      await expect(receiverNfts).to.eql([[nft.address, tokenId]]);
    });
  });
});

async function CreatePortfolio(dos: DOS, signer: Signer) {
  const { portfolio } = await getEventParams(
    await dos.connect(signer).createPortfolio(),
    dos,
    "PortfolioCreated"
  );
  return PortfolioLogic__factory.connect(portfolio as string, signer);
}

async function depositAsset(
  dos: DOS,
  portfolio: PortfolioLogic,
  asset: TestERC20 | WETH9,
  assetIdx: number,
  amount: number | bigint
) {
  await asset.mint(portfolio.address, amount);

  const depositTx = await portfolio.executeBatch([
    makeCallWithValue(asset, "approve", [dos.address, amount]),
    makeCallWithValue(dos, "depositAsset", [assetIdx, amount]),
  ]);
  await depositTx.wait();
}

async function depositNft(
  dos: DOS,
  portfolio: PortfolioLogic,
  nft: TestNFT,
  priceOracle: MockNFTOracle,
  price: bigint = toWei(0.1)
): Promise<BigNumber> {
  const mintTx = await nft.mint(portfolio.address);
  const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
  const tokenId = mintEventArgs[0] as BigNumber;
  await priceOracle.setPrice(tokenId, price);
  const depositNftTx = await portfolio.executeBatch([
    makeCallWithValue(nft, "approve", [dos.address, tokenId]),
    makeCallWithValue(dos, "depositNft", [nft.address, tokenId]),
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
  price: bigint = toWei(0.1)
): Promise<BigNumber> {
  const user = portfolio.signer;
  const mintTx = await nft.mint(await user.getAddress());
  const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
  const tokenId = mintEventArgs[0] as BigNumber;
  await priceOracle.setPrice(tokenId, price);
  await (await nft.connect(user).approve(dos.address, tokenId)).wait();
  const depositNftTx = await portfolio.executeBatch([
    makeCallWithValue(dos, "depositNft", [nft.address, tokenId]),
  ]);
  await depositNftTx.wait();
  return tokenId;
}

async function getBalances(
  dos: DOS,
  portfolio: PortfolioLogic
): Promise<{ usdc: BigNumber; weth: BigNumber }> {
  const [usdc, weth] = await Promise.all([
    dos.viewBalance(portfolio.address, 0),
    dos.viewBalance(portfolio.address, 1),
  ]);
  return { usdc, weth };
}

// This fixes random tests crash with
// "contract call run out of gas and made the transaction revert" error
// and, as a side effect, speeds tests in 2-3 times!
// https://github.com/NomicFoundation/hardhat/issues/1721
export const getFixedGasSigners = async function (gasLimit: number) {
  const signers: SignerWithAddress[] = await ethers.getSigners();
  for (const signer of signers) {
    const orig = signer.sendTransaction;
    signer.sendTransaction = (transaction) => {
      transaction.gasLimit = BigNumber.from(gasLimit.toString());
      return orig.apply(signer, [transaction]);
    };
  }
  return signers;
};
