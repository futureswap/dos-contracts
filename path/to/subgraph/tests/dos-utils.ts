import { newMockEvent } from "matchstick-as"
import { ethereum, Address, BigInt } from "@graphprotocol/graph-ts"
import {
  ApprovalForAll,
  ERC20Approval,
  ERC721Approval
} from "../generated/DOS/DOS"

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
