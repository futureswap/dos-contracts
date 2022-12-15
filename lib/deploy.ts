/* eslint-disable @typescript-eslint/no-unsafe-call */
/* eslint-disable @typescript-eslint/no-unsafe-assignment */
/* eslint-disable @typescript-eslint/no-unsafe-member-access */
/* eslint-disable @typescript-eslint/no-unsafe-argument */
/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable no-await-in-loop */

import type {MockContract} from "@ethereum-waffle/mock-contract";
import type {
  GovernanceProxy,
  IERC20ValueOracle,
  TransferAndCall2,
  IAnyswapCreate2Deployer,
  HashNFT,
  Governance,
  IPermit2,
  VersionManager,
  IDOS,
  IUniswapV3Factory,
  ISwapRouter,
  FutureSwapProxy,
  IERC20WithMetadata,
  IUniswapV3Pool,
} from "../typechain-types";
import type {TransactionRequest} from "@ethersproject/abstract-provider";

import uniV3FactJSON from "@uniswap/v3-core/artifacts/contracts/UniswapV3Factory.sol/UniswapV3Factory.json";
import uniNFTManagerJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungiblePositionManager.sol/NonfungiblePositionManager.json";
import tokenPosDescJSON from "@uniswap/v3-periphery/artifacts/contracts/NonfungibleTokenPositionDescriptor.sol/NonfungibleTokenPositionDescriptor.json";
import nftDescJSON from "@uniswap/v3-periphery/artifacts/contracts/libraries/NFTDescriptor.sol/NFTDescriptor.json";
import swapRouterJSON from "@uniswap/v3-periphery/artifacts/contracts/SwapRouter.sol/SwapRouter.json";
import {ethers} from "ethers";
import {setCode} from "@nomicfoundation/hardhat-network-helpers";
import {waffle} from "hardhat";

import {
  DSafeLogic__factory,
  IUniswapV3Pool__factory,
  IERC20Metadata__factory,
  WETH9__factory,
  TestERC20__factory,
  MockERC20Oracle__factory,
  UniV3Oracle__factory,
  FutureSwapProxy__factory,
  IUniswapV3Factory__factory,
  ISwapRouter__factory,
  VersionManager__factory,
  IDOS__factory,
  AggregatorV3Interface__factory,
  ERC20ChainlinkValueOracle__factory,
  GovernanceProxy__factory,
  Governance__factory,
  HashNFT__factory,
  IPermit2__factory,
  IAnyswapCreate2Deployer__factory,
  TransferAndCall2__factory,
  DOS__factory,
  DOSConfig__factory,
} from "../typechain-types";
import addressesJSON from "../deployment/addresses.json";
import {getEventParams, getEventsTx} from "./events";
import permit2JSON from "../external/Permit2.sol/Permit2.json";
import {toWei} from "./numbers";
import {createDSafe, depositIntoDos, leverageLP, makeCall, proposeAndExecute} from "./calls";
import {checkDefined, checkState} from "./preconditions";

export async function deployUniswapPool(
  uniswapV3Factory: IUniswapV3Factory,
  token0: string,
  token1: string,
  fee: number,
  price: number,
): Promise<IUniswapV3Pool> {
  if (BigInt(token0) >= BigInt(token1)) throw new Error("token0 address must be less than token1");

  const {PoolCreated} = await getEventsTx(
    uniswapV3Factory.createPool(token0, token1, fee),
    uniswapV3Factory,
  );
  const poolAddress = PoolCreated.pool as string;
  const pool = IUniswapV3Pool__factory.connect(poolAddress, uniswapV3Factory.signer);

  // eslint-disable-next-line @typescript-eslint/no-magic-numbers -- false positive
  const Q96 = 2 ** 96; // on expression that is actually a number
  await pool.initialize(BigInt(Math.sqrt(price) * Q96));

  return pool;
}

export const getUniswapFactory = (signer: ethers.Signer): ethers.ContractFactory => {
  return new ethers.ContractFactory(uniV3FactJSON.abi, uniV3FactJSON.bytecode, signer);
};

export const getUniswapNonFungiblePositionManagerFactory = (
  signer: ethers.Signer,
): ethers.ContractFactory => {
  return new ethers.ContractFactory(uniNFTManagerJSON.abi, uniNFTManagerJSON.bytecode, signer);
};

