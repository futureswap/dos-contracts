// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {UniV3LPHelper} from "contracts/periphery/UniV3LPHelper.sol";
import {Supa} from "contracts/supa/Supa.sol";
import {SupaConfig, ISupaConfig} from "contracts/supa/SupaConfig.sol";
import {VersionManager, IVersionManager} from "contracts/supa/VersionManager.sol";
import {INonfungiblePositionManager} from "contracts/external/interfaces/INonfungiblePositionManager.sol";
import {WalletProxy} from "contracts/wallet/WalletProxy.sol";
import {WalletLogic} from "contracts/wallet/WalletLogic.sol";

import {Call} from "contracts/lib/Call.sol";

import {MockERC20Oracle} from "contracts/testing/MockERC20Oracle.sol";
import {ERC20ChainlinkValueOracle} from "contracts/oracles/ERC20ChainlinkValueOracle.sol";
import {UniV3Oracle} from "contracts/oracles/UniV3Oracle.sol";

contract UniV3LPHelperTest is Test {
    uint256 mainnetFork;
    string MAINNET_RPC_URL = vm.envString("MAINNET_RPC_URL");
    SupaConfig public supaConfig;
    Supa public supa;
    VersionManager public versionManager;
    INonfungiblePositionManager public nonfungiblePositionManager =
        INonfungiblePositionManager(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    address public uniswapV3Factory = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    UniV3LPHelper public uniV3LPHelper;
    ISwapRouter public swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    WalletLogic public logic;
    WalletProxy public userWallet;

    IERC20 public usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // mainnet USDC
    IERC20 public dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // mainnet DAI
    IERC20 public weth = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // mainnet WETH

    MockERC20Oracle public usdcOracle;
    MockERC20Oracle public daiOracle;
    MockERC20Oracle public wethOracle;

    UniV3Oracle public uniV3Oracle;

    function setUp() public {
        mainnetFork = vm.createFork(MAINNET_RPC_URL);
        vm.selectFork(mainnetFork);
        address owner = address(this);
        versionManager = new VersionManager(owner);
        supaConfig = new SupaConfig(owner);
        supa = new Supa(address(supaConfig), address(versionManager));
        logic = new WalletLogic(address(supa));

        ISupaConfig(address(supa)).setConfig(
            ISupaConfig.Config({
                treasuryWallet: address(0),
                treasuryInterestFraction: 5e16,
                maxSolvencyCheckGasCost: 1e6,
                liqFraction: 8e17,
                fractionalReserveLeverage: 9
            })
        );

        ISupaConfig(address(supa)).setTokenStorageConfig(
            ISupaConfig.TokenStorageConfig({
                maxTokenStorage: 250,
                erc20Multiplier: 1,
                erc721Multiplier: 1
            })
        );
        uniV3LPHelper = new UniV3LPHelper(address(supa), address(nonfungiblePositionManager));

        usdcOracle = new MockERC20Oracle(owner);
        usdcOracle.setPrice(1e18, 18, 18);
        usdcOracle.setRiskFactors(9e17, 9e17);

        daiOracle = new MockERC20Oracle(owner);
        daiOracle.setPrice(1e18, 18, 18);
        daiOracle.setRiskFactors(9e17, 9e17);

        wethOracle = new MockERC20Oracle(owner);
        wethOracle.setPrice(1e18, 18, 18);
        wethOracle.setRiskFactors(9e17, 9e17);

        ISupaConfig(address(supa)).addERC20Info(
            address(usdc),
            "Circle USD",
            "USDC",
            6,
            address(usdcOracle),
            0, // baseRate
            5, // slope1
            480, // slope2
            8e17 // targetUtilization
        );
        ISupaConfig(address(supa)).addERC20Info(
            address(dai),
            "Dai Stablecoin",
            "Dai",
            18,
            address(daiOracle),
            0, // baseRate
            5, // slope1
            480, // slope2
            8e17 // targetUtilization
        );
        ISupaConfig(address(supa)).addERC20Info(
            address(weth),
            "Wrapped Ether",
            "WETH",
            18,
            address(wethOracle),
            0, // baseRate
            5, // slope1
            480, // slope2
            8e17 // targetUtilization
        );

        uniV3Oracle = new UniV3Oracle(uniswapV3Factory, address(nonfungiblePositionManager), owner);

        uniV3Oracle.setERC20ValueOracle(address(usdc), address(usdcOracle));
        uniV3Oracle.setERC20ValueOracle(address(dai), address(daiOracle));
        uniV3Oracle.setERC20ValueOracle(address(weth), address(wethOracle));

        ISupaConfig(address(supa)).addERC721Info(
            address(nonfungiblePositionManager),
            address(uniV3Oracle)
        );

        // add to version manager
        string memory version = "1.0.0";
        versionManager.addVersion(IVersionManager.Status.PRODUCTION, address(logic));
        versionManager.markRecommendedVersion(version);
    }

    function testMintAndDeposit() public {
        userWallet = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        ISupaConfig.NFTData[] memory nftData = ISupaConfig(address(supa)).getCreditAccountERC721(
            address(userWallet)
        );

        assertEq(nftData.length, 0);

        uint256 usdcAmount = 10_000 * 10 ** 6;
        uint256 wethAmount = 10 ether;

        // load USDC and WETH into userWallet
        deal({token: address(usdc), to: address(userWallet), give: usdcAmount});
        deal({token: address(weth), to: address(userWallet), give: wethAmount});

        Call[] memory calls = new Call[](3);

        // (1) mint and deposit LP token

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager
            .MintParams({
                token0: address(usdc),
                token1: address(weth),
                fee: 500,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: usdcAmount,
                amount1Desired: wethAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(userWallet),
                deadline: block.timestamp + 1000
            });

        calls[0] = Call({
            to: address(usdc),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                type(uint256).max
            ),
            value: 0
        });
        calls[1] = Call({
            to: address(weth),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                type(uint256).max
            ),
            value: 0
        });
        calls[2] = Call({
            to: address(uniV3LPHelper),
            callData: abi.encodeWithSignature(
                "mintAndDeposit((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))",
                params
            ),
            value: 0
        });
        userWallet.executeBatch(calls);

        nftData = ISupaConfig(address(supa)).getCreditAccountERC721(address(userWallet));

        assertEq(nftData.length, 1);
    }

    function testReinvest() public {
        // create user wallet
        userWallet = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        uint256 tokenId = _mintAndDeposit();

        // Get the initial liquidity
        (, , , , , , , uint128 liquidity, , , , ) = nonfungiblePositionManager.positions(tokenId);

        // mock accrued swap fees
        vm.mockCall(
            address(nonfungiblePositionManager),
            abi.encodeWithSelector(INonfungiblePositionManager.collect.selector),
            abi.encode(1_000 * 10 ** 6, 1 ether)
        );

        // Inject mocked fees into uniV3LPHelper
        deal({token: address(usdc), to: address(uniV3LPHelper), give: 1_000 * 10 ** 6});
        deal({token: address(weth), to: address(uniV3LPHelper), give: 1 ether});

        // Create calls to reinvest fees
        Call[] memory reinvestCalls = new Call[](3);
        // (1) withdraw LP token to Wallet
        reinvestCalls[0] = Call({
            to: address(supa),
            callData: abi.encodeWithSelector(
                Supa.withdrawERC721.selector,
                address(nonfungiblePositionManager),
                tokenId
            ),
            value: 0
        });
        // (2) approve LP token to uniV3LPHelper
        reinvestCalls[1] = Call({
            to: address(nonfungiblePositionManager),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                tokenId
            ),
            value: 0
        });
        // (3) reinvest fees
        reinvestCalls[2] = Call({
            to: address(uniV3LPHelper),
            callData: abi.encodeWithSignature("reinvest(uint256)", tokenId),
            value: 0
        });
        userWallet.executeBatch(reinvestCalls);

        // Check that the fees were reinvested
        ISupaConfig.NFTData[] memory nftData = ISupaConfig(address(supa)).getCreditAccountERC721(
            address(userWallet)
        );
        assertEq(nftData.length, 1);

        (, , , , , , , uint128 newLiquidity, , , , ) = nonfungiblePositionManager.positions(
            tokenId
        );
        assert(newLiquidity > liquidity);
    }

    function testReinvestNoAccruedFees() public {
        userWallet = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        uint256 usdcAmount = 10_000 * 10 ** 6;
        uint256 wethAmount = 10 ether;

        // load USDC and WETH into userWallet
        deal({token: address(usdc), to: address(userWallet), give: usdcAmount});
        deal({token: address(weth), to: address(userWallet), give: wethAmount});

        Call[] memory calls = new Call[](3);

        // (1) mint and deposit LP token

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager
            .MintParams({
                token0: address(usdc),
                token1: address(weth),
                fee: 500,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: usdcAmount,
                amount1Desired: wethAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(userWallet),
                deadline: block.timestamp + 1000
            });

        calls[0] = Call({
            to: address(usdc),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                type(uint256).max
            ),
            value: 0
        });
        calls[1] = Call({
            to: address(weth),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                type(uint256).max
            ),
            value: 0
        });
        calls[2] = Call({
            to: address(uniV3LPHelper),
            callData: abi.encodeWithSignature(
                "mintAndDeposit((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))",
                params
            ),
            value: 0
        });
        userWallet.executeBatch(calls);

        ISupaConfig.NFTData[] memory nftData = ISupaConfig(address(supa)).getCreditAccountERC721(
            address(userWallet)
        );

        uint256 tokenId = nftData[0].tokenId;

        Call[] memory reinvestCalls = new Call[](3);
        // (1) withdraw LP token to Wallet
        reinvestCalls[0] = Call({
            to: address(supa),
            callData: abi.encodeWithSelector(
                Supa.withdrawERC721.selector,
                address(nonfungiblePositionManager),
                tokenId
            ),
            value: 0
        });
        // (2) approve LP token to uniV3LPHelper
        reinvestCalls[1] = Call({
            to: address(nonfungiblePositionManager),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                tokenId
            ),
            value: 0
        });
        // (3) reinvest fees
        reinvestCalls[2] = Call({
            to: address(uniV3LPHelper),
            callData: abi.encodeWithSignature("reinvest(uint256)", tokenId),
            value: 0
        });
        vm.expectRevert();
        userWallet.executeBatch(reinvestCalls);
    }

    function testQuickWithdraw() public {
        // create user wallet
        userWallet = WalletProxy(payable(ISupaConfig(address(supa)).createWallet()));

        int256 usdcBalanceBefore = ISupaConfig(address(supa)).getCreditAccountERC20(
            address(userWallet),
            usdc
        );
        int256 wethBalanceBefore = ISupaConfig(address(supa)).getCreditAccountERC20(
            address(userWallet),
            weth
        );

        uint256 tokenId = _mintAndDeposit();

        // Quick withdraw
        Call[] memory calls = new Call[](3);
        calls[0] = Call({
            to: address(supa),
            callData: abi.encodeWithSelector(
                Supa.withdrawERC721.selector,
                address(nonfungiblePositionManager),
                tokenId
            ),
            value: 0
        });
        calls[1] = Call({
            to: address(nonfungiblePositionManager),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                tokenId
            ),
            value: 0
        });
        calls[2] = Call({
            to: address(uniV3LPHelper),
            callData: abi.encodeWithSignature("quickWithdraw(uint256)", tokenId),
            value: 0
        });

        userWallet.executeBatch(calls);

        int256 usdcBalanceAfter = ISupaConfig(address(supa)).getCreditAccountERC20(
            address(userWallet),
            usdc
        );
        int256 wethBalanceAfter = ISupaConfig(address(supa)).getCreditAccountERC20(
            address(userWallet),
            weth
        );

        assert(usdcBalanceAfter > usdcBalanceBefore);
        assert(wethBalanceAfter > wethBalanceBefore);
    }

    function _mintAndDeposit() internal returns (uint256 tokenId) {
        uint256 usdcAmount = 10_000 * 10 ** 6;
        uint256 wethAmount = 10 ether;

        // load USDC and WETH into userWallet
        deal({token: address(usdc), to: address(userWallet), give: usdcAmount});
        deal({token: address(weth), to: address(userWallet), give: wethAmount});

        // Create a position and deposit LP token to supa
        Call[] memory calls = new Call[](3);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager
            .MintParams({
                token0: address(usdc),
                token1: address(weth),
                fee: 500,
                tickLower: -887220,
                tickUpper: 887220,
                amount0Desired: usdcAmount,
                amount1Desired: wethAmount,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(userWallet),
                deadline: block.timestamp + 1000
            });

        // (1) approve usdc
        calls[0] = Call({
            to: address(usdc),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                type(uint256).max
            ),
            value: 0
        });
        // (2) approve weth
        calls[1] = Call({
            to: address(weth),
            callData: abi.encodeWithSignature(
                "approve(address,uint256)",
                address(uniV3LPHelper),
                type(uint256).max
            ),
            value: 0
        });
        // (3) mint and deposit LP token
        calls[2] = Call({
            to: address(uniV3LPHelper),
            callData: abi.encodeWithSignature(
                "mintAndDeposit((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))",
                params
            ),
            value: 0
        });
        userWallet.executeBatch(calls);

        ISupaConfig.NFTData[] memory nftData = ISupaConfig(address(supa)).getCreditAccountERC721(
            address(userWallet)
        );

        // Get the LP token ID
        tokenId = nftData[0].tokenId;

        return tokenId;
    }
}
