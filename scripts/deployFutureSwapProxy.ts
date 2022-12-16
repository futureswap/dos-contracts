import {ethers} from "hardhat";

import {
  deployAnyswapCreate2Deployer,
  deployAtFixedAddress,
  fsSalt,
  governatorAddress,
} from "../lib/deploy";
import {FutureSwapProxy__factory} from "../typechain-types";

async function main() {
  const [workDeployer] = await ethers.getSigners();
  const anyswapCreate2Deployer = await deployAnyswapCreate2Deployer(workDeployer);
  const futureSwapProxy = await deployAtFixedAddress(
    new FutureSwapProxy__factory(workDeployer),
    anyswapCreate2Deployer,
    fsSalt,
    governatorAddress, // this should become FutureSwap team address.
  );
  console.log("FutureSwapProxy deployed at", futureSwapProxy.address);
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
