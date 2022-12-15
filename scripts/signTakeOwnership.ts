import type {
  EthereumSignTransaction,
  EthereumTransaction,
  EthereumTransactionEIP1559,
  EthereumSignTypedDataTypes,
} from "@trezor/connect";
import type {TypedDataSigner} from "@ethersproject/abstract-signer";
import type {FutureSwapProxy} from "../typechain-types";

import TrezorConnect from "@trezor/connect";
import {ethers} from "ethers";
import {ethers as hardhatEthers} from "hardhat";

import {getAddressesForNetwork, getContracts} from "../lib/deployment";
import {governatorAddress} from "../lib/deploy";
import {checkDefined, checkState} from "../lib/preconditions";
import {signTakeFutureSwapProxyOwnership} from "../lib/signers";

function toBytes(s: ethers.Bytes | string | number | bigint | ethers.BigNumber) {
  if (typeof s === "string") {
    s = ethers.utils.toUtf8Bytes(s);
  }
  return ethers.utils.hexlify(s);
}

export class TrezorSigner extends ethers.Signer implements TypedDataSigner {
  readonly path: string;
  private readonly initialize: Promise<void>;

  constructor(
    private address?: string,
    readonly provider?: ethers.providers.Provider,
    path?: string,
  ) {
    super();
    const defaultPath = "m/44'/60'/0'/0/0";
    this.address = address;
    this.path = path ?? defaultPath;

    this.initialize = TrezorConnect.init({
      manifest: {
        email: "",
        appUrl: "",
      },
      lazyLoad: true,
    });
  }

  async getAddress(): Promise<string> {
    if (this.address) return this.address;
    await this.initialize;
    console.log("Please provide address");
    const ret = await TrezorConnect.ethereumGetAddress({
      path: this.path,
      useEmptyPassphrase: true,
    });
    if (!ret.success) throw new Error(`Couldn't acquire address: ${ret.payload.error}`);
    this.address = ret.payload.address;
    return this.address;
  }

  async signMessage(message: ethers.Bytes | string): Promise<string> {
    await this.initialize;
    console.log(message);
    const messageHex = toBytes(message);
    console.log(`Please sign message: "${messageHex}"`);
    const res = await TrezorConnect.ethereumSignMessage({
      path: this.path,
      message: messageHex,
      useEmptyPassphrase: true,
      hex: true,
    });
    if (!res.success) throw new Error(`Failed signing messages: ${res.payload.error}`);
    if (this.address) {
      checkState(res.payload.address === this.address);
    } else {
      this.address = res.payload.address;
    }
    return res.payload.signature;
  }

  async signTransaction(ethersTransaction: ethers.providers.TransactionRequest): Promise<string> {
    await this.initialize;
    const {
      to,
      from,
      nonce,
      gasLimit,
      gasPrice,
      data,
      value,
      chainId,
      type,
      maxPriorityFeePerGas,
      maxFeePerGas,
    } = await ethers.utils.resolveProperties(ethersTransaction);
    const baseTx: ethers.utils.UnsignedTransaction = {
      chainId,
      data,
      gasLimit,
      gasPrice,
      nonce: ethers.BigNumber.from(nonce).toNumber(),
      to,
      value,
    };
    let transaction: EthereumTransaction | EthereumTransactionEIP1559;
    if (type === 2) {
      const tx: EthereumTransactionEIP1559 = {
        to: checkDefined(to),
        value: toBytes(checkDefined(value)),
        gasLimit: toBytes(checkDefined(gasLimit)),
        nonce: toBytes(checkDefined(nonce)),
        data: toBytes(data ?? ""),
        chainId: checkDefined(chainId),
        maxFeePerGas: toBytes(checkDefined(maxFeePerGas)),
        maxPriorityFeePerGas: toBytes(checkDefined(maxPriorityFeePerGas)),
        // accessList: accessList,
      };
      transaction = tx;
    } else {
      const tx: EthereumTransaction = {
        to: checkDefined(to),
        value: toBytes(checkDefined(value)),
        gasPrice: toBytes(checkDefined(gasPrice)),
        gasLimit: toBytes(checkDefined(gasLimit)),
        nonce: toBytes(checkDefined(nonce)),
        data: toBytes(data ?? ""),
        chainId: checkDefined(chainId),
        txType: checkDefined(type),
      };
      transaction = tx;
    }
    const trezorTx: EthereumSignTransaction = {
      path: this.path,
      transaction,
    };

    console.log("Please sign transaction\n", trezorTx);

    const res = await TrezorConnect.ethereumSignTransaction({
      path: this.path,
      transaction,
      useEmptyPassphrase: true,
    });
    if (!res.success) throw new Error(`Failed signing transaction: ${res.payload.error}`);
    checkState(
      from === undefined ||
        this.address === undefined ||
        from.toLowerCase() === this.address.toLowerCase(),
    );
    const sig = res.payload;

    return ethers.utils.serializeTransaction(baseTx, {
      v: ethers.BigNumber.from(sig.v).toNumber(),
      r: sig.r,
      s: sig.s,
    });
  }

  async _signTypedData(
    domain: ethers.TypedDataDomain,
    types: Record<string, ethers.TypedDataField[]>,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    message: Record<string, any>,
  ): Promise<string> {
    await this.initialize;
    const esdt: EthereumSignTypedDataTypes = {
      EIP712Domain: [
        {name: "name", type: "string"},
        {name: "version", type: "string"},
        {name: "chainId", type: "uint256"},
        {name: "verifyingContract", type: "address"},
        // { name: "salt", type: "bytes32"},
      ],
      ...types,
    };
    const trezorDomain = {
      name: domain.name,
      version: domain.version,
      chainId: ethers.BigNumber.from(domain.chainId).toNumber(),
      verifyingContract: domain.verifyingContract,
    };
    let primaryType: string | undefined;
    for (const key in types) {
      let hasAllProperties = true;
      for (const {name} of types[key]) {
        if (!(name in message)) {
          hasAllProperties = false;
        }
      }
      if (hasAllProperties) {
        primaryType = key;
        break;
      }
    }
    if (primaryType === undefined) throw new Error("No primary type found");
    const res = await TrezorConnect.ethereumSignTypedData({
      path: this.path,
      data: {
        types: esdt,
        primaryType,
        domain: trezorDomain,
        message,
      },
      metamask_v4_compat: false,
      useEmptyPassphrase: true,
    });
    if (!res.success) {
      throw new Error(`Failed signing typed data: ${res.payload.error}`);
    }
    if (res.payload.address !== this.address) {
      throw new Error("Address mismatch");
    }
    return res.payload.signature;
  }

  connect(provider: ethers.providers.Provider): ethers.Signer {
    return new TrezorSigner(this.address, provider, this.path);
  }
}

async function main() {
  const [owner] = await hardhatEthers.getSigners();

  const networkAddresses = await getAddressesForNetwork();
  const networkContracts = getContracts(networkAddresses, owner);

  const fsProxy = networkContracts.futureSwapProxy as FutureSwapProxy;

  const governator = new TrezorSigner(governatorAddress, hardhatEthers.provider);

  const signature = await signTakeFutureSwapProxyOwnership(fsProxy, owner.address, 0, governator);

  console.log(signature);

  //  await fsProxy.takeOwnership(signature);
  //  await fsProxy.transferOwnership("0x7aE171b52089Eb7D991FCdd2B9fC0CeaC1217B14");
  console.log("Done");
}

// we recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
