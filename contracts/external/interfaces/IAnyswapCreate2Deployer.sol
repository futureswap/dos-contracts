// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

interface IAnyswapCreate2Deployer {
    event Deployed(address addr, uint256 salt);

    function deploy(bytes memory code, uint256 salt) external;
}
