// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.4;

import "./IDuoswapV2Router01.sol";

interface IDuoswapV2Router is IDuoswapV2Router01 {
    event TokensApproved(address sender, uint256 amount, bytes data);
    event TokensReceived(address spender, address sender, uint256 amount, bytes data);

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}
