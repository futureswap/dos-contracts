import type {BigNumberish, ContractTransaction} from "ethers";
import type {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import type {
  Governance,
  HashNFT,
  Supa,
  ISupa,
  WalletLogic,
  TransferAndCall2,
  IERC20,
  ISwapRouter,
  MockNFTOracle,
  TestERC20,
  TestNFT,
  WETH9,
} from "../typechain-types";

import {BigNumber, ethers} from "ethers";

import {
  IUniswapV3Pool__factory,
  IUniswapV3Factory__factory,
  WalletLogic__factory,
} from "../typechain-types";
import {getEventsTx, getEventParams} from "./events";
import {toWeiUsdc} from "./numbers";
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

// filters Obj by keys that are functions. E.g.
// OnlyFunctions<{x: number: foo: () => number}> -> {foo: () => number}
type OnlyFunctions<Obj> = string &
  keyof {
    [prop in keyof Obj]: Obj[prop] extends (...args: unknown[]) => unknown ? Obj[prop] : never;
  };

// changes the return type of Func to NewReturn. E.g.
// SetReturnType<(x: number) => number, string> -> (x: number) => string
type SetReturnType<Func extends (...args: unknown[]) => unknown, NewReturn> = (
  ...args: Parameters<Func>
) => NewReturn;

// returns an object with methods of Contract. Return value of each method is changed to Call.
// So instead of calling a method of the Contract it would return call parameters that can be sent
// to Supa.executeBatch([...]) or GovernanceProxy.execute(...)
type WrappedContract<Contract extends ethers.Contract> = {
  [key in OnlyFunctions<Contract["functions"]>]: SetReturnType<Contract[key], Call>;
};

export function makeCall<Contract extends ethers.Contract>(
  to: Contract,
  value?: BigNumberish,
): WrappedContract<Contract> {
  const funcKeys = Object.entries(to.functions).map(([key]) => key);

  /* eslint-disable -- embedded types for fromEntries are not expressive enough to express this */
  return Object.fromEntries(
    funcKeys.map(funcKey => [
      funcKey,
      (...args: unknown[]): Call => ({
        to: to.address,
        callData: to.interface.encodeFunctionData(funcKey, args),
        value: BigNumber.from(value ?? 0).toBigInt(),
      }),
    ]),
  ) as any;
  /* eslint-enable */
}

type WrappedContract2<Contract extends ethers.Contract> = {
  [key in OnlyFunctions<Contract["functions"]>]: [string, string];
};

export function getSelector<Contract extends ethers.Contract>(
  to: Contract,
): WrappedContract2<Contract> {
  const funcKeys = Object.entries(to.functions).map(([key]) => key);

  /* eslint-disable -- embedded types for fromEntries are not expressive enough to express this */
  return Object.fromEntries(
    funcKeys.map(funcKey => [
      funcKey,
      [to.address, to.interface.getSighash(to.interface.getFunction(funcKey))],
    ]),
  ) as any;
  /* eslint-enable */
}

export const hashCallWithoutValue = ({
  to,
  callData,
}: {
  to: string;
  callData: ethers.BytesLike;
}): string => {
  const typeHash = ethers.utils.keccak256(
    ethers.utils.toUtf8Bytes("CallWithoutValue(address to,bytes callData)"),
  );
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "address", "bytes32"],
      [typeHash, to, ethers.utils.keccak256(callData)],
    ),
  );
};

export const hashCallWithoutValueArray = (
  calls: {to: string; callData: ethers.BytesLike}[],
): string => {
  return ethers.utils.keccak256(ethers.utils.concat(calls.map(hashCallWithoutValue)));
};

export async function proposeAndExecute(
  governance: Governance,
  voteNFT: HashNFT,
  calls: Call[],
): Promise<ContractTransaction> {
  if (calls.some(({value}) => value != 0n)) throw new Error("Value cannot be positive");
  await voteNFT.mint(governance.address, hashCallWithoutValueArray(calls), "0x");
  return await governance.executeBatch(calls);
}

