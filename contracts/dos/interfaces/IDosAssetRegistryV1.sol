// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "../AssetId.sol";

import "./assessor/INftAssessor.sol";
import "./assessor/ITokenAssessor.sol";

/**
 * @title Addition, update and listing of assets supported by DOS.
 *
 * @notice DOS needs to know a number of things about every asset it operates with, in order to
 * asset their value, risk, as well as to liquidate debt.
 *
 * All the state changing operations in this API are callable only by the DOS operator roles, which
 * would be a voting system for a production deployment.
 *
 * See `IDosYieldApiV1` for the yield generation and borrow fee aspect of assets.
 *
 * See `IDosExchangeRegistryV1` for interaction with exchange and swapping of assets.
 *
 * TODO Removal of an asset is a non-trivial operation.  DOS v1 is not going to support it.
 *
 * TODO Add listing support.  Expose `fungibleAssetInfo` and `nftAssetInfo` from `DosV1.
 */
interface IDosAssetRegistryV1 {
    /**
     * @notice Describes a new fungible, ERC20 asset to be supported by DOS.
     */
    struct AssetRegistration {
        IERC20 token;
        ITokenAssessor assessor;
        bool useAsCollateral;
        bool useAsDebt;
    }

    /**
     * @notice Emitted by the `registerAsset()` call.
     */
    event RegisterAsset(
        AssetId indexed id,
        IERC20 indexed token,
        ITokenAssessor assessor,
        bool useAsCollateral,
        bool useAsDebt
    );

    /**
     * @notice Adds a new fungible, ERC20 token asset to the list the support by the current DOS
     * instance.
     *
     * Emits `RegisterAsset`.
     *
     * @return id Id of the new token.
     */
    function registerAsset(AssetRegistration calldata info) external returns (AssetId id);

    /**
     * @notice Emitted by the `updateAsset()` call.
     */
    event UpdateAsset(
        AssetId indexed id,
        IERC20 indexed token,
        ITokenAssessor assessor,
        bool useAsCollateral,
        bool useAsDebt
    );

    /**
     * @notice Updates a fungible token registration.
     *
     * TODO Describe the details and constraints.
     */
    function updateAsset(AssetId id, AssetRegistration calldata info) external;

    /**
     * @notice Describes a new NFT, ERC721 asset to be supported by DOS.
     */
    struct NftAssetRegistration {
        IERC721 token;
        INftAssessor assessor;
    }

    /**
     * @notice Emitted by the `registerNftAsset()` call.
     */
    event RegisterNftAsset(AssetId indexed id, IERC721 indexed token, INftAssessor assessor);

    /**
     * @notice Adds a new NFT, ERC721 token asset to the list the support by the current DOS
     * instance.
     *
     * @return id Id of the new token.
     */
    function registerNftAsset(NftAssetRegistration calldata info) external returns (AssetId id);

    /**
     * @notice Emitted by the `updateNftAsset()` call.
     */
    event UpdateNftAsset(AssetId indexed id, IERC721 indexed token, INftAssessor assessor);

    /**
     * @notice Updates an NFT token registration.
     *
     * TODO Describe the details and constraints.
     */
    function updateNftAsset(AssetId id, NftAssetRegistration calldata info) external;
}
