// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title Versions
/// @notice Canonical version constants + subaccount id sentinels for the DeOpt V2 hybrid subaccount architecture.
/// @dev
///  - `EVENT_VERSION` is emitted in every subaccount-scoped event per contract-spec 13.
///  - `ARCHITECTURE_VERSION` is bound in EIP-712 payloads per contract-spec 08 + INV-MIG-07.
///  - `STORAGE_VERSION` is exposed by IRiskModule.supportsCanonicalStorageVersion per contract-spec 06.
///  - `SUBACCOUNT_ID_INVALID` and `SUBACCOUNT_ID_DEFAULT` reflect decisions D-03 + INV-ID-01.
///
///  These constants are shared read-only foundation. No mutation. No storage. No behavior.
///  Downstream implementation milestones (WP-02..WP-10) consume these values verbatim.
library Versions {
    /// @notice Event schema version emitted in every subaccount-scoped event.
    uint16 internal constant EVENT_VERSION = 1;

    /// @notice Architecture version bound in every EIP-712 payload.
    /// @dev Used to reject signatures issued against a superseded architecture.
    uint256 internal constant ARCHITECTURE_VERSION = 1;

    /// @notice Canonical storage version exposed by replaceable modules for compatibility checks.
    uint16 internal constant STORAGE_VERSION = 1;

    /// @notice Reserved invalid subaccount id.
    /// @dev Any user operation with subaccountId == 0 MUST be rejected by the registry
    ///      and consuming engines. Enforcement lives in downstream implementations.
    uint32 internal constant SUBACCOUNT_ID_INVALID = 0;

    /// @notice Lazy default subaccount id (per decision D-03).
    /// @dev First authenticated interaction lazily registers this id when required.
    uint32 internal constant SUBACCOUNT_ID_DEFAULT = 1;
}
