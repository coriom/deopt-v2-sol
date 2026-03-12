// contracts/margin/MarginEngine.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MarginEngineOps} from "./MarginEngineOps.sol";

/// @title MarginEngine
/// @notice Façade finale (hérite MarginEngineOps -> Trading/Admin/Storage/Types)
/// @dev
///  Le constructeur ne câble que les dépendances "core".
///  Le reste est configuré via les fonctions d’admin:
///   - matchingEngine
///   - riskModule
///   - insuranceFund
///   - feesManager
///   - feeRecipient
///   - guardian
///   - params liquidation
///   - risk params cache
contract MarginEngine is MarginEngineOps {
    constructor(address _owner, address registry_, address vault_, address oracle_) {
        _initMarginEngineStorage(_owner, registry_, vault_, oracle_);

        // bootstrap guardian: owner at deploy time.
        // In production, ownership can later be transferred to timelock
        // and guardian rotated to a dedicated emergency operator.
        _setGuardian(_owner);

        // defaults explicitement émis au déploiement
        emit LiquidationOracleMaxDelaySet(0, liquidationOracleMaxDelay);
        emit GlobalPauseSet(false);
        emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
    }
}