// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ImmutableGovernance} from "../lib/ImmutableGovernance.sol";
import {IERC20ValueOracle} from "../interfaces/IERC20ValueOracle.sol";
import {FsMath} from "../lib/FsMath.sol";
import {IDOS} from "../interfaces/IDOS.sol";
import {IDuoswapV2Pair} from "../duoswapV2/interfaces/IDuoswapV2Pair.sol";

error ZeroAddress();

contract UniV2Oracle is ImmutableGovernance, IERC20ValueOracle {
    IDOS public immutable dos;
    IDuoswapV2Pair public immutable pair;
    // address public immutable dSafe;
    // address public immutable token0;
    // address public immutable token1;

    mapping(address => IERC20ValueOracle) public erc20ValueOracle;

    constructor(address _dos, address _pair, address _owner) ImmutableGovernance(_owner) {
        if (_dos == address(0) || _pair == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }
        dos = IDOS(_dos);
        pair = IDuoswapV2Pair(_pair);

        // dSafe = IUniswapV2Pair(_pair).dSafe();
        // token0 = IUniswapV2Pair(_pair).token0();
        // token1 = IUniswapV2Pair(_pair).token1();
    }

    /// @notice Set the oracle for an underlying token
    /// @param erc20 The underlying token
    /// @param oracle The oracle for the underlying token
    function setERC20ValueOracle(address erc20, address oracle) external onlyGovernance {
        erc20ValueOracle[erc20] = IERC20ValueOracle(oracle);
    }

    /// @notice Calculate the value of a uniswap pair token
    /// @param amount The amount of the token
    /// @return value The value of the uniswap pair token
    /// @return riskAdjustedValue The risk adjusted value of the uniswap pair token
    function calcValue(
        int256 amount
    ) external view override returns (int256 value, int256 riskAdjustedValue) {
        int256 totalSupply = FsMath.safeCastToSigned(pair.totalSupply());
        if (totalSupply == 0) {
            return (0, 0);
        }
        address token0 = pair.token0();
        address token1 = pair.token1();

        (uint r0, uint r1, ) = pair.getReserves();
        int256 reserve0 = FsMath.safeCastToSigned(r0);
        int256 reserve1 = FsMath.safeCastToSigned(r1);
        int256 sqrtK = FsMath.sqrt(reserve0 * (reserve1)) / (totalSupply);

        (int256 price0, int256 adjustedPrice0) = erc20ValueOracle[token0].calcValue(
            FsMath.safeCastToSigned(1 ether) // TODO: adjust for decimals
        );
        (int256 price1, int256 adjustedPrice1) = erc20ValueOracle[token1].calcValue(
            FsMath.safeCastToSigned(1 ether) // TODO: adjust for decimals
        );

        value =
            (amount * (((sqrtK * 2 * (FsMath.sqrt(price0))) / (2 ** 56)) * (FsMath.sqrt(price1)))) /
            (2 ** 56);

        riskAdjustedValue =
            (amount *
                (((sqrtK * 2 * (FsMath.sqrt(adjustedPrice0))) / (2 ** 56)) *
                    (FsMath.sqrt(adjustedPrice1)))) /
            (2 ** 56);
        return (value, riskAdjustedValue);
    }
}
