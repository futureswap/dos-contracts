import {ethers} from "hardhat";

import {getAddressesForNetwork, saveAddressesForNetwork} from "../lib/deployment";
import {BatchDeployer__factory} from "../typechain-types";

async function main() {
  const [deployer] = await ethers.getSigners();
  const addresses = await getAddressesForNetwork();
  const batchDeployer = await new BatchDeployer__factory(deployer).deploy(
    addresses.anyswapCreate2Deployer,
  );
  await saveAddressesForNetwork({batchDeployer});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
