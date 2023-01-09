// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.7;

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
