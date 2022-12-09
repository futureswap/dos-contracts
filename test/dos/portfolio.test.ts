import type {BigNumber} from "ethers";
import type {PortfolioLogic} from "../../typechain-types";

import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  DOS__factory,
  PortfolioLogic__factory,
  VersionManager__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
} from "../../typechain-types";
import {toWei, toWeiUsdc} from "../../lib/numbers";
import {getFixedGasSigners, signOnTransferReceived2Call} from "../../lib/signers";
import {makeCall, createPortfolio, sortTransfers} from "../../lib/calls";
import {Chainlink, deployFixedAddressForTests} from "../../lib/deploy";

const USDC_PRICE = 1;
const ETH_PRICE = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

const tenThousandUsdc = toWeiUsdc(10_000);
const oneEth = toWei(1);

describe("Portfolio proxy", () => {
  // we define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployDOSFixture() {
    const [owner, user, user2, user3] = await getFixedGasSigners(10_000_000);

    const {permit2, transferAndCall2} = await deployFixedAddressForTests(owner);

    const usdc = await new TestERC20__factory(owner).deploy(
      "USD Coin",
      "USDC",
      USDC_DECIMALS, // 6
    );

    const weth = await new WETH9__factory(owner).deploy();
    const nft = await new TestNFT__factory(owner).deploy("Test NFT1", "NF1", 100);
    const unregisteredNft = await new TestNFT__factory(owner).deploy("Test NFT2", "NF2", 200);

    const usdcChainlink = await Chainlink.deploy(
      owner,
      USDC_PRICE,
      8,
      USDC_DECIMALS,
      USDC_DECIMALS,
    );
    const ethChainlink = await Chainlink.deploy(owner, ETH_PRICE, 8, USDC_DECIMALS, WETH_DECIMALS);

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    const versionManager = await new VersionManager__factory(owner).deploy(owner.address);
    const dos = await new DOS__factory(owner).deploy(owner.address, versionManager.address);
    const proxyLogic = await new PortfolioLogic__factory(owner).deploy(dos.address);
    await versionManager.addVersion("1.0.0", 2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    await dos.setConfig({
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    await dos.addERC20Info(
      usdc.address,
      "USD Coin",
      "USDC",
      USDC_DECIMALS,
      usdcChainlink.oracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    );

    await dos.addERC20Info(
      weth.address,
      "Wrapped ETH",
      "WETH",
      WETH_DECIMALS,
      ethChainlink.oracle.address,
      toWei(0.9),
      toWei(0.9),
      0, // no interest which would include time sensitive calculations
    );

    await dos.addNFTInfo(nft.address, nftOracle.address, toWei(0.5));

    const getBalances = async (
      portfolio: PortfolioLogic,
    ): Promise<{
      nfts: [nftContract: string, tokenId: BigNumber][];
      usdc: BigNumber;
      weth: BigNumber;
    }> => {
      const [nfts, usdcBal, wethBal] = await Promise.all([
        dos.viewNFTs(portfolio.address),
        dos.viewBalance(portfolio.address, usdc.address),
        dos.viewBalance(portfolio.address, weth.address),
      ]);
      return {nfts, usdc: usdcBal, weth: wethBal};
    };

    const portfolio = await createPortfolio(dos, user);
    await usdc.mint(user.address, tenThousandUsdc);
    await weth.connect(user).deposit({value: oneEth});
    await usdc.connect(user).approve(transferAndCall2.address, ethers.constants.MaxUint256);
    await weth.connect(user).approve(transferAndCall2.address, ethers.constants.MaxUint256);

    return {
      owner,
      user,
      user2,
      user3, // default provided by hardhat users (signers)
      usdc,
      weth,
      usdcChainlink,
      ethChainlink,
      nft,
      nftOracle, // some registered nft
      unregisteredNft, // some unregistered nft
      dos,
      permit2,
      getBalances,
      portfolio,
      transferAndCall2,
    };
  }

  it("should be able to transferandcall into proxy", async () => {
    const {user, usdc, weth, portfolio, transferAndCall2} = await loadFixture(deployDOSFixture);

    await transferAndCall2.connect(user).transferAndCall2(
      portfolio.address,
      sortTransfers([
        {token: usdc.address, amount: tenThousandUsdc},
        {token: weth.address, amount: oneEth},
      ]),
      "0x",
    );

    expect(await usdc.balanceOf(portfolio.address)).to.equal(tenThousandUsdc);
    expect(await weth.balanceOf(portfolio.address)).to.equal(oneEth);
  });

  it("should be able to transferandcall into dos", async () => {
    const {user, usdc, weth, portfolio, getBalances, transferAndCall2} = await loadFixture(
      deployDOSFixture,
    );

    await transferAndCall2.connect(user).transferAndCall2(
      portfolio.address,
      sortTransfers([
        {token: usdc.address, amount: tenThousandUsdc},
        {token: weth.address, amount: oneEth},
      ]),
      "0x01",
    );

    expect(await usdc.balanceOf(portfolio.address)).to.equal(0);
    expect(await weth.balanceOf(portfolio.address)).to.equal(0);

    const balances = await getBalances(portfolio);
    expect(balances.usdc).to.equal(tenThousandUsdc);
    expect(balances.weth).to.equal(oneEth);
  });

  it("should be able to transferandcall into other portfolio and make a swap with signatures", async () => {
    const {user, user2, usdc, weth, dos, transferAndCall2} = await loadFixture(deployDOSFixture);

    const portfolio2 = await createPortfolio(dos, user2);
    await usdc.connect(user).transfer(portfolio2.address, tenThousandUsdc);

    const signedCall = {
      operator: user.address,
      from: user.address,
      transfers: [{token: weth.address, amount: oneEth}],
      calls: [makeCall(usdc, "transfer", [user.address, tenThousandUsdc])],
    };

    const signedData = await signOnTransferReceived2Call(portfolio2, signedCall, 0, user2);
    const data = `0x02${signedData.slice(2)}`;

    await transferAndCall2
      .connect(user)
      .transferAndCall2(portfolio2.address, signedCall.transfers, data);

    expect(await usdc.balanceOf(user.address)).to.equal(tenThousandUsdc);
    expect(await weth.balanceOf(portfolio2.address)).to.equal(oneEth);
  });
});
