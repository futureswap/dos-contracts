import { HardhatUserConfig } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import "@nomicfoundation/hardhat-toolbox";

import { config as dotEnvConfig } from "dotenv";

import { createStripFn } from "./lib/hardhat/removeStripBlocks";

dotEnvConfig({ path: "./.env" });

const getEnvVariable = (varName: string) => {
  return process.env[varName] || "";
};

const TEST_MNEMONIC =
  "test test test test test test test test test test test junk";

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.7",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
            details: {
              yul: true,
            },
          },

          viaIR: false,
        },
      },
      {
        version: "0.8.17",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
            details: {
              yul: true,
            },
          },
          viaIR: false,
        },
      },
    ],
  },
  networks: {
    hardhat: {
      accounts: {
        count: 200,
        mnemonic: TEST_MNEMONIC,
        accountsBalance: "10000000000000000000000000000",
      },
      // See more information in https://hardhat.org/hardhat-network/reference/#mining-modes
      mining: {
        // Auto-mining enabled means that hardhat automatically mines new transactions as they are
        // sent.
        auto: true,
        // With this configuration, hardhat will also mine new blocks every 5 seconds, regardless
        // of whether there is a transaction to execute.
        interval: 5000,
      },
      allowUnlimitedContractSize: true,
    },
    localhost: {
      url: "http://localhost:8545/",
      chainId: 31337,
      accounts: {
        count: 200,
        mnemonic: TEST_MNEMONIC,
      },
      allowUnlimitedContractSize: true,
    },
    ethereum: {
      url: getEnvVariable("ETHEREUM_RPC_URL"),
      chainId: Number(getEnvVariable("ETHEREUM_CHAINID")),
      // Can be used to override gas estimation. This is useful if
      // we want to speedup tx.
      // gasPrice: 30000000000,
      accounts: {
        count: 200,
        mnemonic: getEnvVariable("PROD_MNEMONIC"),
      },
    },
    goerli: {
      url: getEnvVariable("GOERLI_RPC_URL"),
      chainId: Number(getEnvVariable("GOERLI_CHAINID")),
      accounts: {
        count: 200,
        mnemonic: getEnvVariable("DEV_MNEMONIC"),
      },
    },
    arbitrum: {
      url: getEnvVariable("ARBITRUM_RPC_URL"),
      chainId: Number(getEnvVariable("ARBITRUM_CHAINID")),
      accounts: {
        count: 200,
        mnemonic: getEnvVariable("PROD_MNEMONIC"),
      },
    },
    avalanche: {
      url: getEnvVariable("AVALANCHE_RPC_URL"),
      chainId: Number(getEnvVariable("AVALANCHE_CHAINID")),
      accounts: {
        count: 200,
        mnemonic: getEnvVariable("PROD_MNEMONIC"),
      },
      gasPrice: 60000000000,
    },
    coverage: {
      url: "http://127.0.0.1:8555", // Coverage launches its own ganache-cli client
    },
    etheno: {
      url: "http://localhost:8550",
      chainId: 31337,
      accounts: {
        count: 200,
        mnemonic: TEST_MNEMONIC,
      },
    },
  },
  etherscan: {
    apiKey: getEnvVariable("ETHERSCAN_API_KEY"),
  },
};

export default {
  ...config,
  preprocess: {
    eachLine: createStripFn((hre: HardhatRuntimeEnvironment) => {
      return (
        hre.network.name !== "hardhat" &&
        hre.network.name !== "localhost" &&
        hre.network.name !== "etheno"
      );
    }),
  },
};
