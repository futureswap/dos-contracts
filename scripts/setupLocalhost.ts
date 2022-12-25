import {FormatTypes} from "@ethersproject/abi";
import hre, {ethers} from "hardhat";

import {deployLocahostEnvironment, setupLocalhost} from "../lib/deploy";
import {saveAddressesForNetwork} from "../lib/deployment";

async function main() {
  const [deployer] = await ethers.getSigners();
  const env = await deployLocahostEnvironment(deployer);
  const contracts = await setupLocalhost(deployer, env);
  await saveAddressesForNetwork(contracts);

  // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access, @typescript-eslint/no-unsafe-call
  await hre.ethernal.startListening();
  for (const [key, value] of Object.entries(contracts)) {
    // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access, no-await-in-loop, @typescript-eslint/no-unsafe-call, @typescript-eslint/no-explicit-any
    await (hre.ethernal.api as any).syncContractData(
      key,
      value.address,
      value.interface.format(FormatTypes.json),
    );
  }
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
