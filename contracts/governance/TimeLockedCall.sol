// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GovernanceProxy} from "./GovernanceProxy.sol";
import {Governance} from "./Governance.sol";
import {ImmutableGovernance} from "../lib/ImmutableGovernance.sol";
import {HashNFT} from "../tokens/HashNFT.sol";
import {AccessControl} from "../lib/AccessControl.sol";
import {CallWithoutValue} from "../lib/Call.sol";
import {FsUtils} from "../lib/FsUtils.sol";

contract TimeLockedCall is ImmutableGovernance, Ownable2Step {
    uint256 constant MIN_TIMELOCK = 1 days;
    uint256 constant MAX_TIMELOCK = 3 days;

    HashNFT public immutable hashNFT;
    uint8 public immutable accessLevel;

    uint256 public lockTime;

    event BatchProposed(CallWithoutValue[] calls, uint256 executionTime);

    constructor(
        address governance,
        address hashNFT_,
        uint8 _accessLevel,
        uint256 _lockTime
    ) ImmutableGovernance(governance) {
        require(
            _accessLevel == uint8(AccessControl.AccessLevel.FINANCIAL_RISK),
            "TimeLockedCall: invalid access level"
        );
        accessLevel = _accessLevel;
        hashNFT = HashNFT(FsUtils.nonNull(hashNFT_));
        _setLockTime(_lockTime);
    }

    function proposeBatch(CallWithoutValue[] calldata calls) external onlyOwner {
        uint256 executionTime = block.timestamp + lockTime;
        emit BatchProposed(calls, block.timestamp + lockTime);
        hashNFT.mint(address(this), calcDigest(calls, executionTime), "");
    }

    function executeBatch(CallWithoutValue[] calldata calls, uint256 executionTime) external {
        require(executionTime <= block.timestamp, "TimeLockedCall: not ready");
        uint256 tokenId = hashNFT.toTokenId(address(this), calcDigest(calls, executionTime));
        hashNFT.burn(address(this), tokenId, 1);
        Governance(GovernanceProxy(immutableGovernance).governance()).executeBatchWithClearance(
            calls,
            accessLevel
        );
    }

    function setLockTime(uint256 _lockTime) external onlyGovernance {
        _setLockTime(_lockTime);
    }

    function _setLockTime(uint256 _lockTime) internal {
        require(_lockTime >= MIN_TIMELOCK, "TimeLockedCall: too short");
        require(_lockTime <= MAX_TIMELOCK, "TimeLockedCall: too long");
        lockTime = _lockTime;
    }

    function calcDigest(
        CallWithoutValue[] calldata calls,
        uint256 executionTime
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(executionTime, calls));
    }
}
