import uniV3FactJSON from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import uniNFTManagerJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import tokenPosDescJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json";
import nftDescJSON from "@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json";
import uniswapPoolJSON from "@uniswap/v3-core/artifacts/contracts/UniswapV3Pool.sol/UniswapV3Pool.json";
import swapRouterJSON from "@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json";
import permit2JSON from "../external/Permit2.sol/Permit2.json";
import anyswapCreate2DeployerJSON from "../artifacts/contracts/external/AnyswapCreate2Deployer.sol/AnyswapCreate2Deployer.json";

import {ContractFactory, ethers} from "ethers";
import {getEventParams, getEventsTx} from "./Events";
import {setCode} from "@nomicfoundation/hardhat-network-helpers";
import {TransactionRequest} from "@ethersproject/abstract-provider";
import {
  AggregatorV3Interface__factory,
  ERC20ChainlinkValueOracle__factory,
  GovernanceProxy,
  GovernanceProxy__factory,
  Governance__factory,
  HashNFT__factory,
  IERC20ValueOracle,
  IPermit2__factory,
  AnyswapCreate2Deployer,
  AnyswapCreate2Deployer__factory,
  TransferAndCall2__factory,
  TransferAndCall2,
} from "../typechain-types";
import {waffle} from "hardhat";
import {MockContract} from "@ethereum-waffle/mock-contract";
import {toWei} from "./Numbers";
import {makeCall, proposeAndExecute} from "./Calls";
import {checkDefined} from "./preconditions";

export async function deployUniswapPool(
  uniswapFactory: ethers.Contract,
  token0: string,
  token1: string,
  price: number,
) {
  if (BigInt(token0) >= BigInt(token1)) throw new Error("token0 address must be less than token1");

  const feeTier: {
    fee: ethers.BigNumberish;
    tickSpacing?: ethers.BigNumberish;
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
  const pool = new ethers.Contract(poolAddress, uniswapPoolJSON.abi, uniswapFactory.signer);

  const Q96 = 2 ** 96;
  await pool.initialize(BigInt(Math.sqrt(price) * Q96));

  return pool;
}

export async function deployUniswapFactory(weth: string, signer: ethers.Signer) {
  const uniswapFactory = await new ethers.ContractFactory(
    uniV3FactJSON.abi,
    uniV3FactJSON.bytecode,
    signer,
  ).deploy();
  const nftDesc = await new ethers.ContractFactory(
    nftDescJSON.abi,
    nftDescJSON.bytecode,
    signer,
  ).deploy();
  const libAddress = nftDesc.address.replace(/^0x/, "").toLowerCase();
  let linkedBytecode = tokenPosDescJSON.bytecode;
  linkedBytecode = linkedBytecode.replace(
    new RegExp("__\\$cea9be979eee3d87fb124d6cbb244bb0b5\\$__", "g"),
    libAddress,
  );
  const tokenDescriptor = await new ethers.ContractFactory(
    tokenPosDescJSON.abi,
    linkedBytecode,
    signer,
  ).deploy(weth, ethers.constants.MaxInt256);
  const uniswapNFTManager = await new ethers.ContractFactory(
    uniNFTManagerJSON.abi,
    uniNFTManagerJSON.bytecode,
    signer,
  ).deploy(uniswapFactory.address, weth, tokenDescriptor.address);
  const swapRouter = await new ethers.ContractFactory(
    swapRouterJSON.abi,
    swapRouterJSON.bytecode,
    signer,
  ).deploy(uniswapFactory.address, weth);
  return {uniswapFactory, uniswapNFTManager, swapRouter};
}

export async function provideLiquidity(
  owner: {address: string},
  uniswapNFTManager: ethers.Contract,
  uniswapPool: ethers.Contract,
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

export const deployFixedAddress = async (signer: ethers.Signer) => {
  const permit2 = IPermit2__factory.connect("0x000000000022D473030F116dDEE9F6B43aC78BA3", signer);
  const anyswapCreate2Deployer = AnyswapCreate2Deployer__factory.connect(
    "0x54F5A04417E29FF5D7141a6d33cb286F50d5d50e",
    signer,
  );
  const transferAndCall2 = TransferAndCall2__factory.connect("0x9848AB09c804dAfCE9e0b82d508aC6d2E8bACFfE", signer);
  await setCode(permit2.address, permit2JSON.deployedBytecode.object);
  await setCode(anyswapCreate2Deployer.address, anyswapCreate2DeployerJSON.deployedBytecode);
  const deployedContract = await new TransferAndCall2__factory(signer).deploy();
  const deployedCode = await deployedContract.provider.getCode(deployedContract.address);
  await setCode(transferAndCall2.address, deployedCode);
  return {
    permit2,
    anyswapCreate2Deployer,
    transferAndCall2,
  };
};

/**
 * Type of the "initialize()" method in logic contracts.
 */
 type InitializeParams<T extends ethers.BaseContract> = T extends {
  initialize(...args: infer Params): Promise<ethers.ContractTransaction>;
}
  ? Omit<Params, "overrides">
  : never;

/**
 * Ideally `ContractFactory` should have been used instead of this type.  But, `ContractFactory`
 * defines `deploy()` method as one returning a `Contract`.  While `typechain` writes actual
 * contracts inheriting them from `BaseContract`.  This breaks the type inference in `DeployResult`.
 */
type ContractFactoryLike = {
  deploy(...args: any[]): Promise<ethers.BaseContract>;
  getDeployTransaction(...args: any[]): TransactionRequest;
  attach(address: string): ethers.BaseContract;
};

/**
 * Type of the "deploy()" method in factories for logic contracts.
 */
type DeployParams<T extends ContractFactoryLike> = T extends {
  getDeployTransaction(...args: infer Params): ethers.ContractTransaction;
}
  ? Omit<Params, "overrides">
  : never;

/**
 * Type of the logic contract deployed by a factory.
 */
type DeployResult<T extends ContractFactoryLike> = T extends {
  deploy(...args: any[]): Promise<infer Result>;
}
  ? Result
  : never;


export const deployAtFixedAddress = async <Factory extends ContractFactoryLike>(
  factory: Factory,
  anyswapCreate2Deployer: AnyswapCreate2Deployer,
  salt: ethers.BytesLike,
  ...params: DeployParams<Factory>
): Promise<DeployResult<Factory>> => {
  const deployTx = factory.getDeployTransaction(...params);
  const x = await getEventsTx(
    anyswapCreate2Deployer.deploy(checkDefined(deployTx.data), salt),
    anyswapCreate2Deployer,
  );
  console.log(x);
  return factory.attach(x.Deployed.addr) as DeployResult<Factory>;
};

export const deployTransferAndCall2 = async (anyswapCreate2Deployer: AnyswapCreate2Deployer) => {
  const salt = ethers.utils.solidityKeccak256(["string"], ["TransferAndCall2"]);
  return (await deployAtFixedAddress(
    new TransferAndCall2__factory(anyswapCreate2Deployer.signer),
    anyswapCreate2Deployer,
    salt,
  ));
};

export async function deployGovernanceProxy(signer: ethers.Signer) {
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
    signer: ethers.Signer,
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
