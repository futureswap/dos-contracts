import type {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import type {IPermit2} from "../typechain-types";

import {ethers} from "hardhat";

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

export const signPermit2TransferFrom = async (
  permit2: IPermit2,
  token: string,
  amount: bigint,
  spender: string,
  nonce: number,
  owner: SignerWithAddress,
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

  return await owner._signTypedData(domain, types, value);
};
