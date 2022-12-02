// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

// Inspired by the following contract: https://github.com/OpenBazaar/smart-contracts/blob/22d3f190163102f9ceee95ac705001c82ca55624/contracts/registry/ContractManager.sol

import "@openzeppelin/contracts/utils/Address.sol";
import {FsUtils} from "../lib/FsUtils.sol";
import {ImmutableOwnable} from "../lib/ImmutableOwnable.sol";
import "../interfaces/IVersionManager.sol";

contract VersionManager is IVersionManager, ImmutableOwnable {
    /// @notice Array of all version names
    string[] internal _versionString;

    /// @notice Mapping from version names to version structs
    mapping(string => Version) internal _versions;

    /// @dev The recommended version
    string internal _recommendedVersion;

    modifier versionExists(string memory versionName) {
        if (_versions[versionName].implementation == address(0)) {
            revert VersionNotRegistered();
        }
        _;
    }

    constructor(address owner) ImmutableOwnable(owner) {}

    /// @notice Registers a new version of the store contract
    /// @param versionName The name of the version to be added
    /// @param status Status of the version to be added
    /// @param _implementation The address of the implementation of the version
    function addVersion(
        string calldata versionName,
        Status status,
        address _implementation
    ) external onlyOwner {
        address implementation = FsUtils.nonNull(_implementation);
        // version name must not be the empty string
        if (bytes(versionName).length == 0) {
            revert InvalidVersionName();
        }

        // implementation must be a contract
        if (!Address.isContract(implementation)) {
            revert InvalidImplementation();
        }

        // the version name should not already be registered
        if (_versions[versionName].implementation != address(0)) {
            revert VersionAlreadyRegistered();
        }
        _versionString.push(versionName);

        _versions[versionName] = Version({
            versionName: versionName,
            status: status,
            bugLevel: BugLevel.NONE,
            implementation: implementation,
            dateAdded: block.timestamp
        });

        emit VersionAdded(versionName, implementation);
    }

    /// @notice Update a contract version
    /// @param versionName Version of the contract
    /// @param status Status of the contract
    /// @param bugLevel New bug level for the contract
    function updateVersion(
        string calldata versionName,
        Status status,
        BugLevel bugLevel
    ) external onlyOwner versionExists(versionName) {
        _versions[versionName].status = status;
        _versions[versionName].bugLevel = bugLevel;

        emit VersionUpdated(versionName, status, bugLevel);
    }

    /// @notice Set the recommended version
    /// @param versionName Version of the contract
    function markRecommendedVersion(
        string calldata versionName
    ) external onlyOwner versionExists(versionName) {
        // set the version name as the recommended version
        _recommendedVersion = versionName;

        emit VersionRecommended(versionName);
    }

    /// @notice Remove the recommended version
    function removeRecommendedVersion() external onlyOwner {
        // delete the recommended version name
        delete _recommendedVersion;

        emit RecommendedVersionRemoved();
    }

    /// @notice Get recommended version for the contract.
    /// @return versionName The name of the recommended version
    /// @return status The status of the recommended version
    /// @return bugLevel The bug level of the recommended version
    /// @return implementation The address of the implementation of the recommended version
    /// @return dateAdded The date the recommended version was added
    function getRecommendedVersion()
        external
        view
        returns (
            string memory versionName,
            Status status,
            BugLevel bugLevel,
            address implementation,
            uint256 dateAdded
        )
    {
        require(bytes(_recommendedVersion).length != 0, "Recommended version is not specified");
        versionName = _recommendedVersion;

        Version storage recommendedVersion = _versions[versionName];

        status = recommendedVersion.status;
        bugLevel = recommendedVersion.bugLevel;
        implementation = recommendedVersion.implementation;
        dateAdded = recommendedVersion.dateAdded;

        return (versionName, status, bugLevel, implementation, dateAdded);
    }

    /// @notice Get total count of versions
    function getVersionCount() external view returns (uint256 count) {
        count = _versionString.length;
        return count;
    }

    /// @dev Returns the version name at specific index in the versionString[] array
    /// @param index The index to be searched for
    function getVersionAtIndex(uint256 index) external view returns (string memory versionName) {
        versionName = _versionString[index];
        return versionName;
    }

    /// @notice Get the implementation address for a version
    /// @param index The index of the version
    function getVersionAddress(uint256 index) external view returns (address) {
        string memory versionName = _versionString[index];
        Version memory v = _versions[versionName];
        return v.implementation;
    }

    /// @notice Returns the version details for the given version name
    /// @param versionName Version string
    function getVersionDetails(
        string calldata versionName
    )
        external
        view
        returns (
            string memory versionString,
            Status status,
            BugLevel bugLevel,
            address implementation,
            uint256 dateAdded
        )
    {
        Version storage v = _versions[versionName];

        versionString = v.versionName;
        status = v.status;
        bugLevel = v.bugLevel;
        implementation = v.implementation;
        dateAdded = v.dateAdded;

        return (versionString, status, bugLevel, implementation, dateAdded);
    }
}
