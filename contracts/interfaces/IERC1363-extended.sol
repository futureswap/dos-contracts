//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import {Call} from "../lib/Call.sol";

interface IERC1363SpenderExtended {
    function onApprovalReceived(
        address owner,
        uint256 value,
        Call calldata call
    ) external returns (bytes4);
}

interface IERC1363ReceiverExtended {
    function onTransferReceived(
        address operator,
        address token,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4);
}
