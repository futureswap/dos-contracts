// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "./interfaces/IDosAssetRegistryV1.sol";

import "./DosV1Storage.sol";
import "./AssetId.sol";

library DosV1AssetRegistry {
    /*
     * === IDosAssetRegistryV1 ===
     */

    /**
     * @notice An implementation for `IDosAssetRegistryV1.registerAsset()`.
     */
    function registerAsset(
        mapping(AssetIndex => FungibleAssetInfo) storage assetInfo,
        uint16 nextAssetIndex,
        IDosAssetRegistryV1.AssetRegistration calldata info
    ) internal returns (AssetId id) {
        AssetIndex idx = AssetIndex.wrap(nextAssetIndex);
        id = AssetIdImpl.fromClassAndIndex(AssetIdClass.Fungible, idx);

        assetInfo[idx] = FungibleAssetInfo({
            token: info.token,
            assessor: info.assessor,
            useAsCollateral: info.useAsCollateral,
            useAsDebt: info.useAsDebt
        });

        return id;
    }

    /**
     * @notice An implementation for `IDosAssetRegistryV1.updateAsset()`.
     */
    function updateAsset(
        mapping(AssetIndex => FungibleAssetInfo) storage assetInfo,
        uint16 maxAssetIndex,
        AssetId id,
        IDosAssetRegistryV1.AssetRegistration calldata info
    ) internal {
        AssetIdClass cls = id.getClass();
        AssetIndex idx = id.getIndex();

        require(cls == AssetIdClass.Fungible, "id must be a Fungible asset");
        require(AssetIndex.unwrap(idx) < maxAssetIndex, "id is not registered yet");

        assetInfo[idx] = FungibleAssetInfo({
            token: info.token,
            assessor: info.assessor,
            useAsCollateral: info.useAsCollateral,
            useAsDebt: info.useAsDebt
        });
    }

    /**
     * @notice An implementation for `IDosAssetRegistryV1.registerNftAsset()`.
     */
    function registerNftAsset(
        mapping(AssetIndex => NftAssetInfo) storage assetInfo,
        uint16 nextAssetIndex,
        IDosAssetRegistryV1.NftAssetRegistration calldata info
    ) internal returns (AssetId id) {
        AssetIndex idx = AssetIndex.wrap(nextAssetIndex);
        id = AssetIdImpl.fromClassAndIndex(AssetIdClass.Nft, idx);

        assetInfo[idx] = NftAssetInfo({ token: info.token, assessor: info.assessor });

        return id;
    }

    /**
     * @notice An implementation for `IDosAssetRegistryV1.updateNftAsset()`.
     */
    function updateNftAsset(
        mapping(AssetIndex => NftAssetInfo) storage assetInfo,
        uint16 maxAssetIndex,
        AssetId id,
        IDosAssetRegistryV1.NftAssetRegistration calldata info
    ) internal {
        AssetIdClass cls = id.getClass();
        AssetIndex idx = id.getIndex();

        require(cls == AssetIdClass.Nft, "id must be an NFT asset");
        require(AssetIndex.unwrap(idx) < maxAssetIndex, "id is not registered yet");

        assetInfo[idx] = NftAssetInfo({ token: info.token, assessor: info.assessor });
    }
}
