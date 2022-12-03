import {ethers} from "ethers";
import {waffle} from "hardhat";
import {MockContract} from "@ethereum-waffle/mock-contract";
import {
  AggregatorV3Interface__factory,
  ERC20ChainlinkValueOracle__factory,
  Governance,
  GovernanceProxy,
  GovernanceProxy__factory,
  Governance__factory,
  HashNFT,
  HashNFT__factory,
  IERC20ValueOracle,
  PortfolioLogic__factory,
  DOS,
} from "../typechain-types";
import {toWei} from "./Numbers";
import {getEventParams} from "./Events";

function cleanValue(v: unknown): any {
  if (v === null || v === undefined) throw new Error("Null");
  if (v instanceof ethers.BigNumber) return v.toBigInt();
  if (typeof v !== "object") return v;
  let x: {[key: string]: any} = {};
  Object.entries(v).forEach(([key, value]) => (x[key] = cleanValue(value)));
  return x;
}

export function cleanResult(r: ethers.utils.Result) {
  const x: {[key: string]: any} = {};
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

  return {voteNFT, governance};
}

export class Chainlink {
  static async deploy(
    signer: ethers.Signer,
    price: number,
    chainLinkDecimals: number,
    baseTokenDecimals: number,
    observedTokenDecimals: number,
  ) {
    const mockChainLink = await waffle.deployMockContract(
      signer,
      AggregatorV3Interface__factory.abi,
    );
    await mockChainLink.mock.decimals.returns(chainLinkDecimals);
    const erc20Oracle = await new ERC20ChainlinkValueOracle__factory(signer).deploy(
      mockChainLink.address,
      baseTokenDecimals,
      observedTokenDecimals,
    );
    const oracle = new Chainlink(mockChainLink, erc20Oracle, chainLinkDecimals);
    await oracle.setPrice(price);
    return oracle;
  }

  private constructor(
    public readonly chainlink: MockContract,
    public readonly oracle: IERC20ValueOracle,
    public readonly chainlinkDecimals: number,
  ) {}

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

export const createPortfolio = async (dos: DOS, signer: ethers.Signer) => {
  const {portfolio} = await getEventParams(
    await dos.connect(signer).createPortfolio(),
    dos,
    "PortfolioCreated",
  );
  return PortfolioLogic__factory.connect(portfolio as string, signer);
};
