//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {FsUtils} from "../lib/FsUtils.sol";
import "../interfaces/IDOS.sol";
import "../interfaces/ITransferReceiver2.sol";
import "../external/interfaces/IPermit2.sol";

// Inspired by TransparentUpdatableProxy
contract PortfolioProxy is Proxy {
    using Address for address;

    address public immutable dos;

    modifier ifDos() {
        if (msg.sender == dos) {
            _;
        } else {
            _fallback();
        }
    }

    constructor(address _dos, address[] memory erc20s, address[] memory erc721s) {
        // slither-disable-next-line missing-zero-check
        dos = FsUtils.nonNull(_dos);

        // Approve DOS and PERMIT2 to spend all ERC20s
        for (uint256 i = 0; i < erc20s.length; i++) {
            // slither-disable-next-line missing-zero-check
            IERC20 erc20 = IERC20(FsUtils.nonNull(erc20s[i]));
            erc20.approve(_dos, type(uint256).max);
            erc20.approve(address(PERMIT2), type(uint256).max);
        }
        // Approve DOS to spend all ERC721s
        for (uint256 i = 0; i < erc721s.length; i++) {
            // slither-disable-next-line missing-zero-check
            IERC721 erc721 = IERC721(FsUtils.nonNull(erc721s[i]));
            erc721.setApprovalForAll(_dos, true);
            // Add future uniswap permit for ERC721 support
        }
    }

    // Allow DOS to make arbitrary calls in lieu of this portfolio
    function doCall(
        address to,
        bytes calldata callData,
        uint256 value
    ) external ifDos returns (bytes memory) {
        return to.functionCallWithValue(callData, value);
    }

    // The implementation of the delegate is controlled by DOS
    function _implementation() internal view override returns (address) {
        return IDOS(dos).getImplementation(address(this));
    }
}

