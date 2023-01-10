import type {ethers} from "ethers";

import {readFile, writeFile} from "node:fs/promises";

import {
  TransferAndCall2__factory,
  GovernanceProxy__factory,
  Governance__factory,
  IWETH9__factory,
  IERC20WithMetadata__factory,
  IPermit2__factory,
  HashNFT__factory,
  VersionManager__factory,
  IAnyswapCreate2Deployer__factory,
  OffchainEntityProxy__factory,
  IDOS__factory,
  UniV3Oracle__factory,
  ISwapRouter__factory,
  IUniswapV3Factory__factory,
} from "../typechain-types";
import {MockERC20Oracle__factory} from "../typechain-types/factories/contracts/testing/MockERC20Oracle__factory";
import {getUniswapNonFungiblePositionManagerFactory} from "./deploy";

type NetworkAddresses = Record<string, string>;
type DeploymentAddresses = Record<string, NetworkAddresses>;

export const getAllAddresses = async (): Promise<DeploymentAddresses> => {
  const path = `./deployment/addresses.json`;
  const content = await readFile(path, {encoding: "utf-8"});
  return JSON.parse(content) as DeploymentAddresses;
};

export const getAddressesForNetwork = async (): Promise<NetworkAddresses> => {
  return (await getAllAddresses())[getNetwork()];
};

export const saveAddressesForNetwork = async (
  contractAddresses: Record<string, ethers.Contract>,
): Promise<void> => {
  const network = getNetwork();
  const oldAddresses = await getAllAddresses();
  oldAddresses[network] ??= {};
  const networkAddresses = oldAddresses[network];
  Object.entries(contractAddresses).forEach(([contractName, contract]) => {
    networkAddresses[contractName] = contract.address;
  });
  const path = `./deployment/addresses.json`;
  let content = JSON.stringify(oldAddresses, null, 2);
  if (!content.endsWith("\n")) {
    content += "\n";
  }
  await writeFile(path, content, {encoding: "utf-8"});
};

const getNetwork = () => {
  const network = (process.env.HARDHAT_NETWORK ?? "localhost").toLowerCase();
  return network;
};

export const getContractFactory = (
  contractName: string,
  address: string,
  signer: ethers.Signer,
): ethers.Contract => {
  switch (contractName) {
    case "anyswapCreate2Deployer":
      return IAnyswapCreate2Deployer__factory.connect(address, signer);
    case "permit2":
      return IPermit2__factory.connect(address, signer);
    case "transferAndCall2":
      return TransferAndCall2__factory.connect(address, signer);
    case "dos":
      return IDOS__factory.connect(address, signer);
    case "versionManager":
      return VersionManager__factory.connect(address, signer);
    case "governanceProxy":
      return GovernanceProxy__factory.connect(address, signer);
    case "governance":
      return Governance__factory.connect(address, signer);
    case "futureSwapProxy":
      return OffchainEntityProxy__factory.connect(address, signer);
    case "voteNFT":
      return HashNFT__factory.connect(address, signer);
    case "weth":
      return IWETH9__factory.connect(address, signer);
    case "usdc":
    case "uni":
      return IERC20WithMetadata__factory.connect(address, signer);
    case "uniswapV3Factory":
      return IUniswapV3Factory__factory.connect(address, signer);
    case "swapRouter":
      return ISwapRouter__factory.connect(address, signer);
    case "nonFungiblePositionManager":
      return getUniswapNonFungiblePositionManagerFactory(signer).attach(address);
    case "usdcOracle":
    case "uniOracle":
    case "ethOracle":
      return MockERC20Oracle__factory.connect(address, signer);
    case "uniV3Oracle":
      return UniV3Oracle__factory.connect(address, signer);
    default:
      throw new Error(`Unknown contract name: ${contractName}`);
  }
};

export const getContracts = (
  networkAddresses: NetworkAddresses,
  signer: ethers.Signer,
): Record<string, ethers.Contract> => {
  const contracts: Record<string, ethers.Contract> = {};
  Object.entries(networkAddresses).forEach(([contractName, address]) => {
    contracts[contractName] = getContractFactory(contractName, address, signer);
  });
  return contracts;
};
