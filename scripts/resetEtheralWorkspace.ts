import "hardhat-ethernal/dist/type-extensions"; // types only

import hre from "hardhat";

async function main() {
  await hre.ethernal.resetWorkspace("test");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
