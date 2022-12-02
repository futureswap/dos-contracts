import { ethers } from "ethers";
import { waffle } from "hardhat";
import { MockContract } from "@ethereum-waffle/mock-contract";
import {
  AggregatorV3Interface__factory,
  DOS__factory,
  ERC20ChainlinkValueOracle__factory,
  Governance,
  GovernanceProxy,
  GovernanceProxy__factory,
  Governance__factory,
  HashNFT,
  HashNFT__factory,
  IAssetValueOracle,
  IERC20,
} from "../typechain-types";
import { toWei } from "./Numbers";

function cleanValue(v: unknown): any {
  if (v === null || v === undefined) throw new Error("Null");
  if (v instanceof ethers.BigNumber) return v.toBigInt();
  if (typeof v !== "object") return v;
  let x: { [key: string]: any } = {};
  Object.entries(v).forEach(([key, value]) => (x[key] = cleanValue(value)));
  return x;
}

export function cleanResult(r: ethers.utils.Result) {
  const x: { [key: string]: any } = {};
  Object.entries(r)
    .slice(r.length)
    .forEach(([key, value]) => {
      if (value) {
        x[key] = cleanValue(value);
        value instanceof ethers.BigNumber ? value.toBigInt() : value;
      }
    });
  return x;
}

interface Call {
  to: string;
  callData: ethers.BytesLike;
  value?: bigint;
}

export function makeCall(to: ethers.Contract, func: string, params: any[], value?: bigint) {
  return {
    to: to.address,
    callData: to.interface.encodeFunctionData(func, params),
    value: value || 0n,
  };
}

export async function proposeAndExecute(governance: Governance, voteNFT: HashNFT, calls: Call[]) {
  const hash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["tuple(address to, bytes callData)[]"], [calls]),
  );
  const nonce = await voteNFT.mintingNonce();
  await voteNFT.mint(governance.address, hash);
  return governance.execute(nonce, calls);
}

export async function deployGovernanceProxy(signer: ethers.Signer) {
  return {
    governanceProxy: await new GovernanceProxy__factory(signer).deploy(),
  };
}

export async function deployGovernance(governanceProxy: GovernanceProxy) {
  const signer = governanceProxy.signer;
  const voteNFT = await new HashNFT__factory(signer).deploy(
    "Voting token",
    "VTOK",
    governanceProxy.address,
  );
  const governance = await new Governance__factory(signer).deploy(
    governanceProxy.address,
    voteNFT.address,
    await signer.getAddress(),
  );
  await governanceProxy.execute([
    makeCall(governanceProxy, "proposeGovernance", [governance.address]),
  ]);
  // Empty execute such that governance accepts the governance role of the
  // governance proxy.
  await proposeAndExecute(governance, voteNFT, []);

  return { voteNFT, governance };
}

export class Chainlink {
  public readonly chainlink: MockContract;
  public readonly assetOracle: IAssetValueOracle;
  public readonly chainlinkDecimals: number;

  static async deploy(
    signer: ethers.Signer,
    price: number,
    chainLinkDecimals: number,
    baseTokenDecimals: number,
    assetTokenDecimals: number,
  ) {
    const mockChainLink = await waffle.deployMockContract(
      signer,
      AggregatorV3Interface__factory.abi,
    );
    await mockChainLink.mock.decimals.returns(chainLinkDecimals);
    const assetOracle = await new ERC20ChainlinkValueOracle__factory(signer).deploy(
      mockChainLink.address,
      baseTokenDecimals,
      assetTokenDecimals,
    );
    const x = new Chainlink(mockChainLink, assetOracle, chainLinkDecimals);
    await x.setPrice(price);
    return x;
  }

  private constructor(
    mockChainlink: MockContract,
    assetOracle: IAssetValueOracle,
    chainlinkDecimals: number,
  ) {
    this.chainlink = mockChainlink;
    this.assetOracle = assetOracle;
    this.chainlinkDecimals = chainlinkDecimals;
  }

  async setPrice(price: number) {
    return this.chainlink.mock.latestRoundData.returns(
      0,
      toWei(price, this.chainlinkDecimals),
      0,
      0,
      0,
    );
  }
}
