// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title RecoveryTypes
/// @notice Shared enums for escape-hatch + recovery interfaces.
/// @dev Transcribed verbatim from escape-hatch spec 15. No behavior. No storage.

/// @notice Per-subaccount recovery state machine SM-Rec.
/// @dev Transitions specified in escape-hatch spec 04. Reserved variant
///      `MIGRATED` is placeholder for future migration bridge integration.
enum RecoveryState {
    NORMAL,
    RECOVERY_PENDING,
    RECOVERY_ACTIVE,
    SETTLEMENT_PENDING,
    WITHDRAWAL_ELIGIBLE,
    RECOVERED,
    CANCELLED,
    MIGRATED
}

/// @notice Recovery scope for epoch bump events.
enum RecoveryScope {
    SUBACCOUNT,
    OWNER
}

/// @notice Fallback finalization status per option series.
enum FinalizationStatus {
    NONE,
    REQUESTED,
    DISPUTED,
    FINALIZED
}

/// @notice Fallback price source hierarchy for `IRecoveryFinalizer`.
/// @dev Ordering matches escape-hatch design: F-A → F-B → F-C → F-D.
enum FallbackSource {
    PRIMARY,
    FALLBACK_ORACLE,
    HISTORICAL_TWAP,
    GOVERNANCE_BOUNDED
}
