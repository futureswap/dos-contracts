import type {
  IDOS,
  IWETH9,
  IERC20WithMetadata,
  TransferAndCall2,
  ISwapRouter,
} from "../typechain-types";
import type {ContractTransaction, Signer} from "ethers";

import {ethers} from "hardhat";

import {DSafeLogic__factory} from "../typechain-types";
import {depositIntoSafeAndCall, leveragePos} from "../lib/calls";
import {getAddressesForNetwork, getContracts} from "../lib/deployment";
import {toWei} from "../lib/numbers";

const doAwait = async (...promises: ContractTransaction[]) => {
  return await Promise.all(promises.map(tx => tx.wait()));
};

export const dSafeInitialLiqAddress = "0x845e8Bab9b7E0dbBAE1EFD6F4ca54ea00cAd4294";

export const dSafeLeverageAddress = "0xE7c07E956E0dA36910bA67fD09555fBEbfd938A1";

const attachDSafe = (dSafe: string, signer: Signer) => {
  return DSafeLogic__factory.connect(dSafe, signer);
};

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);

  const dos = networkContracts.dos as IDOS;
  const transferAndCall2 = networkContracts.transferAndCall2 as TransferAndCall2;
  const usdc = networkContracts.usdc as IERC20WithMetadata;
  const weth = networkContracts.weth as IWETH9;
  // const uni = networkContracts.uni as IERC20WithMetadata;
  // const nonFungiblePositionManager = networkContracts.nonFungiblePositionManager;
  const swapRouter = networkContracts.swapRouter as ISwapRouter;

  // const dSafeInitialLiq = attachDSafe(dSafeInitialLiqAddress, deployer);
  const dSafeLeverage = attachDSafe(dSafeLeverageAddress, deployer);

  const nonce = 0;

  const amount = toWei(1000, 6);
  await doAwait(
    await depositIntoSafeAndCall(
      transferAndCall2,
      dSafeLeverage,
      [{token: usdc.address, amount}],
      leveragePos(dSafeLeverage, dos, usdc, weth, 3000, swapRouter, amount * 2n),
      nonce,
    ),
  );
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});