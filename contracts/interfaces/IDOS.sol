//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

type AssetIdx is uint16;
type AssetShare is int256;

interface IDOSERC20 is IERC20 {
    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;
}

interface IDOS {
    function upgradeImplementation(address portfolio, uint256 version) external;

    function getImplementation(address portfolio) external view returns (address);

    function getPortfolioOwner(address portfolio) external view returns (address);

    function liquidate(address portfolio) external;

    function viewBalance(address portfolio, AssetIdx assetIdx) external view returns (int256);

    function depositFull(AssetIdx[] calldata assetIdxs) external;

    function withdrawFull(AssetIdx[] calldata assetIdxs) external;

    struct Call {
        address to;
        bytes callData;
        uint256 value;
    }

    function executeBatch(Call[] memory calls) external;
}
