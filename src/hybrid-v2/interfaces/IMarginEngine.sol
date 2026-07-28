// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {LiquidationStatus} from "../libraries/PositionTypes.sol";

/// @title IMarginEngine
/// @notice Read-only orchestration surface exposed by `MarginEngineV2` (WP-08).
///         Callers combine a canonical active-series witness with the
///         subaccount identity to obtain per-subaccount margin views computed
///         through the Vault-bound canonical `IRiskModule`.
/// @dev
///  Scope + reservation ownership (Part D verdict
///  `MARGIN_RESERVATION_OWNERSHIP_DEFERRED_BY_APPROVED_DESIGN`):
///   - This interface exposes NO mutation. WP-08 does not itself write
///     Vault reservations; the concrete per-token `applyLock`/`applyUnlock`
///     ownership belongs to the future OptionMatchingEngine (WP-08B / WP-09)
///     which applies fills atomically with post-state health checks.
///   - Every view REQUIRES the caller to pass the exact canonical
///     active-series set for `subKey`. The engine verifies completeness via
///     `IOptionsPositionsLedger.verifyActiveSeriesArrayComplete` and reverts
///     `IncompleteActiveSeriesWitness` on any mismatch.
///
///  Fail-closed contract:
///   - `initialMargin1e18`, `maintenanceMargin1e18`, `availableCollateral1e18`,
///     `marginExcess1e18`, `marginRatio1e18` — MUST revert on unknown subKey,
///     invalid witness, or upstream `IRiskModule` unavailability.
///   - `isHealthy` — MUST return `false` on any failure (never revert).
///   - `liquidationStatus` — MUST revert on indeterminate risk (inherits
///     WP-07 semantics per `contract-spec/06_RISK_MARGIN_MODULE_SPEC.md`).
interface IMarginEngine {
    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `subKey` argument is `bytes32(0)`.
    error SubKeyRequired();

    /// @notice `subKey` is not registered in the canonical Registry.
    error UnknownSubaccount(bytes32 subKey);

    /// @notice The supplied `seriesIds` array does not exactly enumerate the
    ///         canonical active series for `subKey`.
    error IncompleteActiveSeriesWitness(bytes32 subKey);

    /// @notice The upstream Vault-bound `IRiskModule` did not produce an exact
    ///         result and cannot authorize this view.
    error RiskModuleUnavailable();

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initial-margin requirement for `subKey` in 1e18 quote units,
    ///         computed under the frozen Options IM formula
    ///         (`ceil(MM * imFactorBps / 10_000)`).
    function initialMargin1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256);

    /// @notice Maintenance-margin requirement for `subKey` in 1e18 quote units.
    ///         Delegates to the canonical `IRiskModule.marginRequirement`.
    function maintenanceMargin1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256);

    /// @notice Aggregate available collateral value for `subKey` in 1e18 quote
    ///         units. Delegates to the canonical `IRiskModule.availableMargin`.
    function availableCollateral1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256);

    /// @notice `availableCollateral1e18 - maintenanceMargin1e18` clipped to
    ///         zero when the account is undercollateralized.
    function marginExcess1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256);

    /// @notice `availableCollateral * 1e18 / maintenanceMargin`. Returns
    ///         `type(uint256).max` when the maintenance margin is zero.
    function marginRatio1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256);

    /// @notice `true` iff `availableCollateral >= maintenanceMargin`.
    ///         Fail-closed: returns `false` on ANY failure. NEVER reverts.
    function isHealthy(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (bool);

    /// @notice Aggregate liquidation status. Reverts on indeterminate risk
    ///         (inherits WP-07 fail-safe semantics per spec 06).
    function liquidationStatus(bytes32 subKey, uint256[] calldata activeSeriesIds)
        external
        view
        returns (LiquidationStatus);

    /*//////////////////////////////////////////////////////////////
                             CANONICAL BINDINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice The canonical Vault this engine reads collateral universe from.
    function vault() external view returns (address);

    /// @notice The canonical `IRiskModule` this engine consults. Sourced
    ///         from the Vault's `RISK_MODULE()` at construction and never
    ///         changes.
    function riskModule() external view returns (address);
}
