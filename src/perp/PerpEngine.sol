// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PerpEngineTrading} from "./PerpEngineTrading.sol";

/// @title PerpEngine
/// @notice Final perpetual engine façade for DeOpt v2.
/// @dev
///  Constructor only wires core immutable-style dependencies:
///   - owner
///   - market registry
///   - collateral vault
///   - oracle
///
///  The rest is configured later through admin:
///   - matchingEngine
///   - guardian
///   - riskModule
///   - insuranceFund
///   - feesManager
///   - feeRecipient
///
///  Architectural note:
///   - this engine is intentionally separated from the options MarginEngine
///   - both stacks are expected to share:
///       * CollateralVault
///       * OracleRouter
///       * FeesManager
///       * InsuranceFund
///       * Governance / Timelock
contract PerpEngine is PerpEngineTrading {
    constructor(address _owner, address registry_, address vault_, address oracle_) {
        _initPerpEngineStorage(_owner, registry_, vault_, oracle_);

        // bootstrap guardian at deploy time
        _setGuardian(_owner);

        // explicit deployment-state events for consistency with the rest of the protocol
        emit GlobalPauseSet(false);
        emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
    }
}