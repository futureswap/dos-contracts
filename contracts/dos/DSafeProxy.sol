// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "../lib/FsUtils.sol";
import "../interfaces/IDOS.sol";
import "../interfaces/ITransferReceiver2.sol";
import "../external/interfaces/IPermit2.sol";

// Inspired by TransparentUpdatableProxy
contract DSafeProxy is Proxy {
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

    // Allow DOS to make arbitrary calls in lieu of this dSafe
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
// contract. This allows for flexible extra addition to your dSafe.
contract DSafeLogic is IERC721Receiver, IERC1271, ITransferReceiver2, EIP712 {
    IDOS public immutable dos;

    mapping(uint248 => uint256) public nonces;

    modifier onlyOwner() {
        require(IDOS(dos).getDSafeOwner(address(this)) == msg.sender, "");
        _;
    }

    // Note EIP712 is implemented with immutable variables and is not using
    // storage and thus can be used in a proxy contract.
    // Version number should be in sync with VersionManager version.
    constructor(address _dos) EIP712("DOS dSafe", "1") {
        // slither-disable-next-line missing-zero-check
        dos = IDOS(FsUtils.nonNull(_dos));
    }

    function executeBatch(IDOS.Call[] memory calls) external payable onlyOwner {
        IDOS(dos).executeBatch(calls);
    }

    function liquify(
        address dSafe,
        address swapRouter,
        address numeraire,
        IERC20[] calldata erc20s
    ) external {
        if (msg.sender != address(this)) {
            require(msg.sender == IDOS(dos).getDSafeOwner(address(this)), "only owner");

            IDOS.Call[] memory calls = new IDOS.Call[](1);
            calls[0] = IDOS.Call({
                to: address(this),
                callData: abi.encodeWithSelector(
                    this.liquify.selector,
                    dSafe,
                    swapRouter,
                    numeraire,
                    erc20s
                ),
                value: 0
            });
            dos.executeBatch(calls);
            return;
        }
        // Liquidate the dSafe
        dos.liquidate(dSafe);

        // Withdraw all non-numeraire collateral
        int256[] memory balances = new int256[](erc20s.length);
        {
            uint256 ncollaterals = 0;
            for (uint256 i = 0; i < erc20s.length; i++) {
                int256 balance = IDOS(dos).getDAccountERC20(address(this), erc20s[i]);
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

    function owner() external view returns (address) {
        return IDOS(dos).getDSafeOwner(address(this));
    }

    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes memory /* data */
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IERC1271
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) public view override returns (bytes4 magicValue) {
        magicValue = SignatureChecker.isValidSignatureNow(
            IDOS(dos).getDSafeOwner(address(this)),
            hash,
            signature
        )
            ? this.isValidSignature.selector
            : bytes4(0);
    }

    error InvalidSignature();

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

    function valueNonce(uint256 nonce) external view returns (bool) {
        uint248 msp = uint248(nonce >> 8);
        uint256 bit = 1 << (nonce & 0xff);
        return (nonces[msp] & bit) != 0;
    }

    struct SignedCall {
        address operator;
        address from;
        ITransferReceiver2.Transfer[] transfers;
        IDOS.Call[] calls;
    }

    bytes32 constant ONTRANSFERRECEIVED2CALL_TYPEHASH =
        keccak256(
            "OnTransferReceived2Call(SignedCall signedCall,uint256 nonce,uint256 deadline)Call(address to,bytes callData,uint256 value)SignedCall(address operator,address from,Transfer[] transfers,Call[] calls)Transfer(address token,uint256 amount)"
        );
    bytes32 constant SIGNEDCALL_TYPEHASH =
        keccak256(
            "SignedCall(address operator,address from,Transfer[] transfers,Call[] calls)Call(address to,bytes callData,uint256 value)Transfer(address token,uint256 amount)"
        );
    bytes32 constant TRANSFER_TYPEHASH = keccak256("Transfer(address token,uint256 amount)");
    bytes32 constant CALL_TYPEHASH = keccak256("Call(address to,bytes callData,uint256 value)");

    function onTransferReceived2(
        address /* operator */,
        address from,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes calldata data
    ) external override onlyTransferAndCall2 returns (bytes4) {
        // options:
        // 1) deposit into dos contract
        // 2) execute a signed batch of tx's
        // 3) nothing
        if (data.length == 0) {
            /* just deposit in the proxy */
        } else if (data[0] == 0x01) {
            require(data.length == 1, "Invalid data - allowed are [], [1] and [2]");
            // deposit in the dos dSafe
            for (uint256 i = 0; i < transfers.length; i++) {
                ITransferReceiver2.Transfer memory transfer = transfers[i];

                // TODO(gerben)
                dos.depositERC20(IERC20(transfer.token), int256(transfer.amount));
            }
        } else if (data[0] == 0x02) {
            // execute signed batch

            // Verify signature matches
            (
                SignedCall memory signedCall,
                uint256 nonce,
                uint256 deadline,
                bytes memory signature
            ) = abi.decode(data[1:], (SignedCall, uint256, uint256, bytes));
            bytes32[] memory transferDigests = new bytes32[](signedCall.transfers.length);
            for (uint256 i = 0; i < signedCall.transfers.length; i++) {
                transferDigests[i] = keccak256(
                    abi.encode(
                        TRANSFER_TYPEHASH,
                        signedCall.transfers[i].token,
                        signedCall.transfers[i].amount
                    )
                );
            }
            bytes32[] memory callDigests = new bytes32[](signedCall.calls.length);
            for (uint256 i = 0; i < signedCall.calls.length; i++) {
                callDigests[i] = keccak256(
                    abi.encode(
                        CALL_TYPEHASH,
                        signedCall.calls[i].to,
                        keccak256(signedCall.calls[i].callData),
                        signedCall.calls[i].value
                    )
                );
            }
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        ONTRANSFERRECEIVED2CALL_TYPEHASH,
                        keccak256(
                            abi.encode(
                                SIGNEDCALL_TYPEHASH,
                                signedCall.operator,
                                signedCall.from,
                                keccak256(abi.encodePacked(transferDigests)),
                                keccak256(abi.encodePacked(callDigests))
                            )
                        ),
                        nonce,
                        deadline
                    )
                )
            );
            if (
                !SignatureChecker.isValidSignatureNow(
                    IDOS(dos).getDSafeOwner(address(this)),
                    digest,
                    signature
                )
            ) revert InvalidSignature();

            if (deadline < block.timestamp) revert InvalidSignature();
            if (!useNonce(nonce)) revert InvalidSignature();

            // Verify transfers match signed tfer
            if (from != signedCall.from || transfers.length != signedCall.transfers.length) {
                revert InvalidSignature();
            }
            for (uint256 i = 0; i < transfers.length; i++) {
                if (
                    transfers[i].token != signedCall.transfers[i].token ||
                    transfers[i].amount < signedCall.transfers[i].amount
                ) {
                    revert InvalidSignature();
                }
            }

            dos.executeBatch(signedCall.calls);
        }
        return ITransferReceiver2.onTransferReceived2.selector;
    }
}