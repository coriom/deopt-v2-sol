// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarginEngineOps} from "./MarginEngineOps.sol";

/// @title MarginEngine
/// @notice Final options engine façade for DeOpt v2.
/// @dev
///  Inheritance stack:
///   MarginEngine
///     -> MarginEngineOps
///     -> MarginEngineTrading
///     -> MarginEngineAdmin
///     -> MarginEngineStorage
///     -> MarginEngineTypes
///
///  Constructor wires only core immutable-style dependencies:
///   - owner
///   - option registry
///   - collateral vault
///   - oracle
///
///  Remaining dependencies / params are configured later via admin:
///   - matchingEngine
///   - riskModule
///   - insuranceFund
///   - feesManager
///   - feeRecipient
///   - guardian
///   - liquidation params
///   - cached risk params
///
///  Architectural note:
///   - options stack is intentionally separated from perp stack
///   - both are expected to share:
///       * CollateralVault
///       * OracleRouter
///       * FeesManager
///       * InsuranceFund
///       * Governance / Timelock
contract MarginEngine is MarginEngineOps {
    constructor(address _owner, address registry_, address vault_, address oracle_) {
        _initMarginEngineStorage(_owner, registry_, vault_, oracle_);

        // Bootstrap guardian with owner at deploy time.
        // In production, ownership can later move to timelock governance
        // and guardian can be rotated to a dedicated emergency operator.
        _setGuardian(_owner);

        // Explicit bootstrap emission for liquidation freshness config.
        emit LiquidationOracleMaxDelaySet(0, liquidationOracleMaxDelay);
    }
}