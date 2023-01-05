import "hardhat-ethernal/dist/type-extensions"; // types only

import type {Api} from "hardhat-ethernal/dist/api";

import {FormatTypes} from "@ethersproject/abi";
import hre, {ethers} from "hardhat";

import {deployLocalhostEnvironment, setupLocalhost} from "../lib/deploy";
import {saveAddressesForNetwork} from "../lib/deployment";

async function main() {
  const [deployer] = await ethers.getSigners();
  const env = await deployLocalhostEnvironment(deployer);
  const contracts = await setupLocalhost(deployer, env);
  await saveAddressesForNetwork(contracts);

  await hre.ethernal.startListening();
  await Promise.all(
    Object.entries(contracts).map(([key, value]) =>
      // `api` is a private key of hre.ethernal, so it's not present on the type
      (hre.ethernal as typeof hre.ethernal & {api: Api}).api.syncContractData(
        key,
        value.address,
        // @ts-expect-error -- the expected type is `any[]`, but `.format(FormatTypes.json)`
        // returns string of JSON with array. Considering that this argument will be sent over the
        // network, these values are equivalent
        value.interface.format(FormatTypes.json),
        undefined,
      ),
    ),
  );
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
