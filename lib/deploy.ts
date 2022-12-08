/* eslint-disable @typescript-eslint/no-unsafe-call */
/* eslint-disable @typescript-eslint/no-unsafe-assignment */
/* eslint-disable @typescript-eslint/no-unsafe-member-access */
/* eslint-disable @typescript-eslint/no-unsafe-argument */
/* eslint-disable @typescript-eslint/no-explicit-any */

import type {MockContract} from "@ethereum-waffle/mock-contract";
import type {
  GovernanceProxy,
  IERC20ValueOracle,
  AnyswapCreate2Deployer,
  TransferAndCall2,
  IPermit2,
  HashNFT,
  Governance,
} from "../typechain-types";
import type {TransactionRequest} from "@ethersproject/abstract-provider";

import uniV3FactJSON from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import uniNFTManagerJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import tokenPosDescJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json";
import nftDescJSON from "@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json";
import uniswapPoolJSON from "@uniswap/v3-core/artifacts/contracts/UniswapV3Pool.sol/UniswapV3Pool.json";
import swapRouterJSON from "@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json";
import {ethers} from "ethers";
import {setCode} from "@nomicfoundation/hardhat-network-helpers";
import {waffle} from "hardhat";

import {getEventParams, getEventsTx} from "./events";
import permit2JSON from "../external/Permit2.sol/Permit2.json";
import {
  AggregatorV3Interface__factory,
  ERC20ChainlinkValueOracle__factory,
  GovernanceProxy__factory,
  Governance__factory,
  HashNFT__factory,
  IPermit2__factory,
  AnyswapCreate2Deployer__factory,
  TransferAndCall2__factory,
} from "../typechain-types";
import {toWei} from "./numbers";
import {makeCall, proposeAndExecute} from "./calls";
import {checkDefined} from "./preconditions";

export async function deployAnyswapCreate2Deployer(signer: ethers.Signer) {
  const deployerAddress = "0xB39734A1c2f6917c17b38C9Bc30ECB3fCC2dCBf8";
  const contractAddress = "0xDf7Cc8d582D213Db25FBfb9CF659c79e8E4263bd";

  const provider = checkDefined(signer.provider);
  if ((await provider.getTransactionCount(deployerAddress)) == 0) {
    // Deploy AnyswapCreate2Deployer to the same address on all networks
    const tx = {
      nonce: 0,
      gasPrice: 116000000000,
      gasLimit: 158155,
      // EIP-1559 fields
      // maxFeePerGas: gasPrice.maxFeePerGas,
      // maxPriorityFeePerGas: gasPrice.maxPriorityFeePerGas,
      value: 0,
      data: "0x608060405234801561001057600080fd5b506101e7806100206000396000f3fe608060405234801561001057600080fd5b506004361061002b5760003560e01c80639c4ae2d014610030575b600080fd5b61004361003e3660046100b2565b610045565b005b6000818351602085016000f59050803b61005e57600080fd5b6040805173ffffffffffffffffffffffffffffffffffffffff83168152602081018490527fb03c53b28e78a88e31607a27e1fa48234dce28d5d9d9ec7b295aeb02e674a1e1910160405180910390a1505050565b600080604083850312156100c4578182fd5b823567ffffffffffffffff808211156100db578384fd5b818501915085601f8301126100ee578384fd5b81358181111561010057610100610182565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f0116810190838211818310171561014657610146610182565b8160405282815288602084870101111561015e578687fd5b82602086016020830137918201602090810196909652509694909301359450505050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fdfea2646970667358221220144cba0fdb5118b83f6adff581cec1e3628ba45d2e73e9df71c331f8f8a4a13e64736f6c63430008020033",
      type: 0,
      // EIP-2718
      // type: 0
    };
    const sig = {
      v: 27,
      r: "0x1820182018201820182018201820182018201820182018201820182018201820",
      s: "0x1820182018201820182018201820182018201820182018201820182018201820",
    };
    // Make sure the money is send to the deployer address by awaiting the transaction confirmation
    await (await signer.sendTransaction({to: deployerAddress, value: toWei(0.02)})).wait();
    const deployTx = await checkDefined(signer.provider).sendTransaction(
      ethers.utils.serializeTransaction(tx, sig),
    );
    const receipt = await deployTx.wait();
    if (contractAddress != receipt.contractAddress) throw new Error("Incorrect contract addresss");
  }
  return AnyswapCreate2Deployer__factory.connect(contractAddress, signer);
}

