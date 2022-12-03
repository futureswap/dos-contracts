import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";
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
import {toWei, toWeiUsdc} from "../../lib/Numbers";
import {getEventParams, getEventsTx} from "../../lib/Events";
import {getFixedGasSigners, signPermit2TransferFrom} from "../../lib/Signers";
import {BigNumber, ContractTransaction, BigNumberish} from "ethers";
import {makeCall, createPortfolio} from "../../lib/Calls";
import {Chainlink, deployFixedAddress} from "../../lib/Deploy";

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

    const {permit2} = await deployFixedAddress(owner);

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

    const versionManager = await new VersionManager__factory(owner).deploy(owner.address);
    const dos = await new DOS__factory(owner).deploy(owner.address, versionManager.address);
    const proxyLogic = await new PortfolioLogic__factory(owner).deploy(dos.address);
    await versionManager.addVersion("1.0.0", 2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    // const DosDeployData = await ethers.getContractFactory("DOS");
    // const dos = await DosDeployData.deploy(unlockTime, { value: lockedAmount });

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
      0, // No interest which would include time sensitive calculations
    );
    const usdcIdx = 0; // index of the element created above in DOS.erc20Info array

    await dos.addERC20Info(
      weth.address,
      "Wrapped ETH",
      "WETH",
      WETH_DECIMALS,
      ethChainlink.oracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // No interest which would include time sensitive calculations
    );
    const wethIdx = 1; // index of the element created above in DOS.erc20Info array

    await dos.addNFTInfo(nft.address, nftOracle.address, toWei(0.5));

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
      usdcIdx,
      wethIdx,
      permit2,
    };
  }

  describe("Dos tests", () => {
    it("User can create portfolio", async () => {
      const {user, dos} = await loadFixture(deployDOSFixture);

      const portfolio = await createPortfolio(dos, user);
      expect(await portfolio.owner()).to.equal(user.address);
    });

    it("User can deposit money", async () => {
      const {user, dos, usdc, usdcIdx} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);

      await depositErc20(dos, portfolio, usdc, usdcIdx, tenThousandUsdc);

      expect((await getBalances(dos, portfolio)).usdc).to.equal(tenThousandUsdc);
      expect(await usdc.balanceOf(dos.address)).to.equal(tenThousandUsdc);
    });

    it("User can transfer money", async () => {
      const {user, user2, dos, usdc, usdcIdx} = await loadFixture(deployDOSFixture);
      const sender = await createPortfolio(dos, user);
      const receiver = await createPortfolio(dos, user2);
      await depositErc20(dos, sender, usdc, usdcIdx, tenThousandUsdc);

      const tx = transfer(dos, sender, receiver, usdcIdx, tenThousandUsdc);
      await (await tx).wait();

      expect((await getBalances(dos, sender)).usdc).to.equal(0);
      expect((await getBalances(dos, receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User can deposit and transfer money in arbitrary order", async () => {
      const {user, user2, dos, usdc, usdcIdx} = await loadFixture(deployDOSFixture);
      const sender = await createPortfolio(dos, user);
      const receiver = await createPortfolio(dos, user2);
      await usdc.mint(sender.address, tenThousandUsdc);

      await sender.executeBatch([
        makeCall(dos, "transfer", [usdcIdx, receiver.address, tenThousandUsdc]),
        makeCall(dos, "depositERC20", [usdcIdx, tenThousandUsdc]),
      ]);

      expect((await getBalances(dos, sender)).usdc).to.equal(0);
      expect((await getBalances(dos, receiver)).usdc).to.equal(tenThousandUsdc);
    });

    it("User cannot send more then they own", async () => {
      const {user, user2, dos, usdc, usdcIdx} = await loadFixture(deployDOSFixture);
      const sender = await createPortfolio(dos, user);
      const receiver = await createPortfolio(dos, user2);
      await depositErc20(dos, sender, usdc, usdcIdx, toWeiUsdc(10_000));

      const tx = transfer(dos, sender, receiver, usdcIdx, toWeiUsdc(20_000));

      await expect(tx).to.be.revertedWith("Result of operation is not sufficient liquid");
    });

    it("User can send more ERC20 then they have", async () => {
      const {user, user2, dos, usdc, weth, wethIdx, usdcIdx} = await loadFixture(deployDOSFixture);
      const sender = await createPortfolio(dos, user);
      await depositErc20(dos, sender, usdc, usdcIdx, tenThousandUsdc);
      const receiver = await createPortfolio(dos, user2);
      // Put weth in system so we can borrow weth
      const someOther = await createPortfolio(dos, user);
      await depositErc20(dos, someOther, weth, wethIdx, toWei(2));

      const tx = await transfer(dos, sender, receiver, wethIdx, oneEth);
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
        usdc, usdcIdx,
        weth, wethIdx,
        ethChainlink,
      } = await loadFixture(deployDOSFixture);
      const liquidatable = await createPortfolio(dos, user);
      await depositErc20(dos, liquidatable, usdc, usdcIdx, tenThousandUsdc);
      const liquidator = await createPortfolio(dos, user2);
      // ensure that liquidator would have enough collateral to compensate
      // negative balance of collateral/debt obtained from liquidatable
      await depositErc20(dos, liquidator, usdc, usdcIdx, tenThousandUsdc);
      // Put WETH in system so we can borrow weth
      const someOther = await createPortfolio(dos, user);
      await depositErc20(dos, someOther, weth, wethIdx, toWei(2));
      await ethChainlink.setPrice(2_000);

      // generate a debt on liquidatable
      const tx = transfer(dos, liquidatable, someOther, wethIdx, oneEth);
      await (await tx).wait();
      // make liquidatable debt overcome collateral. Now it can be liquidated
      await ethChainlink.setPrice(9_000);
      await liquidator.executeBatch([makeCall(dos, "liquidate", [liquidatable.address])]);

      const liquidatableBalances = await getBalances(dos, liquidatable);
      const liquidatorBalances = await getBalances(dos, liquidator);
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
        usdc, usdcIdx,
        weth, wethIdx
      } = await loadFixture(
        deployDOSFixture,
      );
      const nonLiquidatable = await createPortfolio(dos, user);
      const liquidator = await createPortfolio(dos, user2);
      // Put WETH in system so we can borrow weth
      const other = await createPortfolio(dos, user);
      await depositErc20(dos, other, weth, wethIdx, toWei(0.25));
      await depositErc20(dos, nonLiquidatable, usdc, usdcIdx, tenThousandUsdc);
      const tx = transfer(dos, nonLiquidatable, other, wethIdx, oneEth);
      await (await tx).wait();

      const liquidationTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [nonLiquidatable.address]),
      ]);

      await expect(liquidationTx).to.be.revertedWith("Portfolio is not liquidatable");
    });
  });

  describe("#computePosition", () => {
    it("when portfolio doesn't exist should return 0", async () => {
      const {dos} = await loadFixture(deployDOSFixture);
      const nonPortfolioAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const computeTx = dos.computePosition(nonPortfolioAddress);

      expect(computeTx).to.be.revertedWith("Recipient portfolio doesn't exist");
    });

    it("when portfolio is empty should return 0", async () => {
      const {dos, user} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);

      const [totalValue, collateral, debt] = await dos.computePosition(portfolio.address);

      expect(totalValue).to.equal(0);
      expect(collateral).to.equal(0);
      expect(debt).to.equal(0);
    });

    it("when portfolio has an ERC20 should return the ERC20 value", async () => {
      const {dos, user, usdc, usdcIdx} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);
      await depositErc20(dos, portfolio, usdc, usdcIdx, toWei(10_000, USDC_DECIMALS));

      const position = await dos.computePosition(portfolio.address);

      const [total, collateral, debt] = position;
      expect(total).to.be.approximately(await toWei(10_000, USDC_DECIMALS), 1000);
      // collateral factor is defined in setupDos, and it's 0.9
      expect(collateral).to.be.approximately(await toWei(9000, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("when portfolio has multiple ERC20s should return total ERC20s value", async () => {
      const {dos, user, usdc, weth, usdcIdx, wethIdx} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);

      await Promise.all([
        depositErc20(dos, portfolio, usdc, usdcIdx, toWeiUsdc(10_000)),
        depositErc20(dos, portfolio, weth, wethIdx, toWei(1)),
      ]);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(await toWei(12_000, USDC_DECIMALS));
      // collateral factor is defined in setupDos, and it's 0.9. 12 * 0.9 = 10.8
      expect(collateral).to.be.approximately(await toWei(10_800, USDC_DECIMALS), 1000);
      expect(debt).to.equal(0);
    });

    it("when portfolio has an NFT should return the NFT value", async () => {
      const {dos, user, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);

      await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

      const position = await dos.computePosition(portfolio.address);
      const [total, collateral, debt] = position;
      expect(total).to.equal(toWeiUsdc(NFT_PRICE));
      // collateral factor is defined in setupDos, and it's 0.5
      expect(collateral).to.equal(toWeiUsdc(NFT_PRICE / 2));
      expect(debt).to.equal(0);
    });

    it("when portfolio has a few NFTs should return the total NFTs value", async () => {
      const {dos, user, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);

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

    it("when portfolio has ERC20s and NFTs should return their total value", async () => {
      // prettier-ignore
      const {
        dos,
        user,
        usdc, usdcIdx,
        weth, wethIdx,
        nft, nftOracle
      } =
        await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);

      await Promise.all([
        depositNft(dos, portfolio, nft, nftOracle, 100),
        depositNft(dos, portfolio, nft, nftOracle, 200),
        depositNft(dos, portfolio, nft, nftOracle, 300),
        depositErc20(dos, portfolio, usdc, usdcIdx, toWeiUsdc(10_000)),
        depositErc20(dos, portfolio, weth, wethIdx, toWei(1)),
      ]);

      const position = await dos.computePosition(portfolio.address);
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
      const portfolio = await createPortfolio(dos, user);
      await depositNft(dos, portfolio, nft, nftOracle, 1600);

      const depositNftTx = dos.liquidate(portfolio.address);

      await expect(depositNftTx).to.be.revertedWith("Only portfolio can execute");
    });

    it("when portfolio to liquidate doesn't exist should revert", async () => {
      const {dos, user, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const liquidator = await createPortfolio(dos, user);
      await depositNft(dos, liquidator, nft, nftOracle, NFT_PRICE);
      const nonPortfolioAddress = "0xb4A50D202ca799AA07d4E9FE11C2919e5dFe4220";

      const liquidateTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [nonPortfolioAddress]),
      ]);

      await expect(liquidateTx).to.be.revertedWith("Recipient portfolio doesn't exist");
    });

    it("when portfolio to liquidate is empty should revert", async () => {
      const {dos, user, user2, usdc, usdcIdx} = await loadFixture(deployDOSFixture);
      const emptyPortfolio = await createPortfolio(dos, user);
      const liquidator = await createPortfolio(dos, user2);
      await depositErc20(dos, liquidator, usdc, usdcIdx, toWeiUsdc(1000));

      const liquidateTx = liquidator.executeBatch([
        makeCall(dos, "liquidate", [emptyPortfolio.address]),
      ]);

      await expect(liquidateTx).to.be.revertedWith("Portfolio is not liquidatable");
    });

    it("when debt is zero should revert", async () => {
      const {dos, user, user2, usdc, usdcIdx} = await loadFixture(deployDOSFixture);
      const nonLiquidatable = await createPortfolio(dos, user);
      await depositErc20(dos, nonLiquidatable, usdc, usdcIdx, toWeiUsdc(1000));
      const liquidator = await createPortfolio(dos, user2);
      await depositErc20(dos, liquidator, usdc, usdcIdx, toWeiUsdc(1000));

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
        usdc, usdcIdx,
        weth, wethIdx
      } = await loadFixture(
        deployDOSFixture
      );
      const nonLiquidatable = await createPortfolio(dos, user);
      await depositErc20(dos, nonLiquidatable, usdc, usdcIdx, toWeiUsdc(1000));
      const liquidator = await createPortfolio(dos, user2);
      await depositErc20(dos, liquidator, usdc, usdcIdx, toWeiUsdc(1000));
      const other = await createPortfolio(dos, user3);
      await depositErc20(dos, other, weth, wethIdx, toWei(1));
      const tx = transfer(dos, nonLiquidatable, other, wethIdx, toWei(0.1));
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
        usdc, usdcIdx,
        weth, wethIdx,
        ethChainlink
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createPortfolio(dos, user);
      await depositErc20(dos, liquidatable, usdc, usdcIdx, toWeiUsdc(10_000));
      const liquidator = await createPortfolio(dos, user2);
      const other = await createPortfolio(dos, user3);
      await depositErc20(dos, other, weth, wethIdx, toWei(10));
      const tx = transfer(dos, liquidatable, other, wethIdx, toWei(4));
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
        usdc, usdcIdx,
        weth, wethIdx,
        ethChainlink
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createPortfolio(dos, user);
      await depositErc20(dos, liquidatable, usdc, usdcIdx, toWeiUsdc(10_000));
      const other = await createPortfolio(dos, user2);
      await depositErc20(dos, other, weth, wethIdx, toWei(10));
      const tx = transfer(dos, liquidatable, other, wethIdx, toWei(4));
      await (await tx).wait();

      await ethChainlink.setPrice(2_100); // 2_000 -> 2_100
      const liquidateTx = liquidatable.executeBatch([
        makeCall(dos, "liquidate", [liquidatable.address]),
      ]);

      await expect(liquidateTx).to.revertedWith("Result of operation is not sufficient liquid");
    });

    it("when collateral is smaller then debt should transfer all ERC20s of the portfolio to the caller", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc, usdcIdx,
        weth, wethIdx,
        ethChainlink
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createPortfolio(dos, user);
      await depositErc20(dos, liquidatable, usdc, usdcIdx, toWeiUsdc(10_000));
      const liquidator = await createPortfolio(dos, user2);
      await depositErc20(dos, liquidator, usdc, usdcIdx, toWeiUsdc(10_000));
      const other = await createPortfolio(dos, user3);
      await depositErc20(dos, other, weth, wethIdx, toWei(10));
      const tx = transfer(dos, liquidatable, other, wethIdx, toWei(4));
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
        usdc, weth, usdcIdx, wethIdx
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createPortfolio(dos, user);
      const tokenId = await depositNft(dos, liquidatable, nft, nftOracle, 2000);
      const liquidator = await createPortfolio(dos, user2);
      await depositErc20(dos, liquidator, usdc, usdcIdx, toWeiUsdc(2000));
      const other = await createPortfolio(dos, user3);
      await depositErc20(dos, other, weth, wethIdx, toWei(1));
      const tx = transfer(dos, liquidatable, other, wethIdx, toWei(0.4));
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
      expect(liquidatorBalance.nfts).to.eql([[nft.address, tokenId]]);
    });

    it("when collateral is smaller then debt should transfer all ERC20s and all NFTs of the portfolio to the caller", async () => {
      // prettier-ignore
      const {
        dos,
        user, user2, user3,
        usdc, usdcIdx,
        weth, wethIdx,
        nft, nftOracle,
        ethChainlink,
      } = await loadFixture(
        deployDOSFixture
      );
      const liquidatable = await createPortfolio(dos, user);
      const tokenId = await depositNft(dos, liquidatable, nft, nftOracle, 2000);
      await depositErc20(dos, liquidatable, usdc, usdcIdx, toWeiUsdc(1_500));
      const liquidator = await createPortfolio(dos, user2);
      await depositErc20(dos, liquidator, weth, wethIdx, toWei(1));
      const other = await createPortfolio(dos, user3);
      await depositErc20(dos, other, weth, wethIdx, toWei(1));
      const tx = transfer(dos, liquidatable, other, wethIdx, toWei(1));
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
      expect(liquidatorBalance.nfts).to.eql([[nft.address, tokenId]]);
    });
  });

  describe("#depositNFT", () => {
    it(
      "when user owns the NFT " +
        "should change ownership of the NFT from the user to DOS " +
        "and add NFT to the user DOS portfolio",
      async () => {
        const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
        const portfolio = await createPortfolio(dos, user);
        const tokenId = await depositUserNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

        expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
        const userNfts = await dos.viewNFTs(portfolio.address);
        expect(userNfts).to.eql([[nft.address, tokenId]]);
      },
    );

    it(
      "when portfolio owns the NFT " +
        "should change ownership of the NFT from portfolio to DOS " +
        "and add NFT to the user DOS portfolio",
      async () => {
        const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
        const portfolio = await createPortfolio(dos, user);

        const tokenId = await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

        expect(await nft.ownerOf(tokenId)).to.eql(dos.address);
        const userNfts = await dos.viewNFTs(portfolio.address);
        expect(userNfts).to.eql([[nft.address, tokenId]]);
      },
    );

    it("when NFT contract is not registered should revert the deposit", async () => {
      const {user, dos, unregisteredNft, nftOracle} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);

      const txRevert = depositNft(dos, portfolio, unregisteredNft, nftOracle, NFT_PRICE);

      await expect(txRevert).to.be.revertedWith("Cannot add NFT of unknown NFT contract");
    });

    it("when user is not an owner of NFT should revert the deposit", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);
      const portfolio2 = await createPortfolio(dos, user2);
      const tokenId = await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

      const depositNftTx = portfolio2.executeBatch([
        makeCall(dos, "depositNFT", [nft.address, tokenId]),
      ]);

      await expect(depositNftTx).to.be.revertedWith(
        "NFT must be owned the the user or user's portfolio",
      );
    });

    it("when called directly on DOS should revert the deposit", async () => {
      const {user, dos, nft} = await loadFixture(deployDOSFixture);
      const mintTx = await nft.mint(user.address);
      const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
      const tokenId = mintEventArgs[0] as BigNumber;
      await (await nft.connect(user).approve(dos.address, tokenId)).wait();

      const depositNftTx = dos.depositNFT(nft.address, tokenId);

      await expect(depositNftTx).to.be.revertedWith("Only portfolio can execute");
    });
  });

  describe("#claimNFT", () => {
    it("when called not with portfolio should revert", async () => {
      const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const portfolio = await createPortfolio(dos, user);
      const tokenId = await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

      const claimNftTx = dos.connect(user).claimNFT(nft.address, tokenId);

      await expect(claimNftTx).to.be.revertedWith("Only portfolio can execute");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const ownerPortfolio = await createPortfolio(dos, user);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle, NFT_PRICE);
      const nonOwnerPortfolio = await createPortfolio(dos, user2);

      const claimNftTx = nonOwnerPortfolio.executeBatch([
        makeCall(dos, "claimNFT", [nft.address, tokenId]),
      ]);

      await expect(claimNftTx).to.be.revertedWith("NFT must be on the user's deposit");
    });

    it(
      "when user owns the deposited NFT " +
        "should change ownership of the NFT from DOS to user's portfolio " +
        "and remove NFT from the user DOS portfolio",
      async () => {
        const {user, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
        const portfolio = await createPortfolio(dos, user);
        const tokenId = await depositNft(dos, portfolio, nft, nftOracle, NFT_PRICE);

        const claimNftTx = await portfolio.executeBatch([
          makeCall(dos, "claimNFT", [nft.address, tokenId]),
        ]);
        await claimNftTx.wait();

        await expect(await nft.ownerOf(tokenId)).to.eql(portfolio.address);
        await expect(await dos.viewNFTs(portfolio.address)).to.eql([]);
      },
    );
  });

  describe("#sendNFT", () => {
    it("when called not with portfolio should revert", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const ownerPortfolio = await createPortfolio(dos, user);
      const receiverPortfolio = await createPortfolio(dos, user2);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle, NFT_PRICE);

      const sendNftTx = dos.connect(user).sendNFT(nft.address, tokenId, receiverPortfolio.address);

      await expect(sendNftTx).to.be.revertedWith("Only portfolio can execute");
    });

    it("when user is not the owner of the deposited NFT should revert", async () => {
      const {user, user2, user3, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const ownerPortfolio = await createPortfolio(dos, user);
      const nonOwnerPortfolio = await createPortfolio(dos, user2);
      const receiverPortfolio = await createPortfolio(dos, user3);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle, NFT_PRICE);

      const tx = transfer(dos, nonOwnerPortfolio, receiverPortfolio, nft, tokenId);

      await expect(tx).to.be.revertedWith("NFT must be on the user's deposit");
    });

    it("when receiver is not a portfolio should revert", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const ownerPortfolio = await createPortfolio(dos, user);
      const tokenId = await depositNft(dos, ownerPortfolio, nft, nftOracle, NFT_PRICE);

      // @ts-ignore - bypass `transfer` type that forbids this invariant in TS
      const tx = transfer(dos, ownerPortfolio, user2, nft, tokenId);

      await expect(tx).to.be.revertedWith("Recipient portfolio doesn't exist");
    });

    it("when user owns the deposited NFT should be able to move the NFT to another portfolio", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const sender = await createPortfolio(dos, user);
      const receiver = await createPortfolio(dos, user2);
      const tokenId = await depositNft(dos, sender, nft, nftOracle, NFT_PRICE);

      const tx = await transfer(dos, sender, receiver, nft, tokenId);
      await tx.wait();

      await expect(await dos.viewNFTs(sender.address)).to.eql([]);
      const receiverNfts = await dos.viewNFTs(receiver.address);
      await expect(receiverNfts).to.eql([[nft.address, tokenId]]);
    });
  });
  describe("#integrationAPI", () => {
    it("should set ERC20 token allowance when approve is called", async () => {
      const {user, user2, dos, usdc, usdcIdx} = await loadFixture(deployDOSFixture);
      const owner = await createPortfolio(dos, user);
      const spender = await createPortfolio(dos, user2);
      const amount = ethers.utils.parseEther("100");

      let tx = await approveErc20(dos, owner, spender, usdcIdx, amount);
      await tx.wait();

      await expect(await dos.allowance(usdcIdx, owner.address, spender.address)).to.eql(amount);
    });

    it("should deduct ERC20 token allowance after transferFromERC20", async () => {
      const {user, user2, user3, dos, weth, wethIdx} = await loadFixture(deployDOSFixture);
      const owner = await createPortfolio(dos, user);
      const spender = await createPortfolio(dos, user2);
      const recipient = await createPortfolio(dos, user3);
      const amount = ethers.utils.parseEther("100");

      await depositErc20(dos, owner, weth, wethIdx, toWei(100));

      const approveTx = await approveErc20(dos, owner, spender, wethIdx, amount);
      await approveTx.wait();

      await expect(await dos.allowance(wethIdx, owner.address, spender.address)).to.eql(amount);

      const transferFromTx = await transferFromErc20(
        dos,
        spender,
        owner,
        recipient,
        wethIdx,
        amount,
      );
      await transferFromTx.wait();

      await expect(await dos.allowance(wethIdx, owner.address, spender.address)).to.eql(
        ethers.utils.parseEther("0"),
      );
    });

    it("should properly update portfolio balance with transferFromERC20", async () => {
      const {user, user2, user3, dos, weth, wethIdx} = await loadFixture(deployDOSFixture);
      const owner = await createPortfolio(dos, user);
      const spender = await createPortfolio(dos, user2);
      const recipient = await createPortfolio(dos, user3);
      const amount = ethers.utils.parseEther("100");

      await depositErc20(dos, owner, weth, wethIdx, toWei(100));

      const approveTx = await approveErc20(dos, owner, spender, wethIdx, amount);
      await approveTx.wait();

      await expect(await dos.allowance(wethIdx, owner.address, spender.address)).to.eql(amount);

      const ownerBalanceBefore = (await getBalances(dos, owner)).weth;
      const recipientBalanceBefore = (await getBalances(dos, recipient)).weth;

      const transferFromTx = await transferFromErc20(
        dos,
        spender,
        owner,
        recipient,
        wethIdx,
        amount,
      );
      await transferFromTx.wait();

      const ownerBalanceAfter = (await getBalances(dos, owner)).weth;
      const recipientBalanceAfter = (await getBalances(dos, recipient)).weth;

      await expect(ownerBalanceAfter).to.eql(ownerBalanceBefore.sub(amount));
      await expect(recipientBalanceAfter).to.eql(recipientBalanceBefore.add(amount));
    });

    it("should revert transferFromERC20 if recipient is not a portfolio", async () => {
      const {user, user2, user3, dos, weth, wethIdx} = await loadFixture(deployDOSFixture);
      const owner = await createPortfolio(dos, user);
      const spender = await createPortfolio(dos, user2);
      const recipient = user3;
      const amount = ethers.utils.parseEther("100");

      await depositErc20(dos, owner, weth, wethIdx, toWei(100));

      const approveTx = await approveErc20(dos, owner, spender, wethIdx, amount);
      await approveTx.wait();

      await expect(
        spender.executeBatch([
          makeCall(dos, "transferFromERC20", [wethIdx, owner.address, recipient.address, amount]),
        ]),
      ).to.be.revertedWith("Recipient portfolio doesn't exist");
    });

    it("should set approve ERC721 token", async () => {
      const {user, user2, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const owner = await createPortfolio(dos, user);
      const spender = await createPortfolio(dos, user2);

      const tokenId = await depositNft(dos, owner, nft, nftOracle, 2000);

      let tx = await approveERC721(dos, owner, spender, nft.address, tokenId);
      await tx.wait();

      await expect(await dos.getApproved(nft.address, tokenId)).to.eql(spender.address);
    });

    it("should remove approval after ERC721 token transfer", async () => {
      const {user, user2, user3, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const owner = await createPortfolio(dos, user);
      const spender = await createPortfolio(dos, user2);
      const recipient = await createPortfolio(dos, user3);

      const tokenId = await depositNft(dos, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(dos, owner, spender, nft.address, tokenId);
      await tx.wait();

      await expect(await dos.getApproved(nft.address, tokenId)).to.eql(spender.address);

      const transferTx = await transferFromERC721(
        dos,
        spender,
        owner,
        recipient,
        nft.address,
        tokenId,
      );
      await transferTx.wait();

      await expect(await dos.getApproved(nft.address, tokenId)).to.eql(
        ethers.constants.AddressZero,
      );
    });

    it("should properly update portfolio balance with transferFromERC721", async () => {
      const {user, user2, user3, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const owner = await createPortfolio(dos, user);
      const spender = await createPortfolio(dos, user2);
      const recipient = await createPortfolio(dos, user3);

      const tokenId = await depositNft(dos, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(dos, owner, spender, nft.address, tokenId);
      await tx.wait();

      const ownerBalanceBefore = (await getBalances(dos, owner)).nfts.length;
      const recipientBalanceBefore = (await getBalances(dos, recipient)).nfts.length;

      await expect(await dos.getApproved(nft.address, tokenId)).to.eql(spender.address);

      const transferTx = await transferFromERC721(
        dos,
        spender,
        owner,
        recipient,
        nft.address,
        tokenId,
      );
      await transferTx.wait();

      const ownerBalanceAfter = (await getBalances(dos, owner)).nfts.length;
      const recipientBalanceAfter = (await getBalances(dos, recipient)).nfts.length;

      await expect(ownerBalanceAfter).to.eql(ownerBalanceBefore - 1);
      await expect(recipientBalanceAfter).to.eql(recipientBalanceBefore + 1);
    });

    it("should revert transferFromERC721 if recipient is not a portfolio", async () => {
      const {user, user2, user3, dos, nft, nftOracle} = await loadFixture(deployDOSFixture);
      const owner = await createPortfolio(dos, user);
      const spender = await createPortfolio(dos, user2);
      const recipient = user3.address;

      const tokenId = await depositNft(dos, owner, nft, nftOracle, 2000);

      const tx = await approveERC721(dos, owner, spender, nft.address, tokenId);
      await tx.wait();

      await expect(
        spender.executeBatch([
          makeCall(dos, "transferFromERC721", [nft.address, owner.address, user3.address, tokenId]),
        ]),
      ).to.be.revertedWith("Recipient portfolio doesn't exist");
    });

    it("Can transfer via Permit2", async () => {
      const {user, user2, usdc, dos, permit2} = await loadFixture(deployDOSFixture);

      const port1 = await createPortfolio(dos, user);
      const port2 = await createPortfolio(dos, user2);

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
        makeCall(permit2, "permitTransferFrom", [
          {
            permitted: {token: usdc.address, amount: hundredDollars},
            nonce: 1,
            deadline: ethers.constants.MaxUint256,
          },
          {to: port2.address, requestedAmount: hundredDollars},
          port1.address,
          signature,
        ]),
      ]);
      expect(await usdc.balanceOf(port1.address)).to.eq(0);
      expect(await usdc.balanceOf(port2.address)).to.eq(hundredDollars);
    });
  });
});

async function depositErc20(
  dos: DOS,
  portfolio: PortfolioLogic,
  erc20: TestERC20 | WETH9,
  erc20DosIdx: number,
  amount: number | bigint,
) {
  await erc20.mint(portfolio.address, amount);

  const depositTx = await portfolio.executeBatch([
    makeCall(dos, "depositERC20", [erc20DosIdx, amount]),
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
    makeCall(dos, "depositNFT", [nft.address, tokenId]),
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
    makeCall(dos, "depositNFT", [nft.address, tokenId]),
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
    dos.viewNFTs(portfolio.address),
    dos.viewBalance(portfolio.address, 0),
    dos.viewBalance(portfolio.address, 1),
  ]);
  return {nfts, usdc, weth};
}

async function transfer(
  dos: DOS,
  from: PortfolioLogic,
  to: PortfolioLogic,
  ...value: [erc20DosIdx: number, amount: BigNumberish] | [nft: TestNFT, tokenId: BigNumberish]
): Promise<ContractTransaction> {
  if (typeof value[0] == "number") {
    // transfer erc20
    const [erc20Idx, amount] = value;
    return from.executeBatch([makeCall(dos, "transfer", [erc20Idx, to.address, amount])]);
  } else {
    // transfer NFT
    const [nft, tokenId] = value;
    return from.executeBatch([makeCall(dos, "sendNFT", [nft.address, tokenId, to.address])]);
  }
}

async function approveErc20(
  dos: DOS,
  owner: PortfolioLogic,
  spender: PortfolioLogic,
  erc20Idx: number,
  amount: BigNumberish,
): Promise<ContractTransaction> {
  return owner.executeBatch([makeCall(dos, "approveERC20", [erc20Idx, spender.address, amount])]);
}

async function approveERC721(
  dos: DOS,
  owner: PortfolioLogic,
  spender: PortfolioLogic,
  nft: string,
  tokenId: BigNumber,
): Promise<ContractTransaction> {
  return owner.executeBatch([makeCall(dos, "approveERC721", [nft, spender.address, tokenId])]);
}

async function transferFromErc20(
  dos: DOS,
  spender: PortfolioLogic,
  owner: PortfolioLogic,
  to: PortfolioLogic,
  erc20Idx: number,
  amount: BigNumberish,
): Promise<ContractTransaction> {
  return spender.executeBatch([
    makeCall(dos, "transferFromERC20", [erc20Idx, owner.address, to.address, amount]),
  ]);
}

async function transferFromERC721(
  dos: DOS,
  spender: PortfolioLogic,
  owner: PortfolioLogic,
  to: PortfolioLogic,
  nft: string,
  tokenId: BigNumber,
): Promise<ContractTransaction> {
  return spender.executeBatch([
    makeCall(dos, "transferFromERC721", [nft, owner.address, to.address, tokenId]),
  ]);
}
