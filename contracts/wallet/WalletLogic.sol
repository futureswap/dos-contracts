// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {WalletState} from "./WalletState.sol";
import {Liquifier} from "../supa/Liquifier.sol";
import {IVersionManager} from "../interfaces/IVersionManager.sol";
import {ITransferReceiver2} from "../interfaces/ITransferReceiver2.sol";
import {IWallet} from "../interfaces/IWallet.sol";
import {IERC1363SpenderExtended} from "../interfaces/IERC1363-extended.sol";
import {CallLib, Call} from "../lib/Call.sol";
import {NonceMapLib, NonceMap} from "../lib/NonceMap.sol";
import {ImmutableVersion} from "../lib/ImmutableVersion.sol";

// Calls to the contract not coming from Supa itself are routed to this logic
// contract. This allows for flexible extra addition to your wallet.
contract WalletLogic is
    WalletState,
    ImmutableVersion,
    IERC721Receiver,
    IERC1271,
    ITransferReceiver2,
    EIP712,
    IWallet,
    Liquifier,
    IERC1363SpenderExtended
{
    using NonceMapLib for NonceMap;

    bytes private constant EXECUTEBATCH_TYPESTRING =
        "ExecuteBatch(Call[] calls,uint256 nonce,uint256 deadline)";
    bytes private constant TRANSFER_TYPESTRING = "Transfer(address token,uint256 amount)";
    bytes private constant ONTRANSFERRECEIVED2CALL_TYPESTRING =
        "OnTransferReceived2Call(address operator,address from,Transfer[] transfers,Call[] calls,uint256 nonce,uint256 deadline)";

    bytes32 private constant EXECUTEBATCH_TYPEHASH =
        keccak256(abi.encodePacked(EXECUTEBATCH_TYPESTRING, CallLib.CALL_TYPESTRING));
    bytes32 private constant TRANSFER_TYPEHASH = keccak256(TRANSFER_TYPESTRING);
    bytes32 private constant ONTRANSFERRECEIVED2CALL_TYPEHASH =
        keccak256(
            abi.encodePacked(
                ONTRANSFERRECEIVED2CALL_TYPESTRING,
                CallLib.CALL_TYPESTRING,
                TRANSFER_TYPESTRING
            )
        );

    string private constant VERSION = "1.0.0";

    bool internal forwardNFT;
    NonceMap private nonceMap;

    /// @notice Data does not match the expected format
    error InvalidData();
    /// @notice Signature is invalid
    error InvalidSignature();
    /// @notice Nonce has already been used
    error NonceAlreadyUsed();
    /// @notice Deadline has expired
    error DeadlineExpired();
    /// @notice Only Supa can call this function
    error OnlySupa();
    /// @notice Only the owner or operator can call this function
    error NotOwnerOrOperator();
    /// @notice Only the owner can call this function
    error OnlyOwner();
    /// @notice Only this address can call this function
    error OnlyThisAddress();
    /// @notice The wallet is insolvent
    error Insolvent();

    modifier onlyOwner() {
        if (supa.getWalletOwner(address(this)) != msg.sender) {
            revert OnlyOwner();
        }
        _;
    }

    modifier onlyOwnerOrOperator() {
        if (
            supa.getWalletOwner(address(this)) != msg.sender &&
            !supa.isOperator(address(this), msg.sender)
        ) {
            revert NotOwnerOrOperator();
        }
        _;
    }

    modifier onlySupa() {
        if (msg.sender != address(supa)) {
            revert OnlySupa();
        }
        _;
    }

    // Note EIP712 is implemented with immutable variables and is not using
    // storage and thus can be used in a proxy contract constructor.
    // Version number should be in sync with VersionManager version.
    constructor(
        address _supa
    ) EIP712("Supa wallet", VERSION) ImmutableVersion(VERSION) WalletState(_supa) {}

    /// @notice makes a batch of different calls from the name of wallet owner. Eventual state of
    /// creditAccount and Supa must be solvent, i.e. debt on creditAccount cannot exceed collateral on
    /// creditAccount and wallet and Supa reserve/debt must be sufficient
    /// @dev - this goes to supa.executeBatch that would immediately call WalletProxy.executeBatch
    /// from above of this file
    /// @param calls {address to, bytes callData, uint256 value}[], where
    ///   * to - is the address of the contract whose function should be called
    ///   * callData - encoded function name and it's arguments
    ///   * value - the amount of ETH to sent with the call
    function executeBatch(Call[] memory calls) external payable onlyOwnerOrOperator {
        bool saveForwardNFT = forwardNFT;
        forwardNFT = false;
        CallLib.executeBatch(calls);
        forwardNFT = saveForwardNFT;

        if (!supa.isSolvent(address(this))) {
            revert Insolvent();
        }
    }

    function executeSignedBatch(
        Call[] memory calls,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external payable {
        if (deadline < block.timestamp) revert DeadlineExpired();
        nonceMap.validateAndUseNonce(nonce);
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(EXECUTEBATCH_TYPEHASH, CallLib.hashCallArray(calls), nonce, deadline)
            )
        );
        if (
            !SignatureChecker.isValidSignatureNow(
                supa.getWalletOwner(address(this)),
                digest,
                signature
            )
        ) revert InvalidSignature();

        supa.executeBatch(calls);
    }

    function forwardNFTs(bool _forwardNFT) external {
        if (msg.sender != address(this)) {
            revert OnlyThisAddress();
        }
        forwardNFT = _forwardNFT;
    }

    /// @notice ERC721 transfer callback
    /// @dev it's a callback, required to be implemented by IERC721Receiver interface for the
    /// contract to be able to receive ERC721 NFTs.
    /// we are already using it to support "forwardNFT" of wallet.
    /// `return this.onERC721Received.selector;` is mandatory part for the NFT transfer to work -
    /// not a part of owr business logic
    /// @param - operator The address which called `safeTransferFrom` function
    /// @param - from The address which previously owned the token
    /// @param tokenId The NFT identifier which is being transferred
    /// @param data Additional data with no specified format
    /// @return `bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"))`
    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 tokenId,
        bytes memory data
    ) public virtual override returns (bytes4) {
        if (forwardNFT) {
            IERC721(msg.sender).safeTransferFrom(address(this), address(supa), tokenId, data);
        }
        return this.onERC721Received.selector;
    }

    function setNonce(uint256 nonce) external onlyOwner {
        nonceMap.validateAndUseNonce(nonce);
    }

    /// @inheritdoc ITransferReceiver2
    function onTransferReceived2(
        address operator,
        address from,
        ITransferReceiver2.Transfer[] calldata transfers,
        bytes calldata data
    ) external override onlyTransferAndCall2 returns (bytes4) {
        // options:
        // 1) just deposit into proxy, nothing to do
        // 2) execute a batch of calls (msg.sender is owner)
        // 3) directly deposit into supa contract
        // 3) execute a signed batch of tx's
        if (data.length == 0) {
            /* just deposit in the proxy, nothing to do */
        } else if (data[0] == 0x00) {
            // execute batch
            if (msg.sender != supa.getWalletOwner(address(this))) {
                revert OnlyOwner();
            }
            Call[] memory calls = abi.decode(data[1:], (Call[]));
            supa.executeBatch(calls);
        } else if (data[0] == 0x01) {
            if (data.length != 1) revert InvalidData();
            // deposit in the supa wallet
            for (uint256 i = 0; i < transfers.length; i++) {
                ITransferReceiver2.Transfer memory transfer = transfers[i];
                supa.depositERC20(IERC20(transfer.token), transfer.amount);
            }
        } else if (data[0] == 0x02) {
            // execute signed batch

            // Verify signature matches
            (Call[] memory calls, uint256 nonce, uint256 deadline, bytes memory signature) = abi
                .decode(data[1:], (Call[], uint256, uint256, bytes));

            if (deadline < block.timestamp) revert DeadlineExpired();
            nonceMap.validateAndUseNonce(nonce);

            bytes32[] memory transferDigests = new bytes32[](transfers.length);
            for (uint256 i = 0; i < transfers.length; i++) {
                transferDigests[i] = keccak256(
                    abi.encode(TRANSFER_TYPEHASH, transfers[i].token, transfers[i].amount)
                );
            }
            bytes32 digest = _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        ONTRANSFERRECEIVED2CALL_TYPEHASH,
                        operator,
                        from,
                        keccak256(abi.encodePacked(transferDigests)),
                        CallLib.hashCallArray(calls),
                        nonce,
                        deadline
                    )
                )
            );
            if (
                !SignatureChecker.isValidSignatureNow(
                    supa.getWalletOwner(address(this)),
                    digest,
                    signature
                )
            ) revert InvalidSignature();

            supa.executeBatch(calls);
        } else {
            revert("Invalid data - allowed are '', '0x00...', '0x01' and '0x02...'");
        }
        return ITransferReceiver2.onTransferReceived2.selector;
    }

    function onApprovalReceived(
        address sender,
        uint256 amount,
        Call memory call
    ) external onlySupa returns (bytes4) {
        if (call.callData.length == 0) {
            revert InvalidData();
        }
        emit TokensApproved(sender, amount, call.callData);

        Call[] memory calls = new Call[](1);
        calls[0] = call;

        supa.executeBatch(calls);

        return this.onApprovalReceived.selector;
    }

    function owner() external view returns (address) {
        return supa.getWalletOwner(address(this));
    }

    /// @inheritdoc IERC1271
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) public view override returns (bytes4 magicValue) {
        magicValue = SignatureChecker.isValidSignatureNow(
            supa.getWalletOwner(address(this)),
            hash,
            signature
        )
            ? this.isValidSignature.selector
            : bytes4(0);
    }

    function valueNonce(uint256 nonce) external view returns (bool) {
        return nonceMap.getNonce(nonce);
    }
}
