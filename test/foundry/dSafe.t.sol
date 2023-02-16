// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {IPermit2} from "contracts/external/interfaces/IPermit2.sol";
import {TransferAndCall2} from "contracts/dos/TransferAndCall2.sol";
import {TestERC20} from "contracts/testing/TestERC20.sol";
import {TestNFT} from "contracts/testing/TestNFT.sol";
import {MockERC20Oracle} from "contracts/testing/MockERC20Oracle.sol";
import {MockNFTOracle} from "contracts/testing/MockNFTOracle.sol";
import {DOS, IDOS} from "contracts/dos/DOS.sol";
import {DOSConfig, IDOSConfig} from "contracts/dos/DOSConfig.sol";
import {VersionManager, IVersionManager} from "contracts/dos/VersionManager.sol";
import {DSafeLogic} from "contracts/dsafe/DSafeLogic.sol";
import {DSafeProxy} from "contracts/dsafe/DSafeProxy.sol";
import {Call, CallLib} from "contracts/lib/Call.sol";
import {ITransferReceiver2} from "contracts/interfaces/ITransferReceiver2.sol";

import {SigUtils, ECDSA} from "test/foundry/utils/SigUtils.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract DSafeTest is Test {
    IPermit2 public permit2;
    TransferAndCall2 public transferAndCall2;

    TestERC20 public usdc;
    TestERC20 public weth;
    TestNFT public nft;
    TestNFT public unregisteredNFT;

    MockERC20Oracle public usdcChainlink;
    MockERC20Oracle public ethChainlink;

    MockNFTOracle public nftOracle;

    DOS public dos;
    DOSConfig public dosConfig;
    VersionManager public versionManager;
    DSafeLogic public proxyLogic;

    DSafeProxy public treasurySafe;
    DSafeProxy public userSafe;

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
        dosConfig = new DOSConfig(owner);
        dos = new DOS(address(dosConfig), address(versionManager));
        proxyLogic = new DSafeLogic(address(dos));

        IDOSConfig(address(dos)).setConfig(
            IDOSConfig.Config({
                treasurySafe: address(0),
                treasuryInterestFraction: 0,
                maxSolvencyCheckGasCost: 10_000_000,
                liqFraction: 8e17,
                fractionalReserveLeverage: 10
            })
        );

        versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(proxyLogic));
        versionManager.markRecommendedVersion(version);

        transferAndCall2 = TransferAndCall2(0x4e765952997a33893AfB4457A6A7f381909f3629);
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
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

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

        DSafeLogic(address(userSafe)).executeSignedBatch(calls, nonce, deadline, signature);
    }

    function test_transferAndCall2ToProxy() public {
        // TODO

        deal({token: address(usdc), to: address(this), give: 10_000 * 1e6});

        deal({token: address(weth), to: address(this), give: 1 * 1 ether});

        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

        ITransferReceiver2.Transfer[] memory transfers = new ITransferReceiver2.Transfer[](2);

        transfers[0] = ITransferReceiver2.Transfer({token: address(usdc), amount: 10_000 * 1e6});

        transfers[1] = ITransferReceiver2.Transfer({token: address(weth), amount: 1 * 1 ether});

        _sortTransfers(transfers);

        bytes memory data = bytes("0x");
        transferAndCall2.transferAndCall2(address(userSafe), transfers, data);
    }

    function test_transferAndCall2ToDOS() public {
        // TODO
    }

    function test_transferAndCall2WithSwap() public {
        // TODO
    }

    function test_upgradeVersion() public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        _upgradeDSafeImplementation(versionName);
    }

    function test_upgradeInvalidVersion(string memory invalidVersionName) public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        if (
            keccak256(abi.encodePacked(invalidVersionName)) == keccak256(abi.encodePacked(version))
        ) {
            invalidVersionName = "1.0.1";
        }
        vm.expectRevert();
        _upgradeDSafeImplementation(invalidVersionName);
    }

    function test_upgradeDeprecatedVersion() public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.DEPRECATED,
            IVersionManager.BugLevel.NONE
        );
        vm.expectRevert();
        _upgradeDSafeImplementation(versionName);
    }

    function test_upgradeLowBugVersion() public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.PRODUCTION,
            IVersionManager.BugLevel.LOW
        );
        vm.expectRevert();
        _upgradeDSafeImplementation(versionName);
    }

    function test_upgradeMedBugVersion() public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.PRODUCTION,
            IVersionManager.BugLevel.MEDIUM
        );
        vm.expectRevert();
        _upgradeDSafeImplementation(versionName);
    }

    function test_upgradeHighBugVersion() public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.PRODUCTION,
            IVersionManager.BugLevel.HIGH
        );
        vm.expectRevert();
        _upgradeDSafeImplementation(versionName);
    }

    function test_upgradeCriticalBugVersion() public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (string memory versionName, , , , ) = versionManager.getRecommendedVersion();
        versionManager.updateVersion(
            versionName,
            IVersionManager.Status.PRODUCTION,
            IVersionManager.BugLevel.CRITICAL
        );
        vm.expectRevert();
        _upgradeDSafeImplementation(versionName);
    }

    function test_proposeTransferDSafeOwnership(address newOwner) public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(dos),
            callData: abi.encodeWithSignature("proposeTransferDSafeOwnership(address)", newOwner),
            value: 0
        });
        userSafe.executeBatch(calls);
        address proposedOwner = DOSConfig(address(dos)).dSafeProposedNewOwner(address(userSafe));
        assert(proposedOwner == newOwner);
    }

    function test_executeTransferDSafeOwnership(address newOwner) public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(dos),
            callData: abi.encodeWithSignature("proposeTransferDSafeOwnership(address)", newOwner),
            value: 0
        });
        userSafe.executeBatch(calls);

        vm.prank(newOwner);
        IDOS(address(dos)).executeTransferDSafeOwnership(address(userSafe));

        address actualOwner = IDOS(address(dos)).getDSafeOwner(address(userSafe));
        assert(actualOwner == newOwner);
    }

    function test_executeInvalidOwnershipTransfer(address newOwner) public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

        vm.prank(newOwner);
        vm.expectRevert();
        IDOS(address(dos)).executeTransferDSafeOwnership(address(userSafe));
    }

    function _setupSafes() internal {
        treasurySafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
    }

    function _upgradeDSafeImplementation(string memory versionName) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(dos),
            callData: abi.encodeWithSignature("upgradeDSafeImplementation(string)", versionName),
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
