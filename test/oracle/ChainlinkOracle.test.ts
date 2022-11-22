import { ethers, waffle } from "hardhat";
import {
  ERC20ChainlinkValueOracle__factory,
  AggregatorV3Interface__factory,
} from "../../typechain-types";
import { toWei } from "../../lib/Numbers";
import { expect } from "chai";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";

const usdcPrice = 1;
const usdcChainlinkDecimals = 8;
const usdcDecimals = 6;

const ethPrice = 2000;
const ethChainlinkDecimals = 8;
const ethDecimals = 18;

describe.only("ChainlinkOracle", function () {
    async function setupOracle() {
        const [owner] = await ethers.getSigners();
        const mockUsdcChainlink = await waffle.deployMockContract(owner, AggregatorV3Interface__factory.abi);
        await mockUsdcChainlink.mock.decimals.returns(usdcChainlinkDecimals);
        const usdcOracle = await new ERC20ChainlinkValueOracle__factory(owner).deploy(mockUsdcChainlink.address, usdcDecimals, usdcDecimals);

        const mockEthChainlink = await waffle.deployMockContract(owner, AggregatorV3Interface__factory.abi);
        await mockEthChainlink.mock.decimals.returns(ethChainlinkDecimals);
        const ethOracle = await new ERC20ChainlinkValueOracle__factory(owner).deploy(mockEthChainlink.address, usdcDecimals, ethDecimals);
        return { usdcOracle, mockUsdcChainlink, ethOracle, mockEthChainlink };
    }

    it("Returns right price for usdc", async () => {
        const { usdcOracle, mockUsdcChainlink } = await loadFixture(setupOracle);
        await mockUsdcChainlink.mock.latestRoundData.returns(0, toWei(usdcPrice, usdcChainlinkDecimals), 0, 0, 0);
        expect(await usdcOracle.calcValue(toWei(1, usdcDecimals))).to.equal(toWei(1, usdcDecimals));
    });

    it("Returns right price for eth", async () => {
        const { ethOracle, mockEthChainlink } = await loadFixture(setupOracle);
        await mockEthChainlink.mock.latestRoundData.returns(0, toWei(ethPrice, ethChainlinkDecimals), 0, 0, 0);
        
        expect(await ethOracle.calcValue(toWei(1, ethDecimals))).to.equal(toWei(ethPrice, usdcDecimals));
    });
});

