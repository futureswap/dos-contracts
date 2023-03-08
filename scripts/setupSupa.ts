import type {GovernanceProxy, ISupa, IWETH9, IERC20WithMetadata} from "../typechain-types";

import {ethers} from "hardhat";

import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import {setupSupa} from "../lib/deploy";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);

  const supa = networkContracts.supa as ISupa;
  const governanceProxy = networkContracts.governanceProxy as GovernanceProxy;
  const usdc = networkContracts.usdc as IERC20WithMetadata;
  const weth = networkContracts.weth as IWETH9;
  const uni = networkContracts.uni as IERC20WithMetadata;

  const uniAddresses = {
    uniswapV3Factory: networkAddresses.uniswapV3Factory,
    nonFungiblePositionManager: networkAddresses.nonFungiblePositionManager,
    swapRouter: networkAddresses.swapRouter,
  };

  const oracles = await setupSupa(governanceProxy, supa, usdc, weth, uni, uniAddresses, deployer);

  await saveAddressesForNetwork(oracles);
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
