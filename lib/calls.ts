import type {Governance, HashNFT, DOS, DSafeLogic} from "../typechain-types";
import type {ContractTransaction} from "ethers";

import {ethers} from "ethers";

import {DSafeLogic__factory} from "../typechain-types";
import {getEventParams} from "./events";

function cleanValue(v: unknown): unknown {
  if (v == null) throw new Error("Null");
  if (v instanceof ethers.BigNumber) return v.toBigInt();
  if (typeof v !== "object") return v;
  const x: Record<string, unknown> = {};
  Object.entries(v).forEach(([key, value]) => (x[key] = cleanValue(value)));
  return x;
}

export function cleanResult(r: ethers.utils.Result): Record<string, unknown> {
  const x: Record<string, unknown> = {};
  Object.entries(r)
    .slice(r.length)
    .forEach(([key, value]) => {
      if (value != null) {
        x[key] = cleanValue(value);
      }
    });
  return x;
}

export type Call = {
  to: string;
  callData: ethers.BytesLike;
  value: bigint;
};

export function makeCall(
  to: ethers.Contract,
  func: string,
  params: unknown[],
  value?: bigint,
): Call {
  return {
    to: to.address,
    callData: to.interface.encodeFunctionData(func, params),
    value: value ?? 0n,
  };
}

export async function proposeAndExecute(
  governance: Governance,
  voteNFT: HashNFT,
  calls: Call[],
): Promise<ContractTransaction> {
  if (calls.some(({value}) => value != 0n)) throw new Error("Value cannot be positive");
  const hash = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["tuple(address to, bytes callData)[]"], [calls]),
  );
  const nonce = await voteNFT.mintingNonce();
  await voteNFT.mint(governance.address, hash);
  return await governance.execute(nonce, calls);
}

export const createDSafe = async (dos: DOS, signer: ethers.Signer): Promise<DSafeLogic> => {
  const {dSafe} = await getEventParams(
    await dos.connect(signer).createDSafe(),
    dos,
    "DSafeCreated",
  );
  return DSafeLogic__factory.connect(dSafe as string, signer);
};

export const sortTransfers = (
  transfers: {token: string; amount: ethers.BigNumberish}[],
): {token: string; amount: ethers.BigNumberish}[] => {
  return transfers.sort((a, b) => {
    const diff = BigInt(a.token) - BigInt(b.token);
    return diff > 0 ? 1 : diff < 0 ? -1 : 0;
  });
};
