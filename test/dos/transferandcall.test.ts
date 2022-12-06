import type {BigNumberish} from "ethers";

import {ethers, waffle} from "hardhat";
import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";

import {TestERC20__factory, WETH9__factory} from "../../typechain-types";
import {toWei} from "../../lib/numbers";
import {getFixedGasSigners} from "../../lib/signers";
import {deployFixedAddress} from "../../lib/deploy";
import {ITransferReceiver2__factory} from "../../typechain-types/factories/contracts/interfaces/ITransferReceiver2__factory";

const USDC_DECIMALS = 6;
const WETH_DECIMALS = 18;

const tenThousandUsdc = toWei(10_000, USDC_DECIMALS);
const oneEth = toWei(1);

const sortTransfers = (transfers: {token: string; amount: BigNumberish}[]) => {
  return transfers.sort((a, b) => {
    const diff = BigInt(a.token) - BigInt(b.token);
    return diff > 0 ? 1 : diff < 0 ? -1 : 0;
  });
};

describe("DOS", () => {
  // we define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployDOSFixture() {
    const [owner, user] = await getFixedGasSigners(10_000_000);

    const weth = await new WETH9__factory(owner).deploy();
    const usdc = await new TestERC20__factory(owner).deploy("USDC", "USDC", USDC_DECIMALS);
    const uni = await new TestERC20__factory(owner).deploy("UNI", "UNI", WETH_DECIMALS);

    const {transferAndCall2} = await deployFixedAddress(owner);

    const mockReceiver = await waffle.deployMockContract(owner, ITransferReceiver2__factory.abi);
    const magicValue = mockReceiver.interface.getSighash("onTransferReceived2");

    await usdc.approve(transferAndCall2.address, ethers.constants.MaxUint256);
    await weth.approve(transferAndCall2.address, ethers.constants.MaxUint256);
    await uni.approve(transferAndCall2.address, ethers.constants.MaxUint256);

    await usdc.mint(owner.address, tenThousandUsdc);
    await uni.mint(owner.address, oneEth);
    await weth.deposit({value: oneEth});

    return {owner, user, weth, usdc, uni, transferAndCall2, mockReceiver, magicValue};
  }

  it("Should be able to transferAndCall2 to send to contract that accepts", async () => {
    const {usdc, uni, transferAndCall2, mockReceiver, magicValue} = await loadFixture(
      deployDOSFixture,
    );

    await mockReceiver.mock.onTransferReceived2.returns(magicValue);

    await expect(
      transferAndCall2.transferAndCall2(
        mockReceiver.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
        ]),
        "0x",
      ),
    ).to.not.be.reverted;

    expect(await usdc.balanceOf(mockReceiver.address)).to.equal(tenThousandUsdc);
    expect(await uni.balanceOf(mockReceiver.address)).to.equal(oneEth);
  });

  it("Should be able to transferAndCall2 to send to EOA", async () => {
    const {user, usdc, uni, transferAndCall2} = await loadFixture(deployDOSFixture);

    await expect(
      transferAndCall2.transferAndCall2(
        user.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
        ]),
        "0x",
      ),
    ).to.not.be.reverted;

    expect(await usdc.balanceOf(user.address)).to.equal(tenThousandUsdc);
    expect(await uni.balanceOf(user.address)).to.equal(oneEth);
  });

  it("Should not be able to transferAndCall2 to send to contract that doesn't accept by reverting", async () => {
    const {usdc, uni, transferAndCall2, mockReceiver} = await loadFixture(deployDOSFixture);

    await expect(
      transferAndCall2.transferAndCall2(
        mockReceiver.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
        ]),
        "0x",
      ),
    ).to.be.reverted;
  });

  it("Should not be able to transferAndCall2 to send to contract that doesn't accept by not returning right hash", async () => {
    const {usdc, uni, transferAndCall2, mockReceiver} = await loadFixture(deployDOSFixture);

    await mockReceiver.mock.onTransferReceived2.returns("0x12345678");

    await expect(
      transferAndCall2.transferAndCall2(
        mockReceiver.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
        ]),
        "0x",
      ),
    ).to.be.reverted;
  });

  it("Should be able to transferAndCall2WithValue to send to EOA", async () => {
    const {user, weth, usdc, uni, transferAndCall2} = await loadFixture(deployDOSFixture);

    await expect(
      transferAndCall2.transferAndCall2WithValue(
        user.address,
        weth.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
          {token: weth.address, amount: oneEth},
        ]),
        "0x",
        {value: oneEth},
      ),
    ).to.not.be.reverted;

    expect(await usdc.balanceOf(user.address)).to.equal(tenThousandUsdc);
    expect(await uni.balanceOf(user.address)).to.equal(oneEth);
    expect(await weth.balanceOf(user.address)).to.equal(oneEth);
  });

  it("transferAndCall2WithValue reverts if send too much value to send to EOA", async () => {
    const {user, weth, usdc, uni, transferAndCall2} = await loadFixture(deployDOSFixture);

    await expect(
      transferAndCall2.transferAndCall2WithValue(
        user.address,
        weth.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
          {token: weth.address, amount: oneEth},
        ]),
        "0x",
        {value: 2n * oneEth},
      ),
    ).to.be.reverted;
  });

  it("transferAndCall2WithValue transfers weth if not send enough value to send to EOA", async () => {
    const {user, weth, usdc, uni, transferAndCall2} = await loadFixture(deployDOSFixture);

    await expect(
      transferAndCall2.transferAndCall2WithValue(
        user.address,
        weth.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
          {token: weth.address, amount: 2n * oneEth},
        ]),
        "0x",
        {value: oneEth},
      ),
    ).to.not.be.reverted;

    expect(await usdc.balanceOf(user.address)).to.equal(tenThousandUsdc);
    expect(await uni.balanceOf(user.address)).to.equal(oneEth);
    expect(await weth.balanceOf(user.address)).to.equal(2n * oneEth);
  });

  it("transferFromAndCall2 can send value to send to contract", async () => {
    const {owner, user, usdc, uni, transferAndCall2, mockReceiver, magicValue} = await loadFixture(
      deployDOSFixture,
    );

    await mockReceiver.mock.onTransferReceived2.returns(magicValue);
    await transferAndCall2.setApprovalForAll(user.address, true);

    await expect(
      transferAndCall2.connect(user).transferFromAndCall2(
        owner.address,
        mockReceiver.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
        ]),
        "0x",
      ),
    ).to.not.be.reverted;

    expect(await usdc.balanceOf(mockReceiver.address)).to.equal(tenThousandUsdc);
    expect(await uni.balanceOf(mockReceiver.address)).to.equal(oneEth);
  });

  it("transferFromAndCall2 reverts if not approved", async () => {
    const {owner, user, usdc, uni, transferAndCall2, mockReceiver, magicValue} = await loadFixture(
      deployDOSFixture,
    );

    await mockReceiver.mock.onTransferReceived2.returns(magicValue);

    await expect(
      transferAndCall2.connect(user).transferFromAndCall2(
        owner.address,
        mockReceiver.address,
        sortTransfers([
          {token: usdc.address, amount: tenThousandUsdc},
          {token: uni.address, amount: oneEth},
        ]),
        "0x",
      ),
    ).to.be.reverted;
  });
});
