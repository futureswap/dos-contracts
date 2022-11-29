//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IDOSERC20 is IERC20 {
    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;
}

interface IDOS {
    function upgradeImplementation(uint256 _version) external;

    function getImplementation(address portfolio) external view returns (address);

    function getPortfolioOwner(address portfolio) external view returns (address);

    struct Call {
        address to;
        bytes callData;
        uint256 value;
    }

    function executeBatch(Call[] memory calls) external;
}
