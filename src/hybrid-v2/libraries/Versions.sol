// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title Versions
/// @notice Canonical version constants + subaccount id sentinels for the DeOpt V2 hybrid subaccount architecture.
/// @dev
///  Version-family separation:
///   - `EVENT_VERSION` — schema version emitted in every subaccount-scoped event (spec 13).
///     Bumped on event-schema change.
///   - `ARCHITECTURE_VERSION` — protocol architecture family bound in EIP-712 payloads
///     (spec 08 + INV-MIG-07). Bumped on architecture-family change.
///   - `STORAGE_VERSION` — storage/schema compatibility identifier exposed by replaceable
///     modules via `IRiskModule.supportsCanonicalStorageVersion(uint16)` (spec 06).
///     Bumped when a replaceable module's storage layout changes materially.
///   - `deploymentVersion` — per-deployment monotonic identifier (D-MIG-25 FROZEN).
///     Value is deployment-specific (e.g. `1` for the initial Base Sepolia deployment,
///     `2` after cutover per migration-design 16_BASE_SEPOLIA_RUNBOOK); therefore it
///     is NOT a compile-time global. Canonical shape is `uint256` (matches migration
///     event fields, e.g. `MigrationRootPublished.deploymentVersion: uint256` in
///     migration-design/10_EVENTS_AND_MANIFESTS.md). Downstream contracts expose
///     `deploymentVersion` via constructor `immutable` supplied at deployment time.
///     `INITIAL_DEPLOYMENT_VERSION` below documents the sentinel value used for a
///     first-ever fresh deployment.
///
///  Deployment version is NEVER embedded inside `subKey` derivation (spec 02); domain
///  separation across deployments is achieved via `verifyingContract` in EIP-712 domain
///  fields (spec 08) plus the deployment-scoped registry address encoded into `subKey`.
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

    /// @notice Canonical Solidity type used to represent a per-deployment monotonic version.
    /// @dev Documented as `uint256` per D-MIG-25 + migration-design event schema. Not itself
    ///      a value: consumers MUST supply a `uint256` immutable at deployment time.
    ///      Provided as a `uint256` constant `1` so downstream tooling can assert the type
    ///      unambiguously at compile time.
    uint256 internal constant INITIAL_DEPLOYMENT_VERSION = 1;

    /// @notice Reserved invalid subaccount id.
    /// @dev Any user operation with subaccountId == 0 MUST be rejected by the registry
    ///      and consuming engines. Enforcement lives in downstream implementations.
    uint32 internal constant SUBACCOUNT_ID_INVALID = 0;

    /// @notice Lazy default subaccount id (per decision D-03).
    /// @dev First authenticated interaction lazily registers this id when required.
    uint32 internal constant SUBACCOUNT_ID_DEFAULT = 1;
}