// Calls to the contract not coming from DOS itself are routed to this logic
// contract. This allows for flexible extra addition to your portfolio.
contract PortfolioLogic is IERC721Receiver, IERC1271, ITransferReceiver2 {
    IDOS public immutable dos;

    mapping(uint248 => uint256) public nonces;

    modifier onlyOwner() {
        require(IDOS(dos).getPortfolioOwner(address(this)) == msg.sender, "");
        _;
    }

    constructor(address _dos) {
        // slither-disable-next-line missing-zero-check
        dos = IDOS(FsUtils.nonNull(_dos));
    }

    function executeBatch(IDOS.Call[] memory calls) external payable onlyOwner {
        IDOS(dos).executeBatch(calls);
    }

    function liquify(
        address portfolio,
        address swapRouter,
        address numeraire,
        IERC20[] calldata erc20s
    ) external {
        if (msg.sender != address(this)) {
            require(msg.sender == IDOS(dos).getPortfolioOwner(address(this)), "only owner");

            IDOS.Call[] memory calls = new IDOS.Call[](1);
            calls[0] = IDOS.Call({
                to: address(this),
                callData: abi.encodeWithSelector(
                    this.liquify.selector,
                    portfolio,
                    swapRouter,
                    numeraire,
                    erc20s
                ),
                value: 0
            });
            dos.executeBatch(calls);
            return;
        }
        // Liquidate the portfolio
        dos.liquidate(portfolio);

        // Withdraw all non-numeraire collateral
        int256[] memory balances = new int256[](erc20s.length);
        {
            uint256 ncollaterals = 0;
            for (uint256 i = 0; i < erc20s.length; i++) {
                int256 balance = IDOS(dos).viewBalance(address(this), erc20s[i]);
                balances[i] = balance;
                if (balance > 0) {
                    ncollaterals++;
                }
            }
            IERC20[] memory collaterals = new IERC20[](ncollaterals);
            uint256 j = 0;
            for (uint256 i = 0; i < erc20s.length; i++) {
                if (balances[i] > 0) {
                    collaterals[j++] = erc20s[i];
                }
            }
            dos.withdrawFull(collaterals);
        }

        // Swap all non-numeraire collateral to numeraire
        for (uint256 i = 0; i < erc20s.length; i++) {
            int256 balance = balances[i];
            if (balance > 0) {
                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                    .ExactInputSingleParams({
                        tokenIn: address(erc20s[i]),
                        tokenOut: numeraire,
                        fee: 500,
                        recipient: address(this),
                        deadline: uint256(int256(-1)),
                        amountIn: uint256(balance),
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    });
                ISwapRouter(swapRouter).exactInputSingle(params);
            }
        }

        // Repay all debt by swapping numeraire
        for (uint256 i = 0; i < erc20s.length; i++) {
            int256 balance = balances[i];
            if (balance < 0) {
                ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter
                    .ExactOutputSingleParams({
                        tokenIn: numeraire,
                        tokenOut: address(erc20s[i]),
                        fee: 500,
                        recipient: address(this),
                        deadline: uint256(int256(-1)),
                        amountOut: uint256(-balance),
                        amountInMaximum: uint256(int256(-1)),
                        sqrtPriceLimitX96: 0
                    });
                ISwapRouter(swapRouter).exactOutputSingle(params);
            }
        }

        // Deposit numeraire
        IERC20[] memory numeraireArray = new IERC20[](1);
        numeraireArray[0] = IERC20(numeraire);
        dos.depositFull(numeraireArray);
    }

    /// @inheritdoc IERC1271
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) public view override returns (bytes4 magicValue) {
        magicValue = SignatureChecker.isValidSignatureNow(
            IDOS(dos).getPortfolioOwner(address(this)),
            hash,
            signature
        )
            ? this.isValidSignature.selector
            : bytes4(0);
    }

    function owner() external view returns (address) {
        return IDOS(dos).getPortfolioOwner(address(this));
    }

    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes memory /* data */
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    error InvalidSignature();

    struct RequiredTokenTransfer {
        address token;
        uint256 requiredAmount;
    }

    function useNonce(uint256 nonce) internal returns (bool) {
        uint248 msp = uint248(nonce >> 8);
        uint256 bit = 1 << (nonce & 0xff);
        uint256 mask = nonces[msp];
        if ((mask & bit) != 0) {
            return false;
        }
        nonces[msp] = mask | bit;
        return true;
    }

    function setNonce(uint256 nonce) external onlyOwner {
        uint248 msp = uint248(nonce >> 8);
        uint256 bit = 1 << (nonce & 0xff);
        nonces[msp] |= bit;
    }

    function onTransferReceived2(
        address operator,
        address from,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes calldata data
    ) external override onlyTransferAndCall2 returns (bytes4) {
        // options:
        // 1) deposit into dos contract
        // 2) execute a signed batch of tx's
        // 3) nothing
        if (data.length == 0) {} else if (data[0] == 0x01) {
            // deposit
            for (uint256 i = 0; i < transfers.length; i++) {
                ITransferReceiver2.Transfer memory transfer = transfers[i];

                // TODO(gerben)
                // dos.depositERC20(transfer.token, transfer.amount, from);
            }
        } else if (data[0] == 0x02) {
            // execute signed batch

            // Verify signature matches
            (bytes memory signature, bytes memory callData) = abi.decode(data[1:], (bytes, bytes));
            bytes32 hash = keccak256(callData);
            if (!SignatureChecker.isValidSignatureNow(from, hash, signature))
                revert InvalidSignature();

            // Decode data
            (
                address requiredFrom,
                uint96 deadline,
                uint256 nonce,
                RequiredTokenTransfer[] memory tfers,
                IDOS.Call[] memory calls
            ) = abi.decode(
                    data[1:],
                    (address, uint96, uint256, RequiredTokenTransfer[], IDOS.Call[])
                );

            if (deadline < block.timestamp) revert InvalidSignature();
            if (!useNonce(nonce)) revert InvalidSignature();

            // Verify transfers match signed tfer
            if (from != requiredFrom || transfers.length != tfers.length) {
                revert InvalidSignature();
            }
            for (uint256 i = 0; i < tfers.length; i++) {
                if (
                    transfers[i].token != tfers[i].token ||
                    transfers[i].amount < tfers[i].requiredAmount
                ) {
                    revert InvalidSignature();
                }
            }

            dos.executeBatch(calls);
        }
        return ITransferReceiver2.onTransferReceived2.selector;
    }
}
