import {ethers} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {deployFutureSwapProxy, fsSalt, deployAnyswapCreate2Deployer} from "../../lib/deploy";
import {signTakeFutureSwapProxyOwnership} from "../../lib/signers";

describe("FutureSwapProxy test", () => {
  async function deployGovernanceProxyFixture() {
    const [owner, governator] = await ethers.getSigners();

    const anyswapCreate2Deployer = await deployAnyswapCreate2Deployer(owner);
    const futureSwapProxy = await deployFutureSwapProxy(
      anyswapCreate2Deployer,
      fsSalt,
      governator.address,
    );
    await futureSwapProxy.takeOwnership(
      signTakeFutureSwapProxyOwnership(futureSwapProxy, owner.address, 0, governator),
    );

    return {
      owner,
      futureSwapProxy,
    };
  }

  it("FutureSwapProxy has correct owner", async () => {
    const {owner, futureSwapProxy} = await loadFixture(deployGovernanceProxyFixture);
    expect(await futureSwapProxy.owner()).to.equal(owner.address);
  });
});
