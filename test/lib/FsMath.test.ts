/* eslint-disable no-await-in-loop */

import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";
import {ethers} from "ethers";
import {ethers as hEthers} from "hardhat";

import {TestFsMath__factory} from "../../typechain-types";

const approxExpect = (fp: ethers.BigNumber, expected: number) => {
  const x = Number(fp.toBigInt()) / 2 ** 64;
  // console.log({x, expected});
  if (expected < 1e-10) {
    expect(x).to.be.closeTo(0, 0.0000000000001);
  } else {
    expect(x / expected).to.be.closeTo(1, 0.0000000000001);
  }
};

describe("FSMath", () => {
  const setupFsMath = async () => {
    const [owner] = await hEthers.getSigners();

    const fsMath = await new TestFsMath__factory(owner).deploy();

    return {fsMath};
  };

  it("sign", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    expect(await fsMath.sign(2)).to.equal(1);
    expect(await fsMath.sign(-2)).to.equal(-1);
    expect(await fsMath.sign(0)).to.equal(0);
  });

  it("abs", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    expect(await fsMath.abs(1)).to.equal(1);
    expect(await fsMath.abs(-1)).to.equal(1);
    expect(await fsMath.abs(0)).to.equal(0);
  });

  it("min", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    expect(await fsMath.min(1, 2)).to.equal(1);
    expect(await fsMath.min(4, 3)).to.equal(3);
    expect(await fsMath.min(2, 2)).to.equal(2);
  });

  it("max", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    expect(await fsMath.max(1, 2)).to.equal(2);
    expect(await fsMath.max(4, 3)).to.equal(4);
    expect(await fsMath.max(2, 2)).to.equal(2);
  });

  it("clip", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    expect(await fsMath.clip(1, 2, 4)).to.equal(2);
    expect(await fsMath.clip(3, 2, 4)).to.equal(3);
    expect(await fsMath.clip(5, 2, 4)).to.equal(4);
  });

  it("safeCast", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    expect(await fsMath.safeCastToUnsigned(0)).to.equal(0);
    expect(await fsMath.safeCastToUnsigned(1)).to.equal(1);
    await expect(fsMath.safeCastToUnsigned(-1)).to.revertedWith("underflow");

    expect(await fsMath.safeCastToSigned(0)).to.equal(0);
    expect(await fsMath.safeCastToSigned(1)).to.equal(1);
    const twoPow255 = 2n ** 255n;
    expect(await fsMath.safeCastToSigned((twoPow255 - 1n).toString())).to.equal(
      (twoPow255 - 1n).toString(),
    );
    await expect(fsMath.safeCastToSigned(twoPow255.toString())).to.revertedWith("overflow");
  });

  it("exp", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    const FB = 2 ** 64;
    for (let i = -10; i < 10; i += 0.1) {
      approxExpect(await fsMath.exp(BigInt(i * FB)), Math.exp(i));
    }
  });

  it("sqrt", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    const FB = 2 ** 64;
    for (let i = 0; i < 2; i += 0.1) {
      approxExpect(await fsMath.sqrt(BigInt(i * FB)), Math.sqrt(i));
    }
    for (let i = 2; i < 20; i++) {
      approxExpect(await fsMath.sqrt(BigInt(i * FB)), Math.sqrt(i));
    }
  });

  it("bitCount", async () => {
    const {fsMath} = await loadFixture(setupFsMath);
    expect(await fsMath.bitCount(0)).to.equal(0);
    for (let i = 0; i < 256; i++) {
      const n = (BigInt(i) * ethers.constants.MaxUint256.toBigInt()) / 255n;
      let count = 0;
      for (let j = 0; j < 256; j++) {
        if (n & (1n << BigInt(j))) count++;
      }
      expect(await fsMath.bitCount(n)).to.equal(count);
    }
  });
});
