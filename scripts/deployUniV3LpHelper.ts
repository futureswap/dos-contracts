import type {IAnyswapCreate2Deployer} from "../typechain-types";

import {ethers} from "hardhat";

import {UniV3LPHelper__factory} from "../typechain-types";
import {deployAtFixedAddress, fsSalt} from "../lib/deploy";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);
  const anyswapCreate2Deployer = networkContracts.anyswapCreate2Deployer as IAnyswapCreate2Deployer;

  const nonfungiblePositionManager = "0xC36442b4a4522E871399CD717aBDD847Ab11FE88";

  const uniV3LPHelper = await deployAtFixedAddress(
    new UniV3LPHelper__factory(deployer),
    anyswapCreate2Deployer,
    (BigInt(fsSalt) + 11n).toString(),
    networkContracts.supa.address,
    nonfungiblePositionManager,
  );

  await saveAddressesForNetwork({uniV3LPHelper});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
