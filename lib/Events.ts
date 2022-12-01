import {Contract, ContractTransaction, ContractReceipt, ethers} from "ethers";
import {cleanResult} from "./Calls";

export const getEventParams = async (
  tx: ContractTransaction | ContractReceipt,
  eventContract: Contract,
  eventName: string,
  executionContract?: Contract,
) => {
  executionContract = executionContract || eventContract;
  const fragment = eventContract.interface.getEvent(eventName);
  const topic = eventContract.interface.getEventTopic(fragment);

  const r = "wait" in tx ? await tx.wait() : (tx as ContractReceipt);

  const event = filterLogsWithTopics(r.logs, topic, executionContract.address);

  if (event.length == 0) {
    throw new Error("No event found");
  }

  if (event.length > 1) {
    throw new Error("Multiple events found " + event);
  }

  return (eventContract.interface as ethers.utils.Interface).parseLog(event[0]).args;
};

export function getEvents(
  receipt: ContractReceipt,
  eventContract: Contract,
  contractAddress?: string,
) {
  contractAddress = (contractAddress || eventContract.address).toLowerCase();
  const logs = receipt.logs.filter(log => log.address.toLowerCase() == contractAddress);

  const desc = logs.map(log => eventContract.interface.parseLog(log));
  const events: {[key: string]: {[key: string]: any}} = {};
  desc.forEach(desc => {
    events[desc.name] = cleanResult(desc.args);
  });
  return events;
}

export async function getEventsTx<Events extends {[key: string]: {[key: string]: any}} = any>(
  tx: Promise<ContractTransaction>,
  eventContract: Contract,
  contractAddress?: string,
): Promise<Events> {
  return getEvents(await (await tx).wait(), eventContract, contractAddress) as Events;
}

const filterLogsWithTopics = (logs: ethers.providers.Log[], topic: any, contractAddress: string) =>
  logs
    .filter(log => log.topics.includes(topic))
    .filter(log => log.address && log.address.toLowerCase() === contractAddress.toLowerCase());
