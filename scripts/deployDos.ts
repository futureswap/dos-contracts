import type {GovernanceProxy, IAnyswapCreate2Deployer} from "../typechain-types";

import {ethers} from "hardhat";

import {makeCall} from "../lib/calls";
import {deployAtFixedAddress, deployDos, fsSalt} from "../lib/deploy";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import {DSafeLogic__factory} from "../typechain-types";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);
  const anyswapCreate2Deployer = networkContracts.anyswapCreate2Deployer as IAnyswapCreate2Deployer;
  const governanceProxy = networkContracts.governanceProxy as GovernanceProxy;
  const {versionManager, dos} = await deployDos(
    governanceProxy.address,
    anyswapCreate2Deployer,
    (BigInt(fsSalt) + 9n).toString(),
    deployer,
  );
  console.log("DeployDOS Finished");

  const dSafeLogic = await deployAtFixedAddress(
    new DSafeLogic__factory(deployer),
    anyswapCreate2Deployer,
    (BigInt(fsSalt) + 9n).toString(),
    dos.address,
  );
  console.log("dSafeLogic:", dSafeLogic.address);
  console.log("dSafeLogic Finished");

  await governanceProxy.executeBatch([
    makeCall(versionManager).addVersion(2, dSafeLogic.address),
    makeCall(versionManager).markRecommendedVersion("1.0.0"),
  ]);

  console.log("governanceProxy setup Finished");
  await saveAddressesForNetwork({versionManager, dos});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
