import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import {
  DOS,
  DOS__factory,
  MockValueOracle__factory,
  PortfolioLogic__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
} from "../../typechain-types";
import { toWei } from "../../lib/Numbers";
import { getEventParams } from "../../lib/Events";
import { BigNumber, Contract, Signer } from "ethers";

describe("Fractionalization", function () {
  async function deployDOSFixture() {
    const [owner, user, user2] = await ethers.getSigners();

    const usdc = await new TestERC20__factory(owner).deploy(
      "USD Coin",
      "USDC",
      18
    );

    const weth = await new WETH9__factory(owner).deploy();
    const nft = await new TestNFT__factory(owner).deploy();

    const usdcOracle = await new MockValueOracle__factory(owner).deploy();
    const wethOracle = await new MockValueOracle__factory(owner).deploy();

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
      0
    );
    await dos.addERC20Asset(
      weth.address,
      "Wrapped ETH",
      "WETH",
      18,
      wethOracle.address,
      toWei(0.9),
      toWei(0.9),
      0
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
      "PortfolioCreated"
    );
    return PortfolioLogic__factory.connect(portfolio as string, signer);
  }

  function createCall(c: Contract, funcName: string, params: any[]) {
    return {
      to: c.address,
      callData: c.interface.encodeFunctionData(funcName, params),
      value: 0,
    };
  }

  //   const tenthoushan9dUSD = toWei(10000, 6);
  const onehundredInWei = toWei(100, 6);
  const tenInWei = toWei(10, 6);

  describe("Fractional Reserve Leverage tests", () => {
    it("Check fractional reserve after user borrows", async () => {
      const { user, user2, dos, usdc, weth } = await loadFixture(
        deployDOSFixture
      );

      //setup 1st user
      const portfolio1 = await CreatePortfolio(dos, user);
      expect(await portfolio1.owner()).to.equal(user.address);
      await usdc.mint(portfolio1.address, onehundredInWei);
      await portfolio1.executeBatch([
        createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
        createCall(dos, "depositAsset", [0, onehundredInWei]),
      ]); //deposits 100 USDC

      //setup 2nd user
      const portfolio2 = await CreatePortfolio(dos, user2);
      expect(await portfolio2.owner()).to.equal(user2.address);
      await weth.mint(portfolio2.address, toWei(1)); //10 ETH
      await portfolio2.executeBatch([
        createCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
        createCall(dos, "depositAsset", [1, toWei(1)]),
      ]);

      //borrow 90 USDC // Max borrow for FRL
      await portfolio2.executeBatch([
        createCall(dos, "depositAsset", [0, -toWei(90, 6)]), //to borrow use negative
      ]);

      const isDosOverLev = await dos.isDosOverLeveraged();
      expect(await isDosOverLev).to.equal(true);
    });
    it("Fractional reserve check should fail after borrow and rate is set below threshold", async () => {
      //setup 2 users portfolios

      const { user, user2, dos, usdc, weth } = await loadFixture(
        deployDOSFixture
      );

      //setup first user
      const portfolio1 = await CreatePortfolio(dos, user);
      expect(await portfolio1.owner()).to.equal(user.address);
      await usdc.mint(portfolio1.address, onehundredInWei);
      await portfolio1.executeBatch([
        createCall(usdc, "approve", [dos.address, ethers.constants.MaxUint256]),
        createCall(dos, "depositAsset", [0, onehundredInWei]),
      ]); //deposits 100 USDC

      //setup 2nd user
      const portfolio2 = await CreatePortfolio(dos, user2);
      expect(await portfolio2.owner()).to.equal(user2.address);
      await weth.mint(portfolio2.address, toWei(1)); //10 ETH
      await portfolio2.executeBatch([
        createCall(weth, "approve", [dos.address, ethers.constants.MaxUint256]),
        createCall(dos, "depositAsset", [1, toWei(10, 6)]),
      ]);

      //user 2 borrows 90 USDC
      await portfolio2.executeBatch([
        createCall(dos, "depositAsset", [0, -toWei(90, 6)]), //to borrow use negative
      ]);

      //vote for FDR to change
      await dos.setConfig({
        liqFraction: toWei(0.8),
        fractionalReserveLeverage: 8,
      });

      const isDosOverLevPostVote = await dos.isDosOverLeveraged();
      expect(await isDosOverLevPostVote).to.equal(false);
    });
  });
});
