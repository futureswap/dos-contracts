import uniV3FactJSON from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import posManagerJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import tokenPosDescJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json";
import nftDescJSON from "@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json";
import { abi as UNISWAP_POOL_ABI } from "@uniswap/v3-core/artifacts/contracts/UniswapV3Pool.sol/UniswapV3Pool.json";
import { ethers } from "hardhat";
import { ContractFactory, BigNumberish, Contract, Signer } from "ethers";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import {
  IERC20,
  TestERC20__factory,
  WETH9__factory,
  MockValueOracle__factory,
  UniV3Oracle__factory,
} from "../../typechain-types";
import { numberToHexString, toWei } from "../../lib/Numbers";
import { getEventParams, getEvents, getEventsTx } from "../../lib/Events";
import { expect } from "chai";
import { time, loadFixture } from "@nomicfoundation/hardhat-network-helpers";

describe("UniswapOracle", function () {
  async function deployUniswapFixture() {
    const [owner] = await ethers.getSigners();
    const uniswapFactory = await new ContractFactory(
      uniV3FactJSON.abi,
      uniV3FactJSON.bytecode,
      owner
    ).deploy();
    let token0 = await new TestERC20__factory(owner).deploy("USDC", "USDC", 6);
    let token1 = await new TestERC20__factory(owner).deploy("WETH", "WETH", 18);
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
    const feeTier: {
      fee: BigNumberish;
      tickSpacing?: BigNumberish;
    } = {
      fee: "500",
    };
    const { fee, tickSpacing } = feeTier;
    if (tickSpacing !== undefined) {
      if ((await uniswapFactory.feeAmountTickSpacing(fee)) === 0) {
        const enableFeeAmountTx = await uniswapFactory.enableFeeAmount(
          fee,
          tickSpacing
        );
        await enableFeeAmountTx.wait();
      }
    }
    const tx = await uniswapFactory.createPool(
      token0.address,
      token1.address,
      fee
    );
    const receipt = await tx.wait();
    const poolAddress = receipt.events[0].args.pool;
    const pool = new Contract(poolAddress, UNISWAP_POOL_ABI, owner);
    // Price of token0 in token1 = 100;
    pool.initialize(10n * 0x1000000000000000000000000n);
    const weth = await new WETH9__factory(owner).deploy();
    const nftDesc = await new ContractFactory(
      nftDescJSON.abi,
      nftDescJSON.bytecode,
      owner
    ).deploy();
    const libAddress = nftDesc.address.replace(/^0x/, "").toLowerCase();
    let linkedBytecode = tokenPosDescJSON.bytecode;
    linkedBytecode = linkedBytecode.replace(
      new RegExp("__\\$cea9be979eee3d87fb124d6cbb244bb0b5\\$__", "g"),
      libAddress
    );
    const tokenDescriptor = await new ContractFactory(
      tokenPosDescJSON.abi,
      linkedBytecode,
      owner
    ).deploy(weth.address, ethers.constants.MaxInt256);
    const posManager = await new ContractFactory(
      posManagerJSON.abi,
      posManagerJSON.bytecode,
      owner
    ).deploy(uniswapFactory.address, weth.address, tokenDescriptor.address);
    const uniOracle = await new UniV3Oracle__factory(owner).deploy(
      uniswapFactory.address,
      posManager.address,
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
    return { owner, pool, posManager, token0, token1, uniOracle };
  }

  describe("Uniswap oracle tests", () => {
    it("Calculates proper lp value", async () => {
      const { owner, pool, posManager, token0, token1, uniOracle } =
        await loadFixture(deployUniswapFixture);
      await token0.mint(owner.address, toWei(10));
      await token1.mint(owner.address, toWei(1000));
      await token0.approve(posManager.address, ethers.constants.MaxUint256);
      await token1.approve(posManager.address, ethers.constants.MaxUint256);
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
          posManager.mint(mintParams),
          posManager
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
          posManager.mint(mintParams),
          posManager
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
          posManager.mint(mintParams),
          posManager
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
