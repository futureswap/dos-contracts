//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/interfaces/IERC1363.sol";
import "@openzeppelin/contracts/interfaces/IERC1363Receiver.sol";
import "@openzeppelin/contracts/interfaces/IERC1363Spender.sol";
import "../interfaces/IDOS.sol";
import "../lib/FsUtils.sol";
import "../lib/ImmutableOwnable.sol";

contract DOSERC20 is IDOSERC20, ERC20Permit, IERC1363, ImmutableOwnable {
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

    /// @inheritdoc IERC1363
    function transferAndCall(address to, uint256 value) external override returns (bool success) {
        return transferFromAndCall(msg.sender, to, value, "");
    }

    /// @inheritdoc IERC1363
    function transferAndCall(
        address to,
        uint256 value,
        bytes memory data
    ) external override returns (bool success) {
        return transferFromAndCall(msg.sender, to, value, data);
    }

    function transferFromAndCall(
        address from,
        address to,
        uint256 value
    ) external override returns (bool) {
        return transferFromAndCall(from, to, value, "");
    }

    function transferFromAndCall(
        address from,
        address to,
        uint256 value,
        bytes memory data
    ) public override returns (bool) {
        super.transfer(to, value);
        if (Address.isContract(to)) {
            IERC1363Receiver receiver = IERC1363Receiver(to);
            return
                receiver.onTransferReceived(msg.sender, from, value, data) ==
                IERC1363Receiver.onTransferReceived.selector;
        }
        return true;
    }

    function approveAndCall(
        address spender,
        uint256 value
    ) external override returns (bool success) {
        return approveAndCall(spender, value, "");
    }

    function approveAndCall(
        address spender,
        uint256 value,
        bytes memory data
    ) public override returns (bool success) {
        super.approve(spender, value);
        if (Address.isContract(spender)) {
            IERC1363Spender receiver = IERC1363Spender(spender);
            return
                receiver.onApprovalReceived(msg.sender, value, data) ==
                IERC1363Spender.onApprovalReceived.selector;
        }
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return interfaceId == type(IERC1363).interfaceId ? true : false;
    }

    function decimals() public view override returns (uint8) {
        return erc20Decimals;
    }
}
