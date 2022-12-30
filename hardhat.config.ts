import type {HardhatUserConfig} from "hardhat/config";
import type {HardhatRuntimeEnvironment} from "hardhat/types";

import "hardhat-preprocessor";
import "@nomicfoundation/hardhat-toolbox";
import "@nomiclabs/hardhat-waffle";
import "@nomiclabs/hardhat-ethers";
import {config as dotEnvConfig} from "dotenv";
import "@graphprotocol/hardhat-graph";

import {preprocessCode} from "./lib/hardhat/preprocess";

dotEnvConfig({path: "./.env"});

// account mnemonics and infura api keys should be stored in .env file
// as to not expose them through GitHub.
const getEnvVariable = (varName: string) => {
  return process.env[varName] ?? "";
};

if ((process.env.HARDHAT_NETWORK ?? "").toUpperCase() === "LOCALHOST") {
  require("hardhat-ethernal");
}

const TEST_MNEMONIC = "test test test test test test test test test test test junk";

export const FUTURESWAP_DEPLOYER_MNEMONIC = getEnvVariable("FUTURESWAP_DEPLOYER_MNEMONIC");

// mnemonic for futureswap work accounts these are individual for each
// employee. These accounts carry real ETH for executing TX's but should
// never carry to much and should have no special role in the system.
// Employees should keep these accounts secure, but a compromise is not an issue.
const PROD_MNEMONIC = getEnvVariable("PROD_MNEMONIC");
// mnemonic for futureswap work accounts on testnets. This one is just shared
// among employees. This should be kept secret as well but obvious is not
// important if compromised.
const DEV_MNEMONIC = getEnvVariable("DEV_MNEMONIC");

const ethernalAddOn = {}; /*getEnvVariable("network").toUpperCase() !== "LOCALHOST" ? {} : {
  ethernal: {
    email: process.env.ETHERNAL_EMAIL,
    password: process.env.ETHERNAL_PASSWORD,
  },
};*/

const config: HardhatUserConfig = {
  solidity: {
    compilers: [
      {
        version: "0.8.7",
        settings: {
          metadata: {
            // not including the metadata hash
            // https://github.com/paulrberg/solidity-template/issues/31
            bytecodeHash: "none",
          },
          optimizer: {
            enabled: true,
            runs: 200,
            details: {
              yul: true,
            },
          },

          viaIR: true,
        },
      },
      {
        version: "0.8.17",
        settings: {
          metadata: {
            // not including the metadata hash
            // https://github.com/paulrberg/solidity-template/issues/31
            bytecodeHash: "none",
          },
          optimizer: {
            enabled: true,
            runs: 200,
            details: {
              yul: true,
            },
          },
          viaIR: true,
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
      // see more information in https://hardhat.org/hardhat-network/reference/#mining-modes
      mining: {
        // auto-mining enabled means that hardhat automatically mines new transactions as they are
        // sent.
        auto: true,
        // with this configuration, hardhat will also mine new blocks every 5 seconds, regardless
        // of whether there is a transaction to execute.
        interval: 5000,
      },
      allowUnlimitedContractSize: true,
    },
    localhost: {
      url: "http://127.0.0.1:8545/",
      chainId: 31337,
      accounts: {
        count: 200,
        mnemonic: TEST_MNEMONIC,
      },
      allowUnlimitedContractSize: true,
    },
    ethereum: {
      url: getEnvVariable("ETHEREUM_RPC_URL"),
      chainId: 1,
      // can be used to override gas estimation. This is useful if
      // we want to speedup tx.
      // gasPrice: 30000000000,
      accounts: {
        count: 200,
        mnemonic: PROD_MNEMONIC,
      },
    },
    goerli: {
      url: "https://goerli.infura.io/v3/9aa3d95b3bc440fa88ea12eaa4456161",
      chainId: 5,
      accounts: {
        count: 200,
        mnemonic: DEV_MNEMONIC,
      },
    },
    arbitrum: {
      url: "https://arb1.arbitrum.io/rpc",
      chainId: 42161,
      accounts: {
        count: 200,
        mnemonic: PROD_MNEMONIC,
      },
    },
    arbitrum_goerli: {
      url: "https://goerli-rollup.arbitrum.io/rpc",
      chainId: 421613,
      accounts: {
        count: 200,
        mnemonic: DEV_MNEMONIC,
      },
    },
    avalanche: {
      url: "https://api.avax.network/ext/bc/C/rpc",
      chainId: 43114,
      accounts: {
        count: 200,
        mnemonic: PROD_MNEMONIC,
      },
      gasPrice: 60000000000,
    },
    fuji: {
      url: "https://api.avax-test.network/ext/bc/C/rpc",
      chainId: 43113,
      accounts: {
        count: 200,
        mnemonic: DEV_MNEMONIC,
      },
      gasPrice: 60000000000,
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
    eachLine: preprocessCode((hre: HardhatRuntimeEnvironment) => {
      switch (hre.network.name) {
        case "ethereum":
        case "arbitrum":
        case "avalanche":
          return "production";
        case "goerli":
        case "arbitrum_goerli":
        case "fuji":
          return "testing";
        case "hardhat":
        case "localhost":
          return "development";
        default:
          throw new Error("Unknown network");
      }
    }),
  },
  subgraph: {
    name: "DOS", // defaults to the name of the root folder of the hardhat project
    product: "subgraph-studio", // defaults to 'subgraph-studio'
    indexEvents: false, // defaults to false
    allowSimpleName: true, // defaults to `false` if product is `hosted-service` and `true` if product is `subgraph-studio`
  },
  paths: {
    subgraph: "./subgraph", // defaults to './subgraph'
  },
  ...ethernalAddOn,
};
