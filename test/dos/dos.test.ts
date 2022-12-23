import type {BigNumber, BigNumberish, ContractTransaction} from "ethers";
import type {
  DSafeLogic,
  TestNFT,
  MockNFTOracle,
  TestERC20,
  WETH9,
  IDOS,
} from "../../typechain-types";

import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  DSafeLogic__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
} from "../../typechain-types";
import {toWei, toWeiUsdc} from "../../lib/numbers";
import {getEventParams} from "../../lib/events";
import {getFixedGasSigners} from "../../lib/hardhat/fixedGasSigners";
import {signPermit2TransferFrom} from "../../lib/signers";
import {makeCall, createDSafe} from "../../lib/calls";
import {Chainlink, deployDos, deployFixedAddressForTests} from "../../lib/deploy";

const USDC_PRICE = 1;
const ETH_PRICE = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

const NFT_PRICE = 200;

const tenThousandUsdc = toWeiUsdc(10_000);
const oneEth = toWei(1);

describe("DOS", () => {
  // we define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployDOSFixture() {
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
    );
    const ethChainlink = await Chainlink.deploy(owner, ETH_PRICE, 8, USDC_DECIMALS, WETH_DECIMALS);

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    const {dos, versionManager} = await deployDos(
      owner.address,
      anyswapCreate2Deployer,
      "0x01",
      owner,
    );
    const proxyLogic = await new DSafeLogic__factory(owner).deploy(dos.address);
    await versionManager.addVersion(2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    await dos.setConfig({
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    await dos.addERC20Info(
      usdc.address,
      "USD Coin",
      "USDC",
      USDC_DECIMALS,
      usdcChainlink.oracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    );

    await dos.addERC20Info(
      weth.address,
      "Wrapped ETH",
      "WETH",
      WETH_DECIMALS,
      ethChainlink.oracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    );

    await dos.addNFTInfo(nft.address, nftOracle.address, toWei(0.5));

    const getBalances = async (
      dSafe: DSafeLogic,
    ): Promise<{
      nfts: [nftContract: string, tokenId: BigNumber][];
      usdc: BigNumber;
      weth: BigNumber;
    }> => {
      const [nfts, usdcBal, wethBal] = await Promise.all([
        dos.viewNFTs(dSafe.address),
        dos.getDAccountERC20(dSafe.address, usdc.address),
        dos.getDAccountERC20(dSafe.address, weth.address),
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
      dos,
      permit2,
      getBalances,
    };
  }

  describe("Dos tests", () => {
    it("User can create dSafe", async () => {
      const {user, dos} = await loadFixture(deployDOSFixture);

      const dSafe = await createDSafe(dos, user);
      expect(await dSafe.owner()).to.equal(user.address);
    });

    it("User can deposit money", async () => {
      const {user, dos, usdc, getBalances} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);

      await depositErc20(dos, dSafe, usdc, tenThousandUsdc);

      expect((await getBalances(dSafe)).usdc).to.equal(tenThousandUsdc);
      expect(await usdc.balanceOf(dos.address)).to.equal(tenThousandUsdc);
    });

    it("User can transfer money", async () => {
      const {user, user2, dos, usdc, getBalances} = await loadFixture(deployDOSFixture);
      const sender = await createDSafe(dos, user);
      const receiver = await createDSafe(dos, user2);
      await depositErc20(dos, sender, usdc, tenThousandUsdc);

      const tx = transfer(dos, sender, receiver, usdc.address, tenThousandUsdc);
      await (await tx).wait();

      expect((await getBalances(sender)).usdc).to.equal(0);
      expect((await getBalances(receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User can deposit and transfer money in arbitrary order", async () => {
      const {user, user2, dos, usdc, getBalances} = await loadFixture(deployDOSFixture);
      const sender = await createDSafe(dos, user);
      const receiver = await createDSafe(dos, user2);
      await usdc.mint(sender.address, tenThousandUsdc);

      await sender.executeBatch([
        makeCall(dos).transfer(usdc.address, receiver.address, tenThousandUsdc),
        makeCall(dos).depositERC20(usdc.address, tenThousandUsdc),
      ]);

      expect((await getBalances(sender)).usdc).to.equal(0);
      expect((await getBalances(receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User cannot send more then they own", async () => {
      const {user, user2, dos, usdc} = await loadFixture(deployDOSFixture);
      const sender = await createDSafe(dos, user);
      const receiver = await createDSafe(dos, user2);
      await depositErc20(dos, sender, usdc, toWeiUsdc(10_000));

      const tx = transfer(dos, sender, receiver, usdc.address, toWeiUsdc(20_000));

      await expect(tx).to.be.revertedWith("Result of operation is not sufficient liquid");
    });

    it("User can send more ERC20 then they have", async () => {
      const {user, user2, dos, usdc, weth, getBalances} = await loadFixture(deployDOSFixture);
      const sender = await createDSafe(dos, user);
      await depositErc20(dos, sender, usdc, tenThousandUsdc);
      const receiver = await createDSafe(dos, user2);
      // put weth in system so we can borrow weth
      const someOther = await createDSafe(dos, user);
      await depositErc20(dos, someOther, weth, toWei(2));

      const tx = await transfer(dos, sender, receiver, weth.address, oneEth);
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
        dos,
        usdc,
        weth,
        ethChainlink, getBalances
      } = await loadFixture(deployDOSFixture);
      const liquidatable = await createDSafe(dos, user);
      await depositErc20(dos, liquidatable, usdc, tenThousandUsdc);
      const liquidator = await createDSafe(dos, user2);
      // ensure that liquidator would have enough collateral to compensate
      // negative balance of collateral/debt obtained from liquidatable
      await depositErc20(dos, liquidator, usdc, tenThousandUsdc);
      // put WETH in system so we can borrow weth
      const someOther = await createDSafe(dos, user);
      await depositErc20(dos, someOther, weth, toWei(2));
      await ethChainlink.setPrice(2_000);

      // generate a debt on liquidatable
      const tx = transfer(dos, liquidatable, someOther, weth.address, oneEth);
      await (await tx).wait();
      // make liquidatable debt overcome collateral. Now it can be liquidated
      await ethChainlink.setPrice(9_000);
      await liquidator.executeBatch([makeCall(dos).liquidate(liquidatable.address)]);

      const liquidatableBalances = await getBalances(liquidatable);
      const liquidatorBalances = await getBalances(liquidator);
      // 10_000 - balance in USDC; 9_000 - debt of 1 ETH; 0.8 - liqFraction
      const liquidationLeftover = toWei((10_000 - 9_000) * 0.8, USDC_DECIMALS); // 800 USDC in ETH
      expect(liquidatableBalances.weth).to.equal(0);
      expect(liquidatableBalances.usdc).to.be.approximately(liquidationLeftover, 1000);
      expect(liquidatorBalances.weth).to.equal(-oneEth); // own 10k + 10k of liquidatable
      expect(liquidatorBalances.usdc).to.be.approximately(
        tenThousandUsdc + tenThousandUsdc - liquidationLeftover,
        1000,
      );
    });

    it("Solvent position can not be liquidated", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2,
        usdc,
        weth
      } = await loadFixture(
        deployDOSFixture,
      );
      const nonLiquidatable = await createDSafe(dos, user);
      const liquidator = await createDSafe(dos, user2);
      // put WETH in system so we can borrow weth
      const other = await createDSafe(dos, user);
      await depositErc20(dos, other, weth, toWei(0.25));
      await depositErc20(dos, nonLiquidatable, usdc, tenThousandUsdc);
      const tx = transfer(dos, nonLiquidatable, other, weth.address, oneEth);
      await (await tx).wait();

      const liquidationTx = liquidator.executeBatch([
        makeCall(dos).liquidate(nonLiquidatable.address),
      ]);

      await expect(liquidationTx).to.be.revertedWith("DSafe is not liquidatable");
    });
  });

  describe("#computePosition", () => {
    it("when dSafe doesn't exist should return 0", async () => {
      const {dos} = await loadFixture(deployDOSFixture);
      const nonDSafeAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const computeTx = dos.computePosition(nonDSafeAddress);

      await expect(computeTx).to.be.revertedWith("Recipient dSafe doesn't exist");
    });

    it("when dSafe is empty should return 0", async () => {
      const {dos, user} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);

      const [totalValue, collateral, debt] = await dos.computePosition(dSafe.address);

      expect(totalValue).to.equal(0);
      expect(collateral).to.equal(0);
      expect(debt).to.equal(0);
    });

    it("when dSafe has an ERC20 should return the ERC20 value", async () => {
      const {dos, user, usdc} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);
      await depositErc20(dos, dSafe, usdc, toWei(10_000, USDC_DECIMALS));

      const position = await dos.computePosition(dSafe.address);

      const [total, collateral, debt] = position;
      expect(total).to.be.approximately(toWei(10_000, USDC_DECIMALS), 1000);
      // collateral factor is defined in setupDos, and it's 0.9
      expect(collateral).to.be.approximately(toWei(9000, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("when dSafe has multiple ERC20s should return total ERC20s value", async () => {
      const {dos, user, usdc, weth} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);

      await Promise.all([
        depositErc20(dos, dSafe, usdc, toWeiUsdc(10_000)),
        depositErc20(dos, dSafe, weth, toWei(1)),
      ]);

      const position = await dos.computePosition(dSafe.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWei(12_000, USDC_DECIMALS));
      // collateral factor is defined in setupDos, and it's 0.9. 12 * 0.9 = 10.8
      expect(collateral).to.be.approximately(toWei(10_800, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("when dSafe has an NFT should return the NFT value", async () => {
      const {dos, user, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);

      await depositNft(dos, dSafe, nft, nftOracle, NFT_PRICE);

      const position = await dos.computePosition(dSafe.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWeiUsdc(NFT_PRICE));
      // collateral factor is defined in setupDos, and it's 0.5
      expect(collateral).to.equal(toWeiUsdc(NFT_PRICE / 2));
      expect(debt).to.equal(0);
    });

    it("when dSafe has a few NFTs should return the total NFTs value", async () => {
      const {dos, user, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);

      await Promise.all([
        depositNft(dos, dSafe, nft, nftOracle, 1),
        depositNft(dos, dSafe, nft, nftOracle, 2),
        depositNft(dos, dSafe, nft, nftOracle, 3),
      ]);

      const position = await dos.computePosition(dSafe.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWeiUsdc(6)); // 1 + 2 + 3
      // collateral factor is defined in setupDos, and it's 0.5
      expect(collateral).to.be.approximately(toWeiUsdc(3), 1000);
      expect(debt).to.equal(0);
    });

    it("when dSafe has ERC20s and NFTs should return their total value", async () => {
      // prettier-ignore
      const {
        dos,
        user,
        usdc,
        weth,
        nft, nftOracle
      } =
        await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);

      await Promise.all([
        depositNft(dos, dSafe, nft, nftOracle, 100),
        depositNft(dos, dSafe, nft, nftOracle, 200),
        depositNft(dos, dSafe, nft, nftOracle, 300),
        depositErc20(dos, dSafe, usdc, toWeiUsdc(10_000)),
        depositErc20(dos, dSafe, weth, toWei(1)),
      ]);

      const position = await dos.computePosition(dSafe.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWei(12_600, USDC_DECIMALS));
      // collateral factor is defined in setupDos,
      // and it's 0.5 for nft and 0.9 for erc20s.
      expect(collateral).to.be.approximately(toWei(12_000 * 0.9 + 600 * 0.5, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });
  });

  describe("#liquidate", () => {
    it("when called directly on DOS should revert", async () => {
      const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);
      await depositNft(dos, dSafe, nft, nftOracle, 1600);

      const depositNftTx = dos.liquidate(dSafe.address);

      await expect(depositNftTx).to.be.revertedWith("Only dSafe can execute");
    });

    it("when dSafe to liquidate doesn't exist should revert", async () => {
      const {dos, user, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const liquidator = await createDSafe(dos, user);
      await depositNft(dos, liquidator, nft, nftOracle, NFT_PRICE);
      const nonDSafeAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const liquidateTx = liquidator.executeBatch([makeCall(dos).liquidate(nonDSafeAddress)]);

      await expect(liquidateTx).to.be.revertedWith("Recipient dSafe doesn't exist");
    });

    it("when dSafe to liquidate is empty should revert", async () => {
      const {dos, user, user2, usdc} = await loadFixture(deployDOSFixture);
      const emptyDSafe = await createDSafe(dos, user);
      const liquidator = await createDSafe(dos, user2);
      await depositErc20(dos, liquidator, usdc, toWeiUsdc(1000));

      const liquidateTx = liquidator.executeBatch([makeCall(dos).liquidate(emptyDSafe.address)]);

      await expect(liquidateTx).to.be.revertedWith("DSafe is not liquidatable");
    });

    it("when debt is zero should revert", async () => {
      const {dos, user, user2, usdc} = await loadFixture(deployDOSFixture);
      const nonLiquidatable = await createDSafe(dos, user);
      await depositErc20(dos, nonLiquidatable, usdc, toWeiUsdc(1000));
      const liquidator = await createDSafe(dos, user2);
      await depositErc20(dos, liquidator, usdc, toWeiUsdc(1000));

      const liquidateTx = liquidator.executeBatch([
        makeCall(dos).liquidate(nonLiquidatable.address),
      ]);

      await expect(liquidateTx).to.be.revertedWith("DSafe is not liquidatable");
    });

    it("when collateral is above some debt should revert", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc,
        weth
      } = await loadFixture(
        deployDOSFixture
      );
      const nonLiquidatable = await createDSafe(dos, user);
      await depositErc20(dos, nonLiquidatable, usdc, toWeiUsdc(1000));
      const liquidator = await createDSafe(dos, user2);
      await depositErc20(dos, liquidator, usdc, toWeiUsdc(1000));
      const other = await createDSafe(dos, user3);
      await depositErc20(dos, other, weth, toWei(1));
      const tx = transfer(dos, nonLiquidatable, other, weth.address, toWei(0.1));
      await (await tx).wait();

      const liquidateTx = liquidator.executeBatch([
        makeCall(dos).liquidate(nonLiquidatable.address),
      ]);

      await expect(liquidateTx).to.be.revertedWith("DSafe is not liquidatable");
    });

    it("when liquidator doesn't have enough collateral to cover the debt difference should revert", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc,
        weth,
        ethChainlink
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createDSafe(dos, user);
      await depositErc20(dos, liquidatable, usdc, toWeiUsdc(10_000));
      const liquidator = await createDSafe(dos, user2);
      const other = await createDSafe(dos, user3);
      await depositErc20(dos, other, weth, toWei(10));
      const tx = transfer(dos, liquidatable, other, weth.address, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = liquidator.executeBatch([makeCall(dos).liquidate(liquidatable.address)]);

      await expect(liquidateTx).to.revertedWith("Result of operation is not sufficient liquid");
    });

    it("when a dSafe trys to liquidate itself should revert", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2,
        usdc,
        weth,
        ethChainlink
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createDSafe(dos, user);
      await depositErc20(dos, liquidatable, usdc, toWeiUsdc(10_000));
      const other = await createDSafe(dos, user2);
      await depositErc20(dos, other, weth, toWei(10));
      const tx = transfer(dos, liquidatable, other, weth.address, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = liquidatable.executeBatch([
        makeCall(dos).liquidate(liquidatable.address),
      ]);

      await expect(liquidateTx).to.revertedWith("Result of operation is not sufficient liquid");
    });

    it("when collateral is smaller then debt should transfer all ERC20s of the dSafe to the caller", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc,
        weth,
        ethChainlink, getBalances
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createDSafe(dos, user);
      await depositErc20(dos, liquidatable, usdc, toWeiUsdc(10_000));
      const liquidator = await createDSafe(dos, user2);
      await depositErc20(dos, liquidator, usdc, toWeiUsdc(10_000));
      const other = await createDSafe(dos, user3);
      await depositErc20(dos, other, weth, toWei(10));
      const tx = transfer(dos, liquidatable, other, weth.address, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = await liquidator.executeBatch([
        makeCall(dos).liquidate(liquidatable.address),
      ]);
      await liquidateTx.wait();

      const liquidatableBalance = await getBalances(liquidatable);
      // 10k - positive in USDC. 2_100 - current WETH price in USDC. 4 - debt
      const liquidatableTotal = 10_000 - 4 * 2_100;
      // 0.8 - liqFraction, defined in deployDOSFixture
      const liquidationOddMoney = toWei(liquidatableTotal * 0.8, USDC_DECIMALS);
      expect(liquidatableBalance.weth).to.equal(0);
      expect(liquidatableBalance.usdc).to.be.approximately(liquidationOddMoney, 2000);
      const liquidatorBalance = await getBalances(liquidator);
      // 10k initial USDC, 10k liquidated USDC - returned money to liquidated account
      expect(liquidatorBalance.usdc).to.be.approximately(
        toWei(10_000 + 10_000 - liquidatableTotal * 0.8, USDC_DECIMALS),
        2000,
      );
      expect(liquidatorBalance.weth).to.equal(-toWei(4));
    });

    it("when collateral is smaller then debt should transfer all NFTs of the dSafe to the caller", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        nft, nftOracle,
        usdc, weth, getBalances
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createDSafe(dos, user);
      const tokenId = await depositNft(dos, liquidatable, nft, nftOracle, 2000);
      const liquidator = await createDSafe(dos, user2);
      await depositErc20(dos, liquidator, usdc, toWeiUsdc(2000));
      const other = await createDSafe(dos, user3);
      await depositErc20(dos, other, weth, toWei(1));
      const tx = transfer(dos, liquidatable, other, weth.address, toWei(0.4));
      await (await tx).wait();

      // drop the price of the NFT from 2000 Eth to 1600 Eth. Now dSafe should become liquidatable
      await (await nftOracle.setPrice(tokenId, toWeiUsdc(1600))).wait();
      const liquidateTx = await liquidator.executeBatch([
        makeCall(dos).liquidate(liquidatable.address),
      ]);
      await liquidateTx.wait();

      const liquidatableBalance = await getBalances(liquidatable);
      // 1600 - current price of the owned NFT. 0.4 eth - debt
      const liquidatableTotal = 1600 - 0.4 * 2000;
      // 0.8 - liqFraction, defined in deployDOSFixture
      const liquidationOddMoney = toWeiUsdc(liquidatableTotal * 0.8);
      expect(liquidatableBalance.usdc).to.be.approximately(liquidationOddMoney, 2000);
      expect(liquidatableBalance.weth).to.be.equal(0);
      expect(liquidatableBalance.nfts).to.eql([]);
      const liquidatorBalance = await getBalances(liquidator);
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
      expect(liquidatorBalance.nfts).to.eql([[nft.address, tokenId]]);
    });

    it("when collateral is smaller then debt should transfer all ERC20s and all NFTs of the dSafe to the caller", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc,
        weth,
        nft, nftOracle,
        ethChainlink, getBalances
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createDSafe(dos, user);
      const tokenId = await depositNft(dos, liquidatable, nft, nftOracle, 2000);
      await depositErc20(dos, liquidatable, usdc, toWeiUsdc(1_500));
      const liquidator = await createDSafe(dos, user2);
      await depositErc20(dos, liquidator, weth, toWei(1));
      const other = await createDSafe(dos, user3);
      await depositErc20(dos, other, weth, toWei(1));
      const tx = transfer(dos, liquidatable, other, weth.address, toWei(1));
      await (await tx).wait();

      // with Eth price 2,000 -> 2,500 the collateral (in USDC) would become
      // nft 2,500 * 0.5 + USDC 1,500 * 0.9 = 2,650
      // and the debt would become 2,500 / 0.9 = 2,777
      // So the debt would exceed the collateral and the dSafe becomes liquidatable
      await ethChainlink.setPrice(2_500);
      const liquidateTx = await liquidator.executeBatch([
        makeCall(dos).liquidate(liquidatable.address),
      ]);
      await liquidateTx.wait();

      // 2_500 - NFT; 1_500 - USDC; 2_500 - debt; 2_500 - ETH price, so the result is in ETH
      const liquidatableTotal = 2_000 + 1_500 - 2_500;
      const liquidatableBalance = await getBalances(liquidatable);
      expect(liquidatableBalance.weth).to.equal(0);
      // 0.8 - liqFraction, defined in deployDOSFixture
      expect(liquidatableBalance.usdc).to.be.approximately(
        toWeiUsdc(liquidatableTotal * 0.8),
        2000,
      );
      expect(liquidatableBalance.nfts).to.eql([]);
      const liquidatorBalance = await getBalances(liquidator);
      expect(liquidatorBalance.usdc).to.equal(toWeiUsdc(1_500 - liquidatableTotal * 0.8));
      // 1 - initial balance; -1 transferred debt; 0.8 - liqFactor defined in deployDOSFixture
      expect(liquidatorBalance.weth).to.be.approximately(toWei(0), 2000);
      expect(liquidatorBalance.nfts).to.eql([[nft.address, tokenId]]);
    });
  });

  describe("#depositNFT", () => {
    it(
      "when user owns the NFT " +
        "should change ownership of the NFT from the user to DOS " +
        "and add NFT to the user DOS dSafe",
      async () => {
        const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
        const dSafe = await createDSafe(dos, user);
        const tokenId = await depositUserNft(dos, dSafe, nft, nftOracle, NFT_PRICE);

        expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
        const userNfts = (await dos.viewNFTs(dSafe.address)).map(([erc721, tokenId]) => [
          erc721,
          tokenId,
        ]);
        expect(userNfts).to.eql([[nft.address, tokenId]]);
      },
    );

    it(
      "when dSafe owns the NFT " +
        "should change ownership of the NFT from dSafe to DOS " +
        "and add NFT to the user DOS dSafe",
      async () => {
        const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
        const dSafe = await createDSafe(dos, user);

        const tokenId = await depositNft(dos, dSafe, nft, nftOracle, NFT_PRICE);

        expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
        const userNfts = await dos.viewNFTs(dSafe.address);
        expect(userNfts).to.eql([[nft.address, tokenId]]);
      },
    );

    it("when NFT contract is not registered should revert the deposit", async () => {
      const {user, dos, unregisteredNft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);

      const txRevert = depositNft(dos, dSafe, unregisteredNft, nftOracle, NFT_PRICE);

      await expect(txRevert).to.be.revertedWith("Cannot add NFT of unknown NFT contract");
    });

    it("when user is not an owner of NFT should revert the deposit", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);
      const dSafe2 = await createDSafe(dos, user2);
      const tokenId = await depositNft(dos, dSafe, nft, nftOracle, NFT_PRICE);

      const depositNftTx = dSafe2.executeBatch([makeCall(dos).depositNFT(nft.address, tokenId)]);

      await expect(depositNftTx).to.be.revertedWith(
        "NFT must be owned the the user or user's dSafe",
      );
    });

    it("when called directly on DOS should revert the deposit", async () => {
      const {user, dos, nft} = await loadFixture(deployDOSFixture);
      const mintTx = await nft.mint(user.address);
      const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
      const tokenId = mintEventArgs[0] as BigNumber;
      await (await nft.connect(user).approve(dos.address, tokenId)).wait();

      const depositNftTx = dos.depositNFT(nft.address, tokenId);

      await expect(depositNftTx).to.be.revertedWith("Only dSafe can execute");
    });
  });

  describe("#claimNFT", () => {
    it("when called not with dSafe should revert", async () => {
      const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafe = await createDSafe(dos, user);
      const tokenId = await depositNft(dos, dSafe, nft, nftOracle, NFT_PRICE);

      const claimNftTx = dos.connect(user).claimNFT(nft.address, tokenId);

      await expect(claimNftTx).to.be.revertedWith("Only dSafe can execute");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafeOwner = await createDSafe(dos, user);
      const tokenId = await depositNft(dos, dSafeOwner, nft, nftOracle, NFT_PRICE);
      const nonDSafeOwner = await createDSafe(dos, user2);

      const claimNftTx = nonDSafeOwner.executeBatch([makeCall(dos).claimNFT(nft.address, tokenId)]);

      await expect(claimNftTx).to.be.revertedWith("NFT must be in the user's dSafe");
    });

    it(
      "when user owns the deposited NFT " +
        "should change ownership of the NFT from DOS to user's dSafe " +
        "and remove NFT from the user DOS dSafe",
      async () => {
        const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
        const dSafe = await createDSafe(dos, user);
        const tokenId = await depositNft(dos, dSafe, nft, nftOracle, NFT_PRICE);

        const claimNftTx = await dSafe.executeBatch([makeCall(dos).claimNFT(nft.address, tokenId)]);
        await claimNftTx.wait();

        expect(await nft.ownerOf(tokenId)).to.eql(dSafe.address);
        expect(await dos.viewNFTs(dSafe.address)).to.eql([]);
      },
    );
  });

  describe("#sendNFT", () => {
    it("when called not with dSafe should revert", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafeOwner = await createDSafe(dos, user);
      const dSafeReceiver = await createDSafe(dos, user2);
      const tokenId = await depositNft(dos, dSafeOwner, nft, nftOracle, NFT_PRICE);

      const sendNftTx = dos.connect(user).sendNFT(nft.address, tokenId, dSafeReceiver.address);

      await expect(sendNftTx).to.be.revertedWith("Only dSafe can execute");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const {user, user2, user3, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafeOwner = await createDSafe(dos, user);
      const nonDSafeOwner = await createDSafe(dos, user2);
      const dSafeReceiver = await createDSafe(dos, user3);
      const tokenId = await depositNft(dos, dSafeOwner, nft, nftOracle, NFT_PRICE);

      const tx = transfer(dos, nonDSafeOwner, dSafeReceiver, nft, tokenId);

      await expect(tx).to.be.revertedWith("NFT must be in the user's dSafe");
    });

    it("when receiver is not a dSafe should revert", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const dSafeOwner = await createDSafe(dos, user);
      const tokenId = await depositNft(dos, dSafeOwner, nft, nftOracle, NFT_PRICE);

      // @ts-expect-error - bypass `transfer` type that forbids this invariant in TS
      const tx = transfer(dos, dSafeOwner, user2, nft, tokenId);

      await expect(tx).to.be.revertedWith("Recipient dSafe doesn't exist");
    });

    it("when user owns the deposited NFT should be able to move the NFT to another dSafe", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const sender = await createDSafe(dos, user);
      const receiver = await createDSafe(dos, user2);
      const tokenId = await depositNft(dos, sender, nft, nftOracle, NFT_PRICE);

      const tx = await transfer(dos, sender, receiver, nft, tokenId);
      await tx.wait();

      expect(await dos.viewNFTs(sender.address)).to.eql([]);
      const receiverNfts = await dos.viewNFTs(receiver.address);
      expect(receiverNfts).to.eql([[nft.address, tokenId]]);
    });
  });
  describe.skip("#integrationAPI", () => {
    /*
    it("should set ERC20 token allowance when approve is called", async () => {
      const {user, user2, dos, usdc} = await loadFixture(deployDOSFixture);
      const owner = await createDSafe(dos, user);
      const spender = await createDSafe(dos, user2);
      const amount = ethers.utils.parseEther("100");

      const tx = await approveErc20(dos, owner, spender, usdc.address, amount);
      await tx.wait();

      expect(await dos.allowance(usdc.address, owner.address, spender.address)).to.eql(amount);
    });

    it("should deduct ERC20 token allowance after transferFromERC20", async () => {
      const {user, user2, user3, dos, weth} = await loadFixture(deployDOSFixture);
      const owner = await createDSafe(dos, user);
      const spender = await createDSafe(dos, user2);
      const recipient = await createDSafe(dos, user3);
      const amount = ethers.utils.parseEther("100");

      await depositErc20(dos, owner, weth, toWei(100));

      const approveTx = await approveErc20(dos, owner, spender, weth.address, amount);
      await approveTx.wait();

      expect(await dos.allowance(weth.address, owner.address, spender.address)).to.eql(amount);

      const transferFromTx = await transferFromErc20(
        dos,
        spender,
        owner,
        recipient,
        weth.address,
        amount,
      );
      await transferFromTx.wait();

      expect(await dos.allowance(weth.address, owner.address, spender.address)).to.eql(
        ethers.utils.parseEther("0"),
      );
    });

    it("should properly update dSafe balance with transferFromERC20", async () => {
      const {user, user2, user3, dos, weth, getBalances} = await loadFixture(deployDOSFixture);
      const owner = await createDSafe(dos, user);
      const spender = await createDSafe(dos, user2);
      const recipient = await createDSafe(dos, user3);
      const amount = ethers.utils.parseEther("100");

      await depositErc20(dos, owner, weth, toWei(100));

      const approveTx = await approveErc20(dos, owner, spender, weth.address, amount);
      await approveTx.wait();

      expect(await dos.allowance(weth.address, owner.address, spender.address)).to.eql(amount);

      const ownerBalanceBefore = (await getBalances(owner)).weth;
      const recipientBalanceBefore = (await getBalances(recipient)).weth;

      const transferFromTx = await transferFromErc20(
        dos,
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

    it("should revert transferFromERC20 if recipient is not a dSafe", async () => {
      const {user, user2, user3, dos, weth} = await loadFixture(deployDOSFixture);
      const owner = await createDSafe(dos, user);
      const spender = await createDSafe(dos, user2);
      const recipient = user3;
      const amount = ethers.utils.parseEther("100");

      await depositErc20(dos, owner, weth, toWei(100));

      const approveTx = await approveErc20(dos, owner, spender, weth.address, amount);
      await approveTx.wait();

      await expect(
        spender.executeBatch([
          makeCall(dos).transferFromERC20(weth.address, owner.address, recipient.address, amount),
        ]),
      ).to.be.revertedWith("Recipient dSafe doesn't exist");
    });

    it("should set approve ERC721 token", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const owner = await createDSafe(dos, user);
      const spender = await createDSafe(dos, user2);

      const tokenId = await depositNft(dos, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(dos, owner, spender, nft.address, tokenId);
      await tx.wait();

      expect(await dos.getApproved(nft.address, tokenId)).to.eql(spender.address);
    });

    it("should remove approval after ERC721 token transfer", async () => {
      const {user, user2, user3, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const owner = await createDSafe(dos, user);
      const spender = await createDSafe(dos, user2);
      const recipient = await createDSafe(dos, user3);

      const tokenId = await depositNft(dos, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(dos, owner, spender, nft.address, tokenId);
      await tx.wait();

      expect(await dos.getApproved(nft.address, tokenId)).to.eql(spender.address);

      const transferTx = await transferFromERC721(
        dos,
        spender,
        owner,
        recipient,
        nft.address,
        tokenId,
      );
      await transferTx.wait();

      expect(await dos.getApproved(nft.address, tokenId)).to.eql(ethers.constants.AddressZero);
    });

    it("should properly update dSafe balance with transferFromERC721", async () => {
      const {user, user2, user3, dos, nft, nftOracle, getBalances} = await loadFixture(
        deployDOSFixture,
      );
      const owner = await createDSafe(dos, user);
      const spender = await createDSafe(dos, user2);
      const recipient = await createDSafe(dos, user3);

      const tokenId = await depositNft(dos, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(dos, owner, spender, nft.address, tokenId);
      await tx.wait();

      const ownerBalanceBefore = (await getBalances(owner)).nfts.length;
      const recipientBalanceBefore = (await getBalances(recipient)).nfts.length;

      expect(await dos.getApproved(nft.address, tokenId)).to.eql(spender.address);

      const transferTx = await transferFromERC721(
        dos,
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

    it("should revert transferFromERC721 if recipient is not a dSafe", async () => {
      const {user, user2, user3, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const owner = await createDSafe(dos, user);
      const spender = await createDSafe(dos, user2);

      const tokenId = await depositNft(dos, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(dos, owner, spender, nft.address, tokenId);
      await tx.wait();

      await expect(
        spender.executeBatch([
          makeCall(dos).transferFromERC721(nft.address, owner.address, user3.address, tokenId),
        ]),
      ).to.be.revertedWith("Recipient dSafe doesn't exist");
    });*/

    it("Can transfer via Permit2", async () => {
      const {user, user2, usdc, dos, permit2} = await loadFixture(deployDOSFixture);

      const port1 = await createDSafe(dos, user);
      const port2 = await createDSafe(dos, user2);

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
});

async function depositErc20(
  dos: IDOS,
  dSafe: DSafeLogic,
  erc20: TestERC20 | WETH9,
  amount: number | bigint,
) {
  await erc20.mint(dSafe.address, amount);

  const depositTx = await dSafe.executeBatch([makeCall(dos).depositERC20(erc20.address, amount)]);
  await depositTx.wait();
}

async function depositNft(
  dos: IDOS,
  dSafe: DSafeLogic,
  nft: TestNFT,
  priceOracle: MockNFTOracle,
  price: number,
): Promise<BigNumber> {
  const mintTx = await nft.mint(dSafe.address);
  const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
  const tokenId = mintEventArgs[0] as BigNumber;
  await priceOracle.setPrice(tokenId, toWeiUsdc(price));
  const depositNftTx = await dSafe.executeBatch([
    makeCall(nft).approve(dos.address, tokenId),
    makeCall(dos).depositNFT(nft.address, tokenId),
  ]);
  await depositNftTx.wait();
  return tokenId;
}

// special case of depositNft function above.
// Used only in one test to show that this scenario is supported.
// In depositNft the NFT is minted to the dSafe and transferred from the dSafe to DOS.
// In depositUserNft, nft is minted to the user and transferred from the user to DOS
async function depositUserNft(
  dos: IDOS,
  dSafe: DSafeLogic,
  nft: TestNFT,
  priceOracle: MockNFTOracle,
  price: number,
): Promise<BigNumber> {
  const user = dSafe.signer;
  const mintTx = await nft.mint(await user.getAddress());
  const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
  const tokenId = mintEventArgs[0] as BigNumber;
  await priceOracle.setPrice(tokenId, toWeiUsdc(price));
  await (await nft.connect(user).approve(dos.address, tokenId)).wait();
  const depositNftTx = await dSafe.executeBatch([makeCall(dos).depositNFT(nft.address, tokenId)]);
  await depositNftTx.wait();
  return tokenId;
}

async function transfer(
  dos: IDOS,
  from: DSafeLogic,
  to: DSafeLogic,
  ...value: [erc20: string, amount: BigNumberish] | [nft: TestNFT, tokenId: BigNumberish]
): Promise<ContractTransaction> {
  if (typeof value[0] == "string") {
    // transfer erc20
    const [erc20, amount] = value;
    return await from.executeBatch([makeCall(dos).transfer(erc20, to.address, amount)]);
  } else {
    // transfer NFT
    const [nft, tokenId] = value;
    return await from.executeBatch([makeCall(dos).sendNFT(nft.address, tokenId, to.address)]);
  }
}
/*
async function transferFromErc20(
  dos: IDOS,
  spender: DSafeLogic,
  owner: DSafeLogic,
  to: DSafeLogic,
  erc20: string,
  amount: BigNumberish,
): Promise<ContractTransaction> {
  return await spender.executeBatch([
    makeCall(dos).transferFromERC20(erc20, owner.address, to.address, amount),
  ]);
}

async function transferFromERC721(
  dos: IDOS,
  spender: DSafeLogic,
  owner: DSafeLogic,
  to: DSafeLogic,
  nft: string,
  tokenId: BigNumber,
): Promise<ContractTransaction> {
  return await spender.executeBatch([
    makeCall(dos).transferFromERC721(nft, owner.address, to.address, tokenId),
  ]);
}
*/
