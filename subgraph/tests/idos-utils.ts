import { newMockEvent } from "matchstick-as"
import { ethereum, Address, BigInt } from "@graphprotocol/graph-ts"
import {
  ApprovalForAll,
  DSafeCreated,
  ERC20Added,
  ERC20Approval,
  ERC721Approval
} from "../generated/IDOS/IDOS"

export function createApprovalForAllEvent(
  collection: Address,
  owner: Address,
  operator: Address,
  approved: boolean
): ApprovalForAll {
  let approvalForAllEvent = changetype<ApprovalForAll>(newMockEvent())

  approvalForAllEvent.parameters = new Array()

  approvalForAllEvent.parameters.push(
    new ethereum.EventParam(
      "collection",
      ethereum.Value.fromAddress(collection)
    )
  )
  approvalForAllEvent.parameters.push(
    new ethereum.EventParam("owner", ethereum.Value.fromAddress(owner))
  )
  approvalForAllEvent.parameters.push(
    new ethereum.EventParam("operator", ethereum.Value.fromAddress(operator))
  )
  approvalForAllEvent.parameters.push(
    new ethereum.EventParam("approved", ethereum.Value.fromBoolean(approved))
  )

  return approvalForAllEvent
}

export function createDSafeCreatedEvent(
  dSafe: Address,
  owner: Address
): DSafeCreated {
  let dSafeCreatedEvent = changetype<DSafeCreated>(newMockEvent())

  dSafeCreatedEvent.parameters = new Array()

  dSafeCreatedEvent.parameters.push(
    new ethereum.EventParam("dSafe", ethereum.Value.fromAddress(dSafe))
  )
  dSafeCreatedEvent.parameters.push(
    new ethereum.EventParam("owner", ethereum.Value.fromAddress(owner))
  )

  return dSafeCreatedEvent
}

export function createERC20AddedEvent(
  erc20Idx: i32,
  erc20: Address,
  dosTokem: Address,
  name: string,
  symbol: string,
  decimals: i32,
  valueOracle: Address,
  colFactor: BigInt,
  borrowFactor: BigInt,
  interest: BigInt
): ERC20Added {
  let erc20AddedEvent = changetype<ERC20Added>(newMockEvent())

  erc20AddedEvent.parameters = new Array()

  erc20AddedEvent.parameters.push(
    new ethereum.EventParam(
      "erc20Idx",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(erc20Idx))
    )
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam("erc20", ethereum.Value.fromAddress(erc20))
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam("dosTokem", ethereum.Value.fromAddress(dosTokem))
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam("name", ethereum.Value.fromString(name))
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam("symbol", ethereum.Value.fromString(symbol))
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam(
      "decimals",
      ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(decimals))
    )
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam(
      "valueOracle",
      ethereum.Value.fromAddress(valueOracle)
    )
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam(
      "colFactor",
      ethereum.Value.fromSignedBigInt(colFactor)
    )
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam(
      "borrowFactor",
      ethereum.Value.fromSignedBigInt(borrowFactor)
    )
  )
  erc20AddedEvent.parameters.push(
    new ethereum.EventParam(
      "interest",
      ethereum.Value.fromSignedBigInt(interest)
    )
  )

  return erc20AddedEvent
}

export function createERC20ApprovalEvent(
  erc20: Address,
  owner: Address,
  spender: Address,
  value: BigInt
): ERC20Approval {
  let erc20ApprovalEvent = changetype<ERC20Approval>(newMockEvent())

  erc20ApprovalEvent.parameters = new Array()

  erc20ApprovalEvent.parameters.push(
    new ethereum.EventParam("erc20", ethereum.Value.fromAddress(erc20))
  )
  erc20ApprovalEvent.parameters.push(
    new ethereum.EventParam("owner", ethereum.Value.fromAddress(owner))
  )
  erc20ApprovalEvent.parameters.push(
    new ethereum.EventParam("spender", ethereum.Value.fromAddress(spender))
  )
  erc20ApprovalEvent.parameters.push(
    new ethereum.EventParam("value", ethereum.Value.fromUnsignedBigInt(value))
  )

  return erc20ApprovalEvent
}

export function createERC721ApprovalEvent(
  collection: Address,
  owner: Address,
  approved: Address,
  tokenId: BigInt
): ERC721Approval {
  let erc721ApprovalEvent = changetype<ERC721Approval>(newMockEvent())

  erc721ApprovalEvent.parameters = new Array()

  erc721ApprovalEvent.parameters.push(
    new ethereum.EventParam(
      "collection",
      ethereum.Value.fromAddress(collection)
    )
  )
  erc721ApprovalEvent.parameters.push(
    new ethereum.EventParam("owner", ethereum.Value.fromAddress(owner))
  )
  erc721ApprovalEvent.parameters.push(
    new ethereum.EventParam("approved", ethereum.Value.fromAddress(approved))
  )
  erc721ApprovalEvent.parameters.push(
    new ethereum.EventParam(
      "tokenId",
      ethereum.Value.fromUnsignedBigInt(tokenId)
    )
  )

  return erc721ApprovalEvent
}
