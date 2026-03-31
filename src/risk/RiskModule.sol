// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskModuleViews.sol";

/// @title RiskModule
/// @notice Final façade for the DeOpt v2 unified risk engine.
/// @dev
///  Inheritance stack:
///   RiskModule
///     -> RiskModuleViews
///     -> RiskModuleAdmin
///     -> RiskModuleMargin
///     -> RiskModuleCollateral
///     -> RiskModuleOracle
///     -> RiskModuleUtils
///     -> RiskModuleStorage
///
///  This contract assembles the full risk stack:
///   - storage / admin / pause controls
///   - oracle conversions
///   - collateral valuation
///   - options margin / liability aggregation
///   - best-effort perp risk decomposition when configured
///   - public unified risk views
///
///  Current scope:
///   - canonical protocol risk surface for shared collateral
///   - options-side risk source of truth
///   - prepared for richer protocol-wide cross-product decomposition
///   - compatible with shared CollateralVault and PerpRiskModule bridge
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
///   - perp engine / perp risk module bridge
///   - margin multipliers / pause modes
contract RiskModule is RiskModuleViews {
    constructor(address _owner, address _vault, address _registry, address _marginEngine, address _oracle) {
        _initRiskModuleStorage(_owner, _vault, _registry, _marginEngine, _oracle);
    }
}