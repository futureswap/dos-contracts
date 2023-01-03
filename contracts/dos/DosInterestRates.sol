// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.17;

import "../lib/ImmutableGovernance.sol";

//import "hardhat/console.sol"; // DEV_MODE

error InvalidSlopes();

/// @title DOS Interest Rates
contract DosInterestRates is ImmutableGovernance {
    struct RateParams {
        uint256 baseRate; // interest rate at 0% utilization
        uint256 slope1; // slope before target utilization
        uint256 slope2; // slope after target utilization
        uint256 targetUtilization; // the target utilization (uOptimal/kink)
    }

    /// @notice mapping of rate parameters by asset
    mapping(address => RateParams) public rateParamsByUnderlying;

    constructor(address _owner) ImmutableGovernance(_owner) {}

    /// @notice Add rate parameters for an underlying asset
    /// @param underlying The underlying asset
    /// @param params The rate parameters (base rate, slope1, slope2, target utilization)
    function addUnderlying(address underlying, RateParams calldata params) external onlyGovernance {
        // TODO: add parameter checks (e.g. slope2 > slope 1)?
        if (params.slope2 < params.slope1) {
            revert InvalidSlopes();
        }
        rateParamsByUnderlying[underlying] = params;
        // TODO: emit TokenAdded(underlying);
    }

    /// @notice Compute the interest rate of `underlying` at `utilization`
    /// @param underlying The underlying asset
    /// @param utilization The utilization rate
    /// @return The interest rate of `underlying` at `utilization`
    function computeInterestRate(
        address underlying,
        uint32 utilization
    ) external view returns (int96) {
        RateParams memory params = rateParamsByUnderlying[underlying];
        uint256 ir = params.baseRate;

        if (utilization <= params.targetUtilization) {
            ir += utilization * params.slope1;
        } else {
            ir += params.targetUtilization * params.slope1;
            ir += params.slope2 * (utilization - params.targetUtilization);
        }

        return int96(int256(ir));
    }
}
