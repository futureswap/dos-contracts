import type {IPermit2, DSafeLogic} from "../typechain-types";
import type {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import type {Call} from "./calls";
import type {TypedDataField} from "ethers";

import {ethers} from "hardhat";

import {checkDefined} from "./preconditions";

// this fixes random tests crash with
// "contract call run out of gas and made the transaction revert" error
// and, as a side effect, speeds tests in 2-3 times!
// https://github.com/NomicFoundation/hardhat/issues/1721
export const getFixedGasSigners = async function (gasLimit: number): Promise<SignerWithAddress[]> {
  const signers: SignerWithAddress[] = await ethers.getSigners();
  for (const signer of signers) {
    const sendTransactionOrig = signer.sendTransaction.bind(signer);
    signer.sendTransaction = transaction => {
      transaction.gasLimit = ethers.BigNumber.from(gasLimit.toString());
      return sendTransactionOrig(transaction);
    };
  }
  return signers;
};

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

// helper function to generate error prone typed data strings
export const generateTypedDataString = (
  types: Record<string, TypedDataField[]>,
): Record<string, string> => {
  const typesList = Object.entries(types);
  const structTypes = Object.fromEntries(
    typesList.map(([name, fields]) => [
      name,
      `${name}(${fields.map(({name, type}) => `${type} ${name}`).join(",")})`,
    ]),
  );
  const visit = (typeName: string, visited: Set<string>) => {
    while (typeName.endsWith("[]")) typeName = typeName.slice(0, -2);
    if (visited.has(typeName)) {
      return;
    }
    if (basicTypes.includes(typeName)) {
      return;
    }
    visited.add(typeName);
    const fields = checkDefined(types[typeName], `type ${typeName} not found`);
    fields.forEach(({type}) => visit(type, visited));
  };
  const l = typesList.map(([typeName]) => {
    const visited = new Set<string>();
    visit(typeName, visited);
    visited.delete(typeName);
    return [
      typeName,
      structTypes[typeName].concat(
        ...Array.from(visited.values())
          .sort()
          .map(typeName => structTypes[typeName]),
      ),
    ] as [string, string];
  });
  return Object.fromEntries(l);
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
  signer: SignerWithAddress,
): Promise<string> => {
  // corresponds with the EIP712 constructor call
  const domain = {
    name: "DOS dSafe",
    version: "1",
    chainId: (await dSafe.provider.getNetwork()).chainId,
    verifyingContract: dSafe.address,
  };

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
    SignedCall: [
      {name: "operator", type: "address"},
      {name: "from", type: "address"},
      {name: "transfers", type: "Transfer[]"},
      {name: "calls", type: "Call[]"},
    ],
    OnTransferReceived2Call: [
      {name: "signedCall", type: "SignedCall"},
      {name: "nonce", type: "uint256"},
      {name: "deadline", type: "uint256"},
    ],
  };
  /* eslint-enable */

  const value = {
    signedCall,
    nonce,
    deadline: ethers.constants.MaxUint256,
  };

  const signature = await signer._signTypedData(domain, types, value);

  const signedData = ethers.utils.defaultAbiCoder.encode(
    [
      "tuple(address operator,address from,tuple(address token, uint256 amount)[] transfers,tuple(address to,bytes callData,uint256 value)[] calls) signedCall",
      "uint256 nonce",
      "uint256 deadline",
      "bytes signature",
    ],
    [signedCall, value.nonce, value.deadline, signature],
  );

  return signedData;
};

export const signPermit2TransferFrom = async (
  permit2: IPermit2,
  token: string,
  amount: bigint,
  spender: string,
  nonce: number,
  signer: SignerWithAddress,
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
