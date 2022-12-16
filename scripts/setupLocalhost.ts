import {ethers} from "hardhat";

import {setupLocalhost} from "../lib/deploy";
import {saveAddressesForNetwork} from "../lib/deployment";

async function main() {
  const [deployer] = await ethers.getSigners();
  const contracts = await setupLocalhost(deployer);
  await saveAddressesForNetwork(contracts);
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
