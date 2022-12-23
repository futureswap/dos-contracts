import type {OffchainEntityProxy, IAnyswapCreate2Deployer} from "../typechain-types";

import {ethers} from "hardhat";

import {makeCall} from "../lib/calls";
import {deployAtFixedAddress, fsSalt} from "../lib/deploy";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import {GovernanceProxy__factory} from "../typechain-types";

async function main() {
  const [owner] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, owner);
  const anyswapCreate2Deployer = networkContracts.anyswapCreate2Deployer as IAnyswapCreate2Deployer;
  const futureSwapProxy = networkContracts.futureSwapProxy as OffchainEntityProxy;

  const governanceProxy = await deployAtFixedAddress(
    new GovernanceProxy__factory(owner),
    anyswapCreate2Deployer,
    fsSalt,
    futureSwapProxy.address,
  );

  await saveAddressesForNetwork({governanceProxy});

  await futureSwapProxy.executeBatch([
    makeCall(governanceProxy).executeBatch([
      makeCall(governanceProxy).proposeGovernance(owner.address),
    ]),
  ]);
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
