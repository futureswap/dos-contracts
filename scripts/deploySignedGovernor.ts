import type {IAnyswapCreate2Deployer} from "../typechain-types";

import {ethers} from "hardhat";

import {FUTURESWAP_DEPLOYER_MNEMONIC} from "../hardhat.config";
import {deployAtFixedAddress, deployGovernanceProxy, fsSalt} from "../lib/deploy";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import {FutureSwapProxy__factory} from "../typechain-types";

async function main() {
  const [workDeployer] = await ethers.getSigners();
  const fsDeployer = ethers.Wallet.fromMnemonic(FUTURESWAP_DEPLOYER_MNEMONIC).connect(
    ethers.provider,
  );
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, workDeployer);
  const anyswapCreate2Deployer = networkContracts.anyswapCreate2Deployer as IAnyswapCreate2Deployer;
  const futureSwapProxy = await deployAtFixedAddress(
    new FutureSwapProxy__factory(fsDeployer),
    anyswapCreate2Deployer,
    fsSalt,
    fsDeployer.address,
  );
  await (
    await workDeployer.sendTransaction({
      to: fsDeployer.address,
      value: ethers.utils.parseEther("0.01"),
    })
  ).wait();
  await futureSwapProxy.connect(fsDeployer).transferOwnership(workDeployer.address);
  const governanceProxy = await deployGovernanceProxy(
    futureSwapProxy.address,
    anyswapCreate2Deployer,
    fsSalt,
    workDeployer,
  );
  await saveAddressesForNetwork({futureSwapProxy, governanceProxy});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
