import {ethers} from "ethers";
import {Governance, HashNFT, PortfolioLogic__factory, DOS} from "../typechain-types";
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
  calls.forEach(call => {
    if (call.value !== undefined && call.value !== 0n) throw new Error("Value not supported");
  });
  const hash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["tuple(address to, bytes callData)[]"], [calls]),
  );
  const nonce = await voteNFT.mintingNonce();
  await voteNFT.mint(governance.address, hash);
  return governance.execute(nonce, calls);
}

export const createPortfolio = async (dos: DOS, signer: ethers.Signer) => {
  const {portfolio} = await getEventParams(
    await dos.connect(signer).createPortfolio(),
    dos,
    "PortfolioCreated",
  );
  return PortfolioLogic__factory.connect(portfolio as string, signer);
};
