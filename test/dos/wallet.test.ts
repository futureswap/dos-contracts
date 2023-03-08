import type {BigNumber} from "ethers";
import type {WalletLogic} from "../../typechain-types";

import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  WalletLogic__factory,
  TestERC20__factory,
  WETH9__factory,
  TestNFT__factory,
  MockNFTOracle__factory,
} from "../../typechain-types";
import {toWei, toWeiUsdc} from "../../lib/numbers";
import {getFixedGasSigners} from "../../lib/hardhat/fixedGasSigners";
import {signExecuteBatch, signOnTransferReceived2Call} from "../../lib/signers";
import {
  makeCall,
  createWallet,
  sortTransfers,
  upgradeWalletImplementation,
  proposeTransferWalletOwnership,
} from "../../lib/calls";
import {Chainlink, deploySupa, deployFixedAddressForTests} from "../../lib/deploy";

const USDC_PRICE = 1;
const ETH_PRICE = 2000;

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

const tenThousandUsdc = toWeiUsdc(10_000);
const oneEth = toWei(1);

describe("WalletProxy", () => {
  // we define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deploySupaFixture() {
    const [owner, user, user2, user3] = await getFixedGasSigners(10_000_000);

    const {permit2, transferAndCall2, anyswapCreate2Deployer} = await deployFixedAddressForTests(
      owner,
    );

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
      toWei(0.9),
      toWei(0.9),
      owner.address,
    );
    const ethChainlink = await Chainlink.deploy(
      owner,
      ETH_PRICE,
      8,
      USDC_DECIMALS,
      WETH_DECIMALS,
      toWei(0.9),
      toWei(0.9),
      owner.address,
    );

    const nftOracle = await new MockNFTOracle__factory(owner).deploy();

    const {supa, iSupa, versionManager} = await deploySupa(
      owner.address,
      anyswapCreate2Deployer,
      "0x04",
      owner,
    );
    const proxyLogic = await new WalletLogic__factory(owner).deploy(iSupa.address);
    await versionManager.addVersion(2, proxyLogic.address);
    await versionManager.markRecommendedVersion("1.0.0");

    const treasurySafe = await createWallet(iSupa, owner);

    await iSupa.setConfig({
      treasurySafe: treasurySafe.address,
      treasuryInterestFraction: toWei(0.05),
      maxSolvencyCheckGasCost: 1e6,
      liqFraction: toWei(0.8),
      fractionalReserveLeverage: 9,
    });

    await iSupa.addERC20Info(
      usdc.address,
      "USD Coin",
      "USDC",
      USDC_DECIMALS,
      usdcChainlink.oracle.address,
      0, // no interest which would include time sensitive calculations
      0,
      0,
      0,
    );

    await iSupa.addERC20Info(
      weth.address,
      "Wrapped ETH",
      "WETH",
      WETH_DECIMALS,
      ethChainlink.oracle.address,
      0, // no interest which would include time sensitive calculations
      0,
      0,
      0,
    );

    await iSupa.addERC721Info(nft.address, nftOracle.address);
    await nftOracle.setCollateralFactor(toWei(0.5));

    const getBalances = async (
      wallet: WalletLogic,
    ): Promise<{
      nfts: [nftContract: string, tokenId: BigNumber][];
      usdc: BigNumber;
      weth: BigNumber;
    }> => {
      const [nfts, usdcBal, wethBal] = await Promise.all([
        iSupa.getCreditAccountERC721(wallet.address),
        iSupa.getCreditAccountERC20(wallet.address, usdc.address),
        iSupa.getCreditAccountERC20(wallet.address, weth.address),
      ]);
      return {nfts, usdc: usdcBal, weth: wethBal};
    };

    const wallet = await createWallet(iSupa, user);
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
      iSupa,
      supa,
      permit2,
      getBalances,
      wallet,
      transferAndCall2,
      versionManager,
    };
  }

  it("should be able to executebatch with a valid signature", async () => {
    const {user, user2, wallet} = await loadFixture(deploySupaFixture);

    const signature = await signExecuteBatch(
      wallet, // walletLogic wallet,
      [], // call[] calls,
      0, // nonce
      ethers.constants.MaxUint256.toBigInt(), // deadline
      user, // signer
    );
    await expect(
      wallet.connect(user2).executeSignedBatch([], 0, ethers.constants.MaxUint256, signature),
    ).to.not.be.reverted;
  });

  it("should be able to transferAndCall2 into proxy", async () => {
    const {user, usdc, weth, wallet, transferAndCall2} = await loadFixture(deploySupaFixture);

    await transferAndCall2.connect(user).transferAndCall2(
      wallet.address,
      sortTransfers([
        {token: usdc.address, amount: tenThousandUsdc},
        {token: weth.address, amount: oneEth},
      ]),
      "0x",
    );

    expect(await usdc.balanceOf(wallet.address)).to.equal(tenThousandUsdc);
    expect(await weth.balanceOf(wallet.address)).to.equal(oneEth);
  });

  it("should be able to transferAndCall2 into Supa", async () => {
    const {user, usdc, weth, wallet, getBalances, transferAndCall2} = await loadFixture(
      deploySupaFixture,
    );

    await transferAndCall2.connect(user).transferAndCall2(
      wallet.address,
      sortTransfers([
        {token: usdc.address, amount: tenThousandUsdc},
        {token: weth.address, amount: oneEth},
      ]),
      "0x01",
    );

    expect(await usdc.balanceOf(wallet.address)).to.equal(0);
    expect(await weth.balanceOf(wallet.address)).to.equal(0);

    const balances = await getBalances(wallet);
    expect(balances.usdc).to.equal(tenThousandUsdc);
    expect(balances.weth).to.equal(oneEth);
  });

  it("should be able to transferAndCall into other wallet and make a swap with signatures", async () => {
    const {user, user2, usdc, weth, iSupa, transferAndCall2} = await loadFixture(deploySupaFixture);

    const wallet2 = await createWallet(iSupa, user2);
    await usdc.connect(user).transfer(wallet2.address, tenThousandUsdc);

    const signedCall = {
      operator: user.address,
      from: user.address,
      transfers: [{token: weth.address, amount: oneEth}],
      calls: [makeCall(usdc).transfer(user.address, tenThousandUsdc)],
    };

    const signedData = await signOnTransferReceived2Call(wallet2, signedCall, 0, user2);
    const data = `0x02${signedData.slice(2)}`;

    await transferAndCall2
      .connect(user)
      .transferAndCall2(wallet2.address, signedCall.transfers, data);

    expect(await usdc.balanceOf(user.address)).to.equal(tenThousandUsdc);
    expect(await weth.balanceOf(wallet2.address)).to.equal(oneEth);
  });

  // nOTE: the following tests were moved to foundry
  it("should be able to upgrade to a new version", async () => {
    const {iSupa, wallet, versionManager} = await loadFixture(deploySupaFixture);
    const recommendedVersion = await versionManager.getRecommendedVersion();
    const recommendedImplementation = recommendedVersion.implementation;
    await expect(upgradeWalletImplementation(iSupa, wallet, recommendedVersion.versionName)).to.not
      .be.reverted;
    // get the new implementation address
    const newImplementation = await iSupa.getImplementation(wallet.address);
    // check that the new implementation is the recommended version
    expect(newImplementation).to.equal(recommendedImplementation);
  });

  it("should not be able to upgrade to an invalid version", async () => {
    const {iSupa, wallet} = await loadFixture(deploySupaFixture);

    const oldImplementation = await iSupa.getImplementation(wallet.address);
    const version = "1,0.0";
    await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.reverted;
    // await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.revertedWithCustomError(
    //   supaConfig,
    //   "InvalidImplementation",
    // );
    const newImplementation = await iSupa.getImplementation(wallet.address);
    expect(newImplementation).to.equal(oldImplementation);
  });

  it("should not be able to upgrade to a deprecated version", async () => {
    const {owner, iSupa, wallet, versionManager} = await loadFixture(deploySupaFixture);
    const oldImplementation = await iSupa.getImplementation(wallet.address);
    const recommendedVersion = await versionManager.getRecommendedVersion();
    const version = recommendedVersion.versionName;
    // set a deprecated version
    const DEPRECATED = 3;
    await versionManager.connect(owner).updateVersion(version, DEPRECATED, 0);
    await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.reverted;
    // await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.revertedWithCustomError(
    //   supaConfig,
    //   "DeprecatedVersion",
    // );
    const newImplementation = await iSupa.getImplementation(wallet.address);
    expect(newImplementation).to.equal(oldImplementation);
  });

  it("should not be able to upgrade to a version with a low bug", async () => {
    const {owner, iSupa, wallet, versionManager} = await loadFixture(deploySupaFixture);
    const oldImplementation = await iSupa.getImplementation(wallet.address);
    const recommendedVersion = await versionManager.getRecommendedVersion();
    const version = recommendedVersion.versionName;
    // set a bug level version
    const PRODUCTION = 2;
    const BUG = 1;
    await versionManager.connect(owner).updateVersion(version, PRODUCTION, BUG);
    await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.reverted;
    // await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.revertedWithCustomError(
    //   supaConfig,
    //   "BugLevelTooHigh",
    // );
    const newImplementation = await iSupa.getImplementation(wallet.address);
    expect(newImplementation).to.equal(oldImplementation);
  });

  it("should not be able to upgrade to a version with a medium bug", async () => {
    const {owner, iSupa, wallet, versionManager} = await loadFixture(deploySupaFixture);
    const oldImplementation = await iSupa.getImplementation(wallet.address);
    const recommendedVersion = await versionManager.getRecommendedVersion();
    const version = recommendedVersion.versionName;
    // set a bug level version
    const PRODUCTION = 2;
    const BUG = 2;
    await versionManager.connect(owner).updateVersion(version, PRODUCTION, BUG);
    await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.reverted;
    // await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.revertedWithCustomError(
    //   supaConfig,
    //   "BugLevelTooHigh",
    // );
    const newImplementation = await iSupa.getImplementation(wallet.address);
    expect(newImplementation).to.equal(oldImplementation);
  });

  it("should not be able to upgrade to a version with a high bug", async () => {
    const {owner, iSupa, wallet, versionManager} = await loadFixture(deploySupaFixture);
    const oldImplementation = await iSupa.getImplementation(wallet.address);
    const recommendedVersion = await versionManager.getRecommendedVersion();
    const version = recommendedVersion.versionName;
    // set a bug level version
    const PRODUCTION = 2;
    const BUG = 3;
    await versionManager.connect(owner).updateVersion(version, PRODUCTION, BUG);
    await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.reverted;
    // await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.revertedWithCustomError(
    //   supaConfig,
    //   "BugLevelTooHigh",
    // );
    const newImplementation = await iSupa.getImplementation(wallet.address);
    expect(newImplementation).to.equal(oldImplementation);
  });

  it("should not be able to upgrade to a version with a critical bug", async () => {
    const {owner, iSupa, wallet, versionManager} = await loadFixture(deploySupaFixture);
    const oldImplementation = await iSupa.getImplementation(wallet.address);
    const recommendedVersion = await versionManager.getRecommendedVersion();
    const version = recommendedVersion.versionName;
    // set a bug level version
    const PRODUCTION = 2;
    const BUG = 4;
    await versionManager.connect(owner).updateVersion(version, PRODUCTION, BUG);
    await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.reverted;
    // await expect(upgradeWalletImplementation(iSupa, wallet, version)).to.be.revertedWithCustomError(
    //   supaConfig,
    //   "BugLevelTooHigh",
    // );
    const newImplementation = await iSupa.getImplementation(wallet.address);
    expect(newImplementation).to.equal(oldImplementation);
  });

  it("should be able to propose wallet ownership transfer", async () => {
    const {user2, wallet, iSupa, supa} = await loadFixture(deploySupaFixture);

    await expect(proposeTransferWalletOwnership(iSupa, wallet, user2.address)).to.not.be.reverted;

    expect(await supa.walletProposedNewOwner(wallet.address)).to.equal(user2.address);
  });

  it("should be able to execute wallet ownership transfer after proposal", async () => {
    const {user2, wallet, iSupa, supa} = await loadFixture(deploySupaFixture);

    await proposeTransferWalletOwnership(iSupa, wallet, user2.address);

    expect(await supa.walletProposedNewOwner(wallet.address)).to.equal(user2.address);

    await expect(iSupa.connect(user2).executeTransferWalletOwnership(wallet.address)).to.not.be
      .reverted;

    expect(await supa.getWalletOwner(wallet.address)).to.equal(user2.address);
    expect(await supa.walletProposedNewOwner(wallet.address)).to.equal(
      ethers.constants.AddressZero,
    );
  });

  it("should be not able to execute wallet ownership transfer without proposal", async () => {
    const {user, user2, wallet, iSupa, supa} = await loadFixture(deploySupaFixture);

    expect(await supa.walletProposedNewOwner(wallet.address)).to.equal(
      ethers.constants.AddressZero,
    );

    await expect(iSupa.connect(user2).executeTransferWalletOwnership(wallet.address)).to.be
      .reverted;

    expect(await supa.getWalletOwner(wallet.address)).to.equal(user.address);
  });
});
