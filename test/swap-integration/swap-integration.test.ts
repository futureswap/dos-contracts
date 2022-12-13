import type {DSafeLogic, TestERC20, WETH9} from "../../typechain-types";

import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  DSafeLogic__factory,
  TestERC20__factory,
  WETH9__factory,
  UniV3Oracle__factory,
} from "../../typechain-types";
import {toWei} from "../../lib/numbers";
import {createDSafe, leverageLP, leveragePos, makeCall} from "../../lib/calls";
import {
  Chainlink,
  deployDos,
  deployFixedAddressForTests,
  deployUniswapFactory,
  deployUniswapPool,
} from "../../lib/deploy";
import {getFixedGasSigners} from "../../lib/signers";

const USDC_PRICE = 1;
const ETH_PRICE = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

describe("DOS swap integration", () => {
  // we define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployDOSFixture() {
    const [owner, user, user2, user3] = await getFixedGasSigners(10_000_000);

    const {anyswapCreate2Deployer} = await deployFixedAddressForTests(owner);

    let usdc: TestERC20;
    let weth: WETH9;
    do {
      // eslint-disable-next-line no-await-in-loop
      [weth, usdc] = await Promise.all([
        new WETH9__factory(owner).deploy(),
        new TestERC20__factory(owner).deploy("USD Coin", "USDC", USDC_DECIMALS),
      ]);
    } while (BigInt(weth.address) >= BigInt(usdc.address));

    const usdcChainlink = await Chainlink.deploy(
      owner,
      USDC_PRICE,
      8,
      USDC_DECIMALS,
      USDC_DECIMALS,
    );
    const ethChainlink = await Chainlink.deploy(owner, ETH_PRICE, 8, USDC_DECIMALS, WETH_DECIMALS);

    const {dos, versionManager} = await deployDos(
      owner.address,
      anyswapCreate2Deployer,
      "0x02",
      owner,
    );
    const proxyLogic = await new DSafeLogic__factory(owner).deploy(dos.address);
    await versionManager.addVersion("1.0.0", 2, proxyLogic.address);
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

    const {uniswapFactory, uniswapNFTManager, swapRouter} = await deployUniswapFactory(
      weth.address,
      owner,
    );

    const price = (ETH_PRICE * 10 ** USDC_DECIMALS) / 10 ** WETH_DECIMALS;
    await deployUniswapPool(uniswapFactory, weth.address, usdc.address, price);
    const uniswapNftOracle = await new UniV3Oracle__factory(owner).deploy(
      uniswapFactory.address,
      uniswapNFTManager.address,
      owner.address,
    );

    await uniswapNftOracle.setERC20ValueOracle(usdc.address, usdcChainlink.oracle.address);
    await uniswapNftOracle.setERC20ValueOracle(weth.address, ethChainlink.oracle.address);

    await dos.addNFTInfo(uniswapNFTManager.address, uniswapNftOracle.address, toWei(0.9));

    const ownerDSafe = await createDSafe(dos, owner);
    const usdcAmount = toWei(2000000, USDC_DECIMALS);
    const wethAmount = toWei(1000);

    await usdc.mint(ownerDSafe.address, usdcAmount);
    await ownerDSafe.executeBatch(
      [
        makeCall(weth).withValue(toWei(1000)).deposit(),
        makeCall(dos).depositERC20(usdc.address, usdcAmount),
        makeCall(dos).depositERC20(weth.address, wethAmount),
      ],
      {value: wethAmount},
    );

    const getBalances = async (dSafe: DSafeLogic) => {
      const [nfts, usdcBalance, wethBalance] = await Promise.all([
        dos.viewNFTs(dSafe.address),
        dos.getDAccountERC20(dSafe.address, usdc.address),
        dos.getDAccountERC20(dSafe.address, weth.address),
      ]);
      return {nfts, usdcBalance: usdcBalance.toBigInt(), wethBalance: wethBalance.toBigInt()};
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
      dos,
      uniswapNFTManager,
      swapRouter,
      getBalances,
    };
  }

  describe("Dos tests", () => {
    it("User can leverage LP", async () => {
      const {user, dos, usdc, weth, uniswapNFTManager, getBalances} = await loadFixture(
        deployDOSFixture,
      );

      const dSafe = await createDSafe(dos, user);
      await usdc.mint(dSafe.address, toWei(1600, USDC_DECIMALS));

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
        recipient: dSafe.address,
        deadline: ethers.constants.MaxUint256,
      };
      await expect(
        dSafe.executeBatch(leverageLP(dos, weth, usdc, uniswapNFTManager, mintParams, 1)),
      ).to.not.be.reverted;
      const {usdcBalance, wethBalance, nfts} = await getBalances(dSafe);
      // expect leveraged LP position with NFT as collateral
      expect(usdcBalance).to.be.lessThan(0);
      expect(wethBalance).to.be.lessThan(0);
      expect(nfts.length).to.equal(1);
    });

    it("User can create leveraged position", async () => {
      const {user, user2, dos, usdc, weth, uniswapNFTManager, swapRouter, getBalances} =
        await loadFixture(deployDOSFixture);

      const dSafe = await createDSafe(dos, user);
      await usdc.mint(dSafe.address, toWei(16000, USDC_DECIMALS));

      const mintParams = {
        token0: weth.address,
        token1: usdc.address,
        fee: 500,
        tickLower: -210000,
        tickUpper: -190000,
        amount0Desired: toWei(10),
        amount1Desired: toWei(20000, USDC_DECIMALS),
        amount0Min: 0,
        amount1Min: 0,
        recipient: dSafe.address,
        deadline: ethers.constants.MaxUint256,
      };
      await dSafe.executeBatch(leverageLP(dos, weth, usdc, uniswapNFTManager, mintParams, 1));

      const dSafe2 = await createDSafe(dos, user2);
      await usdc.mint(dSafe2.address, toWei(1000, USDC_DECIMALS));
      await expect(
        dSafe2.executeBatch(
          leveragePos(dSafe2, dos, usdc, weth, 500, swapRouter, toWei(2000, USDC_DECIMALS)),
        ),
      ).to.not.be.reverted;

      const {usdcBalance, wethBalance, nfts} = await getBalances(dSafe2);
      // expect leveraged long eth position
      expect(usdcBalance).to.be.lessThan(0);
      expect(wethBalance).to.be.greaterThan(0);
      expect(nfts.length).to.equal(0); // regular leveraged position, no NFTs
    });

    it("Liquify liquidatable position", async () => {
      const {
        user,
        user2,
        user3,
        dos,
        usdc,
        weth,
        uniswapNFTManager,
        swapRouter,
        ethChainlink,
        getBalances,
      } = await loadFixture(deployDOSFixture);

      const dSafe = await createDSafe(dos, user);
      await usdc.mint(dSafe.address, toWei(16000, USDC_DECIMALS));

      const mintParams = {
        token0: weth.address,
        token1: usdc.address,
        fee: 500,
        tickLower: -210000,
        tickUpper: -190000,
        amount0Desired: toWei(10),
        amount1Desired: toWei(20000, USDC_DECIMALS),
        amount0Min: 0,
        amount1Min: 0,
        recipient: dSafe.address,
        deadline: ethers.constants.MaxUint256,
      };
      await dSafe.executeBatch(leverageLP(dos, weth, usdc, uniswapNFTManager, mintParams, 1));

      const dSafe2 = await createDSafe(dos, user2);
      await usdc.mint(dSafe2.address, toWei(1000, USDC_DECIMALS));
      await dSafe2.executeBatch(
        leveragePos(dSafe2, dos, usdc, weth, 500, swapRouter, toWei(2000, USDC_DECIMALS)),
      );

      // make dSafe2 liquidatable
      await ethChainlink.setPrice(ETH_PRICE / 2);

      const dSafe3 = await createDSafe(dos, user3);
      await usdc.mint(dSafe3.address, toWei(1000, USDC_DECIMALS));
      await dSafe3.executeBatch([
        makeCall(usdc).approve(swapRouter.address, ethers.constants.MaxUint256),
        makeCall(weth).approve(swapRouter.address, ethers.constants.MaxUint256),
        makeCall(dos).depositFull([usdc.address]),
      ]);

      // await dSafe3.liquify(dSafe2.address, swapRouter.address, usdc.address, [wethIdx], [weth.address]);
      await dSafe3.liquify(dSafe2.address, swapRouter.address, usdc.address, [weth.address]);

      const {usdcBalance, wethBalance} = await getBalances(dSafe3);
      expect(await usdc.balanceOf(dSafe3.address)).to.be.equal(0);
      expect(await weth.balanceOf(dSafe3.address)).to.be.equal(0);
      expect(wethBalance).to.equal(0);
      expect(usdcBalance).to.greaterThan(toWei(1000, USDC_DECIMALS));
    });
  });
});
