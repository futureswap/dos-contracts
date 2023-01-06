import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  DSafeLogic__factory,
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

describe("Fractionalization", () => {
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
      0,
      0,
      0,
      0,
    );
    await dos.addERC20Info(
      weth.address,
      "Wrapped ETH",
      "WETH",
      18,
      ethChainlink.oracle.address,
      toWei(0.9),
      toWei(0.9),
      0,
      0,
      0,
      0,
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

  describe("Fractional Reserve Leverage tests", () => {
    it("Check fractional reserve after user borrows", async () => {
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
        makeCall(dos).withdrawERC20(usdc.address, maxBorrowable), // to borrow use negative
      ]);

      // check to see if there is anything left
      const maxBorrowablePost = await dos.getMaximumWithdrawableOfERC20(usdc.address);

      expect(maxBorrowablePost).to.equal("0");
    });

    it("Fractional reserve check should fail after borrow and rate is set below threshold", async () => {
      // setup 2 users dSafes
      const {user, user2, dos, usdc, weth} = await loadFixture(deployDOSFixture);

      // setup first user
      const dSafe1 = await createDSafe(dos, user);
      expect(await dSafe1.owner()).to.equal(user.address);
      await usdc.mint(dSafe1.address, oneHundredUsdc);
      await dSafe1.executeBatch([makeCall(dos).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

      // setup 2nd user
      const dSafe2 = await createDSafe(dos, user2);
      expect(await dSafe2.owner()).to.equal(user2.address);
      await weth.mint(dSafe2.address, toWei(2));
      await dSafe2.executeBatch([makeCall(dos).depositERC20(weth.address, toWei(2))]);

      const maxBorrowableUSDC = await dos.getMaximumWithdrawableOfERC20(usdc.address);

      // user 2 borrows 90 USDC
      await dSafe2.executeBatch([
        makeCall(dos).withdrawERC20(usdc.address, maxBorrowableUSDC), // to borrow use negative
      ]);

      // vote for FDR to change
      await dos.setConfig({
        liqFraction: toWei(0.8),
        fractionalReserveLeverage: 8,
      });

      const maxBorrowableUSDCPost = await dos.getMaximumWithdrawableOfERC20(usdc.address);

      expect(maxBorrowableUSDCPost).is.lessThan(0);
    });

    it("Hit frac limit, vote to increase, and borrow more", async () => {
      // borrow max
      // vote on increasing maximum
      // borrow more

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

      const maxBorrowableUSDC = await dos.getMaximumWithdrawableOfERC20(usdc.address);

      // borrow 90 USDC // Max borrow for FRL
      await dSafe2.executeBatch([
        makeCall(dos).withdrawERC20(usdc.address, maxBorrowableUSDC), // to borrow use negative
      ]);

      // //vote for FDR to change
      await dos.setConfig({
        liqFraction: toWei(0.8),
        fractionalReserveLeverage: 10,
      });

      const maxBorrowableUSDCPostVote = await dos.getMaximumWithdrawableOfERC20(usdc.address);

      // borrow 0.909091 USDC
      await dSafe2.executeBatch([
        makeCall(dos).withdrawERC20(usdc.address, maxBorrowableUSDCPostVote), // to borrow use negative
      ]);

      expect(await dos.getMaximumWithdrawableOfERC20(usdc.address)).to.equal("0");
    });
  });
});
