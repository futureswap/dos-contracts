import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {
  GovernanceProxy__factory,
  Governance__factory,
  HashNFT__factory,
  TestERC20__factory,
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
    const hashNFT = await new HashNFT__factory(voting).deploy("HashERC1155");
    const governance = await new Governance__factory(owner).deploy(
      governanceProxy.address,
      hashNFT.address,
      voting.address,
    );
    await governanceProxy.executeBatch([
      makeCall(governanceProxy).proposeGovernance(governance.address),
    ]);

    return {
      owner,
      voting,
      user,
      governanceProxy,
      hashNFT,
      governance,
    };
  }

  describe("GovernanceProxy tests", () => {
    it("Non-governance cannot execute", async () => {
      const {user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);
      await expect(governanceProxy.connect(user).executeBatch([])).to.be.reverted;
    });

    it("Governance can execute", async () => {
      const {governanceProxy} = await loadFixture(deployGovernanceProxyFixture);
      await expect(governanceProxy.executeBatch([])).to.not.be.reverted;
    });

    it("Governance can propose new governance", async () => {
      const {owner, user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);

      const callData = governanceProxy.interface.encodeFunctionData("proposeGovernance", [
        user.address,
      ]);
      await expect(governanceProxy.executeBatch([{to: governanceProxy.address, callData}])).to.not
        .be.reverted;

      expect(await governanceProxy.governance()).to.equal(owner.address);
      expect(await governanceProxy.proposedGovernance()).to.equal(user.address);
    });

    it("No address except proxy itself can call proposeGovernance", async () => {
      const {user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);

      await expect(governanceProxy.proposeGovernance(user.address)).to.be.reverted;
      await expect(governanceProxy.connect(user).proposeGovernance(user.address)).to.be.reverted;
    });

    it("Proposed governance can execute and execute properly forwards function", async () => {
      const {user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);

      const callData = governanceProxy.interface.encodeFunctionData("proposeGovernance", [
        user.address,
      ]);
      await expect(governanceProxy.executeBatch([{to: governanceProxy.address, callData}])).to.not
        .be.reverted;

      await expect(governanceProxy.connect(user).executeBatch([])).to.not.be.reverted;

      expect(await governanceProxy.governance()).to.equal(user.address);
      expect(await governanceProxy.proposedGovernance()).to.equal(ethers.constants.AddressZero);
    });

    it("Old governance can still execute after new governance is proposed", async () => {
      const {user, governanceProxy} = await loadFixture(deployGovernanceProxyFixture);

      const callData = governanceProxy.interface.encodeFunctionData("proposeGovernance", [
        user.address,
      ]);
      await expect(governanceProxy.executeBatch([{to: governanceProxy.address, callData}])).to.not
        .be.reverted;

      await expect(governanceProxy.executeBatch([])).to.not.be.reverted;
    });
  });

  it("NFT vote and execute", async () => {
    const {hashNFT, governance} = await loadFixture(deployGovernance);

    await expect(proposeAndExecute(governance, hashNFT, [])).to.not.be.reverted;
  });

  it("Cannot execute unless owning NFT", async () => {
    const {governance} = await loadFixture(deployGovernance);

    await expect(governance.executeBatch([])).to.be.revertedWith(
      "ERC1155: burn amount exceeds balance",
    );
  });

  it("Only voting can propose correct NFT", async () => {
    const {user, hashNFT, governance} = await loadFixture(deployGovernance);

    await expect(proposeAndExecute(governance, hashNFT.connect(user), [])).to.be.revertedWith(
      "ERC1155: burn amount exceeds balance",
    );
  });

  it("Governance can change voting", async () => {
    const {user, hashNFT, governance} = await loadFixture(deployGovernance);

    await proposeAndExecute(governance, hashNFT, [
      makeCall(governance).transferVoting(user.address),
    ]);
    expect(await governance.voting()).to.equal(user.address);
  });

  it("Governance can set access level", async () => {
    const {hashNFT, governance} = await loadFixture(deployGovernance);

    const func = hashNFT.interface.getFunction("mint");

    await proposeAndExecute(governance, hashNFT, [
      makeCall(governance).setAccessLevel(
        hashNFT.address,
        hashNFT.interface.getSighash(func),
        1,
        true,
      ),
    ]);
    expect(
      await governance.bitmaskByAddressBySelector(
        hashNFT.address,
        hashNFT.interface.getSighash(func),
      ),
    ).to.equal(1 << 1);
  });

  it("Governance can mint access", async () => {
    const {user, hashNFT, governance} = await loadFixture(deployGovernance);

    await proposeAndExecute(governance, hashNFT, [
      makeCall(governance).mintAccess(user.address, 1, "0x"),
    ]);
    expect(await governance.hasAccess(user.address, 1)).to.equal(true);
  });

  it("User with proper access level can execute call to function with access level set", async () => {
    const {user, hashNFT, governance, governanceProxy} = await loadFixture(deployGovernance);

    const test = await new TestERC20__factory(user).deploy("Test", "TST", 18);
    await test.mint(governanceProxy.address, 1);

    const testMethod = test.interface.getFunction("transfer");

    await proposeAndExecute(governance, hashNFT, [
      makeCall(governance).setAccessLevel(
        test.address,
        test.interface.getSighash(testMethod),
        1,
        true,
      ),
    ]);
    await proposeAndExecute(governance, hashNFT, [
      makeCall(governance).mintAccess(user.address, 1, "0x"),
    ]);

    // user has clearance to execute test.transfer
    await governance
      .connect(user)
      .executeBatchWithClearance([makeCall(test).transfer(user.address, 1)], 1);
    expect(await test.balanceOf(user.address)).to.equal(1);
    // user has no clearance to execute test.approve
    await expect(
      governance
        .connect(user)
        .executeBatchWithClearance([makeCall(test).approve(user.address, 1)], 1),
    ).to.be.reverted;
  });

  it("User with proper access level cannot execute call to function without access level set", async () => {
    const {user, hashNFT, governance} = await loadFixture(deployGovernance);

    const test = await new TestERC20__factory(user).deploy("Test", "TST", 18);

    await proposeAndExecute(governance, hashNFT, [
      makeCall(governance).mintAccess(user.address, 1, "0x"),
    ]);

    // user has clearance to execute test.transfer
    await expect(
      governance
        .connect(user)
        .executeBatchWithClearance([makeCall(test).transfer(user.address, 1)], 1),
    ).to.be.reverted;
  });

  it("Cannot execute functions at wrong access level", async () => {
    const {user, hashNFT, governance, governanceProxy} = await loadFixture(deployGovernance);

    const test = await new TestERC20__factory(user).deploy("Test", "TST", 18);
    await test.mint(governanceProxy.address, 1);

    const testMethod = test.interface.getFunction("transfer");

    await proposeAndExecute(governance, hashNFT, [
      makeCall(governance).setAccessLevel(
        test.address,
        test.interface.getSighash(testMethod),
        2,
        true,
      ),
    ]);
    await proposeAndExecute(governance, hashNFT, [
      makeCall(governance).mintAccess(user.address, 1, "0x"),
    ]);
    expect(await governance.hasAccess(user.address, 1)).to.equal(true);

    await expect(
      governance
        .connect(user)
        .executeBatchWithClearance([makeCall(test).transfer(user.address, 1)], 1),
    ).to.be.reverted;
  });

  it("Cannot set access level of setAccessLevel", async () => {
    const {hashNFT, governance} = await loadFixture(deployGovernance);

    const method = governance.interface.getFunction("setAccessLevel");

    await expect(
      proposeAndExecute(governance, hashNFT, [
        makeCall(governance).setAccessLevel(
          governance.address,
          governance.interface.getSighash(method),
          1,
          true,
        ),
      ]),
    ).to.be.reverted;
  });

  it("Cannot set access level of transferVoting", async () => {
    const {hashNFT, governance} = await loadFixture(deployGovernance);

    const method = governance.interface.getFunction("transferVoting");

    await expect(
      proposeAndExecute(governance, hashNFT, [
        makeCall(governance).setAccessLevel(
          governance.address,
          governance.interface.getSighash(method),
          1,
          true,
        ),
      ]),
    ).to.be.reverted;
  });

  it("Cannot set access level of mintAccess", async () => {
    const {hashNFT, governance} = await loadFixture(deployGovernance);

    const method = governance.interface.getFunction("mintAccess");

    await expect(
      proposeAndExecute(governance, hashNFT, [
        makeCall(governance).setAccessLevel(
          governance.address,
          governance.interface.getSighash(method),
          1,
          true,
        ),
      ]),
    ).to.be.reverted;
  });

  it("Can set access level of revokeAccess", async () => {
    const {hashNFT, governance} = await loadFixture(deployGovernance);

    const method = governance.interface.getFunction("revokeAccess");

    await expect(
      proposeAndExecute(governance, hashNFT, [
        makeCall(governance).setAccessLevel(
          governance.address,
          governance.interface.getSighash(method),
          1,
          true,
        ),
      ]),
    ).to.not.be.reverted;
  });

  it("Cannot set access level of proposeGovernance", async () => {
    const {hashNFT, governance, governanceProxy} = await loadFixture(deployGovernance);

    const method = governanceProxy.interface.getFunction("proposeGovernance");

    await expect(
      proposeAndExecute(governance, hashNFT, [
        makeCall(governance).setAccessLevel(
          governanceProxy.address,
          governance.interface.getSighash(method),
          1,
          true,
        ),
      ]),
    ).to.be.reverted;
  });
});
