// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskModuleViews.sol";

/// @title RiskModule
/// @notice Final façade for the DeOpt v2 options risk engine.
/// @dev
///  This contract assembles the full risk stack:
///   - storage / admin / pause controls
///   - oracle conversions
///   - collateral valuation
///   - options margin / liability aggregation
///   - public unified risk views
///
///  Current scope:
///   - options-side risk source of truth
///   - compatible with shared CollateralVault
///   - prepared for richer protocol-wide cross-product decomposition
///
///  Constructor wiring:
///   - owner
///   - collateral vault
///   - option registry
///   - margin engine
///   - oracle
///
///  Post-deploy configuration remains admin-driven:
///   - base collateral token
///   - collateral configs
///   - underlying configs
///   - margin multipliers / pause modes
contract RiskModule is RiskModuleViews {
    constructor(address _owner, address _vault, address _registry, address _marginEngine, address _oracle) {
        _initRiskModuleStorage(_owner, _vault, _registry, _marginEngine, _oracle);
    }
}