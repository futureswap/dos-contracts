import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

import { config as dotEnvConfig } from "dotenv";

import { checkDefined } from "./lib/preconditions";

import { createStripFn } from "./lib/hardhat/removeStripBlocks";

const result = dotEnvConfig({ path: "./.env" });

if (result.error) {
  throw result.error;
}

const getEnvVariable = (varName: string) => {
  return checkDefined(process.env[varName], varName + " missing");
};

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
};

export default config;
