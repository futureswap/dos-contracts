import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";
import {BigNumber} from "ethers";

import {VersionManager__factory, DOS__factory, DSafeLogic__factory} from "../../typechain-types";
import {getFixedGasSigners} from "../../lib/hardhat/fixedGasSigners";

describe("VersionManager", () => {
  async function deployVersionManagerFixture() {
    const [owner] = await getFixedGasSigners(10_000_000);

    const versionManager = await new VersionManager__factory(owner).deploy(owner.address);
    const dos = await new DOS__factory(owner).deploy(owner.address, versionManager.address);
    const dSafe = await new DSafeLogic__factory(owner).deploy(dos.address);

    return {
      owner,
      versionManager,
      dos,
      dSafe,
    };
  }

  describe("Version Manager Tests", () => {
    it("should add a new version", async () => {
      const {owner, versionManager, dSafe} = await loadFixture(deployVersionManagerFixture);

      const version = "v0.0.1";
      const status = 0; // beta

      // get the block timestamp
      const block = await ethers.provider.getBlock("latest");
      const timestamp = block.timestamp;

      await versionManager.connect(owner).addVersion(version, status, dSafe.address);

      expect(await versionManager.getVersionCount()).to.equal(1);
      expect(await versionManager.getVersionAtIndex(0)).to.equal(version);
      expect(await versionManager.getVersionAddress(0)).to.equal(dSafe.address);
      const details = await versionManager.getVersionDetails(version);
      expect(details[0]).to.equal(version);
      expect(details[1]).to.equal(status);
      expect(details[2]).to.equal(0);
      expect(details[3]).to.equal(dSafe.address);
      expect(details[4]).to.equal(BigNumber.from(timestamp + 1));
    });

    it("should mark a recommended version", async () => {
      const {owner, versionManager, dSafe} = await loadFixture(deployVersionManagerFixture);

      const version = "v0.0.1";
      const status = 0; // beta

      // get the block timestamp
      const block = await ethers.provider.getBlock("latest");
      const timestamp = block.timestamp;

      await versionManager.connect(owner).addVersion(version, status, dSafe.address);

      await versionManager.connect(owner).markRecommendedVersion(version);

      const details = await versionManager.getRecommendedVersion();
      expect(details[0]).to.equal(version);
      expect(details[1]).to.equal(status);
      expect(details[2]).to.equal(0);
      expect(details[3]).to.equal(dSafe.address);
      expect(details[4]).to.equal(BigNumber.from(timestamp + 1));
    });

    it("should remove a recommended version", async () => {
      const {owner, versionManager, dSafe} = await loadFixture(deployVersionManagerFixture);

      const version = "v0.0.1";
      const status = 0; // beta

      await versionManager.connect(owner).addVersion(version, status, dSafe.address);

      await versionManager.connect(owner).markRecommendedVersion(version);

      await versionManager.connect(owner).removeRecommendedVersion();

      await expect(versionManager.getRecommendedVersion()).to.be.revertedWith(
        "Recommended version is not specified",
      );
    });

    it("should update to a new version", async () => {
      const {owner, versionManager, dSafe} = await loadFixture(deployVersionManagerFixture);

      const version = "v0.0.1";
      const status = 0; // beta

      // get the block timestamp
      const block = await ethers.provider.getBlock("latest");
      const timestamp = block.timestamp;

      await versionManager.connect(owner).addVersion(version, status, dSafe.address);

      const newStatus = 3; // deprecated
      const bugLevel = 3; // hIGH

      await versionManager.connect(owner).updateVersion(version, newStatus, bugLevel);

      const details = await versionManager.getVersionDetails(version);
      expect(details[0]).to.equal(version);
      expect(details[1]).to.equal(newStatus);
      expect(details[2]).to.equal(bugLevel);
      expect(details[3]).to.equal(dSafe.address);
      expect(details[4]).to.equal(BigNumber.from(timestamp + 1));
    });
  });
});
