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
import {createDSafe, makeCall, getMaximumWithdrawableOfERC20} from "../../lib/calls";
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
      toWei(0.9),
      toWei(0.9),
      owner.address,
    );
    const ethChainlink = await Chainlink.deploy(
      owner,
      100,
      CHAINLINK_DECIMALS,
      USDC_DECIMALS,
      ETH_DECIMALS,
      toWei(0.9),
      toWei(0.9),
      owner.address,
    );

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    await nftOracle.setPrice(1, toWei(100));

    const {iDos, dos, versionManager} = await deployDos(
      owner.address,
      anyswapCreate2Deployer,
      "0x3",
      owner,
    );
    const proxyLogic = await new DSafeLogic__factory(owner).deploy(iDos.address);
    await versionManager.addVersion(2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    await iDos.setConfig({
      maxSolvencyCheckGasCost: 1e6,
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    // no interest which would include time sensitive calculations
    await iDos.addERC20Info(
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
    await iDos.addERC20Info(
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
      iDos,
      dos,
    };
  }

  const oneHundredUsdc = toWei(100, USDC_DECIMALS);

  describe("Fractional Reserve Leverage tests", () => {
    it("Check fractional reserve after user borrows", async () => {
      const {user, user2, iDos, dos, usdc, weth} = await loadFixture(deployDOSFixture);

      // setup 1st user
      const dSafe1 = await createDSafe(iDos, user);
      expect(await dSafe1.owner()).to.equal(user.address);
      await usdc.mint(dSafe1.address, oneHundredUsdc);
      await dSafe1.executeBatch([makeCall(iDos).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

      // setup 2nd user
      const dSafe2 = await createDSafe(iDos, user2);
      expect(await dSafe2.owner()).to.equal(user2.address);
      await weth.mint(dSafe2.address, toWei(2));
      await dSafe2.executeBatch([makeCall(iDos).depositERC20(weth.address, toWei(2))]);

      // check what the max to borrow of USDC is (90 USDC)
      const maxBorrowable = await getMaximumWithdrawableOfERC20(dos, usdc.address);

      // borrow 90 USDC
      await dSafe2.executeBatch([
        makeCall(iDos).withdrawERC20(usdc.address, maxBorrowable), // to borrow use negative
      ]);

      // check to see if there is anything left
      const maxBorrowablePost = await getMaximumWithdrawableOfERC20(dos, usdc.address);

      expect(maxBorrowablePost).to.equal("0");
    });

    it("Fractional reserve check should fail after borrow and rate is set below threshold", async () => {
      // setup 2 users dSafes
      const {user, user2, iDos, dos, usdc, weth} = await loadFixture(deployDOSFixture);

      // setup first user
      const dSafe1 = await createDSafe(iDos, user);
      expect(await dSafe1.owner()).to.equal(user.address);
      await usdc.mint(dSafe1.address, oneHundredUsdc);
      await dSafe1.executeBatch([makeCall(iDos).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

      // setup 2nd user
      const dSafe2 = await createDSafe(iDos, user2);
      expect(await dSafe2.owner()).to.equal(user2.address);
      await weth.mint(dSafe2.address, toWei(2));
      await dSafe2.executeBatch([makeCall(iDos).depositERC20(weth.address, toWei(2))]);

      const maxBorrowableUSDC = await getMaximumWithdrawableOfERC20(dos, usdc.address);

      // user 2 borrows 90 USDC
      await dSafe2.executeBatch([
        makeCall(iDos).withdrawERC20(usdc.address, maxBorrowableUSDC), // to borrow use negative
      ]);

      // vote for FDR to change
      await iDos.setConfig({
        maxSolvencyCheckGasCost: 1e6,
        liqFraction: toWei(0.8),
        fractionalReserveLeverage: 8,
      });

      const maxBorrowableUSDCPost = await getMaximumWithdrawableOfERC20(dos, usdc.address);

      expect(maxBorrowableUSDCPost).is.lessThan(0);
    });

    it("Hit frac limit, vote to increase, and borrow more", async () => {
      // borrow max
      // vote on increasing maximum
      // borrow more

      const {user, user2, iDos, dos, usdc, weth} = await loadFixture(deployDOSFixture);

      // setup 1st user
      const dSafe1 = await createDSafe(iDos, user);
      expect(await dSafe1.owner()).to.equal(user.address);
      await usdc.mint(dSafe1.address, oneHundredUsdc);
      await dSafe1.executeBatch([makeCall(iDos).depositERC20(usdc.address, oneHundredUsdc)]); // deposits 100 USDC

      // setup 2nd user
      const dSafe2 = await createDSafe(iDos, user2);
      expect(await dSafe2.owner()).to.equal(user2.address);
      await weth.mint(dSafe2.address, toWei(2));
      await dSafe2.executeBatch([makeCall(iDos).depositERC20(weth.address, toWei(2))]);

      const maxBorrowableUSDC = await getMaximumWithdrawableOfERC20(dos, usdc.address);

      // borrow 90 USDC // Max borrow for FRL
      await dSafe2.executeBatch([
        makeCall(iDos).withdrawERC20(usdc.address, maxBorrowableUSDC), // to borrow use negative
      ]);

      // //vote for FDR to change
      await iDos.setConfig({
        maxSolvencyCheckGasCost: 1e6,
        liqFraction: toWei(0.8),
        fractionalReserveLeverage: 10,
      });

      const maxBorrowableUSDCPostVote = await getMaximumWithdrawableOfERC20(dos, usdc.address);

      // borrow 0.909091 USDC
      await dSafe2.executeBatch([
        makeCall(iDos).withdrawERC20(usdc.address, maxBorrowableUSDCPostVote), // to borrow use negative
      ]);

      expect(await getMaximumWithdrawableOfERC20(dos, usdc.address)).to.equal("0");
    });
  });
});
