// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../external/interfaces/IAnyswapCreate2Deployer.sol";
import "../lib/FsUtils.sol";

contract BatchDeploy {
    struct InitCode {
        bytes initCode;
        bytes32 salt;
    }

    IAnyswapCreate2Deployer immutable anyswapCreate2Deployer;

    constructor(address _anyswapCreate2Deployer) {
        anyswapCreate2Deployer = IAnyswapCreate2Deployer(FsUtils.nonNull(_anyswapCreate2Deployer));
    }

    function deploy(InitCode[] calldata initCodes) external {
        for (uint256 i = 0; i < initCodes.length; i++) {
            anyswapCreate2Deployer.deploy(initCodes[i].initCode, uint256(initCodes[i].salt));
        }
    }
}
