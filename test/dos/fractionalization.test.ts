import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import {
  DOS,
  DOS__factory,
  MockAssetOracle__factory,
  PortfolioLogic__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
} from "../../typechain-types";
import { toWei } from "../../lib/Numbers";
import { getEventParams } from "../../lib/Events";
import { Signer } from "ethers";
import { makeCall } from "../../lib/Calls";

describe("Fractionalization", function () {
  async function deployDOSFixture() {
    const [owner, user, user2] = await ethers.getSigners();

    const usdc = await new TestERC20__factory(owner).deploy("USD Coin", "USDC", 18);

    const weth = await new WETH9__factory(owner).deploy();
    const nft = await new TestNFT__factory(owner).deploy();

    const usdcOracle = await new MockAssetOracle__factory(owner).deploy(18);
    const wethOracle = await new MockAssetOracle__factory(owner).deploy(18);

    await usdcOracle.setPrice(toWei(1));
    await wethOracle.setPrice(toWei(100));

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    await nftOracle.setPrice(1, toWei(100));

    const dos = await new DOS__factory(owner).deploy(owner.address);

    await dos.setConfig({
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    // No interest which would include time sensitive calculations
    await dos.addERC20Asset(
      usdc.address,
      "USD Coin",
      "USDC",
      6,
      usdcOracle.address,
      toWei(0.9),
      toWei(0.9),
      0,
    );
    await dos.addERC20Asset(
      weth.address,
      "Wrapped ETH",
      "WETH",
      18,
      wethOracle.address,
      toWei(0.9),
      toWei(0.9),
      0,
    );

    return {
      owner,
      user,
      user2,
      usdc,
      weth,
      usdcOracle,
      wethOracle,
      nft,
      nftOracle,
      dos,
    };
  }

  async function CreatePortfolio(dos: DOS, signer: Signer) {
    const { portfolio } = await getEventParams(
      await dos.connect(signer).createPortfolio(),
      dos,
      "PortfolioCreated",
    );
    return PortfolioLogic__factory.connect(portfolio as string, signer);
  }

  const oneHundredUsdc = toWei(100, 6);

  describe("Fractional Reserve Leverage tests", () => {
    it("Check fractional reserve after user borrows", async () => {
      const { user, user2, dos, usdc, weth } = await loadFixture(deployDOSFixture);

      //setup 1st user
      const portfolio1 = await CreatePortfolio(dos, user);
      expect(await portfolio1.owner()).to.equal(user.address);
      await usdc.mint(portfolio1.address, oneHundredUsdc);
      await portfolio1.executeBatch([
        makeCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(dos, "depositAsset", [0, oneHundredUsdc]),
      ]); //deposits 100 USDC

      //setup 2nd user
      const portfolio2 = await CreatePortfolio(dos, user2);
      expect(await portfolio2.owner()).to.equal(user2.address);
      await weth.mint(portfolio2.address, toWei(1)); //10 ETH
      await portfolio2.executeBatch([
        makeCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(dos, "depositAsset", [1, toWei(1)]),
      ]);

      //check what the max to borrow of USDC is (90 USDC)
      const maxBorrowable = await dos.getMaximumWithdrawableOfAsset(0);

      //borrow 90 USDC
      await portfolio2.executeBatch([
        makeCall(dos, "depositAsset", [0, -maxBorrowable]), //to borrow use negative
      ]);

      //check to see if there is anything left
      const maxBorrowablePost = await dos.getMaximumWithdrawableOfAsset(0);

      expect(maxBorrowablePost).to.equal("0");
    });

    it("Fractional reserve check should fail after borrow and rate is set below threshold", async () => {
      //setup 2 users portfolios
      const { user, user2, dos, usdc, weth } = await loadFixture(deployDOSFixture);

      //setup first user
      const portfolio1 = await CreatePortfolio(dos, user);
      expect(await portfolio1.owner()).to.equal(user.address);
      await usdc.mint(portfolio1.address, oneHundredUsdc);
      await portfolio1.executeBatch([
        makeCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(dos, "depositAsset", [0, oneHundredUsdc]),
      ]); //deposits 100 USDC

      //setup 2nd user
      const portfolio2 = await CreatePortfolio(dos, user2);
      expect(await portfolio2.owner()).to.equal(user2.address);
      await weth.mint(portfolio2.address, toWei(1)); //10 ETH
      await portfolio2.executeBatch([
        makeCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(dos, "depositAsset", [1, toWei(10, 6)]),
      ]);

      const maxBorrowableUSDC = await dos.getMaximumWithdrawableOfAsset(0);

      //user 2 borrows 90 USDC
      await portfolio2.executeBatch([
        makeCall(dos, "depositAsset", [0, -maxBorrowableUSDC]), //to borrow use negative
      ]);

      //vote for FDR to change
      await dos.setConfig({
        liqFraction: toWei(0.8),
        fractionalReserveLeverage: 8,
      });

      const maxBorrowableUSDCPost = await dos.getMaximumWithdrawableOfAsset(0);

      expect(maxBorrowableUSDCPost).is.lessThan(0);
    });

    it("Hit frac limit, vote to increase, and borrow more", async () => {
      //borrow max
      //vote on increasing maximum
      //borrow more

      const { user, user2, dos, usdc, weth } = await loadFixture(deployDOSFixture);

      //setup 1st user
      const portfolio1 = await CreatePortfolio(dos, user);
      expect(await portfolio1.owner()).to.equal(user.address);
      await usdc.mint(portfolio1.address, oneHundredUsdc);
      await portfolio1.executeBatch([
        makeCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(dos, "depositAsset", [0, oneHundredUsdc]),
      ]); //deposits 100 USDC

      //setup 2nd user
      const portfolio2 = await CreatePortfolio(dos, user2);
      expect(await portfolio2.owner()).to.equal(user2.address);
      await weth.mint(portfolio2.address, toWei(1)); //10 ETH
      await portfolio2.executeBatch([
        makeCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
        makeCall(dos, "depositAsset", [1, toWei(1)]),
      ]);

      const maxBorrowableUSDC = await dos.getMaximumWithdrawableOfAsset(0);

      //borrow 90 USDC // Max borrow for FRL
      await portfolio2.executeBatch([
        makeCall(dos, "depositAsset", [0, -maxBorrowableUSDC]), //to borrow use negative
      ]);

      // //vote for FDR to change
      await dos.setConfig({
        liqFraction: toWei(0.8),
        fractionalReserveLeverage: 10,
      });

      const maxBorrowableUSDCPostVote = await dos.getMaximumWithdrawableOfAsset(0);

      //borrow 0.909091 USDC
      await portfolio2.executeBatch([
        makeCall(dos, "depositAsset", [0, -maxBorrowableUSDCPostVote]), //to borrow use negative
      ]);

      expect(await dos.getMaximumWithdrawableOfAsset(0)).to.equal("0");
    });
  });
});
