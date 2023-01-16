import {ethers} from "hardhat";
import {expect} from "chai";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";

import {TestERC20__factory, WETH9__factory, UniV3Oracle__factory} from "../../typechain-types";
import {toWei} from "../../lib/numbers";
import {getEventsTx} from "../../lib/events";
import {deployUniswapFactory, deployUniswapPool, Chainlink} from "../../lib/deploy";

// this three values are connected - you cannot change one without changing others.
// There is no easy way to get the tick values for a specific price - this values
// has been taken from a deployed test pool. If for some reason there would be a need
// to get a new set of values - ask Gerben
const PRICE = 100;
const TICK_LOWER = 40000;
const TICK_UPPER = 51000;

// taken from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"
type IncreaseLiquidity = {
  amount0: bigint;
  amount1: bigint;
  tokenId: bigint;
  liquidity: bigint;
};

describe("UniswapOracle", () => {
  async function deployUniswapFixture() {
    const [owner] = await ethers.getSigners();

    const weth = await new WETH9__factory(owner).deploy();
    const {uniswapV3Factory, nonFungiblePositionManager} = await deployUniswapFactory(
      weth.address,
      owner,
    );

    let tok0 = await new TestERC20__factory(owner).deploy("TOKA", "TOKA", 18);
    let tok1 = await new TestERC20__factory(owner).deploy("TOKB", "TOKB", 18);

    // because of implementation details of Uniswap, it would always consider token with a smaller
    // address as token0 and token with a bigger address as token1.
    // Functions like "mint" will revert with empty string if tokens would be provided in a wrong order.
    // Other components, like Uniswap Pool would silently flip them in case if order would be "wrong".
    // So, arranging test tokens in order for tests to work as expected.
    //   For thous who would like to abstract this away - flipping the tokens also mean that price
    // need to be flipped (function deployUniswapPool is doing this internally), while for these
    // tests the price is hardcoded with ticks - changing one without another will break it
    if (BigInt(tok0.address) > BigInt(tok1.address)) [tok0, tok1] = [tok1, tok0];

    const tok0Chainlink = await Chainlink.deploy(owner, PRICE, 8, 18, 18);
    const tok1Chainlink = await Chainlink.deploy(owner, 1, 8, 18, 18);

    const pool = await deployUniswapPool(uniswapV3Factory, tok0.address, tok1.address, 500, PRICE);

    const uniswapOracle = await new UniV3Oracle__factory(owner).deploy(
      uniswapV3Factory.address,
      nonFungiblePositionManager.address,
      owner.address,
    );
    await uniswapOracle.setERC20ValueOracle(tok0.address, tok0Chainlink.oracle.address);
    await uniswapOracle.setERC20ValueOracle(tok1.address, tok1Chainlink.oracle.address);
    return {owner, pool, nonFungiblePositionManager, tok0, tok1, uniswapOracle};
  }

  describe("#mint", () => {
    it(
      "when minting in a price range that includes the current price " +
        "then liquidity of both tokens in the pool get increased " +
        "and total liquidity is increased by the sum of liquidity of both tokens",
      async () => {
        const {owner, nonFungiblePositionManager, tok0, tok1, uniswapOracle} = await loadFixture(
          deployUniswapFixture,
        );
        await tok0.mint(owner.address, toWei(10));
        await tok1.mint(owner.address, toWei(1000));
        await tok0.approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256);
        await tok1.approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256);

        const mintParams = {
          token0: tok0.address,
          token1: tok1.address,
          fee: 500,
          tickLower: TICK_LOWER,
          tickUpper: TICK_UPPER,
          amount0Desired: toWei(1),
          amount1Desired: toWei(100),
          amount0Min: 0,
          amount1Min: 0,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
        };

        const {IncreaseLiquidity} = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(
          nonFungiblePositionManager.mint(mintParams, {gasLimit: 9e6}),
          nonFungiblePositionManager,
        );
        const token0IncreaseLiquidity = IncreaseLiquidity.amount0 * BigInt(PRICE);
        const token1IncreaseLiquidity = IncreaseLiquidity.amount1;
        // the exact values calculation dependents on the internal Uniswap logic
        expect(token0IncreaseLiquidity).to.approximately(83_886_064_887_012_034_800n, 100);
        expect(token1IncreaseLiquidity).to.approximately(100_000_000_000_000_000_000n, 100);
        // having it otherwise probably means that there is an issue in ordering the tokens
        expect(token0IncreaseLiquidity > token1IncreaseLiquidity);
        const totalIncreaseLiquidityRaw = await uniswapOracle.calcValue(IncreaseLiquidity.tokenId);
        const totalIncreaseLiquidity = totalIncreaseLiquidityRaw.toBigInt();
        expect(totalIncreaseLiquidity).to.approximately(
          token0IncreaseLiquidity + token1IncreaseLiquidity,
          100,
        );
      },
    );
    it(
      "when minting in a price range that is above the current price " +
        "then only liquidity of token0 gets increased" +
        "and total liquidity is increased by the same amount",
      async () => {
        const {owner, nonFungiblePositionManager, tok0, tok1, uniswapOracle} = await loadFixture(
          deployUniswapFixture,
        );
        await tok0.mint(owner.address, toWei(10));
        await tok1.mint(owner.address, toWei(1000));
        await tok0.approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256);
        await tok1.approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256);

        const mintParams = {
          token0: tok0.address,
          token1: tok1.address,
          fee: 500,
          // 10_000 is just a "big value" to be sure that LP is minting in a price range that is
          // above the current price
          tickLower: TICK_LOWER + 10_000,
          tickUpper: TICK_UPPER + 10_000,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
          amount0Min: 0,
          amount0Desired: toWei(1),
          amount1Min: 0,
          amount1Desired: toWei(100),
        };

        const {IncreaseLiquidity} = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(nonFungiblePositionManager.mint(mintParams), nonFungiblePositionManager);
        const token0IncreaseLiquidity = IncreaseLiquidity.amount0 * BigInt(PRICE);
        const token1IncreaseLiquidity = IncreaseLiquidity.amount1;
        // the exact value calculation dependents on the internal Uniswap logic
        expect(token0IncreaseLiquidity).to.approximately(100_000_000_000_000_000_000n, 100);
        expect(token1IncreaseLiquidity).to.equal(0n);
        const totalIncreaseLiquidityRaw = await uniswapOracle.calcValue(IncreaseLiquidity.tokenId);
        const totalIncreaseLiquidity = totalIncreaseLiquidityRaw.toBigInt();
        expect(totalIncreaseLiquidity).to.approximately(token0IncreaseLiquidity, 100);
      },
    );

    it(
      "when minting in a price range that is above the current price " +
        "then only liquidity of token0 get increased" +
        "and total liquidity is increased by the same amount",
      async () => {
        const {owner, nonFungiblePositionManager, tok0, tok1, uniswapOracle} = await loadFixture(
          deployUniswapFixture,
        );
        await tok0.mint(owner.address, toWei(10));
        await tok1.mint(owner.address, toWei(1000));
        await tok0.approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256);
        await tok1.approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256);

        const mintParams = {
          token0: tok0.address,
          token1: tok1.address,
          fee: 500,
          // 10_000 is just a "big value" to be sure that LP is minting in a price range that is
          // above the current price
          tickLower: TICK_LOWER - 10_000,
          tickUpper: TICK_UPPER - 10_000,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
          amount0Min: 0,
          amount0Desired: toWei(1),
          amount1Min: 0,
          amount1Desired: toWei(100),
        };

        const {IncreaseLiquidity} = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(nonFungiblePositionManager.mint(mintParams), nonFungiblePositionManager);
        const token0IncreaseLiquidity = IncreaseLiquidity.amount0 * BigInt(PRICE);
        const token1IncreaseLiquidity = IncreaseLiquidity.amount1;
        expect(token0IncreaseLiquidity).to.equal(0);
        // the exact value calculation dependents on the internal Uniswap logic
        expect(token1IncreaseLiquidity).to.approximately(100_000_000_000_000_000_000n, 100);
        const totalIncreaseLiquidityRaw = await uniswapOracle.calcValue(IncreaseLiquidity.tokenId);
        const totalIncreaseLiquidity = totalIncreaseLiquidityRaw.toBigInt();
        expect(totalIncreaseLiquidity).to.approximately(token1IncreaseLiquidity, 100);
      },
    );
  });
});
