// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/proxy/Proxy.sol";

import {DSafeState} from "./DSafeState.sol";
import {ITransferReceiver2, TRANSFER_AND_CALL2} from "../interfaces/ITransferReceiver2.sol";
import {PERMIT2} from "../external/interfaces/IPermit2.sol";
import {FsUtils} from "../lib/FsUtils.sol";
import {CallLib, Call} from "../lib/Call.sol";

/// @title DSafe Proxy
/// @notice Proxy contract for DOS Safes
// Inspired by TransparentUpdatableProxy
contract DSafeProxy is DSafeState, Proxy {
    modifier ifDos() {
        if (msg.sender == address(dos)) {
            _;
        } else {
            _fallback();
        }
    }

    constructor(address _dos, address[] memory erc20s, address[] memory erc721s) DSafeState(_dos) {
        // Approve DOS and PERMIT2 to spend all ERC20s
        for (uint256 i = 0; i < erc20s.length; i++) {
            // slither-disable-next-line missing-zero-check
            IERC20 erc20 = IERC20(FsUtils.nonNull(erc20s[i]));
            erc20.approve(_dos, type(uint256).max);
            erc20.approve(address(PERMIT2), type(uint256).max);
            erc20.approve(address(TRANSFER_AND_CALL2), type(uint256).max);
        }
        // Approve DOS to spend all ERC721s
        for (uint256 i = 0; i < erc721s.length; i++) {
            // slither-disable-next-line missing-zero-check
            IERC721 erc721 = IERC721(FsUtils.nonNull(erc721s[i]));
            erc721.setApprovalForAll(_dos, true);
            // Add future uniswap permit for ERC721 support
        }
    }

    // Allow ETH transfers
    receive() external payable override {}

    // Allow DOS to make arbitrary calls in lieu of this dSafe
    function executeBatch(Call[] calldata calls) external payable ifDos {
        // Function is payable to allow for ETH transfers to the logic
        // contract, but dos should never send eth (dos contract should
        // never contain eth / other than what's self-destructed into it)
        FsUtils.Assert(msg.value == 0);
        CallLib.executeBatch(calls);
    }

    // The implementation of the delegate is controlled by DOS
    function _implementation() internal view override returns (address) {
        return dos.getImplementation(address(this));
    }
}
