import {ethers} from "hardhat";
import {BigNumber} from "ethers";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  DSafeLogic__factory,
  DOS__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
} from "../../typechain-types";
import {toWei} from "../../lib/numbers";
import {createDSafe, makeCall} from "../../lib/calls";
import {Chainlink, deployDos, deployFixedAddressForTests} from "../../lib/deploy";

const USDC_DECIMALS = 6;
const ETH_DECIMALS = 18;
const CHAINLINK_DECIMALS = 8;

type ERC20Pool = {
  tokens: bigint;
  shares: bigint;
};

type ERC20Info = {
  erc20Contract: string;
  dosContract: string;
  valueOracle: string;
  collateral: ERC20Pool;
  debt: ERC20Pool;
  collateralFactor: bigint;
  borrowFactor: bigint;
  baseRate: bigint;
  slope1: bigint;
  slope2: bigint;
  targetUtilization: bigint;
  timestamp: bigint;
};

describe("Interest", () => {
  async function deployDOSFixture() {
    const [owner, user, user2] = await ethers.getSigners();

    const {anyswapCreate2Deployer} = await deployFixedAddressForTests(owner);

    const usdc = await new TestERC20__factory(owner).deploy("USD Coin", "USDC", USDC_DECIMALS);

    const weth = await new WETH9__factory(owner).deploy();
    const nft = await new TestNFT__factory(owner).deploy("Test NFT", "TNFT", 100);

    const usdcChainlink = await Chainlink.deploy(
      owner,
      1,
      CHAINLINK_DECIMALS,
      USDC_DECIMALS,
      USDC_DECIMALS,
    );
    const ethChainlink = await Chainlink.deploy(
      owner,
      100,
      CHAINLINK_DECIMALS,
      USDC_DECIMALS,
      ETH_DECIMALS,
    );

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    await nftOracle.setPrice(1, toWei(100));

    const {dos, versionManager} = await deployDos(
      owner.address,
      anyswapCreate2Deployer,
      "0x3",
      owner,
    );
    const proxyLogic = await new DSafeLogic__factory(owner).deploy(dos.address);
    await versionManager.addVersion(2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    await dos.setConfig({
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    // no interest which would include time sensitive calculations
    await dos.addERC20Info(
      usdc.address,
      "USD Coin",
      "USDC",
      6,
      usdcChainlink.oracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // 0%
      5, // 4%
      480, // 100%
      "800000000000000000", // 0.80
    );
    await dos.addERC20Info(
      weth.address,
      "Wrapped ETH",
      "WETH",
      18,
      ethChainlink.oracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // 0%
      5, // 4%
      480, // 100%
      "800000000000000000", // 0.80
    );

    return {
      owner,
      user,
      user2,
      usdc,
      weth,
      nft,
      nftOracle,
      dos,
    };
  }

  const oneHundredUsdc = toWei(100, USDC_DECIMALS);

  describe("Interest Rate tests", () => {
    it("Should return the base interest rate with 0% utilization", async () => {
      const {user, user2, dos, usdc, weth} = await loadFixture(deployDOSFixture);

      // setup 1st user
      const dSafe1 = await createDSafe(dos, user);
      expect(await dSafe1.owner()).to.equal(user.address);
      await usdc.mint(dSafe1.address, oneHundredUsdc);
      await dSafe1.executeBatch([makeCall(dos).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

      // setup 2nd user
      const dSafe2 = await createDSafe(dos, user2);
      expect(await dSafe2.owner()).to.equal(user2.address);
      await weth.mint(dSafe2.address, toWei(2));
      await dSafe2.executeBatch([makeCall(dos).depositERC20(weth.address, toWei(2))]);

      const erc20Idx: BigNumber = BigNumber.from(0);
      const interestRate: BigNumber = await dos.computeInterestRate(erc20Idx);
      expect(interestRate).to.equal(BigNumber.from("0"));
    });

    it("Should return the target interest rate at the target utilization", async () => {
      const {user, user2, dos, usdc, weth} = await loadFixture(deployDOSFixture);

      // setup 1st user
      const dSafe1 = await createDSafe(dos, user);
      expect(await dSafe1.owner()).to.equal(user.address);
      await usdc.mint(dSafe1.address, oneHundredUsdc);
      await dSafe1.executeBatch([makeCall(dos).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

      // setup 2nd user
      const dSafe2 = await createDSafe(dos, user2);
      expect(await dSafe2.owner()).to.equal(user2.address);
      await weth.mint(dSafe2.address, toWei(2));
      await dSafe2.executeBatch([makeCall(dos).depositERC20(weth.address, toWei(2))]);

      // check what the max to borrow of USDC is (90 USDC)
      const maxBorrowable = await dos.getMaximumWithdrawableOfERC20(usdc.address);

      const targetUtilization = 0.8;

      // borrow 90 USDC
      await dSafe2.executeBatch([
        makeCall(dos).depositERC20(usdc.address, -maxBorrowable * targetUtilization), // to borrow use negative
      ]);

      const erc20Idx: BigNumber = BigNumber.from(0);
      const realDos = DOS__factory.connect(dos.address, user);
      const erc20Info: ERC20Info = await realDos.erc20Infos(erc20Idx);
      const debt = -erc20Info.debt.tokens;
      const poolAssets = erc20Info.collateral.tokens.add(debt);
      const utilisation = debt / poolAssets; // bUG: this will always be 0;
      const interestRate: BigNumber = await dos.computeInterestRate(erc20Idx);
      console.log("interestRate", interestRate);
      expect(interestRate).to.equal(BigNumber.from("4"));
    });

    it("Should return the max interest rate with 100% utilization", async () => {
      const {user, user2, dos, usdc, weth} = await loadFixture(deployDOSFixture);

      // setup 1st user
      const dSafe1 = await createDSafe(dos, user);
      expect(await dSafe1.owner()).to.equal(user.address);
      await usdc.mint(dSafe1.address, oneHundredUsdc);
      await dSafe1.executeBatch([makeCall(dos).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

      // setup 2nd user
      const dSafe2 = await createDSafe(dos, user2);
      expect(await dSafe2.owner()).to.equal(user2.address);
      await weth.mint(dSafe2.address, toWei(2));
      await dSafe2.executeBatch([makeCall(dos).depositERC20(weth.address, toWei(2))]);

      // check what the max to borrow of USDC is (90 USDC)
      const maxBorrowable = await dos.getMaximumWithdrawableOfERC20(usdc.address);

      // borrow 90 USDC
      await dSafe2.executeBatch([
        makeCall(dos).depositERC20(usdc.address, -maxBorrowable), // to borrow use negative
      ]);

      const erc20Idx: BigNumber = BigNumber.from(0);
      const realDos = DOS__factory.connect(dos.address, user);
      const erc20Info: ERC20Info = await realDos.erc20Infos(erc20Idx);
      const debt = -erc20Info.debt.tokens;
      const poolAssets = erc20Info.collateral.tokens.add(debt);
      const utilisation = debt / poolAssets;
      const interestRate: BigNumber = await dos.computeInterestRate(erc20Idx);
      console.log("interestRate", interestRate.toString());
      expect(interestRate).to.equal(BigNumber.from("100"));
    });
  });
});
