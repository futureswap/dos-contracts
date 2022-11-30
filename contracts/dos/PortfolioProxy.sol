//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/proxy/Proxy.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {FsUtils} from "../lib/FsUtils.sol";
import "../interfaces/IDOS.sol";

// Inspired by TransparentUpdatableProxy
contract PortfolioProxy is Proxy {
    using Address for address;

    address public immutable dos;

    modifier ifDos() {
        if (msg.sender == dos) {
            _;
        } else {
            _fallback();
        }
    }

    constructor(address _dos) {
        // slither-disable-next-line missing-zero-check
        dos = FsUtils.nonNull(_dos);
    }

    // Allow DOS to make arbitrary calls in lieu of this portfolio
    function doCall(
        address to,
        bytes calldata callData,
        uint256 value
    ) external ifDos returns (bytes memory) {
        return to.functionCallWithValue(callData, value);
    }

    // The implementation of the delegate is controlled by DOS
    function _implementation() internal view override returns (address) {
        return IDOS(dos).getImplementation(address(this));
    }
}

// Calls to the contract not coming from DOS itself are routed to this logic
// contract. This allows for flexible extra addition to your portfolio.
contract PortfolioLogic is IERC721Receiver, IERC1271 {
    IDOS public immutable dos;

    modifier onlyOwner() {
        require(IDOS(dos).getPortfolioOwner(address(this)) == msg.sender, "");
        _;
    }

    constructor(address _dos) {
        // slither-disable-next-line missing-zero-check
        dos = IDOS(FsUtils.nonNull(_dos));
    }

    function executeBatch(IDOS.Call[] memory calls) external payable onlyOwner {
        IDOS(dos).executeBatch(calls);
    }

    function liquify(
        address portfolio,
        address swapRouter,
        address numeraire,
        AssetIdx[] calldata assetIdxs,
        address[] calldata erc20s
    ) external {
        if (msg.sender != address(this)) {
            require(msg.sender == IDOS(dos).getPortfolioOwner(address(this)), "only owner");

            IDOS.Call[] memory calls = new IDOS.Call[](1);
            calls[0] = IDOS.Call({
                to: address(this),
                callData: abi.encodeWithSelector(
                    this.liquify.selector,
                    portfolio,
                    swapRouter,
                    numeraire,
                    assetIdxs,
                    erc20s
                ),
                value: 0
            });
            dos.executeBatch(calls);
            return;
        }
        // Liquidate the portfolio
        dos.liquidate(portfolio);

        // Withdraw all non-numeraire collateral
        int256[] memory balances = new int256[](assetIdxs.length);
        {
            uint256 ncollaterals = 0;
            for (uint256 i = 0; i < assetIdxs.length; i++) {
                int256 balance = IDOS(dos).viewBalance(address(this), assetIdxs[i]);
                balances[i] = balance;
                if (balance > 0) {
                    ncollaterals++;
                }
            }
            AssetIdx[] memory collaterals = new AssetIdx[](ncollaterals);
            uint256 j = 0;
            for (uint256 i = 0; i < assetIdxs.length; i++) {
                if (balances[i] > 0) {
                    collaterals[j++] = assetIdxs[i];
                }
            }
            dos.withdrawFull(collaterals);
        }

        // Swap all non-numeraire collateral to numeraire
        for (uint256 i = 0; i < assetIdxs.length; i++) {
            int256 balance = balances[i];
            if (balance > 0) {
                ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                    .ExactInputSingleParams({
                        tokenIn: erc20s[i],
                        tokenOut: numeraire,
                        fee: 500,
                        recipient: address(this),
                        deadline: uint256(int256(-1)),
                        amountIn: uint256(balance),
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    });
                ISwapRouter(swapRouter).exactInputSingle(params);
            }
        }

        // Repay all debt by swapping numeraire
        for (uint256 i = 0; i < assetIdxs.length; i++) {
            int256 balance = balances[i];
            if (balance < 0) {
                ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter
                    .ExactOutputSingleParams({
                        tokenIn: numeraire,
                        tokenOut: erc20s[i],
                        fee: 500,
                        recipient: address(this),
                        deadline: uint256(int256(-1)),
                        amountOut: uint256(-balance),
                        amountInMaximum: uint256(int256(-1)),
                        sqrtPriceLimitX96: 0
                    });
                ISwapRouter(swapRouter).exactOutputSingle(params);
            }
        }

        // Deposit numeraire
        dos.depositFull(new AssetIdx[](1));
    }

    function owner() external view returns (address) {
        return IDOS(dos).getPortfolioOwner(address(this));
    }

    function onERC721Received(
        address /* operator */,
        address /* from */,
        uint256 /* tokenId */,
        bytes memory /* data */
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IERC1271
    function isValidSignature(
        bytes32 hash,
        bytes memory signature
    ) public view returns (bytes4 magicValue) {
        // TODO: need an implementation in order to use permit2
    }
}
