// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {IDOS, DOS, DOSConfig, IDOSConfig, DSafeLib, DOSState, IDOSCore} from "../../contracts/dos/DOS.sol";

import {Call} from "../../contracts/lib/Call.sol";
import {DSafeProxy, DSafeLogic} from "../../contracts/dos/DSafeProxy.sol";

import {IVersionManager, VersionManager, ImmutableVersion} from "../../contracts/dos/VersionManager.sol";

import {ERC20ChainlinkValueOracle} from "../../contracts/oracles/ERC20ChainlinkValueOracle.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {TestERC20} from "../../contracts/testing/TestERC20.sol";

contract DosTest is Test {
    uint256 mainnetFork;
    address user = 0x5FbDB2315678afecb367f032d93F642f64180aa3; // random address

    VersionManager public versionManager;
    DOS public dos;
    DOSConfig public dosConfig;
    DSafeLogic public logic;

    DSafeProxy public userSafe;

    // IWETH9 public weth = IWETH9(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // Mainnet WETH

    // Create 2 tokens
    TestERC20 public token0;
    TestERC20 public token1;

    AggregatorV3Interface public oracleAddress =
        AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);

    ERC20ChainlinkValueOracle public token0Oracle;
    ERC20ChainlinkValueOracle public token1Oracle;

    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");

    function setUp() public {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
        vm.selectFork(mainnetFork);
        address owner = address(this);

        // deploy DOS contracts
        versionManager = new VersionManager(owner);
        dosConfig = new DOSConfig(owner);
        dos = new DOS(address(dosConfig), address(versionManager));
        logic = new DSafeLogic(address(dos));

        IDOSConfig(address(dos)).setConfig(
            IDOSConfig.Config({
                treasurySafe: address(0),
                treasuryInterestFraction: 0,
                maxSolvencyCheckGasCost: 10_000_000,
                liqFraction: 8e17,
                fractionalReserveLeverage: 10
            })
        );

        // setup tokens
        token0 = new TestERC20("token0", "t0", 18);
        token1 = new TestERC20("token1", "t1", 18);
        token0Oracle = new ERC20ChainlinkValueOracle(address(oracleAddress), 18, 18, 0, 0, owner);
        token1Oracle = new ERC20ChainlinkValueOracle(address(oracleAddress), 18, 18, 0, 0, owner);

        IDOSConfig(address(dos)).addERC20Info(
            address(token0),
            "token0",
            "t0",
            18,
            address(token0Oracle),
            9e17,
            9e17,
            0,
            0
        );
        IDOSConfig(address(dos)).addERC20Info(
            address(token1),
            "token1",
            "t1",
            18,
            address(token1Oracle),
            9e17,
            9e17,
            0,
            0
        );

        // add to version manager
        string memory version = "1.0.0";
        versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(logic));
        versionManager.markRecommendedVersion(version);
    }

    function testCreateDSafe() public {
        vm.startPrank(user);
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        vm.stopPrank();
    }

    function testDepositERC20(uint96 _amount0, uint96 _amount1) public {
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

    function testDepositERC20ForSafe(uint96 _amount0, uint96 _amount1) public {
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
    function testTransferERC20(uint96 _amount0) public {
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

    function testDepositThenTransfer(uint96 _amount0) public {
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

    function testTransferMoreThanBalance(uint96 _amount) public {
        vm.startPrank(user);
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));
        DSafeProxy userSafe2 = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

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
                    address(userSafe2),
                    uint256(_amount + 1)
                ),
                value: 0
            })
        );

        userSafe.executeBatch(calls);
        vm.stopPrank();
    }

    function _mintTokens(address to, uint256 amount0, uint256 amount1) internal {
        token0.mint(to, amount0);
        token1.mint(to, amount1);
    }
}
