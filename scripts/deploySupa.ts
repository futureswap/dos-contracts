import type {GovernanceProxy, IAnyswapCreate2Deployer} from "../typechain-types";

import {ethers} from "hardhat";

import {makeCall} from "../lib/calls";
import {deployAtFixedAddress, deploySupa, fsSalt} from "../lib/deploy";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import {WalletLogic__factory} from "../typechain-types";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);
  const anyswapCreate2Deployer = networkContracts.anyswapCreate2Deployer as IAnyswapCreate2Deployer;
  const governanceProxy = networkContracts.governanceProxy as GovernanceProxy;
  const {versionManager, supa} = await deploySupa(
    governanceProxy.address,
    anyswapCreate2Deployer,
    (BigInt(fsSalt) + 11n).toString(),
    deployer,
  );
  console.log("DeploySupa Finished");

  const walletLogic = await deployAtFixedAddress(
    new WalletLogic__factory(deployer),
    anyswapCreate2Deployer,
    (BigInt(fsSalt) + 11n).toString(),
    supa.address,
  );
  console.log("walletLogic:", walletLogic.address);
  console.log("walletLogic Finished");

  await governanceProxy.executeBatch([
    makeCall(versionManager).addVersion(2, walletLogic.address),
    makeCall(versionManager).markRecommendedVersion("1.0.0"),
  ]);

  console.log("governanceProxy setup Finished");
  await saveAddressesForNetwork({versionManager, supa});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
