import { ethers } from "hardhat";
import {
  TestERC20__factory,
  WETH9__factory,
  MockValueOracle__factory,
  UniV3Oracle__factory,
} from "../../typechain-types";
import { toWei } from "../../lib/Numbers";
import { getEventsTx } from "../../lib/Events";
import {
  deployUniswapFactory,
  deployUniswapPool,
} from "../../lib/deploy_uniswap";
import { expect } from "chai";
import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("UniswapOracle", function () {
  async function deployUniswapFixture() {
    const [owner] = await ethers.getSigners();

    console.log(await owner.getTransactionCount());

    const weth = await new WETH9__factory(owner).deploy();
    const { uniswapFactory, uniswapNFTManager } = await deployUniswapFactory(
      weth.address,
      owner
    );

    let token0 = await new TestERC20__factory(owner).deploy("USDC", "USDC", 6);
    let token1 = await new TestERC20__factory(owner).deploy("UNI", "UNI", 18);
    if (BigInt(token1.address) < BigInt(token0.address))
      [token0, token1] = [token1, token0];
    const assetValueOracle0 = await new MockValueOracle__factory(
      owner
    ).deploy();
    const assetValueOracle1 = await new MockValueOracle__factory(
      owner
    ).deploy();
    assetValueOracle0.setPrice(toWei(100));
    assetValueOracle1.setPrice(toWei(1));

    const pool = deployUniswapPool(
      uniswapFactory,
      token0.address,
      token1.address,
      100
    );

    const uniOracle = await new UniV3Oracle__factory(owner).deploy(
      uniswapFactory.address,
      uniswapNFTManager.address,
      owner.address
    );
    await uniOracle.setAssetValueOracle(
      token0.address,
      assetValueOracle0.address
    );
    await uniOracle.setAssetValueOracle(
      token1.address,
      assetValueOracle1.address
    );
    return { owner, pool, uniswapNFTManager, token0, token1, uniOracle };
  }

  describe("Uniswap oracle tests", () => {
    it("Calculates proper lp value", async () => {
      const { owner, pool, uniswapNFTManager, token0, token1, uniOracle } =
        await loadFixture(deployUniswapFixture);

      await token0.mint(owner.address, toWei(10));
      await token1.mint(owner.address, toWei(1000));
      await token0.approve(
        uniswapNFTManager.address,
        ethers.constants.MaxUint256
      );
      await token1.approve(
        uniswapNFTManager.address,
        ethers.constants.MaxUint256
      );
      {
        const mintParams = {
          token0: token0.address,
          token1: token1.address,
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
        const { IncreaseLiquidity } = await getEventsTx(
          uniswapNFTManager.mint(mintParams, { gasLimit: 9e6 }),
          uniswapNFTManager
        );
        expect(
          Number(
            (await uniOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt()
          )
        ).to.approximately(
          Number(IncreaseLiquidity.amount0 * 100n + IncreaseLiquidity.amount1),
          0.1
        );
      }
      {
        const mintParams = {
          token0: token0.address,
          token1: token1.address,
          fee: 500,
          tickLower: 50000,
          tickUpper: 61000,
          amount0Desired: toWei(1),
          amount1Desired: toWei(100),
          amount0Min: 0,
          amount1Min: 0,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
        };
        const { IncreaseLiquidity } = await getEventsTx(
          uniswapNFTManager.mint(mintParams),
          uniswapNFTManager
        );
        expect(
          Number(
            (await uniOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt()
          )
        ).to.approximately(
          Number(IncreaseLiquidity.amount0 * 100n + IncreaseLiquidity.amount1),
          0.1
        );
      }
      {
        const mintParams = {
          token0: token0.address,
          token1: token1.address,
          fee: 500,
          tickLower: 30000,
          tickUpper: 40000,
          amount0Desired: toWei(1),
          amount1Desired: toWei(100),
          amount0Min: 0,
          amount1Min: 0,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
        };
        const { IncreaseLiquidity } = await getEventsTx(
          uniswapNFTManager.mint(mintParams),
          uniswapNFTManager
        );
        expect(
          Number(
            (await uniOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt()
          )
        ).to.approximately(
          Number(IncreaseLiquidity.amount0 * 100n + IncreaseLiquidity.amount1),
          0.1
        );
      }
    });
  });
});
