import {readFile, writeFile} from "node:fs/promises";

type DeploymentAddresses = Record<string, Record<string, string>>;

export const getAllAddresses = async (): Promise<DeploymentAddresses> => {
  const path = `./deployment/addresses.json`;
  const content = await readFile(path, {encoding: "utf-8"});
  return JSON.parse(content) as DeploymentAddresses;
};

export const getAddressesForNetwork = async (): Promise<Record<string, string>> => {
  return (await getAllAddresses())[getNetwork()];
};

export const saveAddressesForNetwork = async (
  contractAddresses: Record<string, string>,
): Promise<void> => {
  const network = getNetwork();
  const oldAddresses = await getAllAddresses();
  if (oldAddresses[network] === undefined) oldAddresses[network] = {};
  const networkAddresses = oldAddresses[network];
  Object.entries(contractAddresses).forEach(([contractName, address]) => {
    networkAddresses[contractName] = address;
  });
  const path = `./deployment/addresses.json`;
  let content = JSON.stringify(oldAddresses, null, 2);
  if (!content.endsWith("\n")) {
    content += "\n";
  }
  await writeFile(path, content, {encoding: "utf-8"});
};

const getNetwork = () => {
  const network = (process.env.HARDHAT_NETWORK ?? "localhost").toLowerCase();
  return network;
};
