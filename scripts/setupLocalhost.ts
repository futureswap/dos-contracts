import type {Contract} from "ethers";
import type {Api} from "hardhat-ethernal/dist/api";
import "hardhat-ethernal/dist/type-extensions"; // types only

import {FormatTypes} from "@ethersproject/abi";
import {ethers, ethernal} from "hardhat";

import {deployLocalhostEnvironment, setupLocalhost} from "../lib/deploy";
import {saveAddressesForNetwork} from "../lib/deployment";

async function main() {
  const [deployer] = await ethers.getSigners();
  const env = await deployLocalhostEnvironment(deployer);
  const contracts = await setupLocalhost(deployer, env);
  await saveAddressesForNetwork(contracts);

  process.env.ETHERNAL_EMAIL && process.env.ETHERNAL_PASSWORD
    ? await startEthernal(contracts)
    : console.log(
        "Ethernal will not be started because credentials are not provided. " +
          "If you want it to be started, ensure having ETHERNAL_EMAIL and ETHERNAL_PASSWORD in your .env",
      );
}

async function startEthernal(contracts: Record<string, Contract>) {
  await ethernal.startListening();
  await Promise.all(
    Object.entries(contracts).map(([contractName, contract]) =>
      // `api` is a private key of ethernal, so it's not present on the type
      (ethernal as typeof ethernal & {api: Api}).api.syncContractData(
        contractName,
        contract.address,
        // @ts-expect-error -- the expected type is `any[]`, but `.format(FormatTypes.json)`
        // returns string of JSON with array. Considering that this argument will be sent over the
        // network, these values are equivalent
        contract.interface.format(FormatTypes.json),
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
