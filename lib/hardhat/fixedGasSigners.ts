import type {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";

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
