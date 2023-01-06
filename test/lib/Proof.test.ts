import type {Proof} from "merkle-patricia-tree/dist/baseTrie";

import {loadFixture} from "@nomicfoundation/hardhat-network-helpers";
import {expect} from "chai";
import {ethers} from "ethers";
import {ethers as hEthers} from "hardhat";
import {BaseTrie as MPT} from "merkle-patricia-tree";

import {TestTrie__factory} from "../../typechain-types";

const encodeProof = (proof: Proof): string => {
  return ethers.utils.RLP.encode(proof.map(item => ethers.utils.RLP.decode(item) as unknown));
};

describe("Proof", () => {
  const setupProof = async () => {
    const [owner] = await hEthers.getSigners();

    const trieLib = await new TestTrie__factory(owner).deploy();

    return {trieLib};
  };

  it("Can proof exclusion of empty trie", async () => {
    const {trieLib} = await loadFixture(setupProof);

    const trie = new MPT();

    const proof = await MPT.createProof(trie, Buffer.from("key"));
    expect(await trieLib.verify(Buffer.from("key"), trie.root, encodeProof(proof))).to.equal("0x");
  });

  it("Can proof exclusion of non-empty trie", async () => {
    const {trieLib} = await loadFixture(setupProof);

    const trie = new MPT();
    await trie.put(Buffer.from("a"), Buffer.from("value"));

    const proof = await MPT.createProof(trie, Buffer.from("key"));
    expect(await trieLib.verify(Buffer.from("key"), trie.root, encodeProof(proof))).to.equal("0x");
  });

  it("Can proof inclusion of non-empty trie", async () => {
    const {trieLib} = await loadFixture(setupProof);

    const trie = new MPT();
    await trie.put(Buffer.from("key"), Buffer.from("value"));

    const key = Buffer.from("key");
    const proof = await MPT.createProof(trie, key);
    expect(await trieLib.verify(key, trie.root, encodeProof(proof))).to.equal(
      ethers.utils.hexlify(Buffer.from("value")),
    );
  });

  it("Can proof exclusion of non-empty trie when prefix of key", async () => {
    const {trieLib} = await loadFixture(setupProof);

    const trie = new MPT();
    await trie.put(Buffer.from("key"), Buffer.from("value"));

    const key = Buffer.from("ke");
    const proof = await MPT.createProof(trie, key);
    expect(await trieLib.verify(key, trie.root, encodeProof(proof))).to.equal("0x");
  });

  it("Can proof exclusion of non-empty trie when key extends key in trie", async () => {
    const {trieLib} = await loadFixture(setupProof);

    const trie = new MPT();
    await trie.put(Buffer.from("key"), Buffer.from("value"));

    const key = Buffer.from("key2");
    const proof = await MPT.createProof(trie, key);
    expect(await trieLib.verify(key, trie.root, encodeProof(proof))).to.equal("0x");
  });

  it("Can proof exclusion when ending on branch node", async () => {
    const {trieLib} = await loadFixture(setupProof);

    const trie = new MPT();
    await trie.put(Buffer.from("ab"), Buffer.from("value"));
    await trie.put(Buffer.from("az"), Buffer.from("value"));

    const key = Buffer.from("a");
    const proof = await MPT.createProof(trie, key);
    expect(await trieLib.verify(key, trie.root, encodeProof(proof))).to.equal("0x");
  });

  it("Can proof exclusion when missing a branch", async () => {
    const {trieLib} = await loadFixture(setupProof);

    const trie = new MPT();
    await trie.put(Buffer.from("ab"), Buffer.from("value"));
    await trie.put(Buffer.from("az"), Buffer.from("value"));

    const key = Buffer.from("aa");
    const proof = await MPT.createProof(trie, key);
    expect(await trieLib.verify(key, trie.root, encodeProof(proof))).to.equal("0x");
  });

  it("Can proof exclusion when missing a branch", async () => {
    const {trieLib} = await loadFixture(setupProof);

    const trie = new MPT();
    await trie.put(Buffer.from("ab"), Buffer.from("value"));
    await trie.put(Buffer.from("az"), Buffer.from("value"));

    const key = Buffer.from("aa");
    const proof = await MPT.createProof(trie, key);
    expect(await trieLib.verify(key, trie.root, encodeProof(proof))).to.equal("0x");
  });
});
