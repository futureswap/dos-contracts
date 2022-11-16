import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import { GovernanceProxy__factory } from "../../typechain-types";

describe("VotingExecutor", function () {
  async function deployVotingExecutorFixture() {
    const [owner, user] = await ethers.getSigners();

    const governanceProxy = await new GovernanceProxy__factory(owner).deploy();

    return {
      owner,
      user,
      governanceProxy,
    };
  }

  describe("GovernanceProxy tests", () => {
    it("Non-governance cannot execute", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployVotingExecutorFixture
      );
      await expect(
        governanceProxy.connect(user).execute([])
      ).to.be.revertedWith("Only governance");
    });

    it("Governance can execute", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployVotingExecutorFixture
      );
      await expect(governanceProxy.execute([])).to.not.be.reverted;
    });

    it("Governance can propose new governance", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployVotingExecutorFixture
      );

      const calldata = governanceProxy.interface.encodeFunctionData(
        "proposeGovernance",
        [user.address]
      );
      await expect(
        governanceProxy.execute([
          { to: governanceProxy.address, callData: calldata },
        ])
      ).to.not.be.reverted;

      expect(await governanceProxy.governance()).to.equal(owner.address);
      expect(await governanceProxy.proposedGovernance()).to.equal(user.address);
    });

    it("No address except proxy itself can call proposeGovernance", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployVotingExecutorFixture
      );

      await expect(
        governanceProxy.proposeGovernance(user.address)
      ).to.be.revertedWith("Only governance");
      await expect(
        governanceProxy.connect(user).proposeGovernance(user.address)
      ).to.be.revertedWith("Only governance");
    });

    it("Proposed governance can execute and execute properly forwards function", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployVotingExecutorFixture
      );

      const calldata = governanceProxy.interface.encodeFunctionData(
        "proposeGovernance",
        [user.address]
      );
      await expect(
        governanceProxy.execute([
          { to: governanceProxy.address, callData: calldata },
        ])
      ).to.not.be.reverted;

      await expect(governanceProxy.connect(user).execute([])).to.not.be
        .reverted;

      expect(await governanceProxy.governance()).to.equal(user.address);
      expect(await governanceProxy.proposedGovernance()).to.equal(
        ethers.constants.AddressZero
      );
    });

    it("Old governance can still execute after new governance is proposed", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployVotingExecutorFixture
      );

      const calldata = governanceProxy.interface.encodeFunctionData(
        "proposeGovernance",
        [user.address]
      );
      await expect(
        governanceProxy.execute([
          { to: governanceProxy.address, callData: calldata },
        ])
      ).to.not.be.reverted;

      await expect(governanceProxy.execute([])).to.not.be.reverted;
    });
  });
});
