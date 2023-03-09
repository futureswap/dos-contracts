// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {ISupa, Supa, WalletLib, SupaState, ISupaCore} from "contracts/supa/Supa.sol";
import {SupaConfig, ISupaConfig} from "contracts/supa/SupaConfig.sol";
import {Call} from "contracts/lib/Call.sol";
import {WalletProxy} from "contracts/wallet/WalletProxy.sol";
import {WalletLogic} from "contracts/wallet/WalletLogic.sol";
import {IVersionManager, VersionManager, ImmutableVersion} from "contracts/supa/VersionManager.sol";
// import "../src/supa/TransferAndCall2.sol";
import {DuoswapV2Factory} from "contracts/duoswapV2/DuoswapV2Factory.sol";
import {DuoswapV2Pair} from "contracts/duoswapV2/DuoswapV2Pair.sol";
import {DuoswapV2Router} from "contracts/duoswapV2/DuoswapV2Router.sol";

import {UniV2Oracle} from "contracts/oracles/UniV2Oracle.sol";
import {MockERC20Oracle} from "contracts/testing/MockERC20Oracle.sol";
import {ERC20ChainlinkValueOracle} from "contracts/oracles/ERC20ChainlinkValueOracle.sol";

import {TestERC20} from "contracts/testing/TestERC20.sol";
import {IWETH9} from "contracts/external/interfaces/IWETH9.sol";

