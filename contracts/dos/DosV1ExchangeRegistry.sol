// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./interfaces/IDosExchangeRegistryV1.sol";
import "./interfaces/exchange/IFungibleOneForOneSwap.sol";

import "./AssetId.sol";
import "./DosV1Storage.sol";

library DosV1ExchangeRegistry {
    /*
     * IDosExchangeRegistryV1
     */

    /**
     * @notice An implementation for `IDosExchangeRegistryV1.registerFungibleOneForOneSwap()`.
     */
    function registerFungibleOneForOneSwap(
        mapping(AssetIndex => mapping(AssetIndex => IFungibleOneForOneSwap)) storage exchanges,
        AssetId from,
        AssetId to,
        IFungibleOneForOneSwap swap
    ) internal {
        require(from.getClass() == AssetIdClass.Fungible, "from is not Fungible");
        require(to.getClass() == AssetIdClass.Fungible, "to is not Fungible");

        if (AssetIndex.unwrap(from.getIndex()) > AssetIndex.unwrap(to.getIndex())) {
            AssetId t = from;
            from = to;
            to = t;
        }

        AssetIndex key1 = from.getIndex();
        AssetIndex key2 = to.getIndex();

        require(AssetIndex.unwrap(key1) != AssetIndex.unwrap(key2), "from and to are the same");

        exchanges[key1][key2] = swap;
    }

    /**
     * @notice A helper to get an `IFungibleOneForOneSwap` for a given pair of assets.
     *
     * As we order keys when we store values, this helper function removes some noise from the
     * call site.
     */
    function getIFungibleOneForOneSwap(
        mapping(AssetIndex => mapping(AssetIndex => IFungibleOneForOneSwap))
            storage exchangeFungibleOneForOne,
        AssetIndex from,
        AssetIndex to
    ) internal view returns (IFungibleOneForOneSwap) {
        if (AssetIndex.unwrap(from) < AssetIndex.unwrap(to)) {
            return exchangeFungibleOneForOne[from][to];
        } else {
            return exchangeFungibleOneForOne[to][from];
        }
    }
}
