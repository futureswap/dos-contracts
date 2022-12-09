import type {IAnyswapCreate2Deployer} from "../typechain-types/contracts/external/interfaces/IAnyswapCreate2Deployer";

import {ethers} from "hardhat";

import {deployTransferAndCall2} from "../lib/deploy";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);
  const transferAndCall2 = await deployTransferAndCall2(
    networkContracts.anyswapCreate2Deployer as IAnyswapCreate2Deployer,
  );
  await saveAddressesForNetwork({transferAndCall2});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
