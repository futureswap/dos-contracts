import type {WalletLogic} from "../../typechain-types";
import type {BigNumber} from "ethers";

import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  WalletLogic__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
} from "../../typechain-types";
import {toWei, toWeiUsdc} from "../../lib/numbers";
import {getEventParams} from "../../lib/events";
import {getFixedGasSigners} from "../../lib/hardhat/fixedGasSigners";
import {signPermit2TransferFrom} from "../../lib/signers";
import {
  makeCall,
  createWallet,
  depositERC20,
  transfer,
  depositERC721,
  depositUserNft,
} from "../../lib/calls";
import {Chainlink, deploySupa, deployFixedAddressForTests} from "../../lib/deploy";

const USDC_PRICE = 1;
const ETH_PRICE = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

const NFT_PRICE = 200;

const tenThousandUsdc = toWeiUsdc(10_000);
const oneEth = toWei(1);

describe("Supa", () => {
  // we define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deploySupaFixture() {
    const [owner, user, user2, user3] = await getFixedGasSigners(10_000_000);

    const {permit2, anyswapCreate2Deployer} = await deployFixedAddressForTests(owner);

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
      toWei(0.9),
      toWei(0.9),
      owner.address,
    );
    const ethChainlink = await Chainlink.deploy(
      owner,
      ETH_PRICE,
      8,
      USDC_DECIMALS,
      WETH_DECIMALS,
      toWei(0.9),
      toWei(0.9),
      owner.address,
    );

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    const {iSupa, supa, versionManager} = await deploySupa(
      owner.address,
      anyswapCreate2Deployer,
      "0x01",
      owner,
    );
    const proxyLogic = await new WalletLogic__factory(owner).deploy(iSupa.address);
    await versionManager.addVersion(2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    const treasuryWallet = await createWallet(iSupa, owner);

    await iSupa.setConfig({
      treasuryWallet: treasuryWallet.address,
      treasuryInterestFraction: toWei(0.05),
      maxSolvencyCheckGasCost: 1e6,
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    await iSupa.setTokenStorageConfig({
      maxTokenStorage: 250,
      erc20Multiplier: 1,
      erc721Multiplier: 1,
    });

    await iSupa.addERC20Info(
      usdc.address,
      "USD Coin",
      "USDC",
      USDC_DECIMALS,
      usdcChainlink.oracle.address,
      0, // 0%
      5, // 0.05 * 100
      480, // 4.8 * 100
      ethers.utils.parseEther("0.8"), // 0.80
    );

    await iSupa.addERC20Info(
      weth.address,
      "Wrapped ETH",
      "WETH",
      WETH_DECIMALS,
      ethChainlink.oracle.address,
      0, // 0%
      5, // 0.05 * 100
      480, // 4.8 * 100
      ethers.utils.parseEther("0.8"), // 0.80
    );

    await iSupa.addERC721Info(nft.address, nftOracle.address);
    await nftOracle.setCollateralFactor(toWei(0.5));

    const getBalances = async (
      wallet: WalletLogic,
    ): Promise<{
      nfts: [nftContract: string, tokenId: BigNumber][];
      usdc: BigNumber;
      weth: BigNumber;
    }> => {
      const [nfts, usdcBal, wethBal] = await Promise.all([
        iSupa.getCreditAccountERC721(wallet.address),
        iSupa.getCreditAccountERC20(wallet.address, usdc.address),
        iSupa.getCreditAccountERC20(wallet.address, weth.address),
      ]);
      return {nfts, usdc: usdcBal, weth: wethBal};
    };

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
      iSupa,
      supa,
      permit2,
      getBalances,
    };
  }

  describe("Supa tests", () => {
    it("User can create wallet", async () => {
      const {user, iSupa} = await loadFixture(deploySupaFixture);

      const wallet = await createWallet(iSupa, user);
      expect(await wallet.owner()).to.equal(user.address);
    });

    it("User can deposit money", async () => {
      const {user, iSupa, usdc, getBalances} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);

      await depositERC20(iSupa, wallet, usdc, tenThousandUsdc);

      expect((await getBalances(wallet)).usdc).to.equal(tenThousandUsdc);
      expect(await usdc.balanceOf(iSupa.address)).to.equal(tenThousandUsdc);
    });

    it("User can transfer money", async () => {
      const {user, user2, iSupa, usdc, getBalances} = await loadFixture(deploySupaFixture);
      const sender = await createWallet(iSupa, user);
      const receiver = await createWallet(iSupa, user2);
      await depositERC20(iSupa, sender, usdc, tenThousandUsdc);

      const tx = transfer(iSupa, sender, receiver, usdc.address, tenThousandUsdc);
      await (await tx).wait();

      expect((await getBalances(sender)).usdc).to.equal(0);
      expect((await getBalances(receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User can deposit and transfer money in arbitrary order", async () => {
      const {user, user2, iSupa, usdc, getBalances} = await loadFixture(deploySupaFixture);
      const sender = await createWallet(iSupa, user);
      const receiver = await createWallet(iSupa, user2);
      await usdc.mint(sender.address, tenThousandUsdc);

      await sender.executeBatch([
        makeCall(iSupa).transferERC20(usdc.address, receiver.address, tenThousandUsdc),
        makeCall(iSupa).depositERC20(usdc.address, tenThousandUsdc),
      ]);

      expect((await getBalances(sender)).usdc).to.equal(0);
      expect((await getBalances(receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User cannot send more than they own", async () => {
      const {user, user2, iSupa, supa, usdc} = await loadFixture(deploySupaFixture);
      const sender = await createWallet(iSupa, user);
      const receiver = await createWallet(iSupa, user2);
      await depositERC20(iSupa, sender, usdc, toWeiUsdc(10_000));

      const tx = transfer(iSupa, sender, receiver, usdc.address, toWeiUsdc(20_000));

      await expect(tx).to.be.revertedWithCustomError(supa, "Insolvent");
    });

    it("User can send more ERC20 then they have", async () => {
      const {user, user2, iSupa, usdc, weth, getBalances} = await loadFixture(deploySupaFixture);
      const sender = await createWallet(iSupa, user);
      await depositERC20(iSupa, sender, usdc, tenThousandUsdc);
      const receiver = await createWallet(iSupa, user2);
      // put weth in system so we can borrow weth
      const someOther = await createWallet(iSupa, user);
      await depositERC20(iSupa, someOther, weth, toWei(2));

      const tx = await transfer(iSupa, sender, receiver, weth.address, oneEth);
      await tx.wait();

      const senderBalances = await getBalances(sender);
      const receiverBalances = await getBalances(receiver);
      expect(senderBalances.usdc).to.equal(tenThousandUsdc);
      expect(senderBalances.weth).to.equal(-oneEth);
      expect(receiverBalances.usdc).to.equal(0);
      expect(receiverBalances.weth).to.equal(oneEth);
    });

    it("Non-solvent position can be liquidated", async () => {
      // prettier-ignore
      const {
        user, user2,
        iSupa,
        usdc,
        weth,
        ethChainlink, getBalances
      } = await loadFixture(deploySupaFixture);
      const liquidatable = await createWallet(iSupa, user);
      await depositERC20(iSupa, liquidatable, usdc, tenThousandUsdc);
      const liquidator = await createWallet(iSupa, user2);
      // ensure that liquidator would have enough collateral to compensate
      // negative balance of collateral/debt obtained from liquidatable
      await depositERC20(iSupa, liquidator, usdc, tenThousandUsdc);
      // put WETH in system so we can borrow weth
      const someOther = await createWallet(iSupa, user);
      await depositERC20(iSupa, someOther, weth, toWei(2));
      await ethChainlink.setPrice(2_000);

      // generate a debt on liquidatable
      const tx = transfer(iSupa, liquidatable, someOther, weth.address, oneEth);
      await (await tx).wait();
      // make liquidatable debt overcome collateral. Now it can be liquidated
      await ethChainlink.setPrice(9_000);
      const {collateral, debt} = await iSupa.getRiskAdjustedPositionValues(liquidatable.address);
      const percentUnderwater = ethers.utils.parseEther(
        (Number(collateral) / Number(debt)).toString(),
      );
      await liquidator.executeBatch([makeCall(iSupa).liquidate(liquidatable.address)]);

      const liquidatableBalances = await getBalances(liquidatable);
      const liquidatorBalances = await getBalances(liquidator);
      // 10_000 - balance in USDC; 9_000 - debt of 1 ETH; 0.8 - liqFraction
      let liquidationLeftover =
        toWei((10_000 - 9_000) * 0.8, USDC_DECIMALS) * BigInt(percentUnderwater.toString()); // 800 USDC in ETH
      liquidationLeftover /= BigInt(ethers.utils.parseEther("1").toString());
      expect(liquidatableBalances.weth).to.equal(0);
      expect(liquidatableBalances.usdc).to.be.approximately(liquidationLeftover, 1000);
      expect(liquidatorBalances.weth).to.be.approximately(-oneEth, 200_000); // own 10k + 10k of liquidatable
      expect(liquidatorBalances.usdc).to.be.approximately(
        tenThousandUsdc + tenThousandUsdc - liquidationLeftover,
        1000,
      );
    });

    it("Solvent position can not be liquidated", async () => {
      // prettier-ignore
      const {
        iSupa,
        supa,
        user, user2,
        usdc,
        weth
      } = await loadFixture(
        deploySupaFixture,
      );
      const nonLiquidatable = await createWallet(iSupa, user);
      const liquidator = await createWallet(iSupa, user2);
      // put WETH in system so we can borrow weth
      const other = await createWallet(iSupa, user);
      await depositERC20(iSupa, other, weth, toWei(0.25));
      await depositERC20(iSupa, nonLiquidatable, usdc, tenThousandUsdc);
      const tx = transfer(iSupa, nonLiquidatable, other, weth.address, oneEth);
      await (await tx).wait();

      const liquidationTx = liquidator.executeBatch([
        makeCall(iSupa).liquidate(nonLiquidatable.address),
      ]);

      await expect(liquidationTx).to.be.revertedWithCustomError(supa, "NotLiquidatable");
    });
  });

  describe("#getRiskAdjustedPositionValues", () => {
    it("Should revert when wallet doesn't exist", async () => {
      const {iSupa, supa} = await loadFixture(deploySupaFixture);
      const nonWalletAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const computeTx = iSupa.getRiskAdjustedPositionValues(nonWalletAddress);

      await expect(computeTx).to.be.revertedWithCustomError(supa, "WalletNonExistent");
    });

    it("when wallet is empty should return 0", async () => {
      const {iSupa, user} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);

      const [totalValue, collateral, debt] = await iSupa.getRiskAdjustedPositionValues(
        wallet.address,
      );

      expect(totalValue).to.equal(0);
      expect(collateral).to.equal(0);
      expect(debt).to.equal(0);
    });

    it("when wallet has an ERC20 should return the ERC20 value", async () => {
      const {iSupa, user, usdc} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);
      await depositERC20(iSupa, wallet, usdc, toWei(10_000, USDC_DECIMALS));

      const position = await iSupa.getRiskAdjustedPositionValues(wallet.address);

      const [total, collateral, debt] = position;
      expect(total).to.be.approximately(toWei(10_000, USDC_DECIMALS), 1000);
      // collateral factor is defined in setupSupa, and it's 0.9
      expect(collateral).to.be.approximately(toWei(9000, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("when wallet has multiple ERC20s should return total ERC20s value", async () => {
      const {iSupa, user, usdc, weth} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);

      await Promise.all([
        depositERC20(iSupa, wallet, usdc, toWeiUsdc(10_000)),
        depositERC20(iSupa, wallet, weth, toWei(1)),
      ]);

      const position = await iSupa.getRiskAdjustedPositionValues(wallet.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWei(12_000, USDC_DECIMALS));
      // collateral factor is defined in setupSupa, and it's 0.9. 12 * 0.9 = 10.8
      expect(collateral).to.be.approximately(toWei(10_800, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("when wallet has an NFT should return the NFT value", async () => {
      const {iSupa, user, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);

      await depositERC721(iSupa, wallet, nft, nftOracle, NFT_PRICE);

      const position = await iSupa.getRiskAdjustedPositionValues(wallet.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWeiUsdc(NFT_PRICE));
      // collateral factor is defined in setupSupa, and it's 0.5
      expect(collateral).to.equal(toWeiUsdc(NFT_PRICE / 2));
      expect(debt).to.equal(0);
    });

    it("when wallet has a few NFTs should return the total NFTs value", async () => {
      const {iSupa, user, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);

      await Promise.all([
        depositERC721(iSupa, wallet, nft, nftOracle, 1),
        depositERC721(iSupa, wallet, nft, nftOracle, 2),
        depositERC721(iSupa, wallet, nft, nftOracle, 3),
      ]);

      const position = await iSupa.getRiskAdjustedPositionValues(wallet.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWeiUsdc(6)); // 1 + 2 + 3
      // collateral factor is defined in setupSupa, and it's 0.5
      expect(collateral).to.be.approximately(toWeiUsdc(3), 1000);
      expect(debt).to.equal(0);
    });

    it("when wallet has ERC20s and NFTs should return their total value", async () => {
      // prettier-ignore
      const {
        iSupa,
        user,
        usdc,
        weth,
        nft, nftOracle
      } =
        await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);

      await Promise.all([
        depositERC721(iSupa, wallet, nft, nftOracle, 100),
        depositERC721(iSupa, wallet, nft, nftOracle, 200),
        depositERC721(iSupa, wallet, nft, nftOracle, 300),
        depositERC20(iSupa, wallet, usdc, toWeiUsdc(10_000)),
        depositERC20(iSupa, wallet, weth, toWei(1)),
      ]);

      const position = await iSupa.getRiskAdjustedPositionValues(wallet.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWei(12_600, USDC_DECIMALS));
      // collateral factor is defined in setupSupa,
      // and it's 0.5 for nft and 0.9 for erc20s.
      expect(collateral).to.be.approximately(toWei(12_000 * 0.9 + 600 * 0.5, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });
  });

  describe("#liquidate", () => {
    it("when called directly on Supa should revert", async () => {
      const {user, iSupa, supa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);
      await depositERC721(iSupa, wallet, nft, nftOracle, 1600);

      const depositERC721Tx = iSupa.liquidate(wallet.address);

      await expect(depositERC721Tx).to.be.revertedWithCustomError(supa, "OnlyWallet");
    });

    it("when wallet to liquidate doesn't exist should revert", async () => {
      const {iSupa, supa, user, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const liquidator = await createWallet(iSupa, user);
      await depositERC721(iSupa, liquidator, nft, nftOracle, NFT_PRICE);
      const nonWalletAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const liquidateTx = liquidator.executeBatch([makeCall(iSupa).liquidate(nonWalletAddress)]);

      await expect(liquidateTx).to.be.revertedWithCustomError(supa, "WalletNonExistent");
    });

    it("when wallet to liquidate is empty should revert", async () => {
      const {iSupa, supa, user, user2, usdc} = await loadFixture(deploySupaFixture);
      const emptyWallet = await createWallet(iSupa, user);
      const liquidator = await createWallet(iSupa, user2);
      await depositERC20(iSupa, liquidator, usdc, toWeiUsdc(1000));

      const liquidateTx = liquidator.executeBatch([makeCall(iSupa).liquidate(emptyWallet.address)]);

      await expect(liquidateTx).to.be.revertedWithCustomError(supa, "NotLiquidatable");
    });

    it("when debt is zero should revert", async () => {
      const {iSupa, supa, user, user2, usdc} = await loadFixture(deploySupaFixture);
      const nonLiquidatable = await createWallet(iSupa, user);
      await depositERC20(iSupa, nonLiquidatable, usdc, toWeiUsdc(1000));
      const liquidator = await createWallet(iSupa, user2);
      await depositERC20(iSupa, liquidator, usdc, toWeiUsdc(1000));

      const liquidateTx = liquidator.executeBatch([
        makeCall(iSupa).liquidate(nonLiquidatable.address),
      ]);

      await expect(liquidateTx).to.be.revertedWithCustomError(supa, "NotLiquidatable");
    });

    it("when collateral is above some debt should revert", async () => {
      // prettier-ignore
      const {
        iSupa,
        supa,
        user, user2, user3,
        usdc,
        weth
      } = await loadFixture(
        deploySupaFixture
      );
      const nonLiquidatable = await createWallet(iSupa, user);
      await depositERC20(iSupa, nonLiquidatable, usdc, toWeiUsdc(1000));
      const liquidator = await createWallet(iSupa, user2);
      await depositERC20(iSupa, liquidator, usdc, toWeiUsdc(1000));
      const other = await createWallet(iSupa, user3);
      await depositERC20(iSupa, other, weth, toWei(1));
      const tx = transfer(iSupa, nonLiquidatable, other, weth.address, toWei(0.1));
      await (await tx).wait();

      const liquidateTx = liquidator.executeBatch([
        makeCall(iSupa).liquidate(nonLiquidatable.address),
      ]);

      await expect(liquidateTx).to.be.revertedWithCustomError(supa, "NotLiquidatable");
    });

    it("when liquidator doesn't have enough collateral to cover the debt difference should revert", async () => {
      // prettier-ignore
      const {
        iSupa,
        supa,
        user, user2, user3,
        usdc,
        weth,
        ethChainlink
      } = await loadFixture(
        deploySupaFixture
      );
      const liquidatable = await createWallet(iSupa, user);
      await depositERC20(iSupa, liquidatable, usdc, toWeiUsdc(10_000));
      const liquidator = await createWallet(iSupa, user2);
      const other = await createWallet(iSupa, user3);
      await depositERC20(iSupa, other, weth, toWei(10));
      const tx = transfer(iSupa, liquidatable, other, weth.address, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = liquidator.executeBatch([
        makeCall(iSupa).liquidate(liquidatable.address),
      ]);

      await expect(liquidateTx).to.revertedWithCustomError(supa, `Insolvent`);
    });

    it("when a wallet tries to liquidate itself should revert", async () => {
      // prettier-ignore
      const {
        iSupa,
        supa,
        user, user2,
        usdc,
        weth,
        ethChainlink
      } = await loadFixture(
        deploySupaFixture
      );
      const liquidatable = await createWallet(iSupa, user);
      await depositERC20(iSupa, liquidatable, usdc, toWeiUsdc(10_000));
      const other = await createWallet(iSupa, user2);
      await depositERC20(iSupa, other, weth, toWei(10));
      const tx = transfer(iSupa, liquidatable, other, weth.address, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = liquidatable.executeBatch([
        makeCall(iSupa).liquidate(liquidatable.address),
      ]);

      await expect(liquidateTx).to.revertedWithCustomError(supa, "Insolvent");
    });

    it("when collateral is smaller than debt should transfer all ERC20s of the wallet to the caller", async () => {
      // prettier-ignore
      const {
        iSupa,
        user, user2, user3,
        usdc,
        weth,
        ethChainlink, getBalances
      } = await loadFixture(
        deploySupaFixture
      );
      const liquidatable = await createWallet(iSupa, user);
      await depositERC20(iSupa, liquidatable, usdc, toWeiUsdc(10_000));
      const liquidator = await createWallet(iSupa, user2);
      await depositERC20(iSupa, liquidator, usdc, toWeiUsdc(10_000));
      const other = await createWallet(iSupa, user3);
      await depositERC20(iSupa, other, weth, toWei(10));
      const tx = transfer(iSupa, liquidatable, other, weth.address, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const {collateral, debt} = await iSupa.getRiskAdjustedPositionValues(liquidatable.address);
      const percentUnderwater = Number(collateral) / Number(debt);
      const liquidateTx = await liquidator.executeBatch([
        makeCall(iSupa).liquidate(liquidatable.address),
      ]);
      await liquidateTx.wait();

      const liquidatableBalance = await getBalances(liquidatable);
      // 10k - positive in USDC. 2_100 - current WETH price in USDC. 4 - debt
      const liquidatableTotal = 10_000 - 4 * 2_100;
      // 0.8 - liqFraction, defined in deploySupaFixture
      const liquidatableTotalAfterLiquidation = liquidatableTotal * 0.8 * percentUnderwater;
      const liquidationOddMoney = toWei(liquidatableTotalAfterLiquidation, USDC_DECIMALS);
      expect(liquidatableBalance.weth).to.equal(0);
      expect(liquidatableBalance.usdc).to.be.approximately(liquidationOddMoney, 2000);
      const liquidatorBalance = await getBalances(liquidator);
      // 10k initial USDC, 10k liquidated USDC - returned money to liquidated account
      expect(liquidatorBalance.usdc).to.be.approximately(
        toWei(10_000 + 10_000 - liquidatableTotalAfterLiquidation, USDC_DECIMALS),
        2000,
      );
      expect(liquidatorBalance.weth).to.be.approximately(-toWei(4), 600_000);
    });

    it("when collateral is smaller then debt should transfer all NFTs of the wallet to the caller", async () => {
      // prettier-ignore
      const {
        iSupa,
        user, user2, user3,
        nft, nftOracle,
        usdc, weth, getBalances
      } = await loadFixture(
        deploySupaFixture
      );
      const liquidatable = await createWallet(iSupa, user);
      const tokenId = await depositERC721(iSupa, liquidatable, nft, nftOracle, 2000);
      const liquidator = await createWallet(iSupa, user2);
      await depositERC20(iSupa, liquidator, usdc, toWeiUsdc(2000));
      const other = await createWallet(iSupa, user3);
      await depositERC20(iSupa, other, weth, toWei(1));
      const tx = transfer(iSupa, liquidatable, other, weth.address, toWei(0.4));
      await (await tx).wait();

      // drop the price of the NFT from 2000 Eth to 1600 Eth. Now wallet should become liquidatable
      await (await nftOracle.setPrice(tokenId, toWeiUsdc(1600))).wait();
      const {collateral, debt} = await iSupa.getRiskAdjustedPositionValues(liquidatable.address);
      const percentUnderwater = Number(collateral) / Number(debt);
      const liquidateTx = await liquidator.executeBatch([
        makeCall(iSupa).liquidate(liquidatable.address),
      ]);
      await liquidateTx.wait();

      const liquidatableBalance = await getBalances(liquidatable);
      // 1600 - current price of the owned NFT. 0.4 eth - debt
      const liquidatableTotal = 1600 - 0.4 * 2000;
      const liquidatableTotalAfterLiquidation = liquidatableTotal * 0.8 * percentUnderwater;
      // 0.8 - liqFraction, defined in deploySupaFixture
      const liquidationOddMoney = toWeiUsdc(liquidatableTotalAfterLiquidation);
      expect(liquidatableBalance.usdc).to.be.approximately(liquidationOddMoney, 2000);
      expect(liquidatableBalance.weth).to.be.equal(0);
      expect(liquidatableBalance.nfts).to.eql([]);
      const liquidatorBalance = await getBalances(liquidator);
      expect(liquidatorBalance.usdc).to.be.approximately(
        // 1 - initial balance; -0.4 transferred debt; 0.8 - liqFactor defined in deploySupaFixture
        toWeiUsdc(2000) - liquidationOddMoney,
        2000,
      );
      expect(liquidatorBalance.weth).to.be.approximately(
        // 1 - initial balance; -0.4 transferred debt; 0.8 - liqFactor defined in deploySupaFixture
        toWei(-0.4),
        60_000,
      );
      expect(liquidatorBalance.nfts).to.eql([[nft.address, tokenId]]);
    });

    it("when collateral is smaller then debt should transfer all ERC20s and all NFTs of the wallet to the caller", async () => {
      // prettier-ignore
      const {
        iSupa,
        user, user2, user3,
        usdc,
        weth,
        nft, nftOracle,
        ethChainlink, getBalances
      } = await loadFixture(
        deploySupaFixture
      );
      const liquidatable = await createWallet(iSupa, user);
      const tokenId = await depositERC721(iSupa, liquidatable, nft, nftOracle, 2000);
      await depositERC20(iSupa, liquidatable, usdc, toWeiUsdc(1_500));
      const liquidator = await createWallet(iSupa, user2);
      await depositERC20(iSupa, liquidator, weth, toWei(1));
      const other = await createWallet(iSupa, user3);
      await depositERC20(iSupa, other, weth, toWei(1));
      const tx = transfer(iSupa, liquidatable, other, weth.address, toWei(1));
      await (await tx).wait();

      // with Eth price 2,000 -> 2,500 the collateral (in USDC) would become
      // nft 2,500 * 0.5 + USDC 1,500 * 0.9 = 2,650
      // and the debt would become 2,500 / 0.9 = 2,777
      // So the debt would exceed the collateral and the wallet becomes liquidatable
      await ethChainlink.setPrice(2_500);
      const {collateral, debt} = await iSupa.getRiskAdjustedPositionValues(liquidatable.address);
      const percentUnderwater = Number(collateral) / Number(debt);
      const liquidateTx = await liquidator.executeBatch([
        makeCall(iSupa).liquidate(liquidatable.address),
      ]);
      await liquidateTx.wait();

      // 2_500 - NFT; 1_500 - USDC; 2_500 - debt; 2_500 - ETH price, so the result is in ETH
      const liquidatableTotal = 2_000 + 1_500 - 2_500;
      const liquidatableTotalAfterLiquidation = liquidatableTotal * 0.8 * percentUnderwater;
      const liquidatableBalance = await getBalances(liquidatable);
      expect(liquidatableBalance.weth).to.equal(0);
      // 0.8 - liqFraction, defined in deploySupaFixture
      expect(liquidatableBalance.usdc).to.be.approximately(
        toWeiUsdc(liquidatableTotalAfterLiquidation),
        2000,
      );
      expect(liquidatableBalance.nfts).to.eql([]);
      const liquidatorBalance = await getBalances(liquidator);
      expect(liquidatorBalance.usdc).to.equal(toWeiUsdc(1_500 - liquidatableTotalAfterLiquidation));
      // 1 - initial balance; -1 transferred debt; 0.8 - liqFactor defined in deploySupaFixture
      expect(liquidatorBalance.weth).to.be.approximately(toWei(0), 132_000);
      expect(liquidatorBalance.nfts).to.eql([[nft.address, tokenId]]);
    });
  });

  describe("#depositERC721", () => {
    it(
      "when user owns the NFT " +
        "should change ownership of the NFT from the user to Supa " +
        "and add NFT to the user Supa wallet",
      async () => {
        const {user, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
        const wallet = await createWallet(iSupa, user);
        const tokenId = await depositUserNft(iSupa, wallet, nft, nftOracle, NFT_PRICE);

        expect(await nft.ownerOf(tokenId)).to.eql(iSupa.address);
        const userNfts = (await iSupa.getCreditAccountERC721(wallet.address)).map(
          ([erc721, tokenId]) => [erc721, tokenId],
        );
        expect(userNfts).to.eql([[nft.address, tokenId]]);
      },
    );

    it(
      "when wallet owns the NFT " +
        "should change ownership of the NFT from wallet to Supa " +
        "and add NFT to the user Supa wallet",
      async () => {
        const {user, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
        const wallet = await createWallet(iSupa, user);

        const tokenId = await depositERC721(iSupa, wallet, nft, nftOracle, NFT_PRICE);

        expect(await nft.ownerOf(tokenId)).to.eql(iSupa.address);
        const userNfts = await iSupa.getCreditAccountERC721(wallet.address);
        expect(userNfts).to.eql([[nft.address, tokenId]]);
      },
    );

    it("when NFT contract is not registered should revert the deposit", async () => {
      const {user, iSupa, supa, unregisteredNft, nftOracle} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);

      const txRevert = depositERC721(iSupa, wallet, unregisteredNft, nftOracle, NFT_PRICE);

      await expect(txRevert).to.be.revertedWithCustomError(supa, `NotRegistered`);
    });

    it("when user is not an owner of NFT should revert the deposit", async () => {
      const {user, user2, iSupa, supa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);
      const wallet2 = await createWallet(iSupa, user2);
      const tokenId = await depositERC721(iSupa, wallet, nft, nftOracle, NFT_PRICE);

      const depositERC721Tx = wallet2.executeBatch([
        makeCall(iSupa).depositERC721(nft.address, tokenId),
      ]);

      await expect(depositERC721Tx).to.be.revertedWithCustomError(supa, `NotNFTOwner`);
    });

    it("when called directly on Supa should revert the deposit", async () => {
      const {user, iSupa, supa, nft} = await loadFixture(deploySupaFixture);
      const mintTx = await nft.mint(user.address);
      const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
      const tokenId = mintEventArgs[0] as BigNumber;
      await (await nft.connect(user).approve(iSupa.address, tokenId)).wait();

      const depositERC721Tx = iSupa.depositERC721(nft.address, tokenId);

      await expect(depositERC721Tx).to.be.revertedWithCustomError(supa, `OnlyWallet`);
    });
  });

  describe("#withdrawERC721", () => {
    it("when called not with wallet should revert", async () => {
      const {user, iSupa, supa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const wallet = await createWallet(iSupa, user);
      const tokenId = await depositERC721(iSupa, wallet, nft, nftOracle, NFT_PRICE);

      const withdrawERC721Tx = iSupa.connect(user).withdrawERC721(nft.address, tokenId);

      await expect(withdrawERC721Tx).to.be.revertedWithCustomError(supa, `OnlyWallet`);
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const {user, user2, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const walletOwner = await createWallet(iSupa, user);
      const tokenId = await depositERC721(iSupa, walletOwner, nft, nftOracle, NFT_PRICE);
      const nonWalletOwner = await createWallet(iSupa, user2);

      const withdrawERC721Tx = nonWalletOwner.executeBatch([
        makeCall(iSupa).withdrawERC721(nft.address, tokenId),
      ]);

      await expect(withdrawERC721Tx).to.be.reverted; // todo: add revert custom error
    });

    it(
      "when user owns the deposited NFT " +
        "should change ownership of the NFT from Supa to user's wallet " +
        "and remove NFT from the user Supa wallet",
      async () => {
        const {user, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
        const wallet = await createWallet(iSupa, user);
        const tokenId = await depositERC721(iSupa, wallet, nft, nftOracle, NFT_PRICE);

        const withdrawERC721Tx = await wallet.executeBatch([
          makeCall(iSupa).withdrawERC721(nft.address, tokenId),
        ]);
        await withdrawERC721Tx.wait();

        expect(await nft.ownerOf(tokenId)).to.eql(wallet.address);
        expect(await iSupa.getCreditAccountERC721(wallet.address)).to.eql([]);
      },
    );

    it(
      "[regression] when user owns two deposited NFT " +
        "should be able to withdraw the first deposited and then the second deposited",
      async () => {
        const {user, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
        const wallet = await createWallet(iSupa, user);
        const _tokenId1 = await depositERC721(iSupa, wallet, nft, nftOracle, NFT_PRICE);
        const tokenId2 = await depositERC721(iSupa, wallet, nft, nftOracle, NFT_PRICE);
        const _tokenId3 = await depositERC721(iSupa, wallet, nft, nftOracle, NFT_PRICE);

        const withdrawERC721Tx = await wallet.executeBatch([
          makeCall(iSupa).withdrawERC721(nft.address, tokenId2),
        ]);
        await expect(withdrawERC721Tx.wait()).not.to.be.reverted;
      },
    );
  });

  describe("#transferERC721", () => {
    it("when called not with wallet should revert", async () => {
      const {user, user2, iSupa, supa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const walletOwner = await createWallet(iSupa, user);
      const walletReceiver = await createWallet(iSupa, user2);
      const tokenId = await depositERC721(iSupa, walletOwner, nft, nftOracle, NFT_PRICE);

      const sendNftTx = iSupa
        .connect(user)
        .transferERC721(nft.address, tokenId, walletReceiver.address);

      await expect(sendNftTx).to.be.revertedWithCustomError(supa, "OnlyWallet");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const {user, user2, user3, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const walletOwner = await createWallet(iSupa, user);
      const nonWalletOwner = await createWallet(iSupa, user2);
      const walletReceiver = await createWallet(iSupa, user3);
      const tokenId = await depositERC721(iSupa, walletOwner, nft, nftOracle, NFT_PRICE);

      const tx = transfer(iSupa, nonWalletOwner, walletReceiver, nft, tokenId);

      await expect(tx).to.be.reverted;
    });

    it("when receiver is not a wallet should revert", async () => {
      const {user, user2, iSupa, supa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const walletOwner = await createWallet(iSupa, user);
      const tokenId = await depositERC721(iSupa, walletOwner, nft, nftOracle, NFT_PRICE);

      // @ts-expect-error - bypass `transfer` type that forbids this invariant in TS
      const tx = transfer(iSupa, walletOwner, user2, nft, tokenId);

      await expect(tx).to.be.revertedWithCustomError(supa, "WalletNonExistent");
    });

    it("when user owns the deposited NFT should be able to move the NFT to another wallet", async () => {
      const {user, user2, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const sender = await createWallet(iSupa, user);
      const receiver = await createWallet(iSupa, user2);
      const tokenId = await depositERC721(iSupa, sender, nft, nftOracle, NFT_PRICE);

      const tx = await transfer(iSupa, sender, receiver, nft, tokenId);
      await tx.wait();

      expect(await iSupa.getCreditAccountERC721(sender.address)).to.eql([]);
      const receiverNfts = await iSupa.getCreditAccountERC721(receiver.address);
      expect(receiverNfts).to.eql([[nft.address, tokenId]]);
    });
  });
  describe("#integrationAPI", () => {
    /*
    it("should set ERC20 token allowance when approve is called", async () => {
      const {user, user2, iSupa, usdc} = await loadFixture(deploySupaFixture);
      const owner = await createWallet(iSupa, user);
      const spender = await createWallet(iSupa, user2);
      const amount = ethers.utils.parseEther("100");

      const tx = await approveErc20(iSupa, owner, spender, usdc.address, amount);
      await tx.wait();

      expect(await iSupa.allowance(usdc.address, owner.address, spender.address)).to.eql(amount);
    });

    it("should deduct ERC20 token allowance after transferFromERC20", async () => {
      const {user, user2, user3, iSupa, weth} = await loadFixture(deploySupaFixture);
      const owner = await createWallet(iSupa, user);
      const spender = await createWallet(iSupa, user2);
      const recipient = await createWallet(iSupa, user3);
      const amount = ethers.utils.parseEther("100");

      await depositERC20(iSupa, owner, weth, toWei(100));

      const approveTx = await approveErc20(iSupa, owner, spender, weth.address, amount);
      await approveTx.wait();

      expect(await iSupa.allowance(weth.address, owner.address, spender.address)).to.eql(amount);

      const transferFromTx = await transferFromErc20(
        iSupa,
        spender,
        owner,
        recipient,
        weth.address,
        amount,
      );
      await transferFromTx.wait();

      expect(await iSupa.allowance(weth.address, owner.address, spender.address)).to.eql(
        ethers.utils.parseEther("0"),
      );
    });

    it("should properly update wallet balance with transferFromERC20", async () => {
      const {user, user2, user3, iSupa, weth, getBalances} = await loadFixture(deploySupaFixture);
      const owner = await createWallet(iSupa, user);
      const spender = await createWallet(iSupa, user2);
      const recipient = await createWallet(iSupa, user3);
      const amount = ethers.utils.parseEther("100");

      await depositERC20(iSupa, owner, weth, toWei(100));

      const approveTx = await approveErc20(iSupa, owner, spender, weth.address, amount);
      await approveTx.wait();

      expect(await iSupa.allowance(weth.address, owner.address, spender.address)).to.eql(amount);

      const ownerBalanceBefore = (await getBalances(owner)).weth;
      const recipientBalanceBefore = (await getBalances(recipient)).weth;

      const transferFromTx = await transferFromErc20(
        iSupa,
        spender,
        owner,
        recipient,
        weth.address,
        amount,
      );
      await transferFromTx.wait();

      const ownerBalanceAfter = (await getBalances(owner)).weth;
      const recipientBalanceAfter = (await getBalances(recipient)).weth;

      expect(ownerBalanceAfter).to.eql(ownerBalanceBefore.sub(amount));
      expect(recipientBalanceAfter).to.eql(recipientBalanceBefore.add(amount));
    });

    it("should revert transferFromERC20 if recipient is not a wallet", async () => {
      const {user, user2, user3, iSupa, weth} = await loadFixture(deploySupaFixture);
      const owner = await createWallet(iSupa, user);
      const spender = await createWallet(iSupa, user2);
      const recipient = user3;
      const amount = ethers.utils.parseEther("100");

      await depositERC20(iSupa, owner, weth, toWei(100));

      const approveTx = await approveErc20(iSupa, owner, spender, weth.address, amount);
      await approveTx.wait();

      await expect(
        spender.executeBatch([
          makeCall(iSupa).transferFromERC20(weth.address, owner.address, recipient.address, amount),
        ]),
      ).to.be.reverted // WithCustomError(iSupa, "WalletNonExistent");
    });

    it("should set approve ERC721 token", async () => {
      const {user, user2, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const owner = await createWallet(iSupa, user);
      const spender = await createWallet(iSupa, user2);

      const tokenId = await depositERC721(iSupa, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(iSupa, owner, spender, nft.address, tokenId);
      await tx.wait();

      expect(await iSupa.getApproved(nft.address, tokenId)).to.eql(spender.address);
    });

    it("should remove approval after ERC721 token transfer", async () => {
      const {user, user2, user3, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const owner = await createWallet(iSupa, user);
      const spender = await createWallet(iSupa, user2);
      const recipient = await createWallet(iSupa, user3);

      const tokenId = await depositERC721(iSupa, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(iSupa, owner, spender, nft.address, tokenId);
      await tx.wait();

      expect(await iSupa.getApproved(nft.address, tokenId)).to.eql(spender.address);

      const transferTx = await transferFromERC721(
        iSupa,
        spender,
        owner,
        recipient,
        nft.address,
        tokenId,
      );
      await transferTx.wait();

      expect(await iSupa.getApproved(nft.address, tokenId)).to.eql(ethers.constants.AddressZero);
    });

    it("should properly update wallet balance with transferFromERC721", async () => {
      const {user, user2, user3, iSupa, nft, nftOracle, getBalances} = await loadFixture(
        deploySupaFixture,
      );
      const owner = await createWallet(iSupa, user);
      const spender = await createWallet(iSupa, user2);
      const recipient = await createWallet(iSupa, user3);

      const tokenId = await depositERC721(iSupa, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(iSupa, owner, spender, nft.address, tokenId);
      await tx.wait();

      const ownerBalanceBefore = (await getBalances(owner)).nfts.length;
      const recipientBalanceBefore = (await getBalances(recipient)).nfts.length;

      expect(await iSupa.getApproved(nft.address, tokenId)).to.eql(spender.address);

      const transferTx = await transferFromERC721(
        iSupa,
        spender,
        owner,
        recipient,
        nft.address,
        tokenId,
      );
      await transferTx.wait();

      const ownerBalanceAfter = (await getBalances(owner)).nfts.length;
      const recipientBalanceAfter = (await getBalances(recipient)).nfts.length;

      expect(ownerBalanceAfter).to.eql(ownerBalanceBefore - 1);
      expect(recipientBalanceAfter).to.eql(recipientBalanceBefore + 1);
    });

    it("should revert transferFromERC721 if recipient is not a wallet", async () => {
      const {user, user2, user3, iSupa, nft, nftOracle} = await loadFixture(deploySupaFixture);
      const owner = await createWallet(iSupa, user);
      const spender = await createWallet(iSupa, user2);

      const tokenId = await depositERC721(iSupa, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(iSupa, owner, spender, nft.address, tokenId);
      await tx.wait();

      await expect(
        spender.executeBatch([
          makeCall(iSupa).transferFromERC721(nft.address, owner.address, user3.address, tokenId),
        ]),
      ).to.be.reverted // WithCustomError(iSupa, "WalletNonExistent");
    });*/

    it("Can transfer via Permit2", async () => {
      const {user, user2, usdc, iSupa, permit2} = await loadFixture(deploySupaFixture);

      const port1 = await createWallet(iSupa, user);
      const port2 = await createWallet(iSupa, user2);

      const hundredDollars = toWei(100, USDC_DECIMALS);
      await usdc.mint(port1.address, hundredDollars);

      const signature = await signPermit2TransferFrom(
        permit2,
        usdc.address,
        hundredDollars,
        port2.address,
        1,
        user,
      );
      await port2.executeBatch([
        makeCall(permit2).permitTransferFrom(
          {
            permitted: {token: usdc.address, amount: hundredDollars},
            nonce: 1,
            deadline: ethers.constants.MaxUint256,
          },
          {to: port2.address, requestedAmount: hundredDollars},
          port1.address,
          signature,
        ),
      ]);
      expect(await usdc.balanceOf(port1.address)).to.eq(0);
      expect(await usdc.balanceOf(port2.address)).to.eq(hundredDollars);
    });
  });

  // describe("Interest Rate tests", () => {
  // const oneHundredUsdc = toWei(100, USDC_DECIMALS);
  //   it("Should return the base interest rate with 0% utilization", async () => {
  //     const {user, user2, iSupa, usdc, weth} = await loadFixture(deploySupaFixture);

  //     // setup 1st user
  //     const wallet1 = await createWallet(iSupa, user);
  //     expect(await wallet1.owner()).to.equal(user.address);
  //     await usdc.mint(wallet1.address, oneHundredUsdc);
  //     await wallet1.executeBatch([makeCall(iSupa).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

  //     // setup 2nd user
  //     const wallet2 = await createWallet(iSupa, user2);
  //     expect(await wallet2.owner()).to.equal(user2.address);
  //     await weth.mint(wallet2.address, toWei(2));
  //     await wallet2.executeBatch([makeCall(iSupa).depositERC20(weth.address, toWei(2))]);

  //     const erc20Idx: BigNumber = BigNumber.from(0);
  //     const interestRate: BigNumber = await iSupa.computeInterestRate(erc20Idx);
  //     console.log("interestRate", interestRate.toString());
  //     expect(interestRate).to.equal(BigNumber.from("0"));
  //   });
  //     const erc20Idx: BigNumber = BigNumber.from(0);
  //     const interestRate: BigNumber = await iSupa.computeInterestRate(erc20Idx);
  //     expect(interestRate).to.equal(BigNumber.from("0"));
  //   });

  //   it("Should return the correct interest rate with 0 < utilization < target", async () => {
  //     const {user, user2, iSupa, usdc, weth} = await loadFixture(deploySupaFixture);
  //   it("Should return the correct interest rate with 0 < utilization < target", async () => {
  //     const {user, user2, iSupa, usdc, weth} = await loadFixture(deploySupaFixture);

  //     // setup 1st user
  //     const wallet1 = await createWallet(iSupa, user);
  //     expect(await wallet1.owner()).to.equal(user.address);
  //     await usdc.mint(wallet1.address, oneHundredUsdc);
  //     await wallet1.executeBatch([makeCall(iSupa).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC
  //     // setup 1st user
  //     const wallet1 = await createWallet(iSupa, user);
  //     expect(await wallet1.owner()).to.equal(user.address);
  //     await usdc.mint(wallet1.address, oneHundredUsdc);
  //     await wallet1.executeBatch([makeCall(iSupa).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

  //     // setup 2nd user
  //     const wallet2 = await createWallet(iSupa, user2);
  //     expect(await wallet2.owner()).to.equal(user2.address);
  //     await weth.mint(wallet2.address, toWei(2));
  //     await wallet2.executeBatch([makeCall(iSupa).depositERC20(weth.address, toWei(2))]);
  //     // setup 2nd user
  //     const wallet2 = await createWallet(iSupa, user2);
  //     expect(await wallet2.owner()).to.equal(user2.address);
  //     await weth.mint(wallet2.address, toWei(2));
  //     await wallet2.executeBatch([makeCall(iSupa).depositERC20(weth.address, toWei(2))]);

  //     // check what the max to borrow of USDC is (90 USDC)
  //     const maxBorrowable = await iSupa.getMaximumWithdrawableOfERC20(usdc.address);
  //     // check what the max to borrow of USDC is (90 USDC)
  //     const maxBorrowable = await iSupa.getMaximumWithdrawableOfERC20(usdc.address);

  //     const utilization = 0.8696;

  //     // borrow 72 USDC (.8 * 90)
  //     await wallet2.executeBatch([
  //       makeCall(iSupa).depositERC20(usdc.address, -maxBorrowable - 1), // to borrow use negative
  //     ]);

  //     const erc20Idx: BigNumber = BigNumber.from(0);
  //     const interestRate: BigNumber = await iSupa.computeInterestRate(erc20Idx);
  //     console.log("interestRate", interestRate.toString());
  //     expect(interestRate).to.equal(BigNumber.from("2000"));
  //   });

  //   it("Should return the target interest rate at the target utilization", async () => {
  //     const {user, user2, iSupa, usdc, weth} = await loadFixture(deploySupaFixture);

  //     // setup 1st user
  //     const wallet1 = await createWallet(iSupa, user);
  //     expect(await wallet1.owner()).to.equal(user.address);
  //     await usdc.mint(wallet1.address, oneHundredUsdc);
  //     await wallet1.executeBatch([makeCall(iSupa).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

  //     // setup 2nd user
  //     const wallet2 = await createWallet(iSupa, user2);
  //     expect(await wallet2.owner()).to.equal(user2.address);
  //     await weth.mint(wallet2.address, toWei(2));
  //     await wallet2.executeBatch([makeCall(iSupa).depositERC20(weth.address, toWei(2))]);

  //     // check what the max to borrow of USDC is (90 USDC)
  //     const maxBorrowable = await iSupa.getMaximumWithdrawableOfERC20(usdc.address);

  //     const targetUtilization = 0.9;

  //     // borrow 72 USDC (.8 * 90)
  //     await wallet2.executeBatch([
  //       makeCall(iSupa).depositERC20(usdc.address, -maxBorrowable * targetUtilization), // to borrow use negative
  //     ]);

  //     const erc20Idx: BigNumber = BigNumber.from(0);
  //     const interestRate: BigNumber = await iSupa.computeInterestRate(erc20Idx);
  //     console.log("interestRate", interestRate.toString());
  //     expect(interestRate).to.equal(BigNumber.from("4000"));
  //   });

  //   it("Should return the correct interest rate with target < utilization < 100", async () => {
  //     const {user, user2, iSupa, usdc, weth} = await loadFixture(deploySupaFixture);

  //     // setup 1st user
  //     const wallet1 = await createWallet(iSupa, user);
  //     expect(await wallet1.owner()).to.equal(user.address);
  //     await usdc.mint(wallet1.address, oneHundredUsdc);
  //     await wallet1.executeBatch([makeCall(iSupa).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

  //     // setup 2nd user
  //     const wallet2 = await createWallet(iSupa, user2);
  //     expect(await wallet2.owner()).to.equal(user2.address);
  //     await weth.mint(wallet2.address, toWei(2));
  //     await wallet2.executeBatch([makeCall(iSupa).depositERC20(weth.address, toWei(2))]);

  //     // check what the max to borrow of USDC is (90 USDC)
  //     const maxBorrowable = await iSupa.getMaximumWithdrawableOfERC20(usdc.address);

  //     const utilization = 0.95;

  //     // borrow 72 USDC (.8 * 90)
  //     await wallet2.executeBatch([
  //       makeCall(iSupa).depositERC20(usdc.address, -maxBorrowable * utilization), // to borrow use negative
  //     ]);

  //     const erc20Idx: BigNumber = BigNumber.from(0);
  //     const interestRate: BigNumber = await iSupa.computeInterestRate(erc20Idx);
  //     console.log("interestRate", interestRate.toString());
  //     expect(interestRate).to.equal(BigNumber.from("52000"));
  //   });

  //   it("Should return the max interest rate with 100% utilization", async () => {
  //     const {user, user2, iSupa, usdc, weth} = await loadFixture(deploySupaFixture);

  //     // setup 1st user
  //     const wallet1 = await createWallet(iSupa, user);
  //     expect(await wallet1.owner()).to.equal(user.address);
  //     await usdc.mint(wallet1.address, oneHundredUsdc);
  //     await wallet1.executeBatch([makeCall(iSupa).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

  //     // setup 2nd user
  //     const wallet2 = await createWallet(iSupa, user2);
  //     expect(await wallet2.owner()).to.equal(user2.address);
  //     await weth.mint(wallet2.address, toWei(2));
  //     await wallet2.executeBatch([makeCall(iSupa).depositERC20(weth.address, toWei(2))]);

  //     // check what the max to borrow of USDC is (90 USDC)
  //     const maxBorrowable = await iSupa.getMaximumWithdrawableOfERC20(usdc.address);

  //     // borrow 90 USDC
  //     await wallet2.executeBatch([
  //       makeCall(iSupa).depositERC20(usdc.address, -maxBorrowable), // to borrow use negative
  //     ]);

  //     const erc20Idx: BigNumber = BigNumber.from(0);
  //     const interestRate: BigNumber = await iSupa.computeInterestRate(erc20Idx);
  //     console.log("interestRate", interestRate.toString());
  //     expect(interestRate).to.equal(BigNumber.from("100000"));
  //   });

  //   it("Should not increase interest rate when different asset is borrowed", async () => {
  //     const {user, user2, iSupa, usdc, weth} = await loadFixture(deploySupaFixture);

  //     // setup 1st user
  //     const wallet1 = await createWallet(iSupa, user);
  //     expect(await wallet1.owner()).to.equal(user.address);
  //     await usdc.mint(wallet1.address, oneHundredUsdc);
  //     await wallet1.executeBatch([makeCall(iSupa).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

  //     // setup 2nd user
  //     const wallet2 = await createWallet(iSupa, user2);
  //     expect(await wallet2.owner()).to.equal(user2.address);
  //     await weth.mint(wallet2.address, toWei(2));
  //     await wallet2.executeBatch([makeCall(iSupa).depositERC20(weth.address, toWei(2))]);

  //     // check what the max to borrow of USDC is (90 USDC)
  //     const maxBorrowable = await iSupa.getMaximumWithdrawableOfERC20(usdc.address);

  //     // borrow 90 USDC
  //     await wallet2.executeBatch([
  //       makeCall(iSupa).depositERC20(usdc.address, -maxBorrowable), // to borrow use negative
  //     ]);

  //     const erc20Idx: BigNumber = BigNumber.from(1);
  //     const interestRate: BigNumber = await iSupa.computeInterestRate(erc20Idx);
  //     expect(interestRate).to.equal(BigNumber.from("0"));
  //   });
  // });
});
