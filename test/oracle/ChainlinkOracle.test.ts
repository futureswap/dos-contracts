import {ethers} from "hardhat";
import {toWei} from "../../lib/Numbers";
import {expect} from "chai";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {Chainlink} from "../../lib/Deploy";

const usdcPrice = 1;
const usdcChainlinkDecimals = 8;
const usdcDecimals = 6;

const ethPrice = 2000;
const ethChainlinkDecimals = 8;
const ethDecimals = 18;

describe("ChainlinkOracle", function () {
  async function setupOracle() {
    const [owner] = await ethers.getSigners();

    const usdcChainlink = await Chainlink.deploy(
      owner,
      usdcPrice,
      usdcChainlinkDecimals,
      usdcDecimals,
      usdcDecimals,
    );
    const ethChainlink = await Chainlink.deploy(
      owner,
      ethPrice,
      ethChainlinkDecimals,
      usdcDecimals,
      ethDecimals,
    );

    return {usdcChainlink, ethChainlink};
  }

  it("Returns right price for usdc", async () => {
    const {usdcChainlink} = await loadFixture(setupOracle);
    expect(await usdcChainlink.oracle.calcValue(toWei(1, usdcDecimals))).to.equal(
      toWei(1, usdcDecimals),
    );
  });

  it("Returns right price for eth", async () => {
    const {ethChainlink} = await loadFixture(setupOracle);

    expect(await ethChainlink.oracle.calcValue(toWei(1, ethDecimals))).to.equal(
      toWei(ethPrice, usdcDecimals),
    );
  });
});