export async function deployUniswapPool(
  uniswapFactory: ethers.Contract,
  token0: string,
  token1: string,
  price: number,
): Promise<ethers.Contract> {
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

  // eslint-disable-next-line @typescript-eslint/no-magic-numbers -- false positive
  const Q96 = 2 ** 96; // on expression that is actually a number
  await pool.initialize(BigInt(Math.sqrt(price) * Q96));

  return pool;
}

export async function deployUniswapFactory(
  weth: string,
  signer: ethers.Signer,
): Promise<{
  uniswapFactory: ethers.Contract;
  uniswapNFTManager: ethers.Contract;
  swapRouter: ethers.Contract;
}> {
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
    /__\$cea9be979eee3d87fb124d6cbb244bb0b5\$__/g,
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
): Promise<{
  tokenId: bigint;
  liquidity: bigint;
  amount0: bigint;
  amount1: bigint;
}> {
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
    tokenId: tokenId.toBigInt(),
    liquidity: liquidity.toBigInt(),
    amount0: amount0.toBigInt(),
    amount1: amount1.toBigInt(),
  };
}

export const deployFixedAddress = async (signer: ethers.Signer) => {
  const permit2 = IPermit2__factory.connect("0x000000000022D473030F116dDEE9F6B43aC78BA3", signer);
  const transferAndCall2 = TransferAndCall2__factory.connect(
    "0x9848AB09c804dAfCE9e0b82d508aC6d2E8bACFfE",
    signer,
  );
  await setCode(permit2.address, permit2JSON.deployedBytecode.object);
  const deployedContract = await new TransferAndCall2__factory(signer).deploy();
  const deployedCode = await deployedContract.provider.getCode(deployedContract.address);
  await setCode(transferAndCall2.address, deployedCode);
  return {
    permit2,
    transferAndCall2,
  };
};

/**
 * ideally `ContractFactory` should have been used instead of this type.  But, `ContractFactory`
 * defines `deploy()` method as one returning a `Contract`.  While `typechain` writes actual
 * contracts inheriting them from `BaseContract`.  This breaks the type inference in `DeployResult`.
 */
type ContractFactoryLike = {
  deploy: (...args: any[]) => Promise<ethers.BaseContract>;
  getDeployTransaction: (...args: any[]) => TransactionRequest;
  attach: (address: string) => ethers.BaseContract;
};

/**
 * type of the "deploy()" method in factories for logic contracts.
 */
type DeployParams<T extends ContractFactoryLike> = T extends {
  getDeployTransaction: (...args: infer Params) => TransactionRequest;
}
  ? Omit<Params, "overrides">
  : never;

/**
 * type of the logic contract deployed by a factory.
 */
type DeployResult<T extends ContractFactoryLike> = T extends {
  deploy: (...args: any[]) => Promise<infer Result>;
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
  const {Deployed} = await getEventsTx<{Deployed: {addr: string}}>(
    anyswapCreate2Deployer.deploy(checkDefined(deployTx.data), salt),
    anyswapCreate2Deployer,
  );
  return factory.attach(Deployed.addr) as DeployResult<Factory>;
};

export const deployTransferAndCall2 = async (
  anyswapCreate2Deployer: AnyswapCreate2Deployer,
): Promise<TransferAndCall2> => {
  const salt = ethers.utils.solidityKeccak256(["string"], ["TransferAndCall2"]);
  return await deployAtFixedAddress(
    new TransferAndCall2__factory(anyswapCreate2Deployer.signer),
    anyswapCreate2Deployer,
    salt,
  );
};

export async function deployGovernanceProxy(signer: ethers.Signer): Promise<{
  governanceProxy: GovernanceProxy;
}> {
  return {
    governanceProxy: await new GovernanceProxy__factory(signer).deploy(),
  };
}

export async function deployGovernance(governanceProxy: GovernanceProxy): Promise<{
  voteNFT: HashNFT;
  governance: Governance;
}> {
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
  // empty execute such that governance accepts the governance role of the
  // governance proxy.
  await proposeAndExecute(governance, voteNFT, []);

  return {voteNFT, governance};
}

export class Chainlink {
  private constructor(
    readonly chainlink: MockContract,
    readonly oracle: IERC20ValueOracle,
    readonly chainlinkDecimals: number,
  ) {}

  static async deploy(
    signer: ethers.Signer,
    price: number,
    chainLinkDecimals: number,
    baseTokenDecimals: number,
    observedTokenDecimals: number,
  ): Promise<Chainlink> {
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

  async setPrice(price: number): Promise<void> {
    await this.chainlink.mock.latestRoundData.returns(
      0,
      toWei(price, this.chainlinkDecimals),
      0,
      0,
      0,
    );
  }
}
