import type {
  Governance,
  HashNFT,
  IDOS,
  DSafeLogic,
  TransferAndCall2,
  IERC20,
  ISwapRouter,
} from "../typechain-types";
import type {ContractTransaction} from "ethers";
import type {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";

import {ethers} from "ethers";

import {DSafeLogic__factory} from "../typechain-types";
import {getEventParams} from "./events";
import {signOnTransferReceived2Call} from "./signers";

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

export const createDSafe = async (dos: IDOS, signer: ethers.Signer): Promise<DSafeLogic> => {
  const {dSafe} = await getEventParams(
    await dos.connect(signer).createDSafe(),
    dos,
    "DSafeCreated",
  );
  return DSafeLogic__factory.connect(dSafe as string, signer);
};

export const sortTransfers = (
  transfers: {token: string; amount: bigint}[],
): {token: string; amount: bigint}[] => {
  return transfers
    .sort((a, b) => {
      const diff = BigInt(a.token) - BigInt(b.token);
      return diff > 0 ? 1 : diff < 0 ? -1 : 0;
    })
    .map(({token, amount}) => ({token, amount: ethers.BigNumber.from(amount).toBigInt()}));
};

const updateTransfers = (
  transfers: {token: string; amount: bigint}[],
  weth: string,
  value: bigint,
) => {
  for (const tfer of transfers) {
    if (tfer.token == weth) {
      tfer.amount += value;
      return;
    }
  }
  transfers.push({token: weth, amount: value});
};

export const depositIntoSafe = async (
  transferAndCall2: TransferAndCall2,
  safe: DSafeLogic,
  transfers: {token: string; amount: bigint}[],
  value?: {weth: string; amount: bigint},
): Promise<ethers.ContractTransaction> => {
  if (value && value.amount > 0n) {
    updateTransfers(transfers, value.weth, value.amount);
    return await transferAndCall2.transferAndCall2WithValue(
      safe.address,
      value.weth,
      sortTransfers(transfers),
      "0x",
      {value: value.amount},
    );
  } else {
    return await transferAndCall2.transferAndCall2(safe.address, sortTransfers(transfers), "0x");
  }
};

export const depositIntoDos = async (
  transferAndCall2: TransferAndCall2,
  safe: DSafeLogic,
  transfers: {token: string; amount: bigint}[],
  value?: {weth: string; amount: bigint},
): Promise<ethers.ContractTransaction> => {
  if (value && value.amount > 0n) {
    updateTransfers(transfers, value.weth, value.amount);
    return await transferAndCall2.transferAndCall2WithValue(
      safe.address,
      value.weth,
      sortTransfers(transfers),
      "0x01",
      {value: value.amount},
    );
  } else {
    return await transferAndCall2.transferAndCall2(safe.address, sortTransfers(transfers), "0x01");
  }
};

export const depositIntoSafeAndCall = async (
  transferAndCall2: TransferAndCall2,
  safe: DSafeLogic,
  transfers: {token: string; amount: bigint}[],
  calls: Call[],
  nonce: number,
  value?: {weth: string; amount: bigint},
): Promise<ethers.ContractTransaction> => {
  if (value && value.amount > 0n) {
    updateTransfers(transfers, value.weth, value.amount);
  }
  const sortedTransfers = sortTransfers(transfers);
  const fromAddress = await transferAndCall2.signer.getAddress();
  const signedCall = {
    operator: fromAddress,
    from: fromAddress,
    transfers: sortedTransfers,
    calls,
  };

  const signedData = await signOnTransferReceived2Call(
    safe,
    signedCall,
    nonce,
    safe.signer as SignerWithAddress,
  );
  const data = `0x02${signedData.slice(2)}`;

  if (value && value.amount > 0n) {
    return await transferAndCall2.transferAndCall2WithValue(
      safe.address,
      value.weth,
      sortedTransfers,
      data,
      {value: value.amount},
    );
  } else {
    return await transferAndCall2.transferAndCall2(safe.address, sortedTransfers, data);
  }
};

export const leverageLP = (
  dos: IDOS,
  token0: IERC20,
  token1: IERC20,
  uniswapNFTManager: ethers.Contract,
  mintParams: any,
  tokenId: number,
): Call[] => {
  if (BigInt(token0.address) >= BigInt(token1.address))
    throw new Error("Token0 must be smaller than token1");
  return [
    makeCall(token0, "approve", [uniswapNFTManager.address, ethers.constants.MaxUint256]),
    makeCall(token1, "approve", [uniswapNFTManager.address, ethers.constants.MaxUint256]),
    makeCall(uniswapNFTManager, "setApprovalForAll", [dos.address, true]),
    makeCall(dos, "depositERC20", [token0.address, -mintParams.amount0Desired]),
    makeCall(dos, "depositERC20", [token1.address, -mintParams.amount1Desired]),
    makeCall(uniswapNFTManager, "mint", [mintParams]),
    makeCall(dos, "depositNFT", [uniswapNFTManager.address, tokenId]),
    makeCall(dos, "depositFull", [[token0.address, token1.address]]),
  ];
};

export const leveragePos = (
  dSafe: DSafeLogic,
  dos: IDOS,
  tokenIn: IERC20,
  tokenOut: IERC20,
  fee: number,
  swapRouter: ISwapRouter,
  amount: bigint,
): Call[] => {
  const exactInputSingleParams: ISwapRouter.ExactInputSingleParamsStruct = {
    tokenIn: tokenIn.address,
    tokenOut: tokenOut.address,
    fee,
    recipient: dSafe.address,
    deadline: ethers.constants.MaxUint256,
    amountIn: amount,
    amountOutMinimum: 0,
    sqrtPriceLimitX96: 0,
  };

  return [
    makeCall(dos, "depositERC20", [tokenIn.address, -amount]),
    makeCall(tokenIn, "approve", [swapRouter.address, ethers.constants.MaxUint256]),
    makeCall(swapRouter, "exactInputSingle", [exactInputSingleParams]),
    makeCall(dos, "depositFull", [[tokenIn.address, tokenOut.address]]),
  ];
};
