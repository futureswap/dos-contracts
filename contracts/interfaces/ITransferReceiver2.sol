// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Contracts that implement can receive multiple ERC20 transfers in a single transaction,
// with backwards compatibility for legacy ERC20's not implementing ERC677.
abstract contract ITransferReceiver2 {
    address private constant TRANSFERANDCALL2 = address(0x49A56Bbfe565b0878a0B2d4F623C20Ea5F9e1fE5);

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
        if (msg.sender == TRANSFERANDCALL2) {
            _;
        } else {
            revert InvalidSender(msg.sender);
        }
    }
}
