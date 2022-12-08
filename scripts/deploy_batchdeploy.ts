import {ethers} from "hardhat";
import {deployAnyswapCreate2Deployer} from "../lib/deploy";
import {getAddressesForNetwork, saveAddressesForNetwork} from "../lib/deployment";
import {BatchDeploy__factory} from "../typechain-types/factories/contracts/utils";

async function main() {
  const [deployer] = await ethers.getSigners();
  const addresses = await getAddressesForNetwork();
  const batchDeployer = await new BatchDeploy__factory(deployer).deploy(
    addresses.anyswapCreate2Deployer,
  );
  await saveAddressesForNetwork({batchDeployer: batchDeployer.address});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
