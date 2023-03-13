//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WETH9 is ERC20 {
    constructor() ERC20("Wrapped ETH", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);

        Address.sendValue(payable(msg.sender), amount);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