export const getSwapRouterFactory = (signer: ethers.Signer): ethers.ContractFactory => {
  return new ethers.ContractFactory(swapRouterJSON.abi, swapRouterJSON.bytecode, signer);
};

export async function deployUniswapFactory(
  weth: string,
  signer: ethers.Signer,
): Promise<{
  uniswapV3Factory: IUniswapV3Factory;
  nonFungiblePositionManager: ethers.Contract;
  swapRouter: ISwapRouter;
}> {
  const uniswapV3Factory = IUniswapV3Factory__factory.connect(
    (await getUniswapFactory(signer).deploy()).address,
    signer,
  );
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
  const nonFungiblePositionManager = await getUniswapNonFungiblePositionManagerFactory(
    signer,
  ).deploy(uniswapV3Factory.address, weth, tokenDescriptor.address);
  const swapRouter = ISwapRouter__factory.connect(
    (await getSwapRouterFactory(signer).deploy(uniswapV3Factory.address, weth)).address,
    signer,
  );
  return {uniswapV3Factory, nonFungiblePositionManager, swapRouter};
}

export async function provideLiquidity(
  owner: {address: string},
  nonFungiblePositionManager: ethers.Contract,
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
    await nonFungiblePositionManager.mint(mintParams),
    nonFungiblePositionManager,
    "IncreaseLiquidity",
  );
  return {
    tokenId: tokenId.toBigInt(),
    liquidity: liquidity.toBigInt(),
    amount0: amount0.toBigInt(),
    amount1: amount1.toBigInt(),
  };
}

