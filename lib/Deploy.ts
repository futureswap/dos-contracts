import uniV3FactJSON from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import uniNFTManagerJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import tokenPosDescJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json";
import nftDescJSON from "@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json";
import uniswapPoolJSON from "@uniswap/v3-core/artifacts/contracts/UniswapV3Pool.sol/UniswapV3Pool.json";
import swapRouterJSON from "@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json";
import permit2JSON from "../external/Permit2.sol/Permit2.json";
import anyswapCreate2DeployerJSON from "../artifacts/contracts/external/AnyswapCreat2Deployer.sol/AnyswapCreate2Deployer.json";

import {ethers} from "hardhat";
import {ContractFactory, BigNumberish, Contract, Signer} from "ethers";
import {getEventParams} from "./Events";
import {setCode} from "@nomicfoundation/hardhat-network-helpers";
import {AnyswapCreate2Deployer__factory} from "../typechain-types/factories/contracts/external/AnyswapCreat2Deployer.sol";
import {
  AggregatorV3Interface__factory,
  ERC20ChainlinkValueOracle__factory,
  GovernanceProxy,
  GovernanceProxy__factory,
  Governance__factory,
  HashNFT__factory,
  IERC20ValueOracle,
  IPermit2__factory,
} from "../typechain-types";
import {waffle} from "hardhat";
import {MockContract} from "@ethereum-waffle/mock-contract";
import {toWei} from "./Numbers";
import {makeCall, proposeAndExecute} from "./Calls";

export async function deployUniswapPool(
  uniswapFactory: Contract,
  token0: string,
  token1: string,
  price: number,
) {
  const feeTier: {
    fee: BigNumberish;
    tickSpacing?: BigNumberish;
  } = {
    fee: "500",
  };
  const {fee, tickSpacing} = feeTier;
  if (tickSpacing !== undefined) {
    if ((await uniswapFactory.feeAmountTickSpacing(fee)) === 0) {
      const enableFeeAmountTx = await uniswapFactory.enableFeeAmount(fee, tickSpacing);
      await enableFeeAmountTx.wait();
    }
  }

  const tx = await uniswapFactory.createPool(token0, token1, fee);
  const receipt = await tx.wait();
  const poolAddress = receipt.events[0].args.pool;
  const pool = new Contract(poolAddress, uniswapPoolJSON.abi, uniswapFactory.signer);

  const Q96 = 2 ** 96;
  if (BigInt(token0) > BigInt(token1)) price = 1 / price;
  await pool.initialize(BigInt(Math.sqrt(price) * Q96));

  return pool;
}

export async function deployUniswapFactory(weth: string, signer: Signer) {
  const uniswapFactory = await new ContractFactory(
    uniV3FactJSON.abi,
    uniV3FactJSON.bytecode,
    signer,
  ).deploy();
  const nftDesc = await new ContractFactory(nftDescJSON.abi, nftDescJSON.bytecode, signer).deploy();
  const libAddress = nftDesc.address.replace(/^0x/, "").toLowerCase();
  let linkedBytecode = tokenPosDescJSON.bytecode;
  linkedBytecode = linkedBytecode.replace(
    new RegExp("__\\$cea9be979eee3d87fb124d6cbb244bb0b5\\$__", "g"),
    libAddress,
  );
  const tokenDescriptor = await new ContractFactory(
    tokenPosDescJSON.abi,
    linkedBytecode,
    signer,
  ).deploy(weth, ethers.constants.MaxInt256);
  const uniswapNFTManager = await new ContractFactory(
    uniNFTManagerJSON.abi,
    uniNFTManagerJSON.bytecode,
    signer,
  ).deploy(uniswapFactory.address, weth, tokenDescriptor.address);
  const swapRouter = await new ContractFactory(
    swapRouterJSON.abi,
    swapRouterJSON.bytecode,
    signer,
  ).deploy(uniswapFactory.address, weth);
  return {uniswapFactory, uniswapNFTManager, swapRouter};
}

export async function provideLiquidity(
  owner: {address: string},
  uniswapNFTManager: Contract,
  uniswapPool: Contract,
  amount0Desired: bigint,
  amount1Desired: bigint,
) {
  const token0 = await uniswapPool.token0();
  const token1 = await uniswapPool.token1();
  const fee = await uniswapPool.fee();

  const mintParams = {
    token0,
    token1,
    fee,
    tickLower: 40000,
    tickUpper: 51000,
    amount0Desired,
    amount1Desired,
    amount0Min: 0,
    amount1Min: 0,
    recipient: owner.address,
    deadline: ethers.constants.MaxUint256,
  };
  const {tokenId, liquidity, amount0, amount1} = await getEventParams(
    await uniswapNFTManager.mint(mintParams),
    uniswapNFTManager,
    "IncreaseLiquidity",
  );
  return {
    tokenId: tokenId.toBigInt() as bigint,
    liquidity: liquidity.toBigInt() as bigint,
    amount0: amount0.toBigInt() as bigint,
    amount1: amount1.toBigInt() as bigint,
  };
}

export const deployFixedAddress = async (signer: Signer) => {
  const permit2Address = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
  await setCode(permit2Address, permit2JSON.deployedBytecode.object);
  const anyswapCreate2Deployer = "0x54F5A04417E29FF5D7141a6d33cb286F50d5d50e";
  await setCode(anyswapCreate2Deployer, anyswapCreate2DeployerJSON.deployedBytecode);
  return {
    permit2: IPermit2__factory.connect(permit2Address, signer),
    anyswapCreate2Deployer: AnyswapCreate2Deployer__factory.connect(anyswapCreate2Deployer, signer),
  };
};

export async function deployGovernanceProxy(signer: Signer) {
  return {
    governanceProxy: await new GovernanceProxy__factory(signer).deploy(),
  };
}

export async function deployGovernance(governanceProxy: GovernanceProxy) {
  const signer = governanceProxy.signer;
  const voteNFT = await new HashNFT__factory(signer).deploy(
    "Voting token",
    "VTOK",
    governanceProxy.address,
  );
  const governance = await new Governance__factory(signer).deploy(
    governanceProxy.address,
    voteNFT.address,
    await signer.getAddress(),
  );
  await governanceProxy.execute([
    makeCall(governanceProxy, "proposeGovernance", [governance.address]),
  ]);
  // Empty execute such that governance accepts the governance role of the
  // governance proxy.
  await proposeAndExecute(governance, voteNFT, []);

  return {voteNFT, governance};
}

export class Chainlink {
  static async deploy(
    signer: Signer,
    price: number,
    chainLinkDecimals: number,
    baseTokenDecimals: number,
    observedTokenDecimals: number,
  ) {
    const mockChainLink = await waffle.deployMockContract(
      signer,
      AggregatorV3Interface__factory.abi,
    );
    await mockChainLink.mock.decimals.returns(chainLinkDecimals);
    const erc20Oracle = await new ERC20ChainlinkValueOracle__factory(signer).deploy(
      mockChainLink.address,
      baseTokenDecimals,
      observedTokenDecimals,
    );
    const oracle = new Chainlink(mockChainLink, erc20Oracle, chainLinkDecimals);
    await oracle.setPrice(price);
    return oracle;
  }

  private constructor(
    public readonly chainlink: MockContract,
    public readonly oracle: IERC20ValueOracle,
    public readonly chainlinkDecimals: number,
  ) {}

  async setPrice(price: number) {
    return this.chainlink.mock.latestRoundData.returns(
      0,
      toWei(price, this.chainlinkDecimals),
      0,
      0,
      0,
    );
  }
}
