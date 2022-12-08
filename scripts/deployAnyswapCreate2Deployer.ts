import {ethers} from "hardhat";

import {deployAnyswapCreate2Deployer} from "../lib/deploy";

async function main() {
  const [deployer] = await ethers.getSigners();
  await deployAnyswapCreate2Deployer(deployer);
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