export async function deployGovernance(governanceProxy: GovernanceProxy): Promise<{
  voteNFT: HashNFT;
  governance: Governance;
}> {
  const signer = governanceProxy.signer;
  const voteNFT = await new HashNFT__factory(signer).deploy("Voting token", "VTOK");
  const governance = await new Governance__factory(signer).deploy(
    governanceProxy.address,
    voteNFT.address,
    await signer.getAddress(),
  );
  await governanceProxy.execute([makeCall(governanceProxy).proposeGovernance(governance.address)]);
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

// fixed address deployments

export const anyswapCreate2DeployerAddress = "0xDf7Cc8d582D213Db25FBfb9CF659c79e8E4263bd";

export async function deployAnyswapCreate2Deployer(
  signer: ethers.Signer,
): Promise<IAnyswapCreate2Deployer> {
  const deployerAddress = "0xB39734A1c2f6917c17b38C9Bc30ECB3fCC2dCBf8";

  const provider = checkDefined(signer.provider);
  if ((await provider.getTransactionCount(deployerAddress)) == 0) {
    // deploy AnyswapCreate2Deployer to the same address on all networks
    const tx = {
      nonce: 0,
      gasPrice: 116000000000,
      gasLimit: 158155,
      // eIP-1559 fields
      // maxFeePerGas: gasPrice.maxFeePerGas,
      // maxPriorityFeePerGas: gasPrice.maxPriorityFeePerGas,
      value: 0,
      data: "0x608060405234801561001057600080fd5b506101e7806100206000396000f3fe608060405234801561001057600080fd5b506004361061002b5760003560e01c80639c4ae2d014610030575b600080fd5b61004361003e3660046100b2565b610045565b005b6000818351602085016000f59050803b61005e57600080fd5b6040805173ffffffffffffffffffffffffffffffffffffffff83168152602081018490527fb03c53b28e78a88e31607a27e1fa48234dce28d5d9d9ec7b295aeb02e674a1e1910160405180910390a1505050565b600080604083850312156100c4578182fd5b823567ffffffffffffffff808211156100db578384fd5b818501915085601f8301126100ee578384fd5b81358181111561010057610100610182565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f0116810190838211818310171561014657610146610182565b8160405282815288602084870101111561015e578687fd5b82602086016020830137918201602090810196909652509694909301359450505050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fdfea2646970667358221220144cba0fdb5118b83f6adff581cec1e3628ba45d2e73e9df71c331f8f8a4a13e64736f6c63430008020033",
      type: 0,
      // eIP-2718
      // type: 0
    };
    const sig = {
      v: 27,
      r: "0x1820182018201820182018201820182018201820182018201820182018201820",
      s: "0x1820182018201820182018201820182018201820182018201820182018201820",
    };
    // make sure the money is sent to the deployer address by awaiting the transaction confirmation
    await (await signer.sendTransaction({to: deployerAddress, value: toWei(0.02)})).wait();
    const deployTx = await checkDefined(signer.provider).sendTransaction(
      ethers.utils.serializeTransaction(tx, sig),
    );
    const receipt = await deployTx.wait();
    if (anyswapCreate2DeployerAddress != receipt.contractAddress)
      throw new Error("Incorrect contract address");
  }
  return IAnyswapCreate2Deployer__factory.connect(anyswapCreate2DeployerAddress, signer);
}

export const governatorAddress = "0x6eEf89f0383dD76c06A8a6Ead63cf95795B5bA3F";

export const governatorHardhatSignature =
  "0xd96936163b3ca51694dce7ac7a832a7edb323195ea30f0ac5365b2a4fa9c15eb7cc0b70b152798696be0612f82e3bd6c0205ff3f09b52982e116f9af3ad58f4f1c";

export const deployFutureSwapProxy = async (
  anyswapCreate2Deployer: IAnyswapCreate2Deployer,
  salt: string,
  governatorAddress: string,
): Promise<FutureSwapProxy> => {
  const futureSwapProxy = deployAtFixedAddress(
    new FutureSwapProxy__factory(anyswapCreate2Deployer.signer),
    anyswapCreate2Deployer,
    salt,
    governatorAddress,
  );
  return await futureSwapProxy;
};

export const fsSalt = "0x1234567890123456789012345678901234567890123456789012345678901234";

const permit2Address = addressesJSON.goerli.permit2;
const futureSwapProxyAddress = addressesJSON.goerli.futureSwapProxy;
const governanceProxyAddress = addressesJSON.goerli.governanceProxy;
const transferAndCall2Address = addressesJSON.goerli.transferAndCall2;

// initialize the fixed address deployments
export const deployFixedAddressForTests = async (
  signer: ethers.Signer,
): Promise<{
  permit2: IPermit2;
  anyswapCreate2Deployer: IAnyswapCreate2Deployer;
  futureSwapProxy: FutureSwapProxy;
  transferAndCall2: TransferAndCall2;
  governanceProxy: GovernanceProxy;
}> => {
  const anyswapCreate2Deployer = await deployAnyswapCreate2Deployer(signer);

  const permit2 = IPermit2__factory.connect(permit2Address, signer);
  const transferAndCall2 = TransferAndCall2__factory.connect(transferAndCall2Address, signer);
  const futureSwapProxy = FutureSwapProxy__factory.connect(futureSwapProxyAddress, signer);
  const governanceProxy = GovernanceProxy__factory.connect(governanceProxyAddress, signer);

  if ((await permit2.provider.getCode(permit2.address)) === "0x") {
    await setCode(permit2.address, permit2JSON.deployedBytecode.object);
    const deployedTransferAndCall2 = await deployAtFixedAddress(
      new TransferAndCall2__factory(signer),
      anyswapCreate2Deployer,
      fsSalt,
    );
    const deployedFutureSwapProxy = await deployFutureSwapProxy(
      anyswapCreate2Deployer,
      fsSalt,
      governatorAddress,
    );
    const deployedGovernanceProxy = await deployGovernanceProxy(
      futureSwapProxy.address,
      anyswapCreate2Deployer,
      fsSalt,
      signer,
    );

    checkState(deployedTransferAndCall2.address === transferAndCall2.address);
    checkState(deployedFutureSwapProxy.address === futureSwapProxy.address);
    checkState(deployedGovernanceProxy.address === governanceProxy.address);

    await futureSwapProxy.takeOwnership(governatorHardhatSignature);

    await futureSwapProxy.execute([
      makeCall(governanceProxy).execute([
        makeCall(governanceProxy).proposeGovernance(await signer.getAddress()),
      ]),
    ]);
  }
  return {
    permit2,
    anyswapCreate2Deployer,
    futureSwapProxy,
    transferAndCall2,
    governanceProxy,
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
  anyswapCreate2Deployer: IAnyswapCreate2Deployer,
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
  anyswapCreate2Deployer: IAnyswapCreate2Deployer,
  salt: ethers.BytesLike,
): Promise<TransferAndCall2> => {
  return await deployAtFixedAddress(
    new TransferAndCall2__factory(anyswapCreate2Deployer.signer),
    anyswapCreate2Deployer,
    salt,
  );
};

export async function deployGovernanceProxy(
  governor: string,
  anyswapCreate2Deployer: IAnyswapCreate2Deployer,
  salt: ethers.BytesLike,
  signer: ethers.Signer,
): Promise<GovernanceProxy> {
  return await deployAtFixedAddress(
    new GovernanceProxy__factory(signer),
    anyswapCreate2Deployer,
    salt,
    governor,
  );
}

export const deployDos = async (
  governanceProxy: string,
  anyswapCreate2Deployer: IAnyswapCreate2Deployer,
  salt: ethers.BytesLike,
  signer: ethers.Signer,
): Promise<{dos: IDOS; versionManager: VersionManager}> => {
  const versionManager = await deployAtFixedAddress(
    new VersionManager__factory(signer),
    anyswapCreate2Deployer,
    salt,
    governanceProxy,
  );
  const dosConfig = await deployAtFixedAddress(
    new DOSConfig__factory(signer),
    anyswapCreate2Deployer,
    salt,
    governanceProxy,
  );
  const dos = await deployAtFixedAddress(
    new DOS__factory(signer),
    anyswapCreate2Deployer,
    salt,
    dosConfig.address,
    versionManager.address,
  );
  return {dos: IDOS__factory.connect(dos.address, signer), versionManager};
};

// eslint-disable-next-line @typescript-eslint/explicit-module-boundary-types
export const setupDos = async (
  governanceProxy: GovernanceProxy,
  dos: IDOS,
  usdc: IERC20WithMetadata,
  weth: IERC20WithMetadata,
  uni: IERC20WithMetadata,
  uniAddresses: Record<string, string>,
  deployer: ethers.Signer,
) => {
  const usdcOracle = await new MockERC20Oracle__factory(deployer).deploy(governanceProxy.address);
  const ethOracle = await new MockERC20Oracle__factory(deployer).deploy(governanceProxy.address);
  const uniOracle = await new MockERC20Oracle__factory(deployer).deploy(governanceProxy.address);
  const uniV3Oracle = await new UniV3Oracle__factory(deployer).deploy(
    uniAddresses.uniswapV3Factory,
    uniAddresses.nonFungiblePositionManager,
    governanceProxy.address,
  );
  await Promise.all(
    [usdcOracle, ethOracle, uniOracle].map(oracle => oracle.deployTransaction.wait()),
  );

  await governanceProxy.execute([
    makeCall(usdcOracle).setPrice(toWei(1), 6, 6),
    makeCall(ethOracle).setPrice(toWei(1200), 6, 18),
    makeCall(uniOracle).setPrice(toWei(840), 6, 18),
    makeCall(dos).setConfig({
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    }),
    makeCall(dos).addERC20Info(
      usdc.address,
      await usdc.name(),
      await usdc.symbol(),
      await usdc.decimals(),
      usdcOracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    ),
    makeCall(dos).addERC20Info(
      weth.address,
      await weth.name(),
      await weth.symbol(),
      await weth.decimals(),
      ethOracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    ),
    makeCall(dos).addERC20Info(
      uni.address,
      await uni.name(),
      await uni.symbol(),
      await uni.decimals(),
      uniOracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    ),
    makeCall(uniV3Oracle).setERC20ValueOracle(usdc.address, usdcOracle.address),
    makeCall(uniV3Oracle).setERC20ValueOracle(weth.address, ethOracle.address),
    makeCall(uniV3Oracle).setERC20ValueOracle(uni.address, uniOracle.address),
    makeCall(dos).addNFTInfo(
      uniAddresses.nonFungiblePositionManager,
      uniV3Oracle.address,
      toWei(0.5),
    ),
  ]);
  return {usdcOracle, ethOracle, uniOracle, uniV3Oracle};
};

// eslint-disable-next-line @typescript-eslint/explicit-module-boundary-types
export const setupLocalhost = async (signer: ethers.Signer) => {
  const {permit2, anyswapCreate2Deployer, transferAndCall2, governanceProxy} =
    await deployFixedAddressForTests(signer);

  const {dos, versionManager} = await deployDos(
    governanceProxy.address,
    anyswapCreate2Deployer,
    fsSalt,
    signer,
  );

  const dSafeLogic = await deployAtFixedAddress(
    new DSafeLogic__factory(signer),
    anyswapCreate2Deployer,
    fsSalt,
    dos.address,
  );
  await governanceProxy.execute([
    makeCall(versionManager).addVersion("1.0.0", 2, dSafeLogic.address),
    makeCall(versionManager).markRecommendedVersion("1.0.0"),
  ]);

  const wethDeploy = await deployAtFixedAddress(
    new WETH9__factory(signer),
    anyswapCreate2Deployer,
    fsSalt,
  );
  const weth = IERC20Metadata__factory.connect(wethDeploy.address, signer);
  const usdc = await deployAtFixedAddress(
    new TestERC20__factory(signer),
    anyswapCreate2Deployer,
    fsSalt,
    "USDC",
    "USDC",
    6,
  );
  const uni = await deployAtFixedAddress(
    new TestERC20__factory(signer),
    anyswapCreate2Deployer,
    fsSalt,
    "UNI",
    "UNI",
    18,
  );

  const {uniswapV3Factory, nonFungiblePositionManager, swapRouter} = await deployUniswapFactory(
    weth.address,
    signer,
  );

  const uniAddresses = {
    uniswapV3Factory: uniswapV3Factory.address,
    nonFungiblePositionManager: nonFungiblePositionManager.address,
  };

  const {usdcOracle, ethOracle, uniOracle, uniV3Oracle} = await setupDos(
    governanceProxy,
    dos,
    usdc,
    weth,
    uni,
    uniAddresses,
    signer,
  );

  // setup some initial liquidity

  await usdc.mint(await signer.getAddress(), toWei(1000000, 6));
  await uni.mint(await signer.getAddress(), toWei(1000000));
  for (const erc20 of [usdc, uni, weth]) {
    await erc20.approve(transferAndCall2.address, ethers.constants.MaxUint256);
    await erc20.approve(swapRouter.address, ethers.constants.MaxUint256);
    await erc20.approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256);
  }
  const dsafe = await createDSafe(dos, signer);
  await depositIntoDos(
    transferAndCall2,
    dsafe,
    [
      {token: usdc.address, amount: toWei(100000, 6)},
      {token: uni.address, amount: toWei(100000)},
    ],
    {weth: weth.address, amount: toWei(100000)},
  );
  await deployUniswapPool(uniswapV3Factory, weth.address, uni.address, 500, 1);
  await deployUniswapPool(
    uniswapV3Factory,
    weth.address,
    usdc.address,
    500,
    (1000 * 10 ** 6) / 10 ** 18,
  );

  await dsafe.executeBatch(
    leverageLP(
      dos,
      weth,
      usdc,
      nonFungiblePositionManager,
      {
        token0: weth.address,
        token1: usdc.address,
        fee: 500,
        tickLower: -210000,
        tickUpper: -190000,
        amount0Desired: toWei(10),
        amount1Desired: toWei(10000, 6),
        amount0Min: 0,
        amount1Min: 0,
        recipient: dsafe.address,
        deadline: ethers.constants.MaxUint256,
      },
      1,
    ),
  );
  await dsafe.executeBatch(
    leverageLP(
      dos,
      weth,
      uni,
      nonFungiblePositionManager,
      {
        token0: weth.address,
        token1: uni.address,
        fee: 500,
        tickLower: -10000,
        tickUpper: 10000,
        amount0Desired: toWei(10),
        amount1Desired: toWei(10),
        amount0Min: 0,
        amount1Min: 0,
        recipient: dsafe.address,
        deadline: ethers.constants.MaxUint256,
      },
      2,
    ),
  );

  console.log("Setup complete");

  return {
    permit2,
    anyswapCreate2Deployer,
    transferAndCall2,
    governanceProxy,
    dos,
    versionManager,
    weth,
    usdc,
    uni,
    usdcOracle,
    ethOracle,
    uniOracle,
    uniV3Oracle,
    uniswapV3Factory,
    nonFungiblePositionManager,
    swapRouter,
  };
};
