import {ethers} from "ethers";
import hre from "hardhat";

import {getAddressesForNetwork, getContracts} from "../lib/deployment";
import {signTakeFutureSwapProxyOwnership} from "../lib/signers";

async function main() {
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, owner);

  const signer = new ethers.Wallet(`0x${process.env.PRIVATE_KEY}`, hre.ethers.provider);
  console.log("Signer address", signer.address);

  // update the address to the one you want to sign for
  const fsProxy = networkContracts.futureSwapProxy as OffchainEntityProxy;

  console.log("fsProxy", fsProxy.address);

  const signature = await signTakeFutureSwapProxyOwnership(
    fsProxy,
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
    0,
    signer,
  );

  console.log(signature);
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
