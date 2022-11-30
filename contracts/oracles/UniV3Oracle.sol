// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../lib/ImmutableOwnable.sol";
import "../interfaces/IERC20ValueOracle.sol";
import "../interfaces/INFTValueOracle.sol";
import "../lib/FsMath.sol";
import "../lib/FsUtils.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint96.sol";

// TickMath lib is inconsistent with solidity compiler version
library TickMath {
    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -887272;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;

    /// @dev The minimum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MIN_TICK)
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    /// @dev The maximum value that can be returned from #getSqrtRatioAtTick. Equivalent to getSqrtRatioAtTick(MAX_TICK)
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    /// @notice Calculates sqrt(1.0001^tick) * 2^96
    /// @dev Throws if |tick| > max tick
    /// @param tick The input tick for the above formula
    /// @return sqrtPriceX96 A Fixed point Q64.96 number representing the sqrt of the ratio of the two erc20s (token1/token0)
    /// at the given tick
    function getSqrtRatioAtTick(int24 tick) internal pure returns (int256 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= uint256(uint24(MAX_TICK)), "T");

        uint256 ratio = absTick & 0x1 != 0
            ? 0xfffcb933bd6fad37aa2d162d1a594001
            : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;

        // this divides by 1<<32 rounding up to go from a Q128.128 to a Q128.96.
        // we then downcast because we know the result always fits within 160 bits due to our tick input constraint
        // we round up in the division so getTickAtSqrtRatio of the output price is always consistent
        sqrtPriceX96 = int256((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}

// Incompatible with our version of OZ
// import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

interface INPM {
    function positions(
        uint256 tokenId
    )
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

contract UniV3Oracle is ImmutableOwnable, INFTValueOracle {
    INPM public immutable manager;
    IUniswapV3Factory public immutable factory;

    mapping(address => IERC20ValueOracle) public erc20ValueOracle;

    int256 constant Q96 = int256(FixedPoint96.Q96);

    constructor(address _factory, address _manager, address _owner) ImmutableOwnable(_owner) {
        manager = INPM(_manager);
        factory = IUniswapV3Factory(_factory);
    }

    function setERC20ValueOracle(address token, address oracle) external onlyOwner {
        erc20ValueOracle[token] = IERC20ValueOracle(oracle);
    }

    function calcValue(uint256 tokenId) external view override returns (int256) {
        address token0;
        address token1;
        int256 liquidity;
        int256 sqrtPrice;
        int256 baseX;
        int256 baseY;
        {
            (
                ,
                ,
                address token0Tmp,
                address token1Tmp,
                uint24 fee,
                int24 tickLower,
                int24 tickUpper,
                uint128 liquidityUnsigned,
                ,
                ,
                ,

            ) = manager.positions(tokenId);
            liquidity = int256(uint256(liquidityUnsigned));
            IUniswapV3Pool pool = IUniswapV3Pool(factory.getPool(token0Tmp, token1Tmp, fee));
            (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();
            sqrtPrice = int256(uint256(sqrtPriceX96));
            token0 = token0Tmp;
            token1 = token1Tmp;
            int256 lowerSqrtPrice = TickMath.getSqrtRatioAtTick(tickLower);
            int256 upperSqrtPrice = TickMath.getSqrtRatioAtTick(tickUpper);
            // Clamp the price into the range
            sqrtPrice = FsMath.clip(sqrtPrice, lowerSqrtPrice, upperSqrtPrice);
            baseX = (liquidity * Q96) / upperSqrtPrice;
            baseY = (lowerSqrtPrice * liquidity) / Q96;
        }
        // X token0 amount, Y token1 amount
        // L = sqrt(X * Y)  p = Y / X
        // Thus sqrt(p) * L = Y and sqrt(p) / L = X

        int256 amountY = (sqrtPrice * liquidity) / Q96 - baseY;
        int256 amountX = (liquidity * Q96) / sqrtPrice - baseX;

        int256 value = 0;
        value += erc20ValueOracle[token0].calcValue(amountX);
        value += erc20ValueOracle[token1].calcValue(amountY);
        return value;
    }
}
