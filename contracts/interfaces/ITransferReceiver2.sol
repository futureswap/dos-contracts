// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// This address is in flux as long as the bytecode of this contract is not fixed. For now
// we deploy it on local block chain on fixed address, when we go deploy this needs to change
// to the permanent address.
address constant TRANSFER_AND_CALL2 = address(0x4e765952997a33893AfB4457A6A7f381909f3629);

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
