//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "../../dosERC20/DOSERC20.sol";

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
