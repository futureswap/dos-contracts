import { ethers } from "ethers";
import { Governance, HashNFT } from "../typechain-types";

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

export function makeCall(
  to: ethers.Contract,
  func: string,
  params: any[],
  value?: bigint
) {
  return {
    to: to.address,
    callData: to.interface.encodeFunctionData(func, params),
    value,
  };
}

export async function proposeAndExecute(
  governance: Governance,
  voteNFT: HashNFT,
  calls: Call[]
) {
  const hash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["tuple(address to, bytes callData)[]"],
      [calls]
    )
  );
  const nonce = await voteNFT.mintingNonce();
  await voteNFT.mint(governance.address, hash);
  return governance.execute(nonce, calls);
}
