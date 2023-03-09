// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {IPermit2} from "contracts/external/interfaces/IPermit2.sol";
import {TransferAndCall2} from "contracts/supa/TransferAndCall2.sol";
import {TestERC20} from "contracts/testing/TestERC20.sol";
import {TestNFT} from "contracts/testing/TestNFT.sol";
import {MockERC20Oracle} from "contracts/testing/MockERC20Oracle.sol";
import {MockNFTOracle} from "contracts/testing/MockNFTOracle.sol";
import {Supa, ISupa} from "contracts/supa/Supa.sol";
import {SupaConfig, ISupaConfig} from "contracts/supa/SupaConfig.sol";
import {VersionManager, IVersionManager} from "contracts/supa/VersionManager.sol";
import {WalletLogic} from "contracts/wallet/WalletLogic.sol";
import {WalletProxy} from "contracts/wallet/WalletProxy.sol";
import {Call, CallLib} from "contracts/lib/Call.sol";
import {ITransferReceiver2} from "contracts/interfaces/ITransferReceiver2.sol";

import {SigUtils, ECDSA} from "test/foundry/utils/SigUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract WalletTest is Test {
    IPermit2 public permit2;
    TransferAndCall2 public transferAndCall2;

    TestERC20 public usdc;
    TestERC20 public weth;
    TestNFT public nft;
    TestNFT public unregisteredNFT;

    MockERC20Oracle public usdcChainlink;
    MockERC20Oracle public ethChainlink;

    MockNFTOracle public nftOracle;

    Supa public supa;
    SupaConfig public supaConfig;
    VersionManager public versionManager;
    WalletLogic public proxyLogic;

    WalletProxy public treasurySafe;
    WalletProxy public userSafe;

    bytes32 fsSALT = bytes32(0x1234567890123456789012345678901234567890123456789012345678901234);

    string version = "1.0.0";

    function setUp() public {
        address owner = address(this);

        usdc = new TestERC20("Circle USD", "USDC", 6);
        weth = new TestERC20("Wrapped Ether", "WETH", 18);
        nft = new TestNFT("Test NFT", "TNFT", 0);
        unregisteredNFT = new TestNFT("Unregistered NFT", "UNFT", 0);

        usdcChainlink = new MockERC20Oracle(owner);
        ethChainlink = new MockERC20Oracle(owner);

        nftOracle = new MockNFTOracle();

        versionManager = new VersionManager(owner);
        supaConfig = new SupaConfig(owner);
        supa = new Supa(address(supaConfig), address(versionManager));
        proxyLogic = new WalletLogic(address(supa));

        ISupaConfig(address(supa)).setConfig(
            ISupaConfig.Config({
                treasurySafe: address(0),
                treasuryInterestFraction: 0,
                maxSolvencyCheckGasCost: 10_000_000,
                liqFraction: 8e17,
                fractionalReserveLeverage: 10
            })
        );

        versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(proxyLogic));
        versionManager.markRecommendedVersion(version);

        transferAndCall2 = TransferAndCall2(0x1554b484D2392672F0375C56d80e91c1d070a007);
        vm.etch(address(transferAndCall2), type(TransferAndCall2).creationCode);
        // transferAndCall2 = new TransferAndCall2{salt: fsSALT}();
        usdc.approve(address(transferAndCall2), type(uint256).max);
        weth.approve(address(transferAndCall2), type(uint256).max);
    }

    function test_validExecuteSignedBatch() public {
        SigUtils sigUtils = new SigUtils();
        uint256 userPrivateKey = 0xB0B;
        address user = vm.addr(userPrivateKey);
        console.log("user: %s", user);
        vm.prank(user);
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        Call[] memory calls = new Call[](0);
        uint256 nonce = 0;
        uint256 deadline = type(uint256).max;

        bytes32 digest = sigUtils.getTypedDataHash(address(userSafe), calls, nonce, deadline);
        console.log("digest");
        console.logBytes32(digest);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        address recovered = ecrecover(digest, v, r, s);
        console.log("recovered");
        console.logAddress(recovered);

        WalletLogic(address(userSafe)).executeSignedBatch(calls, nonce, deadline, signature);
    }

    function test_transferAndCall2ToProxy() public {
        // TODO

        deal({token: address(usdc), to: address(this), give: 10_000 * 1e6});

        deal({token: address(weth), to: address(this), give: 1 * 1 ether});

        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        ITransferReceiver2.Transfer[] memory transfers = new ITransferReceiver2.Transfer[](2);

        transfers[0] = ITransferReceiver2.Transfer({token: address(usdc), amount: 10_000 * 1e6});

        transfers[1] = ITransferReceiver2.Transfer({token: address(weth), amount: 1 * 1 ether});

        _sortTransfers(transfers);

        bytes memory data = bytes("0x");
        transferAndCall2.transferAndCall2(address(userSafe), transfers, data);
    }

    function test_transferAndCall2ToSupa() public {
        // TODO
    }

    function test_transferAndCall2WithSwap() public {
        // TODO
    }

    function test_upgradeVersion() public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        _upgradeWalletImplementation(versionName);
    }

    function test_upgradeInvalidVersion(string memory invalidVersionName) public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        if (
            keccak256(abi.encodePacked(invalidVersionName)) == keccak256(abi.encodePacked(version))
        ) {
            invalidVersionName = "1.0.1";
        }
        vm.expectRevert();
        _upgradeWalletImplementation(invalidVersionName);
    }

    function test_upgradeDeprecatedVersion() public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.DEPRECATED,
            IVersionManager.BugLevel.NONE
        );
        vm.expectRevert();
        _upgradeWalletImplementation(versionName);
    }

    function test_upgradeLowBugVersion() public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.PRODUCTION,
            IVersionManager.BugLevel.LOW
        );
        vm.expectRevert();
        _upgradeWalletImplementation(versionName);
    }

    function test_upgradeMedBugVersion() public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.PRODUCTION,
            IVersionManager.BugLevel.MEDIUM
        );
        vm.expectRevert();
        _upgradeWalletImplementation(versionName);
    }

    function test_upgradeHighBugVersion() public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.PRODUCTION,
            IVersionManager.BugLevel.HIGH
        );
        vm.expectRevert();
        _upgradeWalletImplementation(versionName);
    }

    function test_upgradeCriticalBugVersion() public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.PRODUCTION,
            IVersionManager.BugLevel.CRITICAL
        );
        vm.expectRevert();
        _upgradeWalletImplementation(versionName);
    }

    function test_proposeTransferWalletOwnership(address newOwner) public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(supa),
            callData: abi.encodeWithSignature("proposeTransferWalletOwnership(address)", newOwner),
            value: 0
        });
        userSafe.executeBatch(calls);
        address proposedOwner = SupaConfig(address(supa)).walletProposedNewOwner(address(userSafe));
        assert(proposedOwner == newOwner);
    }

    function test_executeTransferWalletOwnership(address newOwner) public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(supa),
            callData: abi.encodeWithSignature("proposeTransferWalletOwnership(address)", newOwner),
            value: 0
        });
        userSafe.executeBatch(calls);

        vm.prank(newOwner);
        ISupa(address(supa)).executeTransferWalletOwnership(address(userSafe));

        address actualOwner = ISupa(address(supa)).getWalletOwner(address(userSafe));
        assert(actualOwner == newOwner);
    }

    function test_executeInvalidOwnershipTransfer(address newOwner) public {
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        vm.prank(newOwner);
        vm.expectRevert();
        ISupa(address(supa)).executeTransferWalletOwnership(address(userSafe));
    }

    function _setupSafes() internal {
        treasurySafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
        userSafe = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));
    }

    function _upgradeWalletImplementation(string memory versionName) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(supa),
            callData: abi.encodeWithSignature("upgradeWalletImplementation(string)", versionName),
            value: 0
        });
        userSafe.executeBatch(calls);
    }

    function _sortTransfers(ITransferReceiver2.Transfer[] memory transfers) internal pure {
        for (uint256 i = 0; i < transfers.length; i++) {
            for (uint256 j = i + 1; j < transfers.length; j++) {
                if (transfers[i].token > transfers[j].token) {
                    ITransferReceiver2.Transfer memory temp = transfers[i];
                    transfers[i] = transfers[j];
                    transfers[j] = temp;
                }
            }
        }
    }
}
