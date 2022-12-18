import {
  ApprovalForAll as ApprovalForAllEvent,
  DSafeCreated as DSafeCreatedEvent,
  ERC20Added as ERC20AddedEvent,
  ERC20Approval as ERC20ApprovalEvent,
  ERC721Approval as ERC721ApprovalEvent
} from "../generated/IDOS/IDOS"
import {
  ApprovalForAll,
  DSafeCreated,
  ERC20Added,
  ERC20Approval,
  ERC721Approval
} from "../generated/schema"

export function handleApprovalForAll(event: ApprovalForAllEvent): void {
  let entity = new ApprovalForAll(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.collection = event.params.collection
  entity.owner = event.params.owner
  entity.operator = event.params.operator
  entity.approved = event.params.approved

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleDSafeCreated(event: DSafeCreatedEvent): void {
  let entity = new DSafeCreated(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.dSafe = event.params.dSafe
  entity.owner = event.params.owner

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleERC20Added(event: ERC20AddedEvent): void {
  let entity = new ERC20Added(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.erc20Idx = event.params.erc20Idx
  entity.erc20 = event.params.erc20
  entity.dosTokem = event.params.dosTokem
  entity.name = event.params.name
  entity.symbol = event.params.symbol
  entity.decimals = event.params.decimals
  entity.valueOracle = event.params.valueOracle
  entity.colFactor = event.params.colFactor
  entity.borrowFactor = event.params.borrowFactor
  entity.interest = event.params.interest

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleERC20Approval(event: ERC20ApprovalEvent): void {
  let entity = new ERC20Approval(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.erc20 = event.params.erc20
  entity.owner = event.params.owner
  entity.spender = event.params.spender
  entity.value = event.params.value

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}

export function handleERC721Approval(event: ERC721ApprovalEvent): void {
  let entity = new ERC721Approval(
    event.transaction.hash.concatI32(event.logIndex.toI32())
  )
  entity.collection = event.params.collection
  entity.owner = event.params.owner
  entity.approved = event.params.approved
  entity.tokenId = event.params.tokenId

  entity.blockNumber = event.block.number
  entity.blockTimestamp = event.block.timestamp
  entity.transactionHash = event.transaction.hash

  entity.save()
}
