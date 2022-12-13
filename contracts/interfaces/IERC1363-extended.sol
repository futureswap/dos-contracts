//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

interface IERC1363SpenderExtended {
    function onApprovalReceived(
        address owner,
        uint256 value,
        address target,
        bytes calldata data
    ) external returns (bytes4);
}

interface IERC1363ReceiverExtended {
    function onTransferReceived(
        address operator,
        address from,
        uint256 value,
        address target,
        bytes calldata data
    ) external returns (bytes4);
}
