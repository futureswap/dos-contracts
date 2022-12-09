// SPDX-License-Identifier: BUSL-1.1
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

    function upgradeImplementation(address dSafe, uint256 version) external;

    function liquidate(address dSafe) external;

    function depositERC20(IERC20 erc20, int256 amount) external;

    function depositFull(IERC20[] calldata erc20s) external;

    function withdrawFull(IERC20[] calldata erc20s) external;

    function executeBatch(Call[] memory calls) external;

    function viewBalance(address dSafe, IERC20 erc20) external view returns (int256);

    function getImplementation(address dSafe) external view returns (address);

    function getDSafeOwner(address dSafe) external view returns (address);
}
