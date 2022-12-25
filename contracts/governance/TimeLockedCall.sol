// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./GovernanceProxy.sol";
import "../lib/ImmutableGovernance.sol";
import "../tokens/HashNFT.sol";

contract TimeLockedCall is ImmutableGovernance, Ownable2Step {
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
        accessLevel = _accessLevel;
        hashNFT = HashNFT(FsUtils.nonNull(hashNFT_));
        lockTime = _lockTime;
    }

    function proposeBatch(CallWithoutValue[] calldata calls) external onlyOwner {
        uint256 executionTime = block.timestamp + lockTime;
        hashNFT.mint(address(this), calcDigest(calls, executionTime), "");
        emit BatchProposed(calls, block.timestamp + lockTime);
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
        lockTime = _lockTime;
    }

    function calcDigest(
        CallWithoutValue[] calldata calls,
        uint256 executionTime
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(executionTime, calls));
    }
}
