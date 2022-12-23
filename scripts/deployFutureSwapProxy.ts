import {ethers} from "hardhat";

import {
  deployAnyswapCreate2Deployer,
  deployAtFixedAddress,
  fsSalt,
  governatorAddress,
  testGovernatorAddress,
} from "../lib/deploy";
import {OffchainEntityProxy__factory} from "../typechain-types";

async function main() {
  const [workDeployer] = await ethers.getSigners();
  const anyswapCreate2Deployer = await deployAnyswapCreate2Deployer(workDeployer);
  const futureSwapProxy = await deployAtFixedAddress(
    new OffchainEntityProxy__factory(workDeployer),
    anyswapCreate2Deployer,
    fsSalt,
    testGovernatorAddress, // this should become FutureSwap team address.
    "FutureSwapProxy",
  );
  console.log("FutureSwapProxy deployed at", futureSwapProxy.address);
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
