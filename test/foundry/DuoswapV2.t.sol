// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {Approval, IDOS, DOS, DOSConfig, IDOSConfig, DSafeLib, DOSState} from "../../contracts/dos/DOS.sol";
import {Call} from "../../contracts/lib/Call.sol";
import {DSafeProxy, DSafeLogic} from "../../contracts/dos/DSafeProxy.sol";
import {IVersionManager, VersionManager, ImmutableVersion} from "../../contracts/dos/VersionManager.sol";
// import "../src/dos/TransferAndCall2.sol";
import {DuoswapV2Factory} from "../../contracts/duoswapV2/DuoswapV2Factory.sol";
import {DuoswapV2Pair} from "../../contracts/duoswapV2/DuoswapV2Pair.sol";
import {DuoswapV2Router} from "../../contracts/duoswapV2/DuoswapV2Router.sol";

import {UniV2Oracle} from "../../contracts/oracles/UniV2Oracle.sol";
import {ERC20ChainlinkValueOracle} from "../../contracts/oracles/ERC20ChainlinkValueOracle.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestERC20} from "../../contracts/testing/TestERC20.sol";
import {IWETH9} from "../../contracts/external/interfaces/IWETH9.sol";

contract DuoswapV2Test is Test {
    uint256 mainnetFork;

    VersionManager public versionManager;
    DuoswapV2Factory public factory;
    DuoswapV2Pair public pair;
    DuoswapV2Router public router;

    DOS public dos;
    DOSConfig public dosConfig;
    DSafeProxy public userSafe;
    address public pairSafe;
    DSafeLogic public logic;

    IWETH9 public weth = IWETH9(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    // Create 2 tokens
    TestERC20 public token0;
    TestERC20 public token1;

    AggregatorV3Interface public oracleAddress =
        AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");

    ERC20ChainlinkValueOracle public token0Oracle;
    ERC20ChainlinkValueOracle public token1Oracle;
    UniV2Oracle public pairOracle;

    function setUp() public {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
        vm.selectFork(mainnetFork);
        token0 = new TestERC20("token0", "t0", 18);
        token1 = new TestERC20("token1", "t1", 18);

        token0Oracle = new ERC20ChainlinkValueOracle(address(oracleAddress), 18, 18);
        token1Oracle = new ERC20ChainlinkValueOracle(address(oracleAddress), 18, 18);

        versionManager = new VersionManager(address(this));
        dosConfig = new DOSConfig(address(this));
        dos = new DOS(address(dosConfig), address(versionManager));
        logic = new DSafeLogic(address(dos));
        bytes32 iVersion = ImmutableVersion(logic).immutableVersion();

        string memory version = "1.0.0";

        IDOSConfig(address(dos)).addERC20Info(
            address(token0),
            "token0",
            "t0",
            18,
            address(token0Oracle),
            9e17,
            9e17,
            0,
            0,
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
            0,
            0,
            0
        );

        IDOSConfig(address(dos)).setConfig(
            IDOSConfig.Config({liqFraction: 8e17, fractionalReserveLeverage: 10})
        );

        versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(logic));
        versionManager.markRecommendedVersion(version);

        (string memory versionName, , , address implementation, ) = versionManager
            .getRecommendedVersion();
        factory = new DuoswapV2Factory(address(dos), address(this));
        router = new DuoswapV2Router(address(factory), address(weth), address(dos));
    }

    function testCreatePair() public {
        pair = DuoswapV2Pair(factory.createPair(address(token0), address(token1)));
        assertEq(factory.allPairsLength(), 1);
        assertEq(factory.allPairs(0), address(pair));
        assertEq(factory.getPair(address(token0), address(token1)), address(pair));
        assertEq(factory.getPair(address(token1), address(token0)), address(pair));
    }

    function testAddLiquidity(uint96 _amount0, uint96 _amount1) public {
        uint256 amount0 = uint256(_amount0) + 1e18;
        uint256 amount1 = uint256(_amount1) + 1e18;

        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

        _depositTokens(amount0 * 100, amount1 * 100);

        pair = _createPair(address(token0), address(token1));
        pairSafe = pair.dSafe();

        token0.mint(address(userSafe), amount0);
        token1.mint(address(userSafe), amount1);
        Call[] memory calls = new Call[](1);
        IERC20[] memory tokens = new IERC20[](2);
        tokens[0] = token0;
        tokens[1] = token1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        bytes memory callData = abi.encodeWithSignature(
            "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
            address(token0),
            address(token1),
            amount0,
            amount1,
            0,
            0,
            address(userSafe),
            block.timestamp
        );

        Approval[] memory approvals = new Approval[](2);
        approvals[0] = (Approval({ercContract: address(tokens[0]), amountOrTokenId: amounts[0]}));
        approvals[1] = (Approval({ercContract: address(tokens[1]), amountOrTokenId: amounts[1]}));

        calls[0] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "approveAndCall((address,uint256)[],address,bytes)",
                    approvals,
                    address(router),
                    callData
                ),
                value: 0
            })
        );
        DSafeLogic(address(userSafe)).executeBatch(calls);
    }

    function testDepositTokens() public {
        // mint tokens
        token0.mint(address(this), 1e21);
        token1.mint(address(this), 1e21);

        // deposit tokens to portfolios
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

        token0.transfer(address(userSafe), 1e21);
        token1.transfer(address(userSafe), 1e21);

        uint256 userSafeBalance0 = token0.balanceOf(address(userSafe));
        uint256 userSafeBalance1 = token1.balanceOf(address(userSafe));
        assertEq(userSafeBalance0, 1e21);
        assertEq(userSafeBalance1, 1e21);

        Call[] memory calls = new Call[](4);
        calls[0] = (
            Call({
                to: address(token0),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(dos),
                    userSafeBalance0
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
                    userSafeBalance1
                ),
                value: 0
            })
        );

        calls[2] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,int256)",
                    address(token0),
                    1e20
                ),
                value: 0
            })
        );

        calls[3] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,int256)",
                    address(token1),
                    1e20
                ),
                value: 0
            })
        );

        DSafeLogic(address(userSafe)).executeBatch(calls);
    }

    function testSwap() public {
        // deposit tokens to portfolios
        userSafe = DSafeProxy(payable(IDOSConfig(address(dos)).createDSafe()));

        _depositTokens(1e30, 1e30);

        // mint tokens
        token0.mint(address(userSafe), 1e21);
        token1.mint(address(userSafe), 1e21);

        _addLiquidity(1e23, 1e23);

        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        uint256 swapAmount = 1e21;

        int256 userSafeBalance0Before = IDOSConfig(address(dos)).getDAccountERC20(
            address(userSafe),
            token0
        );
        int256 userSafeBalance1Before = IDOSConfig(address(dos)).getDAccountERC20(
            address(userSafe),
            token1
        );

        bytes memory data = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            swapAmount,
            0,
            path,
            address(userSafe),
            block.timestamp
        );

        Approval[] memory approvals = new Approval[](1);
        approvals[0] = (Approval({ercContract: address(token0), amountOrTokenId: swapAmount}));

        bytes memory callData = abi.encodeWithSignature(
            "approveAndCall((address,uint256)[],address,bytes)",
            approvals,
            address(router),
            data
        );
        Call[] memory calls = new Call[](1);
        calls[0] = (Call({to: address(dos), callData: callData, value: 0}));

        console.log("before approveAndCall");
        DSafeLogic(address(userSafe)).executeBatch(calls);

        int256 userSafeBalance0After = IDOSConfig(address(dos)).getDAccountERC20(
            address(userSafe),
            IERC20(token0)
        );
        int256 userSafeBalance1After = IDOSConfig(address(dos)).getDAccountERC20(
            address(userSafe),
            IERC20(token1)
        );

        int256 userSafeBalance0Diff = userSafeBalance0After - userSafeBalance0Before;
        int256 userSafeBalance1Diff = userSafeBalance1After - userSafeBalance1Before;

        assertEq(userSafeBalance0After, userSafeBalance0Before - int256(swapAmount));
        assert(userSafeBalance1After > userSafeBalance1Before);
        assert(userSafeBalance1Diff > 0);
        assert(userSafeBalance0Diff < 0);
    }

    function _addLiquidity(uint256 _amount0, uint256 _amount1) public {
        pair = _createPair(address(token0), address(token1));
        pairSafe = pair.dSafe();

        token0.mint(address(userSafe), _amount0);
        token1.mint(address(userSafe), _amount1);

        bytes memory callData = abi.encodeWithSignature(
            "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
            address(token0),
            address(token1),
            _amount0,
            _amount1,
            0,
            0,
            address(userSafe),
            block.timestamp
        );

        Approval[] memory approvals = new Approval[](2);
        approvals[0] = (Approval({ercContract: address(token0), amountOrTokenId: _amount0}));
        approvals[1] = (Approval({ercContract: address(token1), amountOrTokenId: _amount1}));

        Call[] memory calls = new Call[](1);

        calls[0] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "approveAndCall((address,uint256)[],address,bytes)",
                    approvals,
                    address(router),
                    callData
                ),
                value: 0
            })
        );
        DSafeLogic(address(userSafe)).executeBatch(calls);
    }

    function _depositTokens(uint256 _amount0, uint256 _amount1) public {
        // mint tokens
        token0.mint(address(userSafe), _amount0);
        token1.mint(address(userSafe), _amount1);

        Call[] memory calls = new Call[](4);
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

        calls[2] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,int256)",
                    address(token0),
                    _amount0
                ),
                value: 0
            })
        );

        calls[3] = (
            Call({
                to: address(dos),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,int256)",
                    address(token1),
                    _amount1
                ),
                value: 0
            })
        );

        DSafeLogic(address(userSafe)).executeBatch(calls);
    }

    function _createPair(address _token0, address _token1) public returns (DuoswapV2Pair _pair) {
        _pair = DuoswapV2Pair(factory.createPair(_token0, _token1));
        pairOracle = new UniV2Oracle(address(dos), address(_pair), address(this));
        pairOracle.setERC20ValueOracle(address(token0), address(token0Oracle));
        pairOracle.setERC20ValueOracle(address(token1), address(token1Oracle));
        IDOSConfig(address(dos)).addERC20Info(
            address(_pair),
            "uni-v2",
            "t0-t1",
            18,
            address(pairOracle),
            9e17,
            9e17,
            0,
            0,
            0,
            0
        );
        return _pair;
    }
}
