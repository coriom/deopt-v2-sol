// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskGovernorQueue.sol";

/// @title RiskGovernor
/// @notice Governance wrapper specialized for risk and protocol parameter changes over ProtocolTimelock.
/// @dev
///  Intended architecture:
///   - sensitive contracts are owned by ProtocolTimelock
///   - RiskGovernor is authorized as proposer + executor on the timelock
///   - RiskGovernor owner is the protocol multisig / admin
///   - RiskGovernor guardian can cancel queued ops through the timelock
contract RiskGovernor is RiskGovernorQueue {
    constructor(
        address _owner,
        address _guardian,
        address _timelock,
        address _riskModule,
        address _marginEngine,
        address _oracleRouter,
        address _feesManager,
        address _optionRegistry,
        address _collateralVault,
        address _insuranceFund
    )
        RiskGovernorStorage(
            _owner,
            _guardian,
            _timelock,
            _riskModule,
            _marginEngine,
            _oracleRouter,
            _feesManager,
            _optionRegistry,
            _collateralVault,
            _insuranceFund
        )
    {}
}