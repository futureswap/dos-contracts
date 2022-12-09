import {ethers} from "hardhat";
import { makeCall } from "../lib/calls";

import {deployAtFixedAddress, fsSalt} from "../lib/deploy";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import { DOS__factory, VersionManager__factory, GovernanceProxy, IAnyswapCreate2Deployer, PortfolioLogic__factory } from "../typechain-types";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);
  const anyswapCreate2Deployer = networkContracts.anyswapCreate2Deployer as IAnyswapCreate2Deployer;
  const governanceProxy = networkContracts.governanceProxy as GovernanceProxy;
  const versionManager = await deployAtFixedAddress(new VersionManager__factory(deployer), anyswapCreate2Deployer, fsSalt, governanceProxy.address);
  const dos = await deployAtFixedAddress(new DOS__factory(deployer), anyswapCreate2Deployer, fsSalt, governanceProxy.address, versionManager.address);
  const portfolioLogic = await deployAtFixedAddress(new PortfolioLogic__factory(deployer), anyswapCreate2Deployer, fsSalt, dos.address);
  await governanceProxy.execute([
    makeCall(versionManager, "addVersion", ["1.0.0", 2, portfolioLogic.address]),
    makeCall(versionManager, "markRecommendedVersion", ["1.0.0"]),
  ]);
  await saveAddressesForNetwork({versionManager, dos});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
