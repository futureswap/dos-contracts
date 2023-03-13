// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// This address is in flux as long as the bytecode of this contract is not fixed. For now
// we deploy it on local block chain on fixed address, when we go deploy this needs to change
// to the permanent address.
address constant TRANSFER_AND_CALL2 = address(0x1554b484D2392672F0375C56d80e91c1d070a007);

// Contracts that implement can receive multiple ERC20 transfers in a single transaction,
// with backwards compatibility for legacy ERC20's not implementing ERC677.
abstract contract ITransferReceiver2 {
    error InvalidSender(address sender);

    struct Transfer {
        address token;
        uint256 amount;
    }

    /// @dev Called by a token to indicate a transfer into the callee
    /// @param operator The account that initiated the transfer
    /// @param from The account that has sent the token
    /// @param transfers Transfers that have been made
    /// @param data The extra data being passed to the receiving contract
    function onTransferReceived2(
        address operator,
        address from,
        Transfer[] calldata transfers,
        bytes calldata data
    ) external virtual returns (bytes4);

    modifier onlyTransferAndCall2() {
        if (msg.sender != TRANSFER_AND_CALL2) revert InvalidSender(msg.sender);
        _;
    }
}
