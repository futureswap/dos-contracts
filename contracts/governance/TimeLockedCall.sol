// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./GovernanceProxy.sol";
import "../lib/ImmutableGovernance.sol";

contract TimeLockedCall is ImmutableGovernance, Ownable2Step {
    uint8 public immutable accessLevel;

    uint256 public lockTime;
    // Bit complemented execution time. This makes the default value 0
    // mean uint256.max, which is the larger then any possible timestamp.
    mapping(bytes32 => uint256) public bitComplementedExecutionTime;

    event BatchProposed(CallWithoutValue[] calls, bytes32 salt, uint256 executionTime);

    constructor(
        address governance,
        uint8 _accessLevel,
        uint256 _lockTime
    ) ImmutableGovernance(governance) {
        accessLevel = _accessLevel;
        lockTime = _lockTime;
    }

    function proposeBatch(CallWithoutValue[] calldata calls, bytes32 salt) external onlyOwner {
        bytes32 hash = keccak256(abi.encode(salt, calls));
        require(bitComplementedExecutionTime[hash] == 0, "TimeLockedCall: already proposed");
        bitComplementedExecutionTime[hash] = ~(block.timestamp + lockTime);
        emit BatchProposed(calls, salt, block.timestamp + lockTime);
    }

    function executeBatch(CallWithoutValue[] calldata calls, bytes32 salt) external {
        bytes32 hash = keccak256(abi.encode(salt, calls));
        require(
            ~bitComplementedExecutionTime[hash] <= block.timestamp,
            "TimeLockedCall: not ready"
        );
        Governance(GovernanceProxy(immutableGovernance).governance()).executeBatchWithClearance(
            calls,
            accessLevel
        );
        bitComplementedExecutionTime[hash] = 0;
    }

    function setLockTime(uint256 _lockTime) external onlyGovernance {
        lockTime = _lockTime;
    }
}