export const createWallet = async (supa: ISupa, signer: ethers.Signer): Promise<WalletLogic> => {
  const {wallet} = await getEventParams(
    await supa.connect(signer).createWallet(),
    supa,
    "WalletCreated",
  );
  return WalletLogic__factory.connect(wallet as string, signer);
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

export const depositIntoWallet = async (
  transferAndCall2: TransferAndCall2,
  safe: WalletLogic,
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

export const depositIntoSupa = async (
  transferAndCall2: TransferAndCall2,
  safe: WalletLogic,
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

export const depositIntoWalletAndCall = async (
  transferAndCall2: TransferAndCall2,
  safe: WalletLogic,
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

type NonFungiblePositionManagerTypes = {
  // taken from node_modules/@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol:MintParams
  mintParams: {
    token0: string;
    token1: string;
    fee: number;
    tickLower: number;
    tickUpper: number;
    amount0Desired: BigNumberish;
    amount1Desired: BigNumberish;
    amount0Min: BigNumberish;
    amount1Min: BigNumberish;
    recipient: string;
    deadline: BigNumberish;
  };
};

export const leverageLP = (
  supa: ISupa,
  token0: IERC20,
  token1: IERC20,
  nonFungiblePositionManager: ethers.Contract,
  mintParams: NonFungiblePositionManagerTypes["mintParams"],
  tokenId: number,
): Call[] => {
  if (BigInt(token0.address) >= BigInt(token1.address))
    throw new Error("Token0 must be smaller than token1");

  return [
    makeCall(token0).approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256),
    makeCall(token1).approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256),
    makeCall(nonFungiblePositionManager).setApprovalForAll(supa.address, true),
    makeCall(supa).withdrawERC20(token0.address, mintParams.amount0Desired),
    makeCall(supa).withdrawERC20(token1.address, mintParams.amount1Desired),
    makeCall(nonFungiblePositionManager).mint(mintParams),
    makeCall(supa).depositERC721(nonFungiblePositionManager.address, tokenId),
    makeCall(supa).depositFull([token0.address, token1.address]),
  ];
};

export const leverageLP2 = async (
  wallet: WalletLogic,
  supa: ISupa,
  nonFungiblePositionManager: ethers.Contract,
  {token0, token1, fee}: {token0: IERC20; token1: IERC20; fee: number},
  lowerPrice: number,
  upperPrice: number,
  amount0Desired: bigint,
  amount1Desired: bigint,
  recipient: string,
): Promise<Call[]> => {
  if (BigInt(token0.address) >= BigInt(token1.address))
    throw new Error("Token0 must be smaller than token1");

  const pool = {
    token0: token0.address,
    token1: token1.address,
    fee,
  };
  /* eslint-disable @typescript-eslint/no-unsafe-call */
  const factoryAddress = (await nonFungiblePositionManager.factory()) as string;
  /* eslint-enable @typescript-eslint/no-unsafe-call */

  const uniswapV3Factory = IUniswapV3Factory__factory.connect(
    factoryAddress,
    nonFungiblePositionManager.signer,
  );
  const poolAddress = await uniswapV3Factory.getPool(pool.token0, pool.token1, pool.fee);
  const uniswapV3Pool = IUniswapV3Pool__factory.connect(
    poolAddress,
    nonFungiblePositionManager.signer,
  );
  const tickSpacing = await uniswapV3Pool.tickSpacing();

  const mintParams = computeMintParams(
    lowerPrice,
    upperPrice,
    pool,
    amount0Desired,
    amount1Desired,
    recipient,
    tickSpacing,
  );

  return [
    makeCall(token0).approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256), // tODO: remove
    makeCall(token1).approve(nonFungiblePositionManager.address, ethers.constants.MaxUint256),
    //    makeCall(nonFungiblePositionManager).setApprovalForAll(supa.address, true),
    makeCall(supa).withdrawERC20(token0.address, mintParams.amount0Desired),
    makeCall(supa).withdrawERC20(token1.address, mintParams.amount1Desired),
    makeCall(wallet).forwardNFTs(true),
    makeCall(nonFungiblePositionManager).mint(mintParams),
    makeCall(supa).depositFull([token0.address, token1.address]),
  ];
};

export const leveragePos = (
  wallet: WalletLogic,
  supa: ISupa,
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
    recipient: wallet.address,
    deadline: ethers.constants.MaxUint256,
    amountIn: amount,
    amountOutMinimum: 0,
    sqrtPriceLimitX96: 0,
  };

  return [
    makeCall(supa).withdrawERC20(tokenIn.address, amount),
    makeCall(tokenIn).approve(swapRouter.address, ethers.constants.MaxUint256),
    makeCall(swapRouter).exactInputSingle(exactInputSingleParams),
    makeCall(supa).depositFull([tokenIn.address, tokenOut.address]),
  ];
};

export const computeMintParams = (
  lowerPrice: number,
  upperPrice: number,
  pool: {token0: string; token1: string; fee: number},
  amount0Desired: bigint,
  amount1Desired: bigint,
  recipient: string,
  tickSpacing: number,
): NonFungiblePositionManagerTypes["mintParams"] => {
  const tickBase = 1.0001;
  const tickLower =
    Math.floor(Math.log(lowerPrice) / Math.log(tickBase) / tickSpacing) * tickSpacing;
  const tickUpper =
    Math.floor(Math.log(upperPrice) / Math.log(tickBase) / tickSpacing) * tickSpacing;
  return {
    ...pool,
    tickLower,
    tickUpper,
    amount0Desired,
    amount1Desired,
    amount0Min: 0,
    amount1Min: 0,
    recipient,
    deadline: ethers.constants.MaxUint256,
  };
};

export const provideLiquidity = async (
  nonFungiblePositionManager: ethers.Contract,
  lowerPrice: number,
  upperPrice: number,
  pool: {token0: string; token1: string; fee: number},
  amount0Desired: bigint,
  amount1Desired: bigint,
  recipient: string,
): Promise<{
  tokenId: bigint;
  liquidity: bigint;
  amount0: bigint;
  amount1: bigint;
}> => {
  /* eslint-disable @typescript-eslint/no-unsafe-call */
  const factoryAddress = (await nonFungiblePositionManager.factory()) as string;
  /* eslint-enable @typescript-eslint/no-unsafe-call */
  const uniswapV3Factory = IUniswapV3Factory__factory.connect(
    factoryAddress,
    nonFungiblePositionManager.signer,
  );
  const poolAddress = await uniswapV3Factory.getPool(pool.token0, pool.token1, pool.fee);
  const uniswapV3Pool = IUniswapV3Pool__factory.connect(
    poolAddress,
    nonFungiblePositionManager.signer,
  );
  const tickSpacing = await uniswapV3Pool.tickSpacing();
  /* eslint-disable */
  const {IncreaseLiquidity} = await getEventsTx(
    await nonFungiblePositionManager.mint(
      computeMintParams(
        lowerPrice,
        upperPrice,
        pool,
        amount0Desired,
        amount1Desired,
        recipient,
        tickSpacing,
      ),
    ),
    nonFungiblePositionManager,
  );
  return IncreaseLiquidity as any;
  /* eslint-enable */
};

export async function depositERC20(
  supa: ISupa,
  wallet: WalletLogic,
  erc20: TestERC20 | WETH9,
  amount: number | bigint,
): Promise<void> {
  await erc20.mint(wallet.address, amount);

  const depositTx = await wallet.executeBatch([makeCall(supa).depositERC20(erc20.address, amount)]);
  await depositTx.wait();
}

export async function depositERC721(
  supa: ISupa,
  wallet: WalletLogic,
  nft: TestNFT,
  priceOracle: MockNFTOracle,
  price: number,
): Promise<BigNumber> {
  const mintTx = await nft.mint(wallet.address);
  const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
  const tokenId = mintEventArgs[0] as BigNumber;
  await priceOracle.setPrice(tokenId, toWeiUsdc(price));
  const depositERC721Tx = await wallet.executeBatch([
    makeCall(nft).approve(supa.address, tokenId),
    makeCall(supa).depositERC721(nft.address, tokenId),
  ]);
  await depositERC721Tx.wait();
  return tokenId;
}

// special case of depositERC721 function above.
// Used only in one test to show that this scenario is supported.
// In depositERC721 the NFT is minted to the wallet and transferred from the wallet to Supa.
// In depositUserNft, nft is minted to the user and transferred from the user to Supa
export async function depositUserNft(
  supa: ISupa,
  wallet: WalletLogic,
  nft: TestNFT,
  priceOracle: MockNFTOracle,
  price: number,
): Promise<BigNumber> {
  const user = wallet.signer;
  const mintTx = await nft.mint(await user.getAddress());
  const mintEventArgs = await getEventParams(mintTx, nft, "Mint");
  const tokenId = mintEventArgs[0] as BigNumber;
  await priceOracle.setPrice(tokenId, toWeiUsdc(price));
  await (await nft.connect(user).approve(supa.address, tokenId)).wait();
  const depositERC721Tx = await wallet.executeBatch([
    makeCall(supa).depositERC721(nft.address, tokenId),
  ]);
  await depositERC721Tx.wait();
  return tokenId;
}

export async function transfer(
  supa: ISupa,
  from: WalletLogic,
  to: WalletLogic,
  ...value: [erc20: string, amount: BigNumberish] | [nft: TestNFT, tokenId: BigNumberish]
): Promise<ContractTransaction> {
  if (typeof value[0] == "string") {
    // transfer erc20
    const [erc20, amount] = value;
    return await from.executeBatch([makeCall(supa).transferERC20(erc20, to.address, amount)]);
  } else {
    // transfer NFT
    const [nft, tokenId] = value;
    return await from.executeBatch([
      makeCall(supa).transferERC721(nft.address, tokenId, to.address),
    ]);
  }
}

/*
export async function approveErc20(
  supa: ISupa,
  owner: WalletLogic,
  spender: WalletLogic,
  erc20: string,
  amount: BigNumberish,
): Promise<ContractTransaction> {
  return await owner.executeBatch([makeCall(supa).approveERC20(erc20, spender.address, amount)]);
}

export async function approveERC721(
  supa: ISupa,
  owner: WalletLogic,
  spender: WalletLogic,
  nft: string,
  tokenId: BigNumber,
): Promise<ContractTransaction> {
  return await owner.executeBatch([makeCall(supa).approveERC721(nft, spender.address, tokenId)]);
}
*/

export async function transferFromErc20(
  supa: ISupa,
  spender: WalletLogic,
  owner: WalletLogic,
  to: WalletLogic,
  erc20: string,
  amount: BigNumberish,
): Promise<ContractTransaction> {
  return await spender.executeBatch([
    makeCall(supa).transferFromERC20(erc20, owner.address, to.address, amount),
  ]);
}

export async function transferFromERC721(
  supa: ISupa,
  spender: WalletLogic,
  owner: WalletLogic,
  to: WalletLogic,
  nft: string,
  tokenId: BigNumber,
): Promise<ContractTransaction> {
  return await spender.executeBatch([
    makeCall(supa).transferFromERC721(nft, owner.address, to.address, tokenId),
  ]);
}

export async function getMaximumWithdrawableOfERC20(supa: Supa, erc20: string): Promise<BigNumber> {
  const {fractionalReserveLeverage: leverage} = await supa.config();
  const {idx: erc20Idx} = await supa.infoIdx(erc20);
  const erc20Info = await supa.erc20Infos(erc20Idx);
  const {tokens} = erc20Info.collateral;
  const {tokens: totalDebt} = erc20Info.debt;
  const minReserveAmount = tokens.div(leverage.add(1));
  const borrowable = tokens.sub(minReserveAmount);
  const remainingERC20ToBorrow = borrowable.add(totalDebt);
  return remainingERC20ToBorrow;
}

export async function upgradeWalletImplementation(
  supa: ISupa,
  wallet: WalletLogic,
  version: string,
): Promise<void> {
  const upgradeTx = await wallet.executeBatch([
    makeCall(supa).upgradeWalletImplementation(version),
  ]);
  await upgradeTx.wait();
}

export async function proposeTransferWalletOwnership(
  supa: ISupa,
  wallet: WalletLogic,
  newOwner: string,
): Promise<ContractTransaction> {
  return await wallet.executeBatch([makeCall(supa).proposeTransferWalletOwnership(newOwner)]);
}