contract DuoswapV2Test is Test {
    uint256 mainnetFork;

    VersionManager public versionManager;
    DuoswapV2Factory public factory;
    DuoswapV2Pair public pair;
    DuoswapV2Router public router;

    Supa public supa;
    SupaConfig public supaConfig;
    WalletProxy public userWallet;
    address public pairWallet;
    WalletLogic public logic;

    IWETH9 public weth = IWETH9(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    // Create 2 tokens
    TestERC20 public token0;
    TestERC20 public token1;

    AggregatorV3Interface public oracleAddress =
        AggregatorV3Interface(0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6);
    // string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");

    MockERC20Oracle public token0Oracle;
    MockERC20Oracle public token1Oracle;
    UniV2Oracle public pairOracle;

    function setUp() public {
        address owner = address(this);

        // create Supa contracts
        versionManager = new VersionManager(owner);
        supaConfig = new SupaConfig(owner);
        supa = new Supa(address(supaConfig), address(versionManager));
        logic = new WalletLogic(address(supa));

        string memory version = "1.0.0";

        ISupaConfig(address(supa)).setConfig(
            ISupaConfig.Config({
                treasuryWallet: address(0),
                treasuryInterestFraction: 0,
                maxSolvencyCheckGasCost: 10_000_000,
                liqFraction: 8e17,
                fractionalReserveLeverage: 10
            })
        );

        ISupaConfig(address(supa)).setTokenStorageConfig(
            ISupaConfig.TokenStorageConfig({
                maxTokenStorage: 250,
                erc20Multiplier: 1,
                erc721Multiplier: 1
            })
        );

        versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(logic));
        versionManager.markRecommendedVersion(version);

        // setup tokens and oracles
        token0 = new TestERC20("token0", "t0", 18);
        token1 = new TestERC20("token1", "t1", 18);

        token0Oracle = new MockERC20Oracle(owner);
        token1Oracle = new MockERC20Oracle(owner);

        ISupaConfig(address(supa)).addERC20Info(
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
        ISupaConfig(address(supa)).addERC20Info(
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

        // create duoswap contracts
        factory = new DuoswapV2Factory(address(supa), owner);
        router = new DuoswapV2Router(address(factory), address(weth), address(supa));
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

        userWallet = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        _depositTokens(amount0 * 100, amount1 * 100);

        // create a safe for the air
        pair = _createPair(address(token0), address(token1));
        pairWallet = pair.wallet();

        // mint tokens to safe
        token0.mint(address(userWallet), amount0);
        token1.mint(address(userWallet), amount1);

        // construct call for executeBatch
        Call[] memory calls = new Call[](1);

        bytes memory callData = abi.encodeWithSignature(
            "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
            address(token0),
            address(token1),
            amount0,
            amount1,
            0,
            0,
            address(userWallet),
            block.timestamp
        );

        ISupaCore.Approval[] memory approvals = new ISupaCore.Approval[](2);
        approvals[0] = (
            ISupaCore.Approval({ercContract: address(token0), amountOrTokenId: amount0})
        );
        approvals[1] = (
            ISupaCore.Approval({ercContract: address(token1), amountOrTokenId: amount1})
        );

        calls[0] = (
            Call({
                to: address(supa),
                callData: abi.encodeWithSignature(
                    "approveAndCall((address,uint256)[],address,bytes)",
                    approvals,
                    address(router),
                    callData
                ),
                value: 0
            })
        );
        WalletLogic(address(userWallet)).executeBatch(calls);
    }

    function testDepositTokens() public {
        // mint tokens
        token0.mint(address(this), 1e21);
        token1.mint(address(this), 1e21);

        // deposit tokens to portfolios
        userWallet = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        token0.transfer(address(userWallet), 1e21);
        token1.transfer(address(userWallet), 1e21);

        uint256 userWalletBalance0 = token0.balanceOf(address(userWallet));
        uint256 userWalletBalance1 = token1.balanceOf(address(userWallet));
        assertEq(userWalletBalance0, 1e21);
        assertEq(userWalletBalance1, 1e21);

        Call[] memory calls = new Call[](4);
        calls[0] = (
            Call({
                to: address(token0),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(supa),
                    userWalletBalance0
                ),
                value: 0
            })
        );

        calls[1] = (
            Call({
                to: address(token1),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(supa),
                    userWalletBalance1
                ),
                value: 0
            })
        );

        calls[2] = (
            Call({
                to: address(supa),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    address(token0),
                    1e20
                ),
                value: 0
            })
        );

        calls[3] = (
            Call({
                to: address(supa),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    address(token1),
                    1e20
                ),
                value: 0
            })
        );

        WalletLogic(address(userWallet)).executeBatch(calls);
    }

    function testSwap() public {
        // deposit tokens to portfolios
        userWallet = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        _depositTokens(1e30, 1e30);

        // mint tokens
        token0.mint(address(userWallet), 1e21);
        token1.mint(address(userWallet), 1e21);

        _addLiquidity(1e23, 1e23);

        address[] memory path = new address[](2);
        path[0] = address(token0);
        path[1] = address(token1);
        uint256 swapAmount = 1e21;

        int256 userWalletBalance0Before = ISupaConfig(address(supa)).getCreditAccountERC20(
            address(userWallet),
            token0
        );
        int256 userWalletBalance1Before = ISupaConfig(address(supa)).getCreditAccountERC20(
            address(userWallet),
            token1
        );

        bytes memory data = abi.encodeWithSignature(
            "swapExactTokensForTokens(uint256,uint256,address[],address,uint256)",
            swapAmount,
            0,
            path,
            address(userWallet),
            block.timestamp
        );

        ISupaCore.Approval[] memory approvals = new ISupaCore.Approval[](1);
        approvals[0] = (
            ISupaCore.Approval({ercContract: address(token0), amountOrTokenId: swapAmount})
        );

        bytes memory callData = abi.encodeWithSignature(
            "approveAndCall((address,uint256)[],address,bytes)",
            approvals,
            address(router),
            data
        );
        Call[] memory calls = new Call[](1);
        calls[0] = (Call({to: address(supa), callData: callData, value: 0}));

        WalletLogic(address(userWallet)).executeBatch(calls);

        int256 userWalletBalance0After = ISupaConfig(address(supa)).getCreditAccountERC20(
            address(userWallet),
            IERC20(token0)
        );
        int256 userWalletBalance1After = ISupaConfig(address(supa)).getCreditAccountERC20(
            address(userWallet),
            IERC20(token1)
        );

        int256 userWalletBalance0Diff = userWalletBalance0After - userWalletBalance0Before;
        int256 userWalletBalance1Diff = userWalletBalance1After - userWalletBalance1Before;

        assertEq(userWalletBalance0After, userWalletBalance0Before - int256(swapAmount));
        assert(userWalletBalance1After > userWalletBalance1Before);
        assert(userWalletBalance1Diff > 0);
        assert(userWalletBalance0Diff < 0);
    }

    function _addLiquidity(uint256 _amount0, uint256 _amount1) public {
        pair = _createPair(address(token0), address(token1));
        pairWallet = pair.wallet();

        token0.mint(address(userWallet), _amount0);
        token1.mint(address(userWallet), _amount1);

        bytes memory callData = abi.encodeWithSignature(
            "addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)",
            address(token0),
            address(token1),
            _amount0,
            _amount1,
            0,
            0,
            address(userWallet),
            block.timestamp
        );

        ISupaCore.Approval[] memory approvals = new ISupaCore.Approval[](2);
        approvals[0] = (
            ISupaCore.Approval({ercContract: address(token0), amountOrTokenId: _amount0})
        );
        approvals[1] = (
            ISupaCore.Approval({ercContract: address(token1), amountOrTokenId: _amount1})
        );

        Call[] memory calls = new Call[](1);

        calls[0] = (
            Call({
                to: address(supa),
                callData: abi.encodeWithSignature(
                    "approveAndCall((address,uint256)[],address,bytes)",
                    approvals,
                    address(router),
                    callData
                ),
                value: 0
            })
        );
        WalletLogic(address(userWallet)).executeBatch(calls);
    }

    function _depositTokens(uint256 _amount0, uint256 _amount1) public {
        // mint tokens
        token0.mint(address(userWallet), _amount0);
        token1.mint(address(userWallet), _amount1);

        Call[] memory calls = new Call[](4);
        calls[0] = (
            Call({
                to: address(token0),
                callData: abi.encodeWithSignature(
                    "approve(address,uint256)",
                    address(supa),
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
                    address(supa),
                    _amount1
                ),
                value: 0
            })
        );

        calls[2] = (
            Call({
                to: address(supa),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    address(token0),
                    _amount0
                ),
                value: 0
            })
        );

        calls[3] = (
            Call({
                to: address(supa),
                callData: abi.encodeWithSignature(
                    "depositERC20(address,uint256)",
                    address(token1),
                    _amount1
                ),
                value: 0
            })
        );

        WalletLogic(address(userWallet)).executeBatch(calls);
    }

    function _createPair(address _token0, address _token1) public returns (DuoswapV2Pair _pair) {
        _pair = DuoswapV2Pair(factory.createPair(_token0, _token1));
        pairOracle = new UniV2Oracle(address(supa), address(_pair), address(this));
        pairOracle.setERC20ValueOracle(address(token0), address(token0Oracle));
        pairOracle.setERC20ValueOracle(address(token1), address(token1Oracle));
        ISupaConfig(address(supa)).addERC20Info(
            address(_pair),
            "uni-v2",
            "t0-t1",
            18,
            address(pairOracle),
            9e17,
            9e17,
            0,
            0
        );
        return _pair;
    }
}

contract DuoswapV2ConstructorTest is Test {
    address public oracleAddress = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;

    function testBaseDecimalsValidation(uint8 baseDecimals) public {
        vm.assume(baseDecimals < 3 || 18 < baseDecimals);

        address owner = address(this);
        string memory reason = string.concat(
            "Invalid baseDecimals: must be within [3, 18] range while provided is ",
            Strings.toString(baseDecimals)
        );
        vm.expectRevert(bytes(reason));
        new ERC20ChainlinkValueOracle(address(oracleAddress), baseDecimals, 18, 0, 0, owner);
    }

    function testTokenDecimalsValidation(uint8 tokenDecimals) public {
        vm.assume(tokenDecimals < 3 || 18 < tokenDecimals);

        address owner = address(this);
        string memory reason = string.concat(
            "Invalid tokenDecimals: must be within [3, 18] range while provided is ",
            Strings.toString(tokenDecimals)
        );
        vm.expectRevert(bytes(reason));
        new ERC20ChainlinkValueOracle(address(oracleAddress), 18, tokenDecimals, 0, 0, owner);
    }
}
