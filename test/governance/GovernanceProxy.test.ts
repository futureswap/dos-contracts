import { ethers } from "hardhat";
import { loadFixture } from "@nomicfoundation/hardhat-network-helpers";
import { expect } from "chai";
import {
  GovernanceProxy__factory,
  Governance__factory,
  Governance,
  HashNFT,
  HashNFT__factory,
  BridgeNFT__factory,
} from "../../typechain-types";
import { getEventsTx } from "../../lib/Events";
import { token } from "../../typechain-types/@openzeppelin/contracts";

interface Call {
  to: ethers.Contract;
  func: string;
  params: any[];
}

function makeCall(to: ethers.Contract, func: string, params: any[]): Call {
  return { to, func, params };
}

function encodeParam(param: unknown): any {
  if (typeof param === "object" && param !== null) {
    if ("to" in param && "func" in param && "params" in param) {
      return encodeCall(param as Call);
    }
    const l = Object.entries(param).map(
      ([k, v]) => [k, encodeParam(v)] as [string, any]
    );
    return Object.fromEntries(l);
  }
  if (Array.isArray(param)) {
    param.map(encodeParam);
  }
  return param;
}

function encodeCall(call: Call) {
  const p = call.params.map((p) => encodeParam(p));
  return {
    to: call.to.address,
    callData: call.to.interface.encodeFunctionData(call.func, p),
  };
}

async function proposeAndExecute(
  governance: Governance,
  voteNFT: HashNFT,
  calls: Call[]
) {
  const cd = calls.map(encodeCall);
  const hash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["tuple(address to, bytes callData)[]"],
      [cd]
    )
  );
  const nonce = await voteNFT.mintingNonce();
  await voteNFT.mint(governance.address, hash);
  return governance.execute(nonce, cd);
}

describe("Governance test", function () {
  async function deployGovernanceProxyFixture() {
    const [owner, user] = await ethers.getSigners();

    const governanceProxy = await new GovernanceProxy__factory(owner).deploy();

    return {
      owner,
      user,
      governanceProxy,
    };
  }

  async function deployGovernance() {
    const [owner, voting, user] = await ethers.getSigners();

    const governanceProxy = await new GovernanceProxy__factory(owner).deploy();
    const voteNFT = await new HashNFT__factory(voting).deploy(
      "Voting token",
      "VTOK",
      governanceProxy.address
    );
    const bridgeNFT = await new BridgeNFT__factory(owner).deploy(
      voteNFT.address,
      "Bridge token",
      "BTOK",
      owner.address
    );
    const governance = await new Governance__factory(owner).deploy(
      governanceProxy.address,
      voteNFT.address,
      voting.address
    );
    await governanceProxy.execute([
      encodeCall(makeCall(voteNFT, "setBridgeNFT", [bridgeNFT.address, true])),
      encodeCall(
        makeCall(governanceProxy, "proposeGovernance", [governance.address])
      ),
    ]);

    return {
      owner,
      voting,
      user,
      governanceProxy,
      voteNFT,
      bridgeNFT,
      governance,
    };
  }

  describe("GovernanceProxy tests", () => {
    it("Non-governance cannot execute", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployGovernanceProxyFixture
      );
      await expect(
        governanceProxy.connect(user).execute([])
      ).to.be.revertedWith("Only governance");
    });

    it("Governance can execute", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployGovernanceProxyFixture
      );
      await expect(governanceProxy.execute([])).to.not.be.reverted;
    });

    it("Governance can propose new governance", async () => {
      const { owner, user, governanceProxy } = await loadFixture(
        deployGovernanceProxyFixture
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
        deployGovernanceProxyFixture
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
        deployGovernanceProxyFixture
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
        deployGovernanceProxyFixture
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

  it("NFT vote and execute", async () => {
    const { owner, user, governanceProxy, voteNFT, governance } =
      await loadFixture(deployGovernance);

    await expect(proposeAndExecute(governance, voteNFT, [])).to.not.be.reverted;
  });

  it("Cannot execute unless owning NFT", async () => {
    const { owner, user, governanceProxy, voteNFT, governance } =
      await loadFixture(deployGovernance);

    await expect(governance.execute(0, [])).to.be.revertedWith("Invalid NFT");
  });

  it("Only voting can propose correct NFT", async () => {
    const { owner, user, governanceProxy, voteNFT, governance } =
      await loadFixture(deployGovernance);

    await expect(
      proposeAndExecute(governance, voteNFT.connect(user), [])
    ).to.be.revertedWith("Invalid NFT");
  });

  it("Only voting can propose NFT", async () => {
    const { owner, user, governanceProxy, voteNFT, governance } =
      await loadFixture(deployGovernance);

    await expect(
      proposeAndExecute(governance, voteNFT.connect(user), [])
    ).to.be.revertedWith("Invalid NFT");
  });

  it("Governance can change voting", async () => {
    const { owner, user, governanceProxy, voteNFT, governance } =
      await loadFixture(deployGovernance);

    await proposeAndExecute(governance, voteNFT, [
      makeCall(governance, "transferVoting", [user.address]),
    ]);
    expect(await governance.voting()).to.equal(user.address);
  });

  it("Bridge NFT can be converted to vote NFT", async () => {
    const {
      owner,
      voting,
      user,
      governanceProxy,
      voteNFT,
      bridgeNFT,
      governance,
    } = await loadFixture(deployGovernance);

    const digest = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["tuple(address to, bytes callData)[]"],
        [[]]
      )
    );
    // Bypass voting address by directly constructing tokenId
    const tokenId = ethers.utils.keccak256(
      ethers.utils.defaultAbiCoder.encode(
        ["address", "uint256", "bytes32"],
        [voting.address, 0, digest]
      )
    );

    // Mint token directly to voteNFT thus converting it into a voteNFT
    await bridgeNFT.mint(voteNFT.address, tokenId);
    expect(await voteNFT.ownerOf(tokenId)).to.equal(owner.address);
    await expect(bridgeNFT.ownerOf(tokenId)).to.be.reverted;

    await voteNFT
      .connect(owner)
      ["safeTransferFrom(address,address,uint256)"](
        owner.address,
        governance.address,
        tokenId
      );

    await expect(governance.execute(0, [])).to.not.be.reverted;
  });

  it("Non-owner cannot mint bridge nft", async () => {
    const {
      owner,
      voting,
      user,
      governanceProxy,
      voteNFT,
      bridgeNFT,
      governance,
    } = await loadFixture(deployGovernance);

    // Mint token directly to voteNFT thus converting it into a voteNFT
    await expect(bridgeNFT.connect(user).mint(voteNFT.address, 0)).to.be
      .reverted;
  });

  it("vote NFT can be converted into bridge NFT", async () => {
    const {
      owner,
      voting,
      user,
      governanceProxy,
      voteNFT,
      bridgeNFT,
      governance,
    } = await loadFixture(deployGovernance);

    const { tokenId } = (
      await getEventsTx(
        voteNFT.mint(bridgeNFT.address, ethers.utils.keccak256("0x")),
        voteNFT
      )
    ).Transfer;

    // Mint token directly to voteNFT thus converting it into a voteNFT
    expect(await bridgeNFT.ownerOf(tokenId)).to.equal(voting.address);
  });
});
