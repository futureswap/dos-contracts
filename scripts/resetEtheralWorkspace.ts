import hre from "hardhat";

async function main() {
  // eslint-disable-next-line @typescript-eslint/no-unsafe-member-access, @typescript-eslint/no-unsafe-call, @typescript-eslint/no-explicit-any
  await (hre as any).ethernal.resetWorkspace("test");
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
