// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC1363Receiver} from "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "../external/interfaces/IWETH9.sol";
import {ITransferReceiver2} from "../interfaces/ITransferReceiver2.sol";
import {NonceMapLib, NonceMap} from "../lib/NonceMap.sol";

// Bringing ERC1363 to all tokens, it's to ERC1363 what Permit2 is to ERC2612.
// This should be proposed as an EIP and should be deployed cross chain on
// fixed address using AnyswapCreate2Deployer.
contract TransferAndCall2 is IERC1363Receiver, EIP712 {
    using Address for address;
    using SafeERC20 for IERC20;
    using NonceMapLib for NonceMap;

    bytes private constant TRANSFER_TYPESTRING = "Transfer(address token,uint256 amount)";
    bytes private constant PERMIT_TYPESTRING =
        "Permit(address receiver,Transfer[] transfers,bytes data,uint256 nonce,uint256 deadline)";
    bytes32 private constant TRANSFER_TYPEHASH = keccak256(TRANSFER_TYPESTRING);
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256(abi.encodePacked(PERMIT_TYPESTRING, TRANSFER_TYPESTRING));

    mapping(address => mapping(address => bool)) public approvalByOwnerByOperator;
    mapping(address => NonceMap) private nonceMap;

    error onTransferReceivedFailed(
        address to,
        address operator,
        address from,
        ITransferReceiver2.Transfer[] transfers,
        bytes data
    );

    error TransfersUnsorted();

    error EthDoesntMatchWethTransfer();

    error UnauthorizedOperator(address operator, address from);

    error ExpiredPermit();

    error InvalidSignature();

    constructor() EIP712("TransferAndCall2", "1") {}

    /// @dev Set approval for all token transfers from msg.sender to a particular operator
    function setApprovalForAll(address operator, bool approved) external {
        approvalByOwnerByOperator[msg.sender][operator] = approved;
    }

    /// @dev Called by a token to indicate a transfer into the callee
    /// @param receiver The account to sent the tokens
    /// @param transfers Transfers that have been made
    /// @param data The extra data being passed to the receiving contract
    function transferAndCall2(
        address receiver,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes calldata data
    ) external {
        _transferFromAndCall2Impl(msg.sender, receiver, address(0), transfers, data);
    }

    /// @dev Called by a token to indicate a transfer into the callee, converting ETH to WETH
    /// @param receiver The account to sent the tokens
    /// @param weth The WETH9 contract address
    /// @param transfers Transfers that have been made
    /// @param data The extra data being passed to the receiving contract
    function transferAndCall2WithValue(
        address receiver,
        address weth,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes calldata data
    ) external payable {
        _transferFromAndCall2Impl(msg.sender, receiver, weth, transfers, data);
    }

    /// @dev Called by a token to indicate a transfer into the callee
    /// @param from The account that has sent the tokens
    /// @param receiver The account to sent the tokens
    /// @param transfers Transfers that have been made
    /// @param data The extra data being passed to the receiving contract
    function transferFromAndCall2(
        address from,
        address receiver,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes calldata data
    ) external {
        if (!approvalByOwnerByOperator[from][msg.sender]) {
            revert UnauthorizedOperator(msg.sender, from);
        }
        _transferFromAndCall2Impl(from, receiver, address(0), transfers, data);
    }

    function transferAndCall2WithPermit(
        address from,
        address receiver,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes calldata data,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external {
        nonceMap[from].validateAndUseNonce(nonce);
        if (block.timestamp > deadline) {
            revert ExpiredPermit();
        }
        bytes32[] memory transferHashes = new bytes32[](transfers.length);
        for (uint256 i = 0; i < transfers.length; i++) {
            transferHashes[i] = keccak256(
                abi.encodePacked(TRANSFER_TYPEHASH, transfers[i].token, transfers[i].amount)
            );
        }
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    PERMIT_TYPEHASH,
                    receiver,
                    keccak256(abi.encodePacked(transferHashes)),
                    data,
                    nonce,
                    deadline
                )
            )
        );
        if (!SignatureChecker.isValidSignatureNow(from, digest, signature)) {
            revert InvalidSignature();
        }
        _transferFromAndCall2Impl(from, receiver, address(0), transfers, data);
    }

    /// @notice Callback for ERC1363 transferAndCall
    /// @param _operator The address which called `transferAndCall` function
    /// @param _from The address which previously owned the token
    /// @param _amount The amount of tokens being transferred
    /// @param _data Additional data containing the receiver address and the extra data
    function onTransferReceived(
        address _operator,
        address _from,
        uint256 _amount,
        bytes calldata _data
    ) external override returns (bytes4) {
        (address to, bytes memory decodedData) = abi.decode(_data, (address, bytes));
        ITransferReceiver2.Transfer[] memory transfers = new ITransferReceiver2.Transfer[](1);
        transfers[0] = ITransferReceiver2.Transfer(msg.sender, _amount);
        _callOnTransferReceived2(to, _operator, _from, transfers, decodedData);
        return IERC1363Receiver.onTransferReceived.selector;
    }

    function _transferFromAndCall2Impl(
        address from,
        address receiver,
        address weth,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes memory data
    ) internal {
        uint256 ethAmount = msg.value;
        if (ethAmount != 0) {
            IWETH9(payable(weth)).deposit{value: msg.value}();
            IERC20(weth).safeTransfer(receiver, msg.value);
        }
        address prev = address(0);
        for (uint256 i = 0; i < transfers.length; i++) {
            address tokenAddress = transfers[i].token;
            if (prev >= tokenAddress) revert TransfersUnsorted();
            prev = tokenAddress;
            uint256 amount = transfers[i].amount;
            if (tokenAddress == weth) {
                // Already send WETH
                amount -= ethAmount; // reverts if msg.value > amount
                ethAmount = 0;
            }
            IERC20 token = IERC20(tokenAddress);
            if (amount > 0) token.safeTransferFrom(from, receiver, amount);
        }
        if (ethAmount != 0) revert EthDoesntMatchWethTransfer();
        if (receiver.isContract()) {
            _callOnTransferReceived2(receiver, msg.sender, from, transfers, data);
        }
    }

    function _callOnTransferReceived2(
        address to,
        address operator,
        address from,
        ITransferReceiver2.Transfer[] memory transfers,
        bytes memory data
    ) internal {
        if (
            ITransferReceiver2(to).onTransferReceived2(operator, from, transfers, data) !=
            ITransferReceiver2.onTransferReceived2.selector
        ) {
            revert onTransferReceivedFailed(to, operator, from, transfers, data);
        }
    }
}
