//SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

type ERC20Share is int256;

interface IDOSERC20 is IERC20 {
    function mint(address account, uint256 amount) external;

    function burn(address account, uint256 amount) external;
}

interface IDOS {
    struct Call {
        address to;
        bytes callData;
        uint256 value;
    }

    function createPortfolio() external returns (address);

    function upgradeImplementation(address portfolio, uint256 version) external;

    function liquidate(address portfolio) external;

    function depositFull(IERC20[] calldata erc20Idxs) external;

    function withdrawFull(IERC20[] calldata erc20Idxs) external;

    function executeBatch(Call[] memory calls) external;

    function transferFromERC20(
        address erc20,
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function depositERC20(address erc20, address portfolio, uint256 amount) external;

    function viewBalance(address portfolio, IERC20 erc20) external view returns (int256);

    function getImplementation(address portfolio) external view returns (address);

    function getPortfolioOwner(address portfolio) external view returns (address);
}
