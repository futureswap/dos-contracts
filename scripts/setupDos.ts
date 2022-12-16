import type {GovernanceProxy, IDOS, IWETH9, IERC20WithMetadata} from "../typechain-types";

import {ethers} from "hardhat";

import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import {setupDos} from "../lib/deploy";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);

  const dos = networkContracts.dos as IDOS;
  const governanceProxy = networkContracts.governanceProxy as GovernanceProxy;
  const usdc = networkContracts.usdc as IERC20WithMetadata;
  const weth = networkContracts.weth as IWETH9;
  const uni = networkContracts.uni as IERC20WithMetadata;

  const uniAddresses = {
    uniswapV3Factory: networkAddresses.uniswapV3Factory,
    nonFungiblePositionManager: networkAddresses.nonFungiblePositionManager,
    swapRouter: networkAddresses.swapRouter,
  };

  const oracles = await setupDos(governanceProxy, dos, usdc, weth, uni, uniAddresses, deployer);

  await saveAddressesForNetwork(oracles);
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
