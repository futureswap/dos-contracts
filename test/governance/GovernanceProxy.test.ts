import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  GovernanceProxy__factory,
  Governance__factory,
  HashNFT__factory,
} from "../../typechain-types";
import {proposeAndExecute, makeCall} from "../../lib/calls";

describe("Governance test", () => {
  async function deployGovernanceProxyFixture() {
    const [owner, user] = await ethers.getSigners();

    const governanceProxy = await new GovernanceProxy__factory(owner).deploy(owner.address);

    return {
      owner,
      user,
      governanceProxy,
    };
  }

  async function deployGovernance() {
    const [owner, voting, user] = await ethers.getSigners();

    const governanceProxy = await new GovernanceProxy__factory(owner).deploy(owner.address);
    const voteNFT = await new HashNFT__factory(voting).deploy("Voting token", "VTOK");
    const governance = await new Governance__factory(owner).deploy(
      governanceProxy.address,
      voteNFT.address,
      voting.address,
    );
    await governanceProxy.execute([
      makeCall(governanceProxy).proposeGovernance(governance.address),
    ]);

    return {
      owner,
      voting,
      user,
      governanceProxy,
      voteNFT,
      governance,
    };
  }

  describe("GovernanceProxy tests", () => {
    it("Non-governance cannot execute", async () => {
      const {user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);
      await expect(governanceProxy.connect(user).execute([])).to.be.revertedWith("Only governance");
    });

    it("Governance can execute", async () => {
      const {governanceProxy} = await loadFixture(deployGovernanceProxyFixture);
      await expect(governanceProxy.execute([])).to.not.be.reverted;
    });

    it("Governance can propose new governance", async () => {
      const {owner, user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);

      const callData = governanceProxy.interface.encodeFunctionData("proposeGovernance", [
        user.address,
      ]);
      await expect(governanceProxy.execute([{to: governanceProxy.address, callData}])).to.not.be
        .reverted;

      expect(await governanceProxy.governance()).to.equal(owner.address);
      expect(await governanceProxy.proposedGovernance()).to.equal(user.address);
    });

    it("No address except proxy itself can call proposeGovernance", async () => {
      const {user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);

      await expect(governanceProxy.proposeGovernance(user.address)).to.be.revertedWith(
        "Only governance",
      );
      await expect(
        governanceProxy.connect(user).proposeGovernance(user.address),
      ).to.be.revertedWith("Only governance");
    });

    it("Proposed governance can execute and execute properly forwards function", async () => {
      const {user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);

      const callData = governanceProxy.interface.encodeFunctionData("proposeGovernance", [
        user.address,
      ]);
      await expect(governanceProxy.execute([{to: governanceProxy.address, callData}])).to.not.be
        .reverted;

      await expect(governanceProxy.connect(user).execute([])).to.not.be.reverted;

      expect(await governanceProxy.governance()).to.equal(user.address);
      expect(await governanceProxy.proposedGovernance()).to.equal(ethers.constants.AddressZero);
    });

    it("Old governance can still execute after new governance is proposed", async () => {
      const {user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);

      const callData = governanceProxy.interface.encodeFunctionData("proposeGovernance", [
        user.address,
      ]);
      await expect(governanceProxy.execute([{to: governanceProxy.address, callData}])).to.not.be
        .reverted;

      await expect(governanceProxy.execute([])).to.not.be.reverted;
    });
  });

  it("NFT vote and execute", async () => {
    const {voteNFT, governance} = await loadFixture(deployGovernance);

    await expect(proposeAndExecute(governance, voteNFT, [])).to.not.be.reverted;
  });

  it("Cannot execute unless owning NFT", async () => {
    const {governance} = await loadFixture(deployGovernance);

    await expect(governance.execute(0, [])).to.be.revertedWith("ERC721: invalid token ID");
  });

  it("Only voting can propose correct NFT", async () => {
    const {user, voteNFT, governance} = await loadFixture(deployGovernance);

    await expect(proposeAndExecute(governance, voteNFT.connect(user), [])).to.be.revertedWith(
      "ERC721: invalid token ID",
    );
  });

  it("Only voting can propose NFT", async () => {
    const {user, voteNFT, governance} = await loadFixture(deployGovernance);

    await expect(proposeAndExecute(governance, voteNFT.connect(user), [])).to.be.revertedWith(
      "ERC721: invalid token ID",
    );
  });

  it("Governance can change voting", async () => {
    const {user, voteNFT, governance} = await loadFixture(deployGovernance);

    await proposeAndExecute(governance, voteNFT, [
      makeCall(governance).transferVoting(user.address),
    ]);
    expect(await governance.voting()).to.equal(user.address);
  });
});
