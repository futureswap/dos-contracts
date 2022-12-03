import type {SignerWithAddress} from "@nomiclabs/hardhat-ethers/signers";
import {setCode} from "@nomicfoundation/hardhat-network-helpers";
import {ethers} from "hardhat";
import permit2JSON from "../external/Permit2.sol/Permit2.json";
import {VoidSigner} from "ethers";
import {IPermit2, IPermit2__factory} from "../typechain-types";

// This fixes random tests crash with
// "contract call run out of gas and made the transaction revert" error
// and, as a side effect, speeds tests in 2-3 times!
// https://github.com/NomicFoundation/hardhat/issues/1721
export const getFixedGasSigners = async function (gasLimit: number) {
  const signers: SignerWithAddress[] = await ethers.getSigners();
  for (const signer of signers) {
    const orig = signer.sendTransaction;
    signer.sendTransaction = transaction => {
      transaction.gasLimit = ethers.BigNumber.from(gasLimit.toString());
      return orig.apply(signer, [transaction]);
    };
  }
  return signers;
};

export const deployPermit2 = async () => {
  const permit2Address = "0x000000000022D473030F116dDEE9F6B43aC78BA3";
  await setCode(permit2Address, permit2JSON.deployedBytecode.object);
  return IPermit2__factory.connect(permit2Address, new VoidSigner(permit2Address, ethers.provider));
};

export const signPermitTransferFrom = async (
  permit2: IPermit2,
  token: string,
  amount: bigint,
  spender: string,
  nonce: number,
  owner: SignerWithAddress,
) => {
  // Corresponds with the EIP712 constructor call
  const domain = {
    name: "Permit2",
    chainId: (await permit2.provider.getNetwork()).chainId,
    verifyingContract: permit2.address,
  };

  // The named list of all type definitions
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

  const value = {
    permitted: {
      token: token,
      amount,
    },
    spender,
    nonce,
    deadline: ethers.constants.MaxUint256,
  };

  return owner._signTypedData(domain, types, value);
};
