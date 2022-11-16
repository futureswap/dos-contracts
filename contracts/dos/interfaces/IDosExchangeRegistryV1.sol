// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../AssetId.sol";

import "./exchange/IFungibleOneForOneSwap.sol";

/**
 * @title Addition, update and listing of exchange bridges, supported by DOS.
 */
interface IDosExchangeRegistryV1 {
    /**
     * @notice Emitted by the `registerFungibleOneForOneSwap()` call.
     */
    event RegisterFungibleOneForOneSwap(AssetId from, AssetId to, IFungibleOneForOneSwap swap);

    /**
     * @notice TODO
     */
    function registerFungibleOneForOneSwap(
        AssetId from,
        AssetId to,
        IFungibleOneForOneSwap swap
    ) external;
}
