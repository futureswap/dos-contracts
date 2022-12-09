import type {GovernanceProxy, IAnyswapCreate2Deployer} from "../typechain-types";

import {ethers} from "hardhat";

import {makeCall} from "../lib/calls";
import {deployAtFixedAddress, deployDos, fsSalt} from "../lib/deploy";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import {PortfolioLogic__factory} from "../typechain-types";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);
  const anyswapCreate2Deployer = networkContracts.anyswapCreate2Deployer as IAnyswapCreate2Deployer;
  const governanceProxy = networkContracts.governanceProxy as GovernanceProxy;
  const {versionManager, dos} = await deployDos(
    governanceProxy.address,
    anyswapCreate2Deployer,
    fsSalt,
    deployer,
  );
  const portfolioLogic = await deployAtFixedAddress(
    new PortfolioLogic__factory(deployer),
    anyswapCreate2Deployer,
    fsSalt,
    dos.address,
  );
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
