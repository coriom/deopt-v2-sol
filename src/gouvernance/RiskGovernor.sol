// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskGovernorQueue.sol";

/// @title RiskGovernor
/// @notice Final governance façade specialized for protocol risk and parameter changes over ProtocolTimelock.
/// @dev
///  Inheritance stack:
///   RiskGovernor
///     -> RiskGovernorQueue
///     -> RiskGovernorAdmin
///     -> RiskGovernorStorage
///
///  Intended architecture:
///   - sensitive protocol contracts are owned by ProtocolTimelock
///   - RiskGovernor is the high-level orchestration layer used to queue / cancel / execute operations
///   - RiskGovernor owner is expected to be the protocol multisig / admin authority
///   - RiskGovernor guardian can cancel queued operations through the timelock flow
///   - supports both options and perps stacks
///
///  Scope of governance surface:
///   - RiskModule
///   - MarginEngine
///   - OracleRouter
///   - FeesManager
///   - OptionProductRegistry
///   - CollateralVault
///   - InsuranceFund
///   - PerpMarketRegistry
///   - PerpEngine
///
///  Operational note:
///   - this contract intentionally contains no additional mutable logic beyond the inherited queue/admin/storage layers
///   - its role is to expose a clean final deployment artifact for protocol governance
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
        address _insuranceFund,
        address _perpMarketRegistry,
        address _perpEngine
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
            _insuranceFund,
            _perpMarketRegistry,
            _perpEngine
        )
    {}
}