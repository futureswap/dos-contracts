import type {IPermit2, DSafeLogic, OffchainEntityProxy} from "../typechain-types";
import type {Call} from "./calls";
import type {TypedDataSigner} from "@ethersproject/abstract-signer";

import {ethers} from "ethers";

import {checkDefined} from "./preconditions";

const basicTypes = [
  "address",
  "bool",
  "bytes",
  "string",
  "uint8",
  "uint16",
  "uint32",
  "uint64",
  "uint128",
  "uint256",
  "int8",
  "int16",
  "int32",
  "int64",
  "int128",
  "int256",
  "bytes1",
  "bytes2",
  "bytes4",
  "bytes8",
  "bytes16",
  "bytes32",
];

const getStructName = (name: string, type: ethers.TypedDataField[]) => {
  return `${name}(${type.map(({name, type}) => `${type} ${name}`).join(",")})`;
};

// helper function to generate error prone typed data strings
export const generateTypedDataString = (
  types: Record<string, ethers.TypedDataField[]>,
): Record<string, string> => {
  const visit = (typeName: string, visited: Set<string>) => {
    while (typeName.endsWith("[]")) typeName = typeName.slice(0, -2);
    if (visited.has(typeName)) return;
    if (basicTypes.includes(typeName)) return;
    visited.add(typeName);
    const fields = checkDefined(types[typeName], `type ${typeName} not found`);
    fields.forEach(({type}) => visit(type, visited));
  };
  const l = Object.entries(types).map(([typeName]) => {
    const visited = new Set<string>();
    visit(typeName, visited);
    visited.delete(typeName);
    const deps = Array.from(visited.values()).sort();
    return [
      typeName,
      [typeName, ...deps].map(type => getStructName(type, types[type])).join(""),
    ] as [string, string];
  });
  return Object.fromEntries(l);
};

const dSafeDomain = async (dSafe: DSafeLogic) => {
  return {
    name: "DOS dSafe",
    version: "1.0.0",
    chainId: (await dSafe.provider.getNetwork()).chainId,
    verifyingContract: dSafe.address,
  };
};

export const signExecuteBatch = async (
  dSafe: DSafeLogic,
  calls: Call[],
  nonce: number,
  deadline: bigint,
  signer: TypedDataSigner,
): Promise<string> => {
  // corresponds with the EIP712 constructor call
  const domain = await dSafeDomain(dSafe);

  /* eslint-disable @typescript-eslint/naming-convention */
  const types = {
    ExecuteBatch: [
      {name: "calls", type: "Call[]"},
      {name: "nonce", type: "uint256"},
      {name: "deadline", type: "uint256"},
    ],
    Call: [
      {name: "to", type: "address"},
      {name: "callData", type: "bytes"},
      {name: "value", type: "uint256"},
    ],
  };
  /* eslint-enable */
  return await signer._signTypedData(domain, types, {calls, nonce, deadline});
};

export const signOnTransferReceived2Call = async (
  dSafe: DSafeLogic,
  signedCall: {
    operator: string;
    from: string;
    transfers: {token: string; amount: bigint}[];
    calls: Call[];
  },
  nonce: number,
  signer: TypedDataSigner,
): Promise<string> => {
  // corresponds with the EIP712 constructor call
  const domain = await dSafeDomain(dSafe);

  // the named list of all type definitions
  /* eslint-disable @typescript-eslint/naming-convention */
  const types = {
    Transfer: [
      {name: "token", type: "address"},
      {name: "amount", type: "uint256"},
    ],
    Call: [
      {name: "to", type: "address"},
      {name: "callData", type: "bytes"},
      {name: "value", type: "uint256"},
    ],
    OnTransferReceived2Call: [
      {name: "operator", type: "address"},
      {name: "from", type: "address"},
      {name: "transfers", type: "Transfer[]"},
      {name: "calls", type: "Call[]"},
      {name: "nonce", type: "uint256"},
      {name: "deadline", type: "uint256"},
    ],
  };
  /* eslint-enable */

  const value = {
    ...signedCall,
    nonce,
    deadline: ethers.constants.MaxUint256,
  };

  const signature = await signer._signTypedData(domain, types, value);

  const signedData = ethers.utils.defaultAbiCoder.encode(
    [
      "tuple(address to,bytes callData,uint256 value)[] calls",
      "uint256 nonce",
      "uint256 deadline",
      "bytes signature",
    ],
    [signedCall.calls, value.nonce, value.deadline, signature],
  );

  return signedData;
};

export const signPermit2TransferFrom = async (
  permit2: IPermit2,
  token: string,
  amount: bigint,
  spender: string,
  nonce: number,
  signer: TypedDataSigner,
): Promise<string> => {
  // corresponds with the EIP712 constructor call
  const domain = {
    name: "Permit2",
    chainId: (await permit2.provider.getNetwork()).chainId,
    verifyingContract: permit2.address,
  };

  // the named list of all type definitions
  /* eslint-disable @typescript-eslint/naming-convention */
  const types = {
    TokenPermissions: [
      {name: "token", type: "address"},
      {name: "amount", type: "uint256"},
    ],
    PermitTransferFrom: [
      {name: "permitted", type: "TokenPermissions"},
      {name: "spender", type: "address"},
      {name: "nonce", type: "uint256"},
      {name: "deadline", type: "uint256"},
    ],
  };
  /* eslint-enable */

  const value = {
    permitted: {
      token,
      amount,
    },
    spender,
    nonce,
    deadline: ethers.constants.MaxUint256,
  };

  return await signer._signTypedData(domain, types, value);
};

export const signTakeFutureSwapProxyOwnership = async (
  futureSwapProxy: OffchainEntityProxy,
  newOwner: string,
  nonce: number,
  signer: TypedDataSigner,
): Promise<string> => {
  // corresponds with the EIP712 constructor call
  const domain = {
    name: "OffchainEntityProxy",
    version: "1",
    chainId: (await futureSwapProxy.provider.getNetwork()).chainId,
    verifyingContract: futureSwapProxy.address,
  };

  // the named list of all type definitions
  /* eslint-disable @typescript-eslint/naming-convention */
  const types = {
    TakeOwnership: [
      {name: "newOwner", type: "address"},
      {name: "nonce", type: "uint256"},
    ],
  };
  /* eslint-enable */

  const value = {
    newOwner,
    nonce,
  };

  return await signer._signTypedData(domain, types, value);
};
