import type { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";
import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import {
  VersionManager__factory,
  DOS__factory,
  PortfolioLogic__factory,
} from "../../typechain-types";

import { BigNumber, Signer, ContractTransaction, BigNumberish } from "ethers";

describe("VersionManager", function () {
  let versionManager: VersionManager__factory;

  async function deployVersionManagerFixture() {
    const [owner] = await getFixedGasSigners(10_000_000);

    const versionManager = await new VersionManager__factory(owner).deploy();
    const dos = await new DOS__factory(owner).deploy(owner.address, versionManager.address);
    const portfolioLogic = await new PortfolioLogic__factory(owner).deploy(dos.address);

    return {
      owner,
      versionManager,
      dos,
      portfolioLogic,
    };
  }

  describe("Version Manager Tests", () => {
    it("should add a new version", async () => {
      const { owner, versionManager, portfolioLogic } = await loadFixture(
        deployVersionManagerFixture,
      );

      const version = "v0.0.1";
      const status = 0; // beta

      // get the block timestamp
      const block = await ethers.provider.getBlock("latest");
      const timestamp = block.timestamp;

      await versionManager.connect(owner).addVersion(version, status, portfolioLogic.address);

      expect(await versionManager.getVersionCount()).to.equal(1);
      expect(await versionManager.getVersionAtIndex(0)).to.equal(version);
      expect(await versionManager.getVersionAddress(0)).to.equal(portfolioLogic.address);
      let details = await versionManager.getVersionDetails(version);
      expect(details[0]).to.equal(version);
      expect(details[1]).to.equal(status);
      expect(details[2]).to.equal(0);
      expect(details[3]).to.equal(portfolioLogic.address);
      expect(details[4]).to.equal(BigNumber.from(timestamp + 1));
    });

    it("should mark a recommended version", async () => {
      const { owner, versionManager, portfolioLogic } = await loadFixture(
        deployVersionManagerFixture,
      );

      const version = "v0.0.1";
      const status = 0; // beta

      // get the block timestamp
      const block = await ethers.provider.getBlock("latest");
      const timestamp = block.timestamp;

      await versionManager.connect(owner).addVersion(version, status, portfolioLogic.address);

      await versionManager.connect(owner).markRecommendedVersion(version);

      let details = await versionManager.getRecommendedVersion();
      expect(details[0]).to.equal(version);
      expect(details[1]).to.equal(status);
      expect(details[2]).to.equal(0);
      expect(details[3]).to.equal(portfolioLogic.address);
      expect(details[4]).to.equal(BigNumber.from(timestamp + 1));
    });

    it("should remove a recommended version", async () => {
      const { owner, versionManager, portfolioLogic } = await loadFixture(
        deployVersionManagerFixture,
      );

      const version = "v0.0.1";
      const status = 0; // beta

      // get the block timestamp
      const block = await ethers.provider.getBlock("latest");
      const timestamp = block.timestamp;

      await versionManager.connect(owner).addVersion(version, status, portfolioLogic.address);

      await versionManager.connect(owner).markRecommendedVersion(version);

      await versionManager.connect(owner).removeRecommendedVersion();

      await expect(versionManager.getRecommendedVersion()).to.be.revertedWith(
        "Recommended version is not specified",
      );
    });

    it("should update to a new version", async () => {
      const { owner, versionManager, portfolioLogic } = await loadFixture(
        deployVersionManagerFixture,
      );

      const version = "v0.0.1";
      const status = 0; // beta

      // get the block timestamp
      const block = await ethers.provider.getBlock("latest");
      const timestamp = block.timestamp;

      await versionManager.connect(owner).addVersion(version, status, portfolioLogic.address);

      const newStatus = 3; // deprecated
      const bugLevel = 3; // HIGH

      await versionManager.connect(owner).updateVersion(version, newStatus, bugLevel);

      let details = await versionManager.getVersionDetails(version);
      expect(details[0]).to.equal(version);
      expect(details[1]).to.equal(newStatus);
      expect(details[2]).to.equal(bugLevel);
      expect(details[3]).to.equal(portfolioLogic.address);
      expect(details[4]).to.equal(BigNumber.from(timestamp + 1));
    });
  });
});

// This fixes random tests crash with
// "contract call run out of gas and made the transaction revert" error
// and, as a side effect, speeds tests in 2-3 times!
// https://github.com/NomicFoundation/hardhat/issues/1721
export const getFixedGasSigners = async function (gasLimit: number) {
  const signers: SignerWithAddress[] = await ethers.getSigners();
  for (const signer of signers) {
    const orig = signer.sendTransaction;
    signer.sendTransaction = transaction => {
      transaction.gasLimit = BigNumber.from(gasLimit.toString());
      return orig.apply(signer, [transaction]);
    };
  }
  return signers;
};
