import type {WalletLogic, TestERC20, WETH9} from "../../typechain-types";

import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  WalletLogic__factory,
  TestERC20__factory,
  WETH9__factory,
  UniV3Oracle__factory,
  UniV3LPHelper__factory,
} from "../../typechain-types";
import {toWei, toWeiUsdc} from "../../lib/numbers";
import {createWallet, depositERC20, leverageLP, leveragePos, makeCall} from "../../lib/calls";
import {
  Chainlink,
  deploySupa,
  deployFixedAddressForTests,
  deployUniswapFactory,
  deployUniswapPool,
} from "../../lib/deploy";
import {getFixedGasSigners} from "../../lib/hardhat/fixedGasSigners";

const USDC_PRICE = 1;
const ETH_PRICE = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

describe("Supa swap integration", () => {
  // we define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deploySupaFixture() {
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

    const {iSupa, versionManager} = await deploySupa(
      owner.address,
      anyswapCreate2Deployer,
      "0x02",
      owner,
    );
    const proxyLogic = await new WalletLogic__factory(owner).deploy(iSupa.address);
    await versionManager.addVersion(2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    const treasurySafe = await createWallet(iSupa, owner);

    await iSupa.setConfig({
      treasurySafe: treasurySafe.address,
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
      0, // no interest which would include time sensitive calculations
      0,
      0,
      0,
    );

    await iSupa.addERC20Info(
      weth.address,
      "Wrapped ETH",
      "WETH",
      WETH_DECIMALS,
      ethChainlink.oracle.address,
      0, // no interest which would include time sensitive calculations
      0,
      0,
      0,
    );

    const {uniswapV3Factory, nonFungiblePositionManager, swapRouter} = await deployUniswapFactory(
      weth.address,
      owner,
    );

    const uniV3LPHelper = await new UniV3LPHelper__factory(owner).deploy(
      iSupa.address,
      nonFungiblePositionManager.address,
    );

    const price = (ETH_PRICE * 10 ** USDC_DECIMALS) / 10 ** WETH_DECIMALS;
    await deployUniswapPool(uniswapV3Factory, weth.address, usdc.address, 500, price);
    const uniswapNftOracle = await new UniV3Oracle__factory(owner).deploy(
      uniswapV3Factory.address,
      nonFungiblePositionManager.address,
      owner.address,
    );

    await uniswapNftOracle.setERC20ValueOracle(usdc.address, usdcChainlink.oracle.address);
    await uniswapNftOracle.setERC20ValueOracle(weth.address, ethChainlink.oracle.address);

    await iSupa.addERC721Info(nonFungiblePositionManager.address, uniswapNftOracle.address);

    const ownerWallet = await createWallet(iSupa, owner);
    const usdcAmount = toWeiUsdc(2_000_000);
    const wethAmount = toWei(1000);

    await usdc.mint(ownerWallet.address, usdcAmount);
    await ownerWallet.executeBatch(
      [
        makeCall(weth, toWei(1000)).deposit(),
        makeCall(iSupa).depositERC20(usdc.address, usdcAmount),
        makeCall(iSupa).depositERC20(weth.address, wethAmount),
      ],
      {value: wethAmount},
    );

    const getBalances = async (wallet: WalletLogic) => {
      const [nfts, usdcBalance, wethBalance] = await Promise.all([
        iSupa.getCreditAccountERC721(wallet.address),
        iSupa.getCreditAccountERC20(wallet.address, usdc.address),
        iSupa.getCreditAccountERC20(wallet.address, weth.address),
      ]);
      return {nfts, usdcBalance: usdcBalance.toBigInt(), wethBalance: wethBalance.toBigInt()};
    };

    const addAllowances = async (wallet: WalletLogic) => {
      await wallet.executeBatch([
        makeCall(usdc).approve(swapRouter.address, ethers.constants.MaxUint256),
        makeCall(weth).approve(swapRouter.address, ethers.constants.MaxUint256),
      ]);
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
      iSupa,
      nonFungiblePositionManager,
      uniV3LPHelper,
      swapRouter,
      getBalances,
      addAllowances,
    };
  }

  describe("Supa tests", () => {
    it("User can leverage LP", async () => {
      const {user, iSupa, usdc, weth, nonFungiblePositionManager, getBalances} = await loadFixture(
        deploySupaFixture,
      );

      const wallet = await createWallet(iSupa, user);
      await usdc.mint(wallet.address, toWeiUsdc(1_600));

      const mintParams = {
        token0: weth.address,
        token1: usdc.address,
        fee: 500,
        tickLower: -210000,
        tickUpper: -190000,
        amount0Desired: toWei(1),
        amount1Desired: toWeiUsdc(2_000),
        amount0Min: 0,
        amount1Min: 0,
        recipient: wallet.address,
        deadline: ethers.constants.MaxUint256,
      };
      await expect(
        wallet.executeBatch(
          leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, mintParams, 1),
        ),
      ).to.not.be.reverted;
      const {usdcBalance, wethBalance, nfts} = await getBalances(wallet);
      // expect leveraged LP position with NFT as collateral
      expect(usdcBalance).to.be.lessThan(0);
      expect(wethBalance).to.be.lessThan(0);
      expect(nfts.length).to.equal(1);
    });

    it("User can create leveraged position", async () => {
      const {user, user2, iSupa, usdc, weth, nonFungiblePositionManager, swapRouter, getBalances} =
        await loadFixture(deploySupaFixture);

      const wallet = await createWallet(iSupa, user);
      await usdc.mint(wallet.address, toWeiUsdc(16_000));

      const mintParams = {
        token0: weth.address,
        token1: usdc.address,
        fee: 500,
        tickLower: -210000,
        tickUpper: -190000,
        amount0Desired: toWei(10),
        amount1Desired: toWeiUsdc(20_000),
        amount0Min: 0,
        amount1Min: 0,
        recipient: wallet.address,
        deadline: ethers.constants.MaxUint256,
      };
      await wallet.executeBatch(
        leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, mintParams, 1),
      );

      const wallet2 = await createWallet(iSupa, user2);
      await usdc.mint(wallet2.address, toWeiUsdc(1_000));
      await expect(
        wallet2.executeBatch(
          leveragePos(wallet2, iSupa, usdc, weth, 500, swapRouter, toWeiUsdc(2_000)),
        ),
      ).to.not.be.reverted;

      const {usdcBalance, wethBalance, nfts} = await getBalances(wallet2);
      // expect leveraged long eth position
      expect(usdcBalance).to.be.lessThan(0);
      expect(wethBalance).to.be.greaterThan(0);
      expect(nfts.length).to.equal(0); // regular leveraged position, no NFTs
    });

    it("should mint an LP position and deposit to credit account", async () => {
      const {user, iSupa, usdc, weth, uniV3LPHelper} = await loadFixture(deploySupaFixture);

      const wallet = await createWallet(iSupa, user);
      await usdc.mint(wallet.address, toWeiUsdc(25_000));
      await weth.mint(wallet.address, toWei(15));

      const mintParams = {
        token0: weth.address,
        token1: usdc.address,
        fee: 500,
        tickLower: -210000,
        tickUpper: -190000,
        amount0Desired: toWei(10),
        amount1Desired: toWeiUsdc(20_000),
        amount0Min: 0,
        amount1Min: 0,
        recipient: wallet.address,
        deadline: ethers.constants.MaxUint256,
      };

      await wallet.executeBatch([
        makeCall(weth).approve(uniV3LPHelper.address, ethers.constants.MaxUint256),
        makeCall(usdc).approve(uniV3LPHelper.address, ethers.constants.MaxUint256),
        makeCall(uniV3LPHelper).mintAndDeposit(mintParams),
      ]);

      const nfts = await iSupa.getCreditAccountERC721(wallet.address);
      expect(nfts.length).to.equal(1);
    });

    // considering that #liquify uses #liquidate, all "negative" tests for non-liquidatable
    // positions are done in tests for #liquidate in iSupa.tests.ts
    describe("#liquify successfully", () => {
      describe("when liquidatable wallet has only erc20s", () => {
        it("when liquidation creates no intermediate debt on liquidator", async () => {
          // prettier-ignore
          const {
            iSupa,
            user, user2, user3,
            usdc, weth,
            swapRouter, nonFungiblePositionManager, ethChainlink,
            getBalances, addAllowances
          } = await loadFixture(deploySupaFixture);

          // provides assets both to Supa and to Uniswap pool
          const initialAssetsProvider = await createWallet(iSupa, user);
          await usdc.mint(initialAssetsProvider.address, toWeiUsdc(16_000));
          const mintParams = {
            token0: weth.address,
            token1: usdc.address,
            fee: 500,
            tickLower: -210000,
            tickUpper: -190000,
            amount0Desired: toWei(10),
            amount1Desired: toWeiUsdc(20_000),
            amount0Min: 0,
            amount1Min: 0,
            recipient: initialAssetsProvider.address,
            deadline: ethers.constants.MaxUint256,
          };
          await initialAssetsProvider.executeBatch(
            leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, mintParams, 1),
          );

          const liquidatable = await createWallet(iSupa, user2);
          await usdc.mint(liquidatable.address, toWeiUsdc(1_000));
          await liquidatable.executeBatch(
            leveragePos(liquidatable, iSupa, usdc, weth, 500, swapRouter, toWeiUsdc(2_000)),
          );

          // make `liquidatable` liquidatable
          await ethChainlink.setPrice(ETH_PRICE / 2);

          const liquidator = await createWallet(iSupa, user3);
          await usdc.mint(liquidator.address, toWeiUsdc(1_000));
          await addAllowances(liquidator);

          await liquidator.liquify(
            liquidatable.address,
            swapRouter.address,
            nonFungiblePositionManager.address,
            usdc.address,
            [weth.address],
            [{maxBuy: 0, minSell: 0}],
          );

          const {usdcBalance, wethBalance} = await getBalances(liquidator);
          expect(wethBalance).to.equal(0);
          // if there was no debt in USDC to pay then there is no need to transfer USDC from wallet
          // to creditAccount to pay it back. So all USDC remains on wallet
          expect(usdcBalance).to.greaterThan(toWeiUsdc(1_000));
        });

        it("when liquidation creates an intermediate debt on liquidator", async () => {
          // prettier-ignore
          const {
            iSupa,
            user, user2, user3,
            usdc, weth,
            swapRouter, nonFungiblePositionManager, ethChainlink,
            getBalances, addAllowances
          } = await loadFixture(deploySupaFixture);

          // provides assets both to Supa and to Uniswap pool
          const initialAssetsProvider = await createWallet(iSupa, user);
          await weth.mint(initialAssetsProvider.address, toWei(10));
          await usdc.mint(initialAssetsProvider.address, toWeiUsdc(20_000));
          const mintParams = {
            token0: weth.address,
            token1: usdc.address,
            fee: 500,
            tickLower: -210000,
            tickUpper: -190000,
            amount0Desired: toWei(5),
            amount1Desired: toWeiUsdc(10_000),
            amount0Min: 0,
            amount1Min: 0,
            recipient: initialAssetsProvider.address,
            deadline: ethers.constants.MaxUint256,
          };
          await initialAssetsProvider.executeBatch(
            leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, mintParams, 1),
          );

          const liquidatable = await createWallet(iSupa, user2);
          await weth.mint(liquidatable.address, toWei(1));
          await liquidatable.executeBatch(
            leveragePos(liquidatable, iSupa, weth, usdc, 500, swapRouter, toWei(2)),
          );

          // make `liquidatable` liquidatable
          await ethChainlink.setPrice(ETH_PRICE * 2);

          const liquidator = await createWallet(iSupa, user3);
          await usdc.mint(liquidator.address, toWeiUsdc(1_000));
          await addAllowances(liquidator);

          await liquidator.liquify(
            liquidatable.address,
            swapRouter.address,
            nonFungiblePositionManager.address,
            usdc.address,
            [weth.address],
            [{maxBuy: 0, minSell: 0}],
          );

          const {usdcBalance, wethBalance} = await getBalances(liquidator);
          expect(wethBalance).to.be.equal(0);
          expect(usdcBalance).to.be.greaterThan(toWeiUsdc(1_000));
        });
      });

      it("when liquidatable wallet has erc721", async () => {
        // prettier-ignore
        const {
          iSupa,
          user, user2, user3,
          usdc, weth,
          nonFungiblePositionManager, swapRouter, ethChainlink,
          getBalances, addAllowances,
        } = await loadFixture(deploySupaFixture);

        const initialAssetsProvider = await createWallet(iSupa, user);
        await usdc.mint(initialAssetsProvider.address, toWeiUsdc(160_000));
        const initMintParams = {
          token0: weth.address,
          token1: usdc.address,
          fee: 500,
          tickLower: -210_000,
          tickUpper: -190_000,
          amount0Desired: toWei(5),
          amount1Desired: toWeiUsdc(10_000),
          amount0Min: 0,
          amount1Min: 0,
          recipient: initialAssetsProvider.address,
          deadline: ethers.constants.MaxUint256,
        };
        await initialAssetsProvider.executeBatch(
          leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, initMintParams, 1),
        );

        const liquidatable = await createWallet(iSupa, user2);
        await usdc.mint(liquidatable.address, toWeiUsdc(5_000));
        const mintParams = {
          token0: weth.address,
          token1: usdc.address,
          fee: 500,
          tickLower: -210_000,
          tickUpper: -190_000,
          amount0Desired: toWei(5),
          amount1Desired: toWeiUsdc(10_000),
          amount0Min: 0,
          amount1Min: 0,
          recipient: liquidatable.address,
          deadline: ethers.constants.MaxUint256,
        };
        await liquidatable.executeBatch(
          leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, mintParams, 2),
        );

        const liquidator = await createWallet(iSupa, user3);
        await depositERC20(iSupa, liquidator, usdc, toWeiUsdc(100_000));
        await addAllowances(liquidator);

        await ethChainlink.setPrice(ETH_PRICE * 2); // make `liquidatable` liquidatable
        await liquidator.liquify(
          liquidatable.address,
          swapRouter.address,
          nonFungiblePositionManager.address,
          usdc.address,
          [weth.address],
          [{maxBuy: 0, minSell: 0}],
        );

        const {usdcBalance, wethBalance} = await getBalances(liquidator);
        expect(wethBalance).to.equal(0);
        expect(usdcBalance).to.be.greaterThan(toWeiUsdc(100_000));
      });

      it("when liquidatable wallet has erc20 and erc721", async () => {
        // prettier-ignore
        const {
          iSupa,
          user, user2, user3,
          usdc, weth,
          nonFungiblePositionManager, swapRouter, ethChainlink,
          getBalances, addAllowances,
        } = await loadFixture(deploySupaFixture);

        const initialAssetsProvider = await createWallet(iSupa, user);
        await usdc.mint(initialAssetsProvider.address, toWeiUsdc(160_000));
        const initMintParams = {
          token0: weth.address,
          token1: usdc.address,
          fee: 500,
          tickLower: -210_000,
          tickUpper: -190_000,
          amount0Desired: toWei(5),
          amount1Desired: toWeiUsdc(10_000),
          amount0Min: 0,
          amount1Min: 0,
          recipient: initialAssetsProvider.address,
          deadline: ethers.constants.MaxUint256,
        };
        await initialAssetsProvider.executeBatch(
          leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, initMintParams, 1),
        );

        const liquidatable = await createWallet(iSupa, user2);
        await usdc.mint(liquidatable.address, toWeiUsdc(5_000));
        await liquidatable.executeBatch(
          leveragePos(liquidatable, iSupa, weth, usdc, 500, swapRouter, toWei(2.5)),
        );
        const mintParams = {
          token0: weth.address,
          token1: usdc.address,
          fee: 500,
          tickLower: -210_000,
          tickUpper: -190_000,
          amount0Desired: toWei(2.5),
          amount1Desired: toWeiUsdc(5_000),
          amount0Min: 0,
          amount1Min: 0,
          recipient: liquidatable.address,
          deadline: ethers.constants.MaxUint256,
        };
        await liquidatable.executeBatch(
          leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, mintParams, 2),
        );

        const liquidator = await createWallet(iSupa, user3);
        await depositERC20(iSupa, liquidator, usdc, toWeiUsdc(100_000));
        await addAllowances(liquidator);

        await ethChainlink.setPrice(ETH_PRICE * 2); // make `liquidatable` liquidatable
        await liquidator.liquify(
          liquidatable.address,
          swapRouter.address,
          nonFungiblePositionManager.address,
          usdc.address,
          [weth.address],
          [{maxBuy: 0, minSell: 0}],
        );

        const {usdcBalance, wethBalance} = await getBalances(liquidator);
        expect(wethBalance).to.equal(0);
        expect(usdcBalance).to.be.greaterThan(toWeiUsdc(100_000));
      });

      describe("when exchange price is outside of ERC20 buy/sell range", () => {
        // todo - to write tests with reasonable values we need to have a precise control over
        //   the Uniswap pools. As for now, we can create them only in a single state with hardcoded
        //   values. There are two options:
        //   * wrap them with some explicit interface, so we can control at least price and better -slippage
        //   * mock Uniswap pools
        it("when buy price is too high, should liquidate without conversion", async () => {
          // prettier-ignore
          const {
            iSupa,
            user, user2, user3,
            usdc, weth,
            nonFungiblePositionManager, swapRouter, ethChainlink,
            getBalances, addAllowances
          } = await loadFixture(deploySupaFixture);

          // provides assets both to Supa and to Uniswap pool
          const initialAssetsProvider = await createWallet(iSupa, user);
          await usdc.mint(initialAssetsProvider.address, toWeiUsdc(16_000));
          const mintParams = {
            token0: weth.address,
            token1: usdc.address,
            fee: 500,
            tickLower: -210000,
            tickUpper: -190000,
            amount0Desired: toWei(10),
            amount1Desired: toWeiUsdc(20_000),
            amount0Min: 0,
            amount1Min: 0,
            recipient: initialAssetsProvider.address,
            deadline: ethers.constants.MaxUint256,
          };
          await initialAssetsProvider.executeBatch(
            leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, mintParams, 1),
          );

          const liquidatable = await createWallet(iSupa, user2);
          await usdc.mint(liquidatable.address, toWeiUsdc(1_000));
          await liquidatable.executeBatch(
            leveragePos(liquidatable, iSupa, usdc, weth, 500, swapRouter, toWeiUsdc(2_000)),
          );

          // make `liquidatable` liquidatable
          await ethChainlink.setPrice(ETH_PRICE / 2);

          const liquidator = await createWallet(iSupa, user3);
          await usdc.mint(liquidator.address, toWeiUsdc(2_000));
          await addAllowances(liquidator);

          // constant used to represent float with bignumber used in Uniswap
          const Q96 = 2 ** 96;
          // if we would have a more precise control over the Uniswap pool, we would just change
          // the price and the set this value to some expected value like 1.01. But without precise
          // price control we are just setting it to something that will cause a revert of exchange
          const multiply = 2;
          // 10n ** 6n comes from `sqrt of (10 ** (weth decimals 18 - usdc decimals 6))`, so
          // `sqrt(10 ** 12)`, that is `10 ** 6`, and then to bigint `10n ** 6n`.
          const decimals = 10n ** 6n;
          // unfortunately, after changing the price in ethChainlink in the code above, the price
          // in the Uniswap pool remains the same. So at this point they are divert by about x2.
          // This is why we are using `ETH_PRICE` here and not `ETH_PRICE / 2` that we kind-of
          // set a few lines above
          const minSellEthSqrtPriceX96 = BigInt(Math.sqrt(ETH_PRICE * multiply) * Q96) / decimals;
          await liquidator.liquify(
            liquidatable.address,
            swapRouter.address,
            nonFungiblePositionManager.address,
            usdc.address,
            [weth.address],
            [{maxBuy: 0, minSell: minSellEthSqrtPriceX96}],
          );

          const {usdcBalance, wethBalance} = await getBalances(liquidator);
          expect(wethBalance).to.greaterThan(toWei(0.9));
          // initially there was 1_000 of initial 2_000 has been used to cover the 1_000 debt and
          // so the 1_000 left
          expect(usdcBalance).to.equal(toWeiUsdc(1_000));
        });

        it("when sell price is too low, should liquidate without conversion", async () => {
          // prettier-ignore
          const {
            iSupa,
            user, user2, user3,
            usdc, weth,
            nonFungiblePositionManager, swapRouter, ethChainlink,
            getBalances, addAllowances,
          } = await loadFixture(deploySupaFixture);

          const initialAssetsProvider = await createWallet(iSupa, user);
          await usdc.mint(initialAssetsProvider.address, toWeiUsdc(160_000));
          const initMintParams = {
            token0: weth.address,
            token1: usdc.address,
            fee: 500,
            tickLower: -210_000,
            tickUpper: -190_000,
            amount0Desired: toWei(5),
            amount1Desired: toWeiUsdc(10_000),
            amount0Min: 0,
            amount1Min: 0,
            recipient: initialAssetsProvider.address,
            deadline: ethers.constants.MaxUint256,
          };
          await initialAssetsProvider.executeBatch(
            leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, initMintParams, 1),
          );

          const liquidatable = await createWallet(iSupa, user2);
          await usdc.mint(liquidatable.address, toWeiUsdc(5_000));
          await liquidatable.executeBatch(
            leveragePos(liquidatable, iSupa, weth, usdc, 500, swapRouter, toWei(2.5)),
          );
          const mintParams = {
            token0: weth.address,
            token1: usdc.address,
            fee: 500,
            tickLower: -210_000,
            tickUpper: -190_000,
            amount0Desired: toWei(2.5),
            amount1Desired: toWeiUsdc(5_000),
            amount0Min: 0,
            amount1Min: 0,
            recipient: liquidatable.address,
            deadline: ethers.constants.MaxUint256,
          };
          await liquidatable.executeBatch(
            leverageLP(iSupa, weth, usdc, nonFungiblePositionManager, mintParams, 2),
          );

          const liquidator = await createWallet(iSupa, user3);
          await depositERC20(iSupa, liquidator, usdc, toWeiUsdc(4_000));
          await addAllowances(liquidator);

          await ethChainlink.setPrice(ETH_PRICE * 2); // make `liquidatable` liquidatable
          // constant used to represent float with bignumber used in Uniswap
          const Q96 = 2 ** 96;
          // if we would have a more precise control over the Uniswap pool, we would just change
          // the price and the set this value to some expected value like 1.01. But without precise
          // price control we are just setting it to something that will cause a revert of exchange
          const multiply = 2;
          // 10n ** 6n comes from `sqrt of (10 ** (weth decimals 18 - usdc decimals 6))`, so
          // `sqrt(10 ** 12)`, that is `10 ** 6`, and then to bigint `10n ** 6n`.
          const decimals = 10n ** 6n;
          // unfortunately, after changing the price in ethChainlink in the code above, the price
          // in the Uniswap pool remains the same. So at this point they are divert by about x2.
          // This is why we are using `ETH_PRICE` here and not `ETH_PRICE / 2` that we kind-of
          // set a few lines above
          const maxBuyEthSqrtPriceX96 = BigInt(Math.sqrt(ETH_PRICE / multiply) * Q96) / decimals;

          await liquidator.liquify(
            liquidatable.address,
            swapRouter.address,
            nonFungiblePositionManager.address,
            usdc.address,
            [weth.address],
            [{maxBuy: maxBuyEthSqrtPriceX96, minSell: 0}],
          );

          const {usdcBalance, wethBalance} = await getBalances(liquidator);
          expect(wethBalance).to.approximately(toWei(-2.5), 10 ** 3);
          expect(usdcBalance).to.greaterThan(toWeiUsdc(4_000));
        });
      });
    });
  });
});
