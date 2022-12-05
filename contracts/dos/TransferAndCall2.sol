// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../external/interfaces/IWETH9.sol";
import "../interfaces/ITransferReceiver2.sol";
import "../lib/FsUtils.sol";

// Bringing ERC677 to all tokens, it's to ERC667 what Permit2 is to ERC2612.
// This should be proposed as an ERC and should be deployed cross chain on
// fixed address using AnyswapCreate2Deployer.
contract TransferAndCall2 is IERC1363Receiver {
    using Address for address;
    using SafeERC20 for IERC20;

    error onTransferReceivedFailed(
        address to,
        address operator,
        address from,
        ITransferReceiver2.Transfer[] transfers,
        bytes data
    );

    address private immutable weth;

    constructor(address _weth) {
        weth = FsUtils.nonNull(_weth);
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
        return transferFromAndCall2Impl(msg.sender, receiver, transfers, data);
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
        return transferFromAndCall2Impl(from, receiver, transfers, data);
    }

    function transferFromAndCall2Impl(
        address from,
        address receiver,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes calldata data
    ) internal {
        if (msg.value != 0) IWETH9(payable(weth)).deposit{value: msg.value}();
        address prev = address(0);
        for (uint256 i = 0; i < transfers.length; i++) {
            address tokenAddress = transfers[i].token;
            require(prev < tokenAddress);
            prev = tokenAddress;
            uint256 amount = transfers[i].amount;
            if (tokenAddress == weth) {
                IERC20(weth).safeTransfer(receiver, amount);
                amount -= msg.value; // reverts if msg.value > amount
            }
            IERC20 token = IERC20(tokenAddress);
            if (amount > 0) token.safeTransferFrom(msg.sender, receiver, amount);
        }
        if (receiver.isContract())
            callOnTransferReceived2(receiver, msg.sender, from, transfers, data);
    }

    // TODO: ERC2612 permit transferAndCall2
    // TODO: permit2 transferAndCall

    function onTransferReceived(
        address _operator,
        address _from,
        uint256 _amount,
        bytes calldata _data
    ) external override returns (bytes4) {
        (address to, bytes memory decodedData) = abi.decode(_data, (address, bytes));
        ITransferReceiver2.Transfer[] memory transfers = new ITransferReceiver2.Transfer[](1);
        transfers[0] = ITransferReceiver2.Transfer(msg.sender, _amount);
        callOnTransferReceived2(to, _operator, _from, transfers, decodedData);
        return IERC1363Receiver.onTransferReceived.selector;
    }

    function callOnTransferReceived2(
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