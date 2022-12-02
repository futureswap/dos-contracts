// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/// @notice version is not registered
error VersionNotRegistered();
/// @notice version name cannot be the empty string
error InvalidVersionName();
/// @notice implementation must be a contract
error InvalidImplementation();
/// @notice version is already registered
error VersionAlreadyRegistered();

interface IVersionManager {
    /// @dev Signifies the status of a version
    enum Status {
        BETA,
        RC,
        PRODUCTION,
        DEPRECATED
    }

    /// @dev Indicated the highest level of bug found in the version
    enum BugLevel {
        NONE,
        LOW,
        MEDIUM,
        HIGH,
        CRITICAL
    }

    /// @dev A struct to encode version details
    struct Version {
        // the version number string ex. "v1.0"
        string versionName;
        Status status;
        BugLevel bugLevel;
        // the address of the instantiation of the version
        address implementation;
        // the date when this version was registered with the contract
        uint256 dateAdded;
    }

    event VersionAdded(string versionName, address indexed implementation);

    event VersionUpdated(string versionName, Status status, BugLevel bugLevel);

    event VersionRecommended(string versionName);

    event RecommendedVersionRemoved();

    function addVersion(
        string calldata versionName,
        Status status,
        address implementation
    ) external;

    function updateVersion(string calldata versionName, Status status, BugLevel bugLevel) external;

    function markRecommendedVersion(string calldata versionName) external;

    function removeRecommendedVersion() external;

    function getRecommendedVersion()
        external
        view
        returns (
            string memory versionName,
            Status status,
            BugLevel bugLevel,
            address implementation,
            uint256 dateAdded
        );

    function getVersionCount() external view returns (uint256 count);

    function getVersionAtIndex(uint256 index) external view returns (string memory versionName);

    function getVersionAddress(uint256 index) external view returns (address);

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
        );
}
