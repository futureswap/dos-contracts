import { BigNumberish } from "ethers";
import { ethers } from "hardhat";
import {
  TestERC20__factory,
  WETH9__factory,
  UniV3Oracle__factory,
  TestERC20,
} from "../../typechain-types";
import { toWei, toWeiUsdc } from "../../lib/Numbers";
import { getEventsTx } from "../../lib/Events";
import { deployUniswapFactory, deployUniswapPool } from "../../lib/deploy_uniswap";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { Chainlink } from "../../lib/Calls";

const PRICE = 100;

// taken from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json"
type IncreaseLiquidity = {
  amount0: bigint;
  amount1: bigint;
  tokenId: bigint;
  liquidity: bigint;
};

describe("UniswapOracle", function () {
  async function deployUniswapFixture() {
    const [owner] = await ethers.getSigners();

    const weth = await new WETH9__factory(owner).deploy();
    const { uniswapFactory, uniswapNFTManager } = await deployUniswapFactory(weth.address, owner);

    let tok0;
    let tok1;
    tok0 = await new TestERC20__factory(owner).deploy("TOKA", "TOKA", 18);
    tok1 = await new TestERC20__factory(owner).deploy("TOKB", "TOKB", 18);

    if (BigInt(tok0.address) > BigInt(tok1.address))
      [tok0, tok1] = [tok1, tok0];

    const tok0Chainlink = await Chainlink.deploy(owner, PRICE, 8, 18, 18);
    const tok1Chainlink = await Chainlink.deploy(owner, 1, 8, 18, 18);

    const pool = await deployUniswapPool(
      uniswapFactory,
      tok0.address,
      tok1.address,
      PRICE
    );

    const uniswapOracle = await new UniV3Oracle__factory(owner).deploy(
      uniswapFactory.address,
      uniswapNFTManager.address,
      owner.address,
    );
    await uniswapOracle.setAssetValueOracle(
      tok0.address,
      tok0Chainlink.assetOracle.address
    );
    await uniswapOracle.setAssetValueOracle(
      tok1.address,
      tok1Chainlink.assetOracle.address
    );
    return { owner, pool, uniswapNFTManager, tok0, tok1, uniswapOracle };
  }

  describe("Uniswap oracle tests", () => {
    it("Calculates proper lp value", async () => {
      const { owner, uniswapNFTManager, tok0, tok1, uniswapOracle } =
        await loadFixture(deployUniswapFixture);

      await tok0.mint(owner.address, toWei(10));
      await tok1.mint(owner.address, toWei(1000));
      await tok0.approve(
        uniswapNFTManager.address,
        ethers.constants.MaxUint256
      );
      await tok1.approve(
        uniswapNFTManager.address,
        ethers.constants.MaxUint256
      );
      {
        const mintParams = {
          token0: tok0.address,
          token1: tok1.address,
          fee: 500,
          tickLower: 40000,
          tickUpper: 51000,
          amount0Desired: toWei(1),
          amount1Desired: toWei(100),
          amount0Min: 0,
          amount1Min: 0,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
        };
        const { IncreaseLiquidity } = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(
          uniswapNFTManager.mint(mintParams, { gasLimit: 9e6 }),
          uniswapNFTManager
        );
        expect(
          (await uniswapOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt()
        ).to.approximately(
          IncreaseLiquidity.amount0 * BigInt(PRICE) + IncreaseLiquidity.amount1,
          100
        );
      }
      {
        const mintParams = {
          token0: tok0.address,
          token1: tok1.address,
          fee: 500,
          tickLower: 50000,
          tickUpper: 61000,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
          amount0Min: 0,
          amount0Desired: toWei(1),
          amount1Min: 0,
          amount1Desired: toWei(100),
        };
        const { IncreaseLiquidity } = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(uniswapNFTManager.mint(mintParams), uniswapNFTManager);
        expect(
          (await uniswapOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt()
        ).to.approximately(
          IncreaseLiquidity.amount0 * 100n + IncreaseLiquidity.amount1,
          100
        );
      }
      {
        const mintParams = {
          token0: tok0.address,
          token1: tok1.address,
          fee: 500,
          tickLower: 30000,
          tickUpper: 40000,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
          amount0Min: 0,
          amount0Desired: toWei(1),
          amount1Min: 0,
          amount1Desired: toWei(100),
        };
        const { IncreaseLiquidity } = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(uniswapNFTManager.mint(mintParams), uniswapNFTManager);
        expect(
          (await uniswapOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt()
        ).to.approximately(
          IncreaseLiquidity.amount0 * 100n + IncreaseLiquidity.amount1,
          100
        );
      }
    });
  });
});
