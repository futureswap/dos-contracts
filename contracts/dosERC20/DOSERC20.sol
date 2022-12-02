//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "../interfaces/IERC677Receiver.sol";
import "../interfaces/IERC677Token.sol";
import "../interfaces/IDOS.sol";
import "../lib/FsUtils.sol";
import "../lib/ImmutableOwnable.sol";

contract DOSERC20 is IDOSERC20, ERC20Permit, IERC677Token, ImmutableOwnable {
    uint8 private immutable erc20Decimals;

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals
    ) ImmutableOwnable(msg.sender) ERC20(_name, _symbol) ERC20Permit(_symbol) {
        erc20Decimals = _decimals;
    }

    /// @notice Invalidate nonce for permit approval
    function useNonce() external {
        _useNonce(msg.sender);
    }

    /// @notice burn amount tokens from account
    function burn(address account, uint256 amount) external override onlyOwner {
        _burn(account, amount);
    }

    /// @notice mint amount tokens to account
    function mint(address account, uint256 amount) external override onlyOwner {
        _mint(account, amount);
    }

    /// @inheritdoc IERC677Token
    function transferAndCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external override returns (bool success) {
        super.transfer(to, value);
        if (Address.isContract(to)) {
            IERC677Receiver receiver = IERC677Receiver(to);
            return receiver.onTokenTransfer(msg.sender, value, data);
        }
        return true;
    }

    function decimals() public view override returns (uint8) {
        return erc20Decimals;
    }
}
