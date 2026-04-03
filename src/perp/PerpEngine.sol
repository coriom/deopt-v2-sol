// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PerpEngineTrading} from "./PerpEngineTrading.sol";

/// @title PerpEngine
/// @notice Final perpetual engine façade for DeOpt v2.
/// @dev
///  Target inheritance stack:
///   PerpEngine
///     -> PerpEngineTrading
///     -> PerpEngineViews
///     -> PerpEngineAdmin
///     -> PerpEngineStorage
///     -> PerpEngineTypes
///
///  Constructor wires the immutable-style core dependencies:
///   - owner
///   - market registry
///   - collateral vault
///   - oracle
///
///  The rest of the operational surface is configured later through admin:
///   - matchingEngine
///   - guardian
///   - riskModule
///   - collateralSeizer
///   - insuranceFund
///   - feesManager
///   - feeRecipient
///
///  Architectural note:
///   - this engine remains intentionally separated from the options MarginEngine
///   - both stacks are expected to share:
///       * CollateralVault
///       * OracleRouter
///       * FeesManager
///       * InsuranceFund
///       * Governance / Timelock
///
///  Deployment note:
///   - `_initPerpEngineStorage()` already emits the base deployment-state events
///   - the constructor only finalizes guardian bootstrap here
contract PerpEngine is PerpEngineTrading {
    constructor(address _owner, address registry_, address vault_, address oracle_) {
        _initPerpEngineStorage(_owner, registry_, vault_, oracle_);

        // Bootstrap guardian at deploy time.
        // In production, ownership can later move to timelock governance
        // and guardian can be rotated to a dedicated emergency operator.
        _setGuardian(_owner);
    }
}