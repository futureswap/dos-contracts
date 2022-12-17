// THIS IS AN AUTOGENERATED FILE. DO NOT EDIT THIS FILE DIRECTLY.

import {
  ethereum,
  JSONValue,
  TypedMap,
  Entity,
  Bytes,
  Address,
  BigInt
} from "@graphprotocol/graph-ts";

export class ApprovalForAll extends ethereum.Event {
  get params(): ApprovalForAll__Params {
    return new ApprovalForAll__Params(this);
  }
}

export class ApprovalForAll__Params {
  _event: ApprovalForAll;

  constructor(event: ApprovalForAll) {
    this._event = event;
  }

  get collection(): Address {
    return this._event.parameters[0].value.toAddress();
  }

  get owner(): Address {
    return this._event.parameters[1].value.toAddress();
  }

  get operator(): Address {
    return this._event.parameters[2].value.toAddress();
  }

  get approved(): boolean {
    return this._event.parameters[3].value.toBoolean();
  }
}

export class ERC20Approval extends ethereum.Event {
  get params(): ERC20Approval__Params {
    return new ERC20Approval__Params(this);
  }
}

export class ERC20Approval__Params {
  _event: ERC20Approval;

  constructor(event: ERC20Approval) {
    this._event = event;
  }

  get erc20(): Address {
    return this._event.parameters[0].value.toAddress();
  }

  get owner(): Address {
    return this._event.parameters[1].value.toAddress();
  }

  get spender(): Address {
    return this._event.parameters[2].value.toAddress();
  }

  get value(): BigInt {
    return this._event.parameters[3].value.toBigInt();
  }
}

export class ERC721Approval extends ethereum.Event {
  get params(): ERC721Approval__Params {
    return new ERC721Approval__Params(this);
  }
}

export class ERC721Approval__Params {
  _event: ERC721Approval;

  constructor(event: ERC721Approval) {
    this._event = event;
  }

  get collection(): Address {
    return this._event.parameters[0].value.toAddress();
  }

  get owner(): Address {
    return this._event.parameters[1].value.toAddress();
  }

  get approved(): Address {
    return this._event.parameters[2].value.toAddress();
  }

  get tokenId(): BigInt {
    return this._event.parameters[3].value.toBigInt();
  }
}

export class DOS__computePositionResult {
  value0: BigInt;
  value1: BigInt;
  value2: BigInt;

  constructor(value0: BigInt, value1: BigInt, value2: BigInt) {
    this.value0 = value0;
    this.value1 = value1;
    this.value2 = value2;
  }

  toMap(): TypedMap<string, ethereum.Value> {
    let map = new TypedMap<string, ethereum.Value>();
    map.set("value0", ethereum.Value.fromSignedBigInt(this.value0));
    map.set("value1", ethereum.Value.fromSignedBigInt(this.value1));
    map.set("value2", ethereum.Value.fromSignedBigInt(this.value2));
    return map;
  }

  getTotalValue(): BigInt {
    return this.value0;
  }

  getCollateral(): BigInt {
    return this.value1;
  }

  getDebt(): BigInt {
    return this.value2;
  }
}

export class DOS__stateResultConfigStruct extends ethereum.Tuple {
  get liqFraction(): BigInt {
    return this[0].toBigInt();
  }

  get fractionalReserveLeverage(): BigInt {
    return this[1].toBigInt();
  }
}

export class DOS__stateResult {
  value0: Address;
  value1: DOS__stateResultConfigStruct;

  constructor(value0: Address, value1: DOS__stateResultConfigStruct) {
    this.value0 = value0;
    this.value1 = value1;
  }

  toMap(): TypedMap<string, ethereum.Value> {
    let map = new TypedMap<string, ethereum.Value>();
    map.set("value0", ethereum.Value.fromAddress(this.value0));
    map.set("value1", ethereum.Value.fromTuple(this.value1));
    return map;
  }

  getVersionManager(): Address {
    return this.value0;
  }

  getConfig(): DOS__stateResultConfigStruct {
    return this.value1;
  }
}

export class DOS extends ethereum.SmartContract {
  static bind(address: Address): DOS {
    return new DOS("DOS", address);
  }

  allowance(erc20: Address, _owner: Address, spender: Address): BigInt {
    let result = super.call(
      "allowance",
      "allowance(address,address,address):(uint256)",
      [
        ethereum.Value.fromAddress(erc20),
        ethereum.Value.fromAddress(_owner),
        ethereum.Value.fromAddress(spender)
      ]
    );

    return result[0].toBigInt();
  }

  try_allowance(
    erc20: Address,
    _owner: Address,
    spender: Address
  ): ethereum.CallResult<BigInt> {
    let result = super.tryCall(
      "allowance",
      "allowance(address,address,address):(uint256)",
      [
        ethereum.Value.fromAddress(erc20),
        ethereum.Value.fromAddress(_owner),
        ethereum.Value.fromAddress(spender)
      ]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toBigInt());
  }

  approveERC20(erc20: Address, spender: Address, amount: BigInt): boolean {
    let result = super.call(
      "approveERC20",
      "approveERC20(address,address,uint256):(bool)",
      [
        ethereum.Value.fromAddress(erc20),
        ethereum.Value.fromAddress(spender),
        ethereum.Value.fromUnsignedBigInt(amount)
      ]
    );

    return result[0].toBoolean();
  }

  try_approveERC20(
    erc20: Address,
    spender: Address,
    amount: BigInt
  ): ethereum.CallResult<boolean> {
    let result = super.tryCall(
      "approveERC20",
      "approveERC20(address,address,uint256):(bool)",
      [
        ethereum.Value.fromAddress(erc20),
        ethereum.Value.fromAddress(spender),
        ethereum.Value.fromUnsignedBigInt(amount)
      ]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toBoolean());
  }

  computePosition(dSafeAddress: Address): DOS__computePositionResult {
    let result = super.call(
      "computePosition",
      "computePosition(address):(int256,int256,int256)",
      [ethereum.Value.fromAddress(dSafeAddress)]
    );

    return new DOS__computePositionResult(
      result[0].toBigInt(),
      result[1].toBigInt(),
      result[2].toBigInt()
    );
  }

  try_computePosition(
    dSafeAddress: Address
  ): ethereum.CallResult<DOS__computePositionResult> {
    let result = super.tryCall(
      "computePosition",
      "computePosition(address):(int256,int256,int256)",
      [ethereum.Value.fromAddress(dSafeAddress)]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(
      new DOS__computePositionResult(
        value[0].toBigInt(),
        value[1].toBigInt(),
        value[2].toBigInt()
      )
    );
  }

  getApproved(collection: Address, tokenId: BigInt): Address {
    let result = super.call(
      "getApproved",
      "getApproved(address,uint256):(address)",
      [
        ethereum.Value.fromAddress(collection),
        ethereum.Value.fromUnsignedBigInt(tokenId)
      ]
    );

    return result[0].toAddress();
  }

  try_getApproved(
    collection: Address,
    tokenId: BigInt
  ): ethereum.CallResult<Address> {
    let result = super.tryCall(
      "getApproved",
      "getApproved(address,uint256):(address)",
      [
        ethereum.Value.fromAddress(collection),
        ethereum.Value.fromUnsignedBigInt(tokenId)
      ]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toAddress());
  }

  getDSafeOwner(dSafe: Address): Address {
    let result = super.call(
      "getDSafeOwner",
      "getDSafeOwner(address):(address)",
      [ethereum.Value.fromAddress(dSafe)]
    );

    return result[0].toAddress();
  }

  try_getDSafeOwner(dSafe: Address): ethereum.CallResult<Address> {
    let result = super.tryCall(
      "getDSafeOwner",
      "getDSafeOwner(address):(address)",
      [ethereum.Value.fromAddress(dSafe)]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toAddress());
  }

  getImplementation(dSafe: Address): Address {
    let result = super.call(
      "getImplementation",
      "getImplementation(address):(address)",
      [ethereum.Value.fromAddress(dSafe)]
    );

    return result[0].toAddress();
  }

  try_getImplementation(dSafe: Address): ethereum.CallResult<Address> {
    let result = super.tryCall(
      "getImplementation",
      "getImplementation(address):(address)",
      [ethereum.Value.fromAddress(dSafe)]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toAddress());
  }

  isApprovedForAll(
    collection: Address,
    _owner: Address,
    spender: Address
  ): boolean {
    let result = super.call(
      "isApprovedForAll",
      "isApprovedForAll(address,address,address):(bool)",
      [
        ethereum.Value.fromAddress(collection),
        ethereum.Value.fromAddress(_owner),
        ethereum.Value.fromAddress(spender)
      ]
    );

    return result[0].toBoolean();
  }

  try_isApprovedForAll(
    collection: Address,
    _owner: Address,
    spender: Address
  ): ethereum.CallResult<boolean> {
    let result = super.tryCall(
      "isApprovedForAll",
      "isApprovedForAll(address,address,address):(bool)",
      [
        ethereum.Value.fromAddress(collection),
        ethereum.Value.fromAddress(_owner),
        ethereum.Value.fromAddress(spender)
      ]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toBoolean());
  }

  isSolvent(dSafe: Address): boolean {
    let result = super.call("isSolvent", "isSolvent(address):(bool)", [
      ethereum.Value.fromAddress(dSafe)
    ]);

    return result[0].toBoolean();
  }

  try_isSolvent(dSafe: Address): ethereum.CallResult<boolean> {
    let result = super.tryCall("isSolvent", "isSolvent(address):(bool)", [
      ethereum.Value.fromAddress(dSafe)
    ]);
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toBoolean());
  }

  onERC721Received(
    param0: Address,
    from: Address,
    tokenId: BigInt,
    data: Bytes
  ): Bytes {
    let result = super.call(
      "onERC721Received",
      "onERC721Received(address,address,uint256,bytes):(bytes4)",
      [
        ethereum.Value.fromAddress(param0),
        ethereum.Value.fromAddress(from),
        ethereum.Value.fromUnsignedBigInt(tokenId),
        ethereum.Value.fromBytes(data)
      ]
    );

    return result[0].toBytes();
  }

  try_onERC721Received(
    param0: Address,
    from: Address,
    tokenId: BigInt,
    data: Bytes
  ): ethereum.CallResult<Bytes> {
    let result = super.tryCall(
      "onERC721Received",
      "onERC721Received(address,address,uint256,bytes):(bytes4)",
      [
        ethereum.Value.fromAddress(param0),
        ethereum.Value.fromAddress(from),
        ethereum.Value.fromUnsignedBigInt(tokenId),
        ethereum.Value.fromBytes(data)
      ]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toBytes());
  }

  state(): DOS__stateResult {
    let result = super.call("state", "state():(address,(int256,int256))", []);

    return new DOS__stateResult(
      result[0].toAddress(),
      changetype<DOS__stateResultConfigStruct>(result[1].toTuple())
    );
  }

  try_state(): ethereum.CallResult<DOS__stateResult> {
    let result = super.tryCall(
      "state",
      "state():(address,(int256,int256))",
      []
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(
      new DOS__stateResult(
        value[0].toAddress(),
        changetype<DOS__stateResultConfigStruct>(value[1].toTuple())
      )
    );
  }

  transferFromERC20(
    erc20: Address,
    from: Address,
    to: Address,
    amount: BigInt
  ): boolean {
    let result = super.call(
      "transferFromERC20",
      "transferFromERC20(address,address,address,uint256):(bool)",
      [
        ethereum.Value.fromAddress(erc20),
        ethereum.Value.fromAddress(from),
        ethereum.Value.fromAddress(to),
        ethereum.Value.fromUnsignedBigInt(amount)
      ]
    );

    return result[0].toBoolean();
  }

  try_transferFromERC20(
    erc20: Address,
    from: Address,
    to: Address,
    amount: BigInt
  ): ethereum.CallResult<boolean> {
    let result = super.tryCall(
      "transferFromERC20",
      "transferFromERC20(address,address,address,uint256):(bool)",
      [
        ethereum.Value.fromAddress(erc20),
        ethereum.Value.fromAddress(from),
        ethereum.Value.fromAddress(to),
        ethereum.Value.fromUnsignedBigInt(amount)
      ]
    );
    if (result.reverted) {
      return new ethereum.CallResult();
    }
    let value = result.value;
    return ethereum.CallResult.fromValue(value[0].toBoolean());
  }
}

export class ConstructorCall extends ethereum.Call {
  get inputs(): ConstructorCall__Inputs {
    return new ConstructorCall__Inputs(this);
  }

  get outputs(): ConstructorCall__Outputs {
    return new ConstructorCall__Outputs(this);
  }
}

export class ConstructorCall__Inputs {
  _call: ConstructorCall;

  constructor(call: ConstructorCall) {
    this._call = call;
  }

  get _dosConfig(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get _versionManager(): Address {
    return this._call.inputValues[1].value.toAddress();
  }
}

export class ConstructorCall__Outputs {
  _call: ConstructorCall;

  constructor(call: ConstructorCall) {
    this._call = call;
  }
}

export class DefaultCall extends ethereum.Call {
  get inputs(): DefaultCall__Inputs {
    return new DefaultCall__Inputs(this);
  }

  get outputs(): DefaultCall__Outputs {
    return new DefaultCall__Outputs(this);
  }
}

export class DefaultCall__Inputs {
  _call: DefaultCall;

  constructor(call: DefaultCall) {
    this._call = call;
  }
}

export class DefaultCall__Outputs {
  _call: DefaultCall;

  constructor(call: DefaultCall) {
    this._call = call;
  }
}

export class ApproveERC20Call extends ethereum.Call {
  get inputs(): ApproveERC20Call__Inputs {
    return new ApproveERC20Call__Inputs(this);
  }

  get outputs(): ApproveERC20Call__Outputs {
    return new ApproveERC20Call__Outputs(this);
  }
}

export class ApproveERC20Call__Inputs {
  _call: ApproveERC20Call;

  constructor(call: ApproveERC20Call) {
    this._call = call;
  }

  get erc20(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get spender(): Address {
    return this._call.inputValues[1].value.toAddress();
  }

  get amount(): BigInt {
    return this._call.inputValues[2].value.toBigInt();
  }
}

export class ApproveERC20Call__Outputs {
  _call: ApproveERC20Call;

  constructor(call: ApproveERC20Call) {
    this._call = call;
  }

  get value0(): boolean {
    return this._call.outputValues[0].value.toBoolean();
  }
}

export class ApproveERC721Call extends ethereum.Call {
  get inputs(): ApproveERC721Call__Inputs {
    return new ApproveERC721Call__Inputs(this);
  }

  get outputs(): ApproveERC721Call__Outputs {
    return new ApproveERC721Call__Outputs(this);
  }
}

export class ApproveERC721Call__Inputs {
  _call: ApproveERC721Call;

  constructor(call: ApproveERC721Call) {
    this._call = call;
  }

  get collection(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get to(): Address {
    return this._call.inputValues[1].value.toAddress();
  }

  get tokenId(): BigInt {
    return this._call.inputValues[2].value.toBigInt();
  }
}

export class ApproveERC721Call__Outputs {
  _call: ApproveERC721Call;

  constructor(call: ApproveERC721Call) {
    this._call = call;
  }
}

export class ClaimNFTCall extends ethereum.Call {
  get inputs(): ClaimNFTCall__Inputs {
    return new ClaimNFTCall__Inputs(this);
  }

  get outputs(): ClaimNFTCall__Outputs {
    return new ClaimNFTCall__Outputs(this);
  }
}

export class ClaimNFTCall__Inputs {
  _call: ClaimNFTCall;

  constructor(call: ClaimNFTCall) {
    this._call = call;
  }

  get erc721(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get tokenId(): BigInt {
    return this._call.inputValues[1].value.toBigInt();
  }
}

export class ClaimNFTCall__Outputs {
  _call: ClaimNFTCall;

  constructor(call: ClaimNFTCall) {
    this._call = call;
  }
}

export class DepositERC20Call extends ethereum.Call {
  get inputs(): DepositERC20Call__Inputs {
    return new DepositERC20Call__Inputs(this);
  }

  get outputs(): DepositERC20Call__Outputs {
    return new DepositERC20Call__Outputs(this);
  }
}

export class DepositERC20Call__Inputs {
  _call: DepositERC20Call;

  constructor(call: DepositERC20Call) {
    this._call = call;
  }

  get erc20(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get amount(): BigInt {
    return this._call.inputValues[1].value.toBigInt();
  }
}

export class DepositERC20Call__Outputs {
  _call: DepositERC20Call;

  constructor(call: DepositERC20Call) {
    this._call = call;
  }
}

export class DepositFullCall extends ethereum.Call {
  get inputs(): DepositFullCall__Inputs {
    return new DepositFullCall__Inputs(this);
  }

  get outputs(): DepositFullCall__Outputs {
    return new DepositFullCall__Outputs(this);
  }
}

export class DepositFullCall__Inputs {
  _call: DepositFullCall;

  constructor(call: DepositFullCall) {
    this._call = call;
  }

  get erc20s(): Array<Address> {
    return this._call.inputValues[0].value.toAddressArray();
  }
}

export class DepositFullCall__Outputs {
  _call: DepositFullCall;

  constructor(call: DepositFullCall) {
    this._call = call;
  }
}

export class DepositNFTCall extends ethereum.Call {
  get inputs(): DepositNFTCall__Inputs {
    return new DepositNFTCall__Inputs(this);
  }

  get outputs(): DepositNFTCall__Outputs {
    return new DepositNFTCall__Outputs(this);
  }
}

export class DepositNFTCall__Inputs {
  _call: DepositNFTCall;

  constructor(call: DepositNFTCall) {
    this._call = call;
  }

  get nftContract(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get tokenId(): BigInt {
    return this._call.inputValues[1].value.toBigInt();
  }
}

export class DepositNFTCall__Outputs {
  _call: DepositNFTCall;

  constructor(call: DepositNFTCall) {
    this._call = call;
  }
}

export class ExecuteBatchCall extends ethereum.Call {
  get inputs(): ExecuteBatchCall__Inputs {
    return new ExecuteBatchCall__Inputs(this);
  }

  get outputs(): ExecuteBatchCall__Outputs {
    return new ExecuteBatchCall__Outputs(this);
  }
}

export class ExecuteBatchCall__Inputs {
  _call: ExecuteBatchCall;

  constructor(call: ExecuteBatchCall) {
    this._call = call;
  }

  get calls(): Array<ExecuteBatchCallCallsStruct> {
    return this._call.inputValues[0].value.toTupleArray<
      ExecuteBatchCallCallsStruct
    >();
  }
}

export class ExecuteBatchCall__Outputs {
  _call: ExecuteBatchCall;

  constructor(call: ExecuteBatchCall) {
    this._call = call;
  }
}

export class ExecuteBatchCallCallsStruct extends ethereum.Tuple {
  get to(): Address {
    return this[0].toAddress();
  }

  get callData(): Bytes {
    return this[1].toBytes();
  }

  get value(): BigInt {
    return this[2].toBigInt();
  }
}

export class LiquidateCall extends ethereum.Call {
  get inputs(): LiquidateCall__Inputs {
    return new LiquidateCall__Inputs(this);
  }

  get outputs(): LiquidateCall__Outputs {
    return new LiquidateCall__Outputs(this);
  }
}

export class LiquidateCall__Inputs {
  _call: LiquidateCall;

  constructor(call: LiquidateCall) {
    this._call = call;
  }

  get dSafe(): Address {
    return this._call.inputValues[0].value.toAddress();
  }
}

export class LiquidateCall__Outputs {
  _call: LiquidateCall;

  constructor(call: LiquidateCall) {
    this._call = call;
  }
}

export class OnERC721ReceivedCall extends ethereum.Call {
  get inputs(): OnERC721ReceivedCall__Inputs {
    return new OnERC721ReceivedCall__Inputs(this);
  }

  get outputs(): OnERC721ReceivedCall__Outputs {
    return new OnERC721ReceivedCall__Outputs(this);
  }
}

export class OnERC721ReceivedCall__Inputs {
  _call: OnERC721ReceivedCall;

  constructor(call: OnERC721ReceivedCall) {
    this._call = call;
  }

  get value0(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get from(): Address {
    return this._call.inputValues[1].value.toAddress();
  }

  get tokenId(): BigInt {
    return this._call.inputValues[2].value.toBigInt();
  }

  get data(): Bytes {
    return this._call.inputValues[3].value.toBytes();
  }
}

export class OnERC721ReceivedCall__Outputs {
  _call: OnERC721ReceivedCall;

  constructor(call: OnERC721ReceivedCall) {
    this._call = call;
  }

  get value0(): Bytes {
    return this._call.outputValues[0].value.toBytes();
  }
}

export class SendNFTCall extends ethereum.Call {
  get inputs(): SendNFTCall__Inputs {
    return new SendNFTCall__Inputs(this);
  }

  get outputs(): SendNFTCall__Outputs {
    return new SendNFTCall__Outputs(this);
  }
}

export class SendNFTCall__Inputs {
  _call: SendNFTCall;

  constructor(call: SendNFTCall) {
    this._call = call;
  }

  get erc721(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get tokenId(): BigInt {
    return this._call.inputValues[1].value.toBigInt();
  }

  get to(): Address {
    return this._call.inputValues[2].value.toAddress();
  }
}

export class SendNFTCall__Outputs {
  _call: SendNFTCall;

  constructor(call: SendNFTCall) {
    this._call = call;
  }
}

export class SetApprovalForAllCall extends ethereum.Call {
  get inputs(): SetApprovalForAllCall__Inputs {
    return new SetApprovalForAllCall__Inputs(this);
  }

  get outputs(): SetApprovalForAllCall__Outputs {
    return new SetApprovalForAllCall__Outputs(this);
  }
}

export class SetApprovalForAllCall__Inputs {
  _call: SetApprovalForAllCall;

  constructor(call: SetApprovalForAllCall) {
    this._call = call;
  }

  get collection(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get operator(): Address {
    return this._call.inputValues[1].value.toAddress();
  }

  get approved(): boolean {
    return this._call.inputValues[2].value.toBoolean();
  }
}

export class SetApprovalForAllCall__Outputs {
  _call: SetApprovalForAllCall;

  constructor(call: SetApprovalForAllCall) {
    this._call = call;
  }
}

export class TransferCall extends ethereum.Call {
  get inputs(): TransferCall__Inputs {
    return new TransferCall__Inputs(this);
  }

  get outputs(): TransferCall__Outputs {
    return new TransferCall__Outputs(this);
  }
}

export class TransferCall__Inputs {
  _call: TransferCall;

  constructor(call: TransferCall) {
    this._call = call;
  }

  get erc20(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get to(): Address {
    return this._call.inputValues[1].value.toAddress();
  }

  get amount(): BigInt {
    return this._call.inputValues[2].value.toBigInt();
  }
}

export class TransferCall__Outputs {
  _call: TransferCall;

  constructor(call: TransferCall) {
    this._call = call;
  }
}

export class TransferFromERC20Call extends ethereum.Call {
  get inputs(): TransferFromERC20Call__Inputs {
    return new TransferFromERC20Call__Inputs(this);
  }

  get outputs(): TransferFromERC20Call__Outputs {
    return new TransferFromERC20Call__Outputs(this);
  }
}

export class TransferFromERC20Call__Inputs {
  _call: TransferFromERC20Call;

  constructor(call: TransferFromERC20Call) {
    this._call = call;
  }

  get erc20(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get from(): Address {
    return this._call.inputValues[1].value.toAddress();
  }

  get to(): Address {
    return this._call.inputValues[2].value.toAddress();
  }

  get amount(): BigInt {
    return this._call.inputValues[3].value.toBigInt();
  }
}

export class TransferFromERC20Call__Outputs {
  _call: TransferFromERC20Call;

  constructor(call: TransferFromERC20Call) {
    this._call = call;
  }

  get value0(): boolean {
    return this._call.outputValues[0].value.toBoolean();
  }
}

export class TransferFromERC721Call extends ethereum.Call {
  get inputs(): TransferFromERC721Call__Inputs {
    return new TransferFromERC721Call__Inputs(this);
  }

  get outputs(): TransferFromERC721Call__Outputs {
    return new TransferFromERC721Call__Outputs(this);
  }
}

export class TransferFromERC721Call__Inputs {
  _call: TransferFromERC721Call;

  constructor(call: TransferFromERC721Call) {
    this._call = call;
  }

  get collection(): Address {
    return this._call.inputValues[0].value.toAddress();
  }

  get from(): Address {
    return this._call.inputValues[1].value.toAddress();
  }

  get to(): Address {
    return this._call.inputValues[2].value.toAddress();
  }

  get tokenId(): BigInt {
    return this._call.inputValues[3].value.toBigInt();
  }
}

export class TransferFromERC721Call__Outputs {
  _call: TransferFromERC721Call;

  constructor(call: TransferFromERC721Call) {
    this._call = call;
  }
}

export class WithdrawFullCall extends ethereum.Call {
  get inputs(): WithdrawFullCall__Inputs {
    return new WithdrawFullCall__Inputs(this);
  }

  get outputs(): WithdrawFullCall__Outputs {
    return new WithdrawFullCall__Outputs(this);
  }
}

export class WithdrawFullCall__Inputs {
  _call: WithdrawFullCall;

  constructor(call: WithdrawFullCall) {
    this._call = call;
  }

  get erc20s(): Array<Address> {
    return this._call.inputValues[0].value.toAddressArray();
  }
}

export class WithdrawFullCall__Outputs {
  _call: WithdrawFullCall;

  constructor(call: WithdrawFullCall) {
    this._call = call;
  }
}
