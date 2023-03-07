// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {DOS, IDOS, DSafeLib, DOSState, IDOSCore, TokenStorageExceeded} from "../../contracts/dos/DOS.sol";
import {DOSConfig, IDOSConfig} from "../../contracts/dos/DOSConfig.sol";

import {Call} from "../../contracts/lib/Call.sol";
import {DSafeProxy} from "../../contracts/dsafe/DSafeProxy.sol";
import {DSafeLogic} from "../../contracts/dsafe/DSafeLogic.sol";

import {IVersionManager, VersionManager, ImmutableVersion} from "../../contracts/dos/VersionManager.sol";

import {MockERC20Oracle} from "../../contracts/testing/MockERC20Oracle.sol";
import {ERC20ChainlinkValueOracle} from "../../contracts/oracles/ERC20ChainlinkValueOracle.sol";
import {MockNFTOracle} from "../../contracts/testing/MockNFTOracle.sol";

import {TestERC20} from "../../contracts/testing/TestERC20.sol";
import {TestNFT} from "../../contracts/testing/TestNFT.sol";

contract DosTest is Test {
    uint256 mainnetFork;
    address public user = 0x8FffFfD4AFb6115b954bd326CbE7b4bA576818f5;

    VersionManager public versionManager;
    DOS public dos;
    DOSConfig public dosConfig;
    DSafeLogic public logic;

    DSafeProxy public userSafe;

    // IWETH9 public weth = IWETH9(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // Mainnet WETH

    // Create 2 tokens
    TestERC20 public token0;
    TestERC20 public token1;

    MockERC20Oracle public token0Oracle;
    MockERC20Oracle public token1Oracle;

    TestNFT public nft0;
    MockNFTOracle public nft0Oracle;

    // string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");

    function setUp() public {
        // mainnetFork = vm.createFork(MAINNET_RPC_URL);
        // vm.selectFork(mainnetFork);
        address owner = address(this);

        // deploy DOS contracts
        versionManager = new VersionManager(owner);
        dosConfig = new DOSConfig(owner);
        dos = new DOS(address(dosConfig), address(versionManager));
        logic = new DSafeLogic(address(dos));

        IDOSConfig(address(dos)).setConfig(
            IDOSConfig.Config({
                treasurySafe: address(0),
                treasuryInterestFraction: 5e16,
                maxSolvencyCheckGasCost: 1e6,
                liqFraction: 8e17,
                fractionalReserveLeverage: 9
            })
        );

        IDOSConfig(address(dos)).setTokenStorageConfig(
            IDOSConfig.TokenStorageConfig({
                maxTokenStorage: 250,
                erc20Multiplier: 1,
                erc721Multiplier: 1
            })
        );

        // setup tokens
        token0 = new TestERC20("token0", "t0", 18);
        token1 = new TestERC20("token1", "t1", 18);

        token0Oracle = new MockERC20Oracle(owner);
        token0Oracle.setPrice(1e18, 18, 18);
        token0Oracle.setRiskFactors(9e17, 9e17);

        token1Oracle = new MockERC20Oracle(owner);
        token1Oracle.setPrice(1e18, 18, 18);
        token1Oracle.setRiskFactors(9e17, 9e17);

        nft0 = new TestNFT("nft0", "n0", 0);
        nft0Oracle = new MockNFTOracle();

        IDOSConfig(address(dos)).addERC20Info(
            address(token0),
            "token0",
            "t0",
            18,
            address(token0Oracle),
            0, // baseRate
            5, // slope1
            480, // slope2
            8e17 // targetUtilization
        );
        IDOSConfig(address(dos)).addERC20Info(
            address(token1),
            "token1",
            "t1",
            18,
            address(token1Oracle),
            0, // baseRate
            5, // slope1
            480, // slope2
            8e17 // targetUtilization
        );

        IDOSConfig(address(dos)).addERC721Info(address(nft0), address(nft0Oracle));

        // add to version manager
        string memory version = "1.0.0";
        versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(logic));
        versionManager.markRecommendedVersion(version);
    }

    function test_CreateDSafe() public {
        vm.startPrank(user);
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        vm.stopPrank();
    }

    function test_DepositERC20(uint96 _amount0, uint96 _amount1) public {
        vm.startPrank(user);
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        _mintTokens(address(userSafe), _amount0, _amount1);

        // construct calls
        Call[] memory calls = new Call[](4);

        // set token allowances
        calls[0] = (
            Call({
                to: address(token0),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(dos),
                    _amount0
                ),
                value: 0
            })
        );
        calls[1] = (
            Call({
                to: address(token1),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(dos),
                    _amount1
                ),
                value: 0
            })
        );

        // deposit erc20 tokens
        calls[2] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    token0,
                    uint256(_amount0)
                ),
                value: 0
            })
        );

        calls[3] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    token1,
                    uint256(_amount1)
                ),
                value: 0
            })
        );

        // execute batch
        DSafeLogic(address(userSafe)).executeBatch(calls);
        vm.stopPrank();
    }

    function test_DepositERC20ForSafe(uint96 _amount0, uint96 _amount1) public {
        vm.startPrank(user);
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        vm.stopPrank();

        _mintTokens(address(this), _amount0, _amount1);

        // set allowances
        token0.approve(address(dos), _amount0);
        token1.approve(address(dos), _amount1);

        dos.depositERC20ForSafe(address(token0), address(userSafe), _amount0);
        dos.depositERC20ForSafe(address(token1), address(userSafe), _amount1);
    }

    /// @dev using uint96 to avoid arithmetic overflow in uint -> int conversion
    function test_TransferERC20(uint96 _amount0) public {
        vm.startPrank(user);
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        DSafeProxy userSafe2 = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

        // mint tokens to user's wallet
        token0.mint(address(userSafe), _amount0);

        // construct calls
        Call[] memory calls = new Call[](3);

        // set token allowances
        calls[0] = (
            Call({
                to: address(token0),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(dos),
                    uint256(_amount0)
                ),
                value: 0
            })
        );
        calls[1] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    token0,
                    uint256(_amount0)
                ),
                value: 0
            })
        );
        calls[2] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "transferERC20(address,address,uint256)",
                    token0,
                    address(userSafe2),
                    uint256(_amount0)
                ),
                value: 0
            })
        );

        userSafe.executeBatch(calls);
        vm.stopPrank();
    }

    function test_DepositThenTransfer(uint96 _amount0) public {
        vm.startPrank(user);
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        DSafeProxy userSafe2 = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

        // mint tokens to user's wallet
        token0.mint(address(userSafe), _amount0);

        // construct calls
        Call[] memory calls = new Call[](3);

        // set token allowances
        calls[0] = (
            Call({
                to: address(token0),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(dos),
                    uint256(_amount0)
                ),
                value: 0
            })
        );
        calls[1] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "transferERC20(address,address,uint256)",
                    token0,
                    address(userSafe2),
                    uint256(_amount0)
                ),
                value: 0
            })
        );
        calls[2] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    token0,
                    uint256(_amount0)
                ),
                value: 0
            })
        );

        userSafe.executeBatch(calls);
        vm.stopPrank();
    }

    function test_TransferMoreThanBalance(uint96 _amount, uint96 _extraAmount) public {
        vm.assume(_amount > 1 ether);
        vm.assume(_extraAmount > 1);
        DSafeProxy otherSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        vm.startPrank(user);
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

        // mint tokens to user's wallet
        token0.mint(address(userSafe), _amount);

        // construct calls
        Call[] memory calls = new Call[](3);

        // set token allowances
        calls[0] = (
            Call({
                to: address(token0),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(dos),
                    uint256(_amount)
                ),
                value: 0
            })
        );
        calls[1] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    token0,
                    uint256(_amount)
                ),
                value: 0
            })
        );
        calls[2] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "transferERC20(address,address,uint256)",
                    token0,
                    address(otherSafe),
                    uint256(_amount) + uint256(_extraAmount)
                ),
                value: 0
            })
        );

        vm.expectRevert();
        userSafe.executeBatch(calls);
        vm.stopPrank();
    }

    function test_depositERC20IncreaseTokenCounter(uint256 amount) public {
        amount = bound(amount, 0, uint256(type(int256).max));
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (, int256 tokenCounter) = DOSState(dos).dSafes(address(userSafe));
        assertEq(tokenCounter, 0);
        _mintTokens(address(this), amount, 0);
        token0.approve(address(dos), amount);
        dos.depositERC20ForSafe(address(token0), address(userSafe), amount);
        (, tokenCounter) = DOSState(dos).dSafes(address(userSafe));
        if (amount == 0) {
            assertEq(tokenCounter, 0);
        } else {
            assertEq(tokenCounter, 1);
        }
    }

    function test_depositERC20IncreaseTokenCounter2(uint256 amount) public {
        amount = bound(amount, 0, uint256(type(int256).max));
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (, int256 tokenCounter) = DOSState(dos).dSafes(address(userSafe));
        assertEq(tokenCounter, 0);
        _mintTokens(address(this), amount, amount);
        token0.approve(address(dos), amount);
        token1.approve(address(dos), amount);
        dos.depositERC20ForSafe(address(token0), address(userSafe), amount);
        dos.depositERC20ForSafe(address(token1), address(userSafe), amount);
        (, tokenCounter) = DOSState(dos).dSafes(address(userSafe));
        if (amount == 0) {
            assertEq(tokenCounter, 0);
        } else {
            assertEq(tokenCounter, 2);
        }
    }

    function test_withdrawERC20DecreaseTokenCounter(uint256 amount) public {
        // NOTE: reverts with some amount > 2^96
        amount = bound(amount, 0, uint256(int256(type(int96).max)));
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        (, int256 tokenCounter) = DOSState(dos).dSafes(address(userSafe));
        assertEq(tokenCounter, 0);
        _mintTokens(address(this), amount, 0);
        token0.approve(address(dos), amount);
        dos.depositERC20ForSafe(address(token0), address(userSafe), amount);
        (, tokenCounter) = DOSState(dos).dSafes(address(userSafe));
        if (amount == 0) {
            assertEq(tokenCounter, 0);
        } else {
            assertEq(tokenCounter, 1);
            Call[] memory calls = new Call[](1);
            calls[0] = (
                Call({
                    to: address(dos),
                    callData: abi.encodeWithSignature(
                        "withdrawERC20(address,uint256)",
                        address(token0),
                        amount
                    ),
                    value: 0
                })
            );
            userSafe.executeBatch(calls);
            (, tokenCounter) = DOSState(dos).dSafes(address(userSafe));
            assertEq(tokenCounter, 0);
        }
    }

    function test_depositERC721IncreaseNftCounter() public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        nft0Oracle.setPrice(0, 1 ether);
        uint256 nftCounter = DOSConfig(address(dos)).getDAccountERC721Counter(address(userSafe));
        assertEq(nftCounter, 0);
        nft0.mint(address(userSafe));
        Call[] memory calls = new Call[](1);
        calls[0] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC721(address,uint256)",
                    address(nft0),
                    0
                ),
                value: 0
            })
        );
        userSafe.executeBatch(calls);
        nftCounter = DOSConfig(address(dos)).getDAccountERC721Counter(address(userSafe));
        assertEq(nftCounter, 1);
    }

    function test_withdrawERC721DecreaseNftCounter() public {
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        nft0Oracle.setPrice(0, 1 ether);
        uint256 nftCounter = DOSConfig(address(dos)).getDAccountERC721Counter(address(userSafe));
        assertEq(nftCounter, 0);
        nft0.mint(address(userSafe));
        Call[] memory calls = new Call[](1);
        calls[0] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC721(address,uint256)",
                    address(nft0),
                    0
                ),
                value: 0
            })
        );
        userSafe.executeBatch(calls);
        nftCounter = DOSConfig(address(dos)).getDAccountERC721Counter(address(userSafe));
        assertEq(nftCounter, 1);
        calls[0] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "withdrawERC721(address,uint256)",
                    address(nft0),
                    0
                ),
                value: 0
            })
        );
        userSafe.executeBatch(calls);
        nftCounter = DOSConfig(address(dos)).getDAccountERC721Counter(address(userSafe));
        assertEq(nftCounter, 0);
    }

    function test_exceedMaxTokenStorage() public {
        IDOSConfig(address(dos)).setTokenStorageConfig(
            IDOSConfig.TokenStorageConfig({
                maxTokenStorage: 100,
                erc20Multiplier: 100,
                erc721Multiplier: 1
            })
        );

        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        _mintTokens(address(this), 100 * 1 ether, 100 * 1 ether);
        token0.approve(address(dos), 100 * 1 ether);
        token1.approve(address(dos), 100 * 1 ether);
        dos.depositERC20ForSafe(address(token0), address(userSafe), 100 * 1 ether);
        vm.expectRevert(TokenStorageExceeded.selector);
        dos.depositERC20ForSafe(address(token1), address(userSafe), 100 * 1 ether);
    }

    function test_exceedMaxTokenStorageNFT() public {
        IDOSConfig(address(dos)).setTokenStorageConfig(
            IDOSConfig.TokenStorageConfig({
                maxTokenStorage: 1,
                erc20Multiplier: 1,
                erc721Multiplier: 1
            })
        );

        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        _mintTokens(address(this), 100 * 1 ether, 100 * 1 ether);
        token0.approve(address(dos), 100 * 1 ether);
        token1.approve(address(dos), 100 * 1 ether);
        dos.depositERC20ForSafe(address(token0), address(userSafe), 100 * 1 ether);

        nft0.mint(address(userSafe));
        Call[] memory calls = new Call[](1);
        calls[0] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC721(address,uint256)",
                    address(nft0),
                    0
                ),
                value: 0
            })
        );
        vm.expectRevert(TokenStorageExceeded.selector);
        userSafe.executeBatch(calls);
    }

    function test_increaseMaxTokenStorage() public {
        IDOSConfig(address(dos)).setTokenStorageConfig(
            IDOSConfig.TokenStorageConfig({
                maxTokenStorage: 100,
                erc20Multiplier: 100,
                erc721Multiplier: 1
            })
        );

        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        _mintTokens(address(this), 100 * 1 ether, 100 * 1 ether);
        token0.approve(address(dos), 100 * 1 ether);
        token1.approve(address(dos), 100 * 1 ether);
        dos.depositERC20ForSafe(address(token0), address(userSafe), 100 * 1 ether);
        vm.expectRevert(TokenStorageExceeded.selector);
        dos.depositERC20ForSafe(address(token1), address(userSafe), 100 * 1 ether);

        IDOSConfig(address(dos)).setTokenStorageConfig(
            IDOSConfig.TokenStorageConfig({
                maxTokenStorage: 250,
                erc20Multiplier: 1,
                erc721Multiplier: 1
            })
        );
        dos.depositERC20ForSafe(address(token1), address(userSafe), 100 * 1 ether);
    }

    function test_decreaseMaxTokenStorage() public {
        IDOSConfig(address(dos)).setTokenStorageConfig(
            IDOSConfig.TokenStorageConfig({
                maxTokenStorage: 100,
                erc20Multiplier: 10,
                erc721Multiplier: 1
            })
        );

        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        _mintTokens(address(this), 100 * 1 ether, 100 * 1 ether);
        token0.approve(address(dos), 100 * 1 ether);
        token1.approve(address(dos), 100 * 1 ether);
        dos.depositERC20ForSafe(address(token0), address(userSafe), 100 * 1 ether);
        dos.depositERC20ForSafe(address(token1), address(userSafe), 100 * 1 ether);

        IDOSConfig(address(dos)).setTokenStorageConfig(
            IDOSConfig.TokenStorageConfig({
                maxTokenStorage: 10,
                erc20Multiplier: 10,
                erc721Multiplier: 1
            })
        );
        nft0.mint(address(userSafe));
        Call[] memory calls = new Call[](1);
        calls[0] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC721(address,uint256)",
                    address(nft0),
                    0
                ),
                value: 0
            })
        );
        vm.expectRevert(TokenStorageExceeded.selector);
        userSafe.executeBatch(calls);
    }

    function _mintTokens(address to, uint256 amount0, uint256 amount1) internal {
        token0.mint(to, amount0);
        token1.mint(to, amount1);
    }
}
