import { BigNumberish } from "ethers";
import { ethers } from "hardhat";
import {
  TestERC20__factory,
  WETH9__factory,
  MockAssetOracle__factory,
  UniV3Oracle__factory,
  TestERC20,
} from "../../typechain-types";
import { toWei, toWeiUsdc } from "../../lib/Numbers";
import { getEventsTx } from "../../lib/Events";
import { deployUniswapFactory, deployUniswapPool } from "../../lib/deploy_uniswap";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

const USDC_DECIMALS = 6;
const UNI_DECIMALS = 18;

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

    let usdc = await new TestERC20__factory(owner).deploy("USDC", "USDC", USDC_DECIMALS);
    let uni = await new TestERC20__factory(owner).deploy("UNI", "UNI", UNI_DECIMALS);

    const uniValueOracle = await new MockAssetOracle__factory(owner).deploy(UNI_DECIMALS);
    const usdcValueOracle = await new MockAssetOracle__factory(owner).deploy(USDC_DECIMALS);
    await (await uniValueOracle.setPrice(toWei(100))).wait(); // 1 UNI = 50 USDC
    await (await usdcValueOracle.setPrice(toWeiUsdc(1))).wait();

    const pool = await deployUniswapPool(
      uniswapFactory,
      uni.address,
      usdc.address,
      100, // 1 UNI = 100 USDC
    );

    const uniswapOracle = await new UniV3Oracle__factory(owner).deploy(
      uniswapFactory.address,
      uniswapNFTManager.address,
      owner.address,
    );
    const setUniOracleToUniswapTx = await uniswapOracle.setAssetValueOracle(
      uni.address,
      uniValueOracle.address,
    );
    await setUniOracleToUniswapTx.wait();
    const setUsdcOracleToUniswapTx = await uniswapOracle.setAssetValueOracle(
      usdc.address,
      usdcValueOracle.address,
    );
    await setUsdcOracleToUniswapTx.wait();
    return { owner, pool, uniswapNFTManager, uni, usdc, uniswapOracle };
  }

  describe("Uniswap oracle tests", () => {
    it("Calculates proper lp value", async () => {
      const { owner, uniswapNFTManager, uni, usdc, uniswapOracle } = await loadFixture(
        deployUniswapFixture,
      );

      await uni.mint(owner.address, toWei(10));
      await usdc.mint(owner.address, toWeiUsdc(1000));
      await uni.approve(uniswapNFTManager.address, ethers.constants.MaxUint256);
      await usdc.approve(uniswapNFTManager.address, ethers.constants.MaxUint256);
      {
        const mintParams = {
          fee: 500,
          tickLower: 40000,
          tickUpper: 51000,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
          ...toToken0andToken1Params(
            { token: uni, amountMin: 0, amountDesired: toWei(1) },
            { token: usdc, amountMin: 0, amountDesired: toWeiUsdc(100) },
          ),
        };
        const { IncreaseLiquidity } = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(uniswapNFTManager.mint(mintParams, { gasLimit: 9e6 }), uniswapNFTManager);
        const [usdcIncreaseAmount, uniIncreaseAmount] = fromToken0AndToken1(IncreaseLiquidity, [
          usdc,
          uni,
        ]);
        expect(
          (await uniswapOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt(),
        ).to.approximately(usdcIncreaseAmount * 100n + uniIncreaseAmount, 100);
      }
      {
        const mintParams = {
          fee: 500,
          tickLower: 50000,
          tickUpper: 61000,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
          ...toToken0andToken1Params(
            { token: uni, amountMin: 0, amountDesired: toWei(1) },
            { token: usdc, amountMin: 0, amountDesired: toWeiUsdc(100) },
          ),
        };
        const { IncreaseLiquidity } = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(uniswapNFTManager.mint(mintParams), uniswapNFTManager);
        const [usdcIncreaseAmount, uniIncreaseAmount] = fromToken0AndToken1(IncreaseLiquidity, [
          usdc,
          uni,
        ]);
        expect(
          (await uniswapOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt(),
        ).to.approximately(usdcIncreaseAmount * 100n + uniIncreaseAmount, 100);
      }
      {
        const mintParams = {
          fee: 500,
          tickLower: 30000,
          tickUpper: 40000,
          recipient: owner.address,
          deadline: ethers.constants.MaxUint256,
          ...toToken0andToken1Params(
            { token: uni, amountMin: 0, amountDesired: toWei(1) },
            { token: usdc, amountMin: 0, amountDesired: toWeiUsdc(100) },
          ),
        };
        const { IncreaseLiquidity } = await getEventsTx<{
          IncreaseLiquidity: IncreaseLiquidity;
        }>(uniswapNFTManager.mint(mintParams), uniswapNFTManager);
        const [usdcIncreaseAmount, uniIncreaseAmount] = fromToken0AndToken1(IncreaseLiquidity, [
          usdc,
          uni,
        ]);
        expect(
          (await uniswapOracle.calcValue(IncreaseLiquidity.tokenId)).toBigInt(),
        ).to.approximately(usdcIncreaseAmount * 100n + uniIncreaseAmount, 100);
      }
    });
  });
});

type TokenParams = {
  token: TestERC20;
  amountDesired: BigNumberish;
  amountMin: BigNumberish;
};
// Converts tokens params into non-deterministic Uniswap format.
// Unfortunately, what token would be token0 and what token would be token1 depends on what token
// would have a smaller address. If Uniswap Pool was initialized with tokens with token0 address
// grater than token1 address, the .mint call would be reverted with empty string.
// I assume, this is the callstack:
// mint: https://github.com/Uniswap/v3-periphery/blob/a0e0e5817528f0b810583c04feea17b696a16755/contracts/NonfungiblePositionManager.sol#L142
// addLiquidity: https://github.com/Uniswap/v3-periphery/blob/9ca9575d09b0b8d985cc4d9a0f689f7a4470ecb7/contracts/base/LiquidityManagement.sol#L63
// computeAddress: https://github.com/Uniswap/v3-periphery/blob/464a8a49611272f7349c970e0fadb7ec1d3c1086/contracts/libraries/PoolAddress.sol#L34
function toToken0andToken1Params(tokenAParams: TokenParams, tokenBParams: TokenParams) {
  if (tokenAParams.token.address > tokenBParams.token.address)
    [tokenAParams, tokenBParams] = [tokenBParams, tokenAParams];

  const token0Params = {
    token0: tokenAParams.token.address,
    amount0Desired: tokenAParams.amountDesired,
    amount0Min: tokenAParams.amountMin,
  };

  const token1Params = {
    token1: tokenBParams.token.address,
    amount1Desired: tokenBParams.amountDesired,
    amount1Min: tokenBParams.amountMin,
  };

  return { ...token0Params, ...token1Params };
}

type TokensData = {
  amount0: bigint;
  amount1: bigint;
};
// Convert tokens data from non-deterministic Uniswap call response into specific result.
// Unfortunately, that token is token0 and what token is token1 depends on what token have a smaller
// address.
function fromToken0AndToken1(
  { amount0, amount1 }: TokensData,
  expectedOrder: [TestERC20, TestERC20],
) {
  return expectedOrder[0].address > expectedOrder[1].address
    ? [amount0, amount1]
    : [amount1, amount0];
}
