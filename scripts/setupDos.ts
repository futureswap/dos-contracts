import type {GovernanceProxy, IDOS, IWETH9, IERC20WithMetadata} from "../typechain-types";

import {ethers} from "hardhat";

import {makeCall} from "../lib/calls";
import {getAddressesForNetwork, getContracts, saveAddressesForNetwork} from "../lib/deployment";
import {toWei} from "../lib/numbers";
import {MockERC20Oracle__factory, UniV3Oracle__factory} from "../typechain-types";

async function main() {
  const [deployer] = await ethers.getSigners();
  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, deployer);

  const dos = networkContracts.dos as IDOS;
  const governanceProxy = networkContracts.governanceProxy as GovernanceProxy;
  const usdc = networkContracts.usdc as IERC20WithMetadata;
  const weth = networkContracts.weth as IWETH9;
  const uni = networkContracts.uni as IERC20WithMetadata;

  const usdcOracle = await new MockERC20Oracle__factory(deployer).deploy(governanceProxy.address);
  const ethOracle = await new MockERC20Oracle__factory(deployer).deploy(governanceProxy.address);
  const uniOracle = await new MockERC20Oracle__factory(deployer).deploy(governanceProxy.address);
  const uniV3Oracle = await new UniV3Oracle__factory(deployer).deploy(
    networkAddresses.uniswapV3Factory,
    networkAddresses.nonFungiblePositionManager,
    governanceProxy.address,
  );
  await Promise.all(
    [usdcOracle, ethOracle, uniOracle].map(oracle => oracle.deployTransaction.wait()),
  );

  await governanceProxy.execute([
    makeCall(usdcOracle).setPrice(toWei(1), 6, 6),
    makeCall(ethOracle).setPrice(toWei(1200), 6, 18),
    makeCall(uniOracle).setPrice(toWei(840), 6, 18),
    makeCall(dos).setConfig({
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    }),
    makeCall(dos).addERC20Info(
      usdc.address,
      await usdc.name(),
      await usdc.symbol(),
      await usdc.decimals(),
      usdcOracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    ),
    makeCall(dos).addERC20Info(
      weth.address,
      await weth.name(),
      await weth.symbol(),
      await weth.decimals(),
      ethOracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    ),
    makeCall(dos).addERC20Info(
      uni.address,
      await uni.name(),
      await uni.symbol(),
      await uni.decimals(),
      uniOracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    ),
    makeCall(uniV3Oracle).setERC20ValueOracle(usdc.address, usdcOracle.address),
    makeCall(uniV3Oracle).setERC20ValueOracle(weth.address, ethOracle.address),
    makeCall(uniV3Oracle).setERC20ValueOracle(uni.address, uniOracle.address),
    makeCall(dos).addNFTInfo(
      networkAddresses.nonFungiblePositionManager,
      uniV3Oracle.address,
      toWei(0.5),
    ),
  ]);

  await saveAddressesForNetwork({usdcOracle, ethOracle, uniOracle, uniV3Oracle});
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
