// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ImmutableOwnable} from "../lib/ImmutableOwnable.sol";
import {IERC20ValueOracle} from "../interfaces/IERC20ValueOracle.sol";
import {FsMath} from "../lib/FsMath.sol";
import {IDOS} from "../interfaces/IDOS.sol";
import {IDuoswapV2Pair} from "../duoswapV2/interfaces/IDuoswapV2Pair.sol";

contract UniV2Oracle is ImmutableOwnable, IERC20ValueOracle {
    IDOS public immutable dos;
    IDuoswapV2Pair public immutable pair;
    // address public immutable dSafe;
    // address public immutable token0;
    // address public immutable token1;

    mapping(address => IERC20ValueOracle) public erc20ValueOracle;

    constructor(address _dos, address _pair, address _owner) ImmutableOwnable(_owner) {
        dos = IDOS(_dos);
        pair = IDuoswapV2Pair(_pair);

        // dSafe = IUniswapV2Pair(_pair).dSafe();
        // token0 = IUniswapV2Pair(_pair).token0();
        // token1 = IUniswapV2Pair(_pair).token1();
    }

    /// @notice Set the oracle for an underlying token
    /// @param erc20 The underlying token
    /// @param oracle The oracle for the underlying token
    function setERC20ValueOracle(address erc20, address oracle) external onlyOwner {
        erc20ValueOracle[erc20] = IERC20ValueOracle(oracle);
    }

    /// @notice Calculate the value of a uniswap pair token
    /// @param amount The amount of the token
    /// @return The value of the uniswap pair token
    function calcValue(int256 amount) external view override returns (int256) {
        uint256 totalSupply = pair.totalSupply();
        if (totalSupply == 0) {
            return 0;
        }
        address dSafe = pair.dSafe();
        address token0 = pair.token0();
        address token1 = pair.token1();

        uint256 balance0 = uint256(IDOS(dos).viewBalance(dSafe, IERC20(token0)));
        uint256 balance1 = uint256(IDOS(dos).viewBalance(dSafe, IERC20(token1)));

        int256 price0 = erc20ValueOracle[token0].calcValue(FsMath.safeCastToSigned(balance0));
        int256 price1 = erc20ValueOracle[token1].calcValue(FsMath.safeCastToSigned(balance1));

        return ((price0 + price1) * amount) / FsMath.safeCastToSigned(totalSupply);
    }
}
