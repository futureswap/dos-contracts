import ethers, { Contract, ContractTransaction, ContractReceipt } from "ethers";

export const getEventParams = async (
  tx: ContractTransaction | ContractReceipt,
  eventContract: Contract,
  eventName: string,
  executionContract?: Contract
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

  return (eventContract.interface as ethers.utils.Interface).parseLog(event[0])
    .args;
};

const filterLogsWithTopics = (
  logs: ethers.providers.Log[],
  topic: any,
  contractAddress: string
) =>
  logs
    .filter((log) => log.topics.includes(topic))
    .filter(
      (log) =>
        log.address &&
        log.address.toLowerCase() === contractAddress.toLowerCase()
    );
