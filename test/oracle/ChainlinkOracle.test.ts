import {ethers} from "hardhat";
import {expect} from "chai";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";

import {toWei} from "../../lib/numbers";
import {Chainlink} from "../../lib/deploy";

const usdcPrice = 1;
const usdcChainlinkDecimals = 8;
const usdcDecimals = 6;

const ethPrice = 2000;
const ethChainlinkDecimals = 8;
const ethDecimals = 18;

describe("ChainlinkOracle", () => {
  async function setupOracle() {
    const [owner] = await ethers.getSigners();

    const usdcChainlink = await Chainlink.deploy(
      owner,
      usdcPrice,
      usdcChainlinkDecimals,
      usdcDecimals,
      usdcDecimals,
      toWei(0.9),
      toWei(0.9),
      owner.address,
    );
    const ethChainlink = await Chainlink.deploy(
      owner,
      ethPrice,
      ethChainlinkDecimals,
      usdcDecimals,
      ethDecimals,
      toWei(0.9),
      toWei(0.9),
      owner.address,
    );

    return {usdcChainlink, ethChainlink};
  }

  it("Returns right price for usdc", async () => {
    const {usdcChainlink} = await loadFixture(setupOracle);
    const value = await usdcChainlink.oracle.calcValue(toWei(1, usdcDecimals));
    expect(value[0]).to.equal(toWei(1, usdcDecimals));
  });

  it("Returns right price for eth", async () => {
    const {ethChainlink} = await loadFixture(setupOracle);

    const value = await ethChainlink.oracle.calcValue(toWei(1, ethDecimals));
    expect(value[0]).to.equal(toWei(ethPrice, usdcDecimals));
  });
});
