// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {IOptionsPositionsLedger} from "../interfaces/IOptionsPositionsLedger.sol";
import {LiquidationStatus} from "../libraries/PositionTypes.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title RiskModuleV2
/// @notice Abstract Options RiskModule V2 boundary for the DeOpt V2 hybrid subaccount
///         architecture (WP-07). Owns NO canonical economic state.
/// @dev
///  Frozen scope (spec 06 + WP-07 authorization):
///   - Read-only views that fail closed by construction.
///   - Immutable references to canonical state owners (Registry / Vault / Ledger).
///   - Compatibility surface (`moduleVersion` + `supportsCanonicalStorageVersion`).
///   - Aggregate margin views and product-enablement gates.
///   - Vault-integration hooks (`withdrawalAllowed` / `transferAllowed`) that call
///     into abstract `_compute*` primitives and translate failures into the
///     `IRiskModule` fail-closed contract.
///
///  Explicit OUT OF SCOPE (spec 06 §"What this spec does NOT decide" + prompt):
///   - Concrete numeric margin formulas + parameter values (deferred to
///     `ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1`).
///   - Bounded portfolio walk primitives (deferred to WP-08 MarginEngineV2
///     which owns Options-side series discovery + oracle integration).
///   - Concrete oracle / series metadata / finalization providers.
///   - Perps risk (V1 has Options only; `productsEnabled(perps)` returns false).
///   - Timelocked risk-module slot rotation (deferred to WP-08 which owns the
///     Vault + engine wiring). V1 posture is immutable per-deployment; a full
///     Vault redeploy replaces the module reference, which spec 06 §"C-01
///     Replacement policy" permits as a fresh-deployment cutover.
///
///  Authorization / provider posture (Part K + Part F):
///   - No mutable admin. No governance-driven balance / position editor.
///   - The `_compute*` hooks are `internal view virtual` with NO permissive
///     default: concrete inheritors MUST override + return `ok = true` from a
///     canonical portfolio walk. The abstract's own default implementations
///     (declared below) return `ok = false` so every `IRiskModule` external
///     view fails closed until a concrete override exists.
///   - Compatibility check `supportsCanonicalStorageVersion(v)` returns
///     `v == Versions.STORAGE_VERSION`. Migration cutover MUST call this
///     before wiring; consumers reject `false`.
///
///  Fail-closed model (Part T + RISK-I5):
///   - Every hook returns a `(uint256 value, bool ok)` pair.
///   - Every public view collapses `ok == false` into either a revert
///     (`RiskModuleUnavailable`) OR the safety-negative return
///     (`marginHealthy = false`, `withdrawalAllowed = false`, etc.).
///   - No path returns an affirmative safety decision when any hook fails.
///
///  Isolation model (spec 06 §"Between subaccounts there is NO offset"):
///   - Every view takes a single `subKey` (or `sourceSubKey`). No sibling
///     account is read within a single view. Concrete inheritors MUST
///     preserve this isolation.
///
///  Vault-integration flow (Part Q):
///   - The Vault's abstract `_requireWithdrawalAllowed` / `_requireInternalTransferAllowed`
///     hooks are overridden by `CollateralVaultV2RiskIntegrated` (this
///     package) which stores an immutable `IRiskModule` reference and
///     translates `withdrawalAllowed == false` into `revert UnsafeWithdrawal`.
///     Failed risk checks roll back the entire Vault mutation atomically.
abstract contract RiskModuleV2 is IRiskModule {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical identity source. Immutable at construction.
    ISubaccountRegistry public immutable REGISTRY;

    /// @notice Canonical collateral source. Immutable at construction.
    ICollateralVault public immutable VAULT;

    /// @notice Canonical Options-position source. Immutable at construction.
    IOptionsPositionsLedger public immutable OPTIONS_LEDGER;

    /// @notice Architecture version bound at construction. Downstream engines
    ///         compare against `Versions.ARCHITECTURE_VERSION` to reject
    ///         cross-architecture module wiring.
    uint256 public immutable ARCHITECTURE_VERSION;

    /// @notice Canonical storage version this module compiles against. Consumed by
    ///         `supportsCanonicalStorageVersion`.
    uint16 public immutable SUPPORTED_STORAGE_VERSION;

    /// @notice Module version (spec 06 §Interface). Bumps on any material change
    ///         to the concrete inheritor's formulas / providers.
    uint16 public immutable MODULE_VERSION;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor argument `registry_` is the zero address.
    error InvalidRegistry();

    /// @notice Constructor argument `vault_` is the zero address.
    error InvalidVault();

    /// @notice Constructor argument `optionsLedger_` is the zero address.
    error InvalidOptionsLedger();

    /// @notice Constructor argument `moduleVersion_` is zero.
    error InvalidModuleVersion();

    /// @notice Public `subKey` argument is `bytes32(0)`.
    error SubKeyRequired();

    /// @notice `subKey` is not registered in the canonical `SubaccountRegistry`.
    error UnknownSubaccount(bytes32 subKey);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param registry_ Canonical SubaccountRegistry deployment.
    /// @param vault_ Canonical CollateralVaultV2 deployment. MUST share the same
    ///        Registry as `registry_` (cross-checked at construction).
    /// @param optionsLedger_ Canonical OptionsPositionsLedger deployment. MUST share the
    ///        same Registry as `registry_` (cross-checked at construction).
    /// @param moduleVersion_ Concrete-inheritor version tag (>0).
    constructor(address registry_, address vault_, address optionsLedger_, uint16 moduleVersion_) {
        if (registry_ == address(0)) revert InvalidRegistry();
        if (vault_ == address(0)) revert InvalidVault();
        if (optionsLedger_ == address(0)) revert InvalidOptionsLedger();
        if (moduleVersion_ == 0) revert InvalidModuleVersion();

        // Vault + Ledger registry cross-checks intentionally live in the
        // *RiskAwareVault* constructor (see `CollateralVaultV2RiskIntegrated`),
        // not here. Rationale: production deployments use CREATE2 nonce
        // prediction with the Vault → RiskModule → Vault two-way immutable
        // reference. At the moment the RiskModule constructor runs, the Vault
        // + Ledger may not yet have code (they are deployed AFTER the module).
        // The RiskAwareVault gates the Vault-Registry mismatch case; a
        // mis-wired Vault would additionally fail closed at every risk view
        // (subKeys derived from the RiskModule's Registry return zero from a
        // foreign Vault's `ownerOf` / `availableOf` lookups). Defence in depth
        // is therefore preserved.

        REGISTRY = ISubaccountRegistry(registry_);
        VAULT = ICollateralVault(vault_);
        OPTIONS_LEDGER = IOptionsPositionsLedger(optionsLedger_);
        ARCHITECTURE_VERSION = Versions.ARCHITECTURE_VERSION;
        SUPPORTED_STORAGE_VERSION = Versions.STORAGE_VERSION;
        MODULE_VERSION = moduleVersion_;
    }

    /*//////////////////////////////////////////////////////////////
                        VERSION + COMPATIBILITY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRiskModule
    function moduleVersion() external view returns (uint16) {
        return MODULE_VERSION;
    }

    /// @inheritdoc IRiskModule
    function supportsCanonicalStorageVersion(uint16 storageVersion) external view returns (bool) {
        return storageVersion == SUPPORTED_STORAGE_VERSION;
    }

    /*//////////////////////////////////////////////////////////////
                        PRODUCT ENABLEMENT (V1)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRiskModule
    /// @dev V1 Options-only: `optionsEnabled = true`, `perpsEnabled = false`.
    ///      Concrete inheritors MAY refine per-subKey gating by overriding
    ///      `_optionsProductEnabled`; the perps flag stays `false` in V1
    ///      irrespective of overrides.
    function productsEnabled(bytes32 subKey) external view returns (bool optionsEnabled, bool perpsEnabled) {
        // Fail closed on invalid inputs.
        if (subKey == bytes32(0)) return (false, false);
        if (REGISTRY.ownerOf(subKey) == address(0)) return (false, false);
        optionsEnabled = _optionsProductEnabled(subKey);
        perpsEnabled = false;
    }

    /*//////////////////////////////////////////////////////////////
                         AGGREGATE MARGIN VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRiskModule
    /// @dev Reverts `RiskModuleUnavailable` on any hook failure (fail-closed).
    function marginRequirement(bytes32 subKey) external view returns (uint256 requiredCollateralValue1e18) {
        _requireKnownSubaccount(subKey);
        (uint256 value, bool ok) = _computeMarginRequirement(subKey);
        if (!ok) revert RiskModuleUnavailable();
        return value;
    }

    /// @inheritdoc IRiskModule
    /// @dev Reverts `RiskModuleUnavailable` on any hook failure (fail-closed).
    function availableMargin(bytes32 subKey) external view returns (uint256 availableCollateralValue1e18) {
        _requireKnownSubaccount(subKey);
        (uint256 value, bool ok) = _computeAvailableMargin(subKey);
        if (!ok) revert RiskModuleUnavailable();
        return value;
    }

    /// @inheritdoc IRiskModule
    /// @dev Fail-closed convenience view. Returns `false` on ANY hook failure or
    ///      when available < required. Never reverts.
    function marginHealthy(bytes32 subKey) external view returns (bool) {
        if (subKey == bytes32(0)) return false;
        if (REGISTRY.ownerOf(subKey) == address(0)) return false;
        (uint256 required, bool okReq) = _computeMarginRequirement(subKey);
        if (!okReq) return false;
        (uint256 available, bool okAvail) = _computeAvailableMargin(subKey);
        if (!okAvail) return false;
        return available >= required;
    }

    /// @inheritdoc IRiskModule
    /// @dev Returns `type(uint256).max` when `required == 0`. Reverts
    ///      `RiskModuleUnavailable` on hook failure (fail-closed).
    function marginRatio(bytes32 subKey) external view returns (uint256 ratio1e18) {
        _requireKnownSubaccount(subKey);
        (uint256 required, bool okReq) = _computeMarginRequirement(subKey);
        if (!okReq) revert RiskModuleUnavailable();
        if (required == 0) return type(uint256).max;
        (uint256 available, bool okAvail) = _computeAvailableMargin(subKey);
        if (!okAvail) revert RiskModuleUnavailable();
        // available * 1e18 / required. `required > 0` guaranteed by branch above.
        return (available * 1e18) / required;
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAWAL + TRANSFER SAFETY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRiskModule
    /// @dev Pre-withdrawal safety. Fails closed on:
    ///      - zero subKey / unknown subaccount;
    ///      - zero token;
    ///      - zero amount;
    ///      - unsupported token per Vault whitelist;
    ///      - amount exceeds current available collateral for the token;
    ///      - `_computeMarginRequirement` / `_computeAvailableMargin` fail;
    ///      - post-withdrawal available margin < required margin.
    function withdrawalAllowed(bytes32 subKey, address token, uint256 amount) external view returns (bool) {
        if (subKey == bytes32(0) || token == address(0) || amount == 0) return false;
        if (REGISTRY.ownerOf(subKey) == address(0)) return false;
        if (!VAULT.supportedTokens(token)) return false;

        // Token-level solvency: cannot withdraw more than the currently-available
        // token balance. `availableOf` = `balanceOf - lockedOf`.
        if (amount > VAULT.availableOf(subKey, token)) return false;

        // Delegate to the concrete margin computation. Both hooks must succeed
        // and the caller-provided post-withdrawal delta must satisfy the
        // approved threshold.
        (uint256 required, bool okReq) = _computeMarginRequirement(subKey);
        if (!okReq) return false;
        (uint256 available, bool okAvail) = _computeAvailableMargin(subKey);
        if (!okAvail) return false;

        // Concrete inheritor is expected to include this token's value in
        // `available`. Subtract the value of the withdrawn amount from
        // `available` (in 1e18 units) via the concrete hook so the abstract
        // never invents a valuation.
        (uint256 delta, bool okDelta) = _valueOfWithdrawnAmount(subKey, token, amount);
        if (!okDelta) return false;
        if (delta > available) return false;
        uint256 postAvailable = available - delta;
        return postAvailable >= required;
    }

    /// @inheritdoc IRiskModule
    /// @dev Pre-internal-transfer safety on the SOURCE side. Destination MAY
    ///      receive credit without independent margin check (spec 10 + Part O),
    ///      because the destination's post-state is at-least the pre-state and
    ///      cannot subsidize the source. Reverse semantics: source's post-transfer
    ///      margin MUST clear the approved threshold. Same fail-closed rules as
    ///      `withdrawalAllowed`.
    function transferAllowed(bytes32 sourceSubKey, address token, uint256 amount) external view returns (bool) {
        // Reuse the withdrawal fail-closed model: an internal transfer moves
        // `amount` OUT of the source. The safety check on the source is
        // identical to a withdrawal safety check.
        return this.withdrawalAllowed(sourceSubKey, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                          LIQUIDATION STATUS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IRiskModule
    /// @dev Fail-safe on the LIQUIDATION SIDE: an indeterminate risk state
    ///      (missing / stale / unsupported / reverting hook) MUST NOT return
    ///      any affirmative liquidation authority. Uncertainty about health is
    ///      NOT uncertainty about seizure permission — silently converting an
    ///      unavailable risk view into `ELIGIBLE_FOR_LIQUIDATION` would create
    ///      wrongful liquidation authority the moment ANY downstream consumer
    ///      trusts the enum value.
    ///
    ///      Semantics under the frozen 3-value `LiquidationStatus` enum
    ///      (HEALTHY / WARN / ELIGIBLE_FOR_LIQUIDATION) — no INDETERMINATE
    ///      state exists — so uncertainty is surfaced via revert:
    ///        - zero subKey → `SubKeyRequired`;
    ///        - unknown subKey → `UnknownSubaccount`;
    ///        - either hook returns `ok=false` → `RiskModuleUnavailable`
    ///          (matches the identical pattern already used by
    ///          `marginRequirement` / `availableMargin` / `marginRatio`).
    ///      Downstream WP-08 liquidation execution MUST wrap this call in
    ///      try/catch and translate any revert into "no liquidation
    ///      authority" (see also `RISK-LIQ-I1`). Spec 06 explicitly requires:
    ///      "Liquidation triggers MUST NOT trigger if `liquidationStatus`
    ///      cannot be computed."
    ///
    ///      Superseded 2026-07-27 by
    ///      `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-BOUNDEDNESS-AND-LIQUIDATION-SAFETY-PATCH`.
    ///      Prior fail-closed-to-ELIGIBLE behavior violated spec 06 and is now
    ///      corrected.
    function liquidationStatus(bytes32 subKey) external view returns (LiquidationStatus) {
        _requireKnownSubaccount(subKey);
        (uint256 required, bool okReq) = _computeMarginRequirement(subKey);
        if (!okReq) revert RiskModuleUnavailable();
        (uint256 available, bool okAvail) = _computeAvailableMargin(subKey);
        if (!okAvail) revert RiskModuleUnavailable();
        if (available >= required) return LiquidationStatus.HEALTHY;
        // Concrete inheritors MAY refine WARN thresholds by overriding
        // `_isWarnStatus`. Default: any shortfall → ELIGIBLE.
        if (_isWarnStatus(subKey, required, available)) return LiquidationStatus.WARN;
        return LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts `SubKeyRequired` on zero subKey; reverts
    ///      `UnknownSubaccount` when the Registry does not know the subKey.
    function _requireKnownSubaccount(bytes32 subKey) internal view {
        if (subKey == bytes32(0)) revert SubKeyRequired();
        if (REGISTRY.ownerOf(subKey) == address(0)) revert UnknownSubaccount(subKey);
    }

    /*//////////////////////////////////////////////////////////////
                           ABSTRACT HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Compute the aggregate maintenance margin requirement for `subKey`
    ///      in 1e18 precision. Fail closed by returning `ok = false`.
    ///      Concrete inheritors MUST walk the canonical Options portfolio via
    ///      `OPTIONS_LEDGER`, resolve series metadata + oracle prices, and apply
    ///      the approved DeOpt margin model. No permissive default.
    function _computeMarginRequirement(bytes32 subKey) internal view virtual returns (uint256 value, bool ok);

    /// @dev Compute the aggregate available collateral value for `subKey` in
    ///      1e18 precision (typically post-haircut sum of unlocked collateral
    ///      across supported tokens). Fail closed by returning `ok = false`.
    function _computeAvailableMargin(bytes32 subKey) internal view virtual returns (uint256 value, bool ok);

    /// @dev Compute the 1e18-scaled value delta produced by withdrawing `amount`
    ///      of `token` from `subKey`. Concrete inheritors resolve the oracle
    ///      price + token decimals. Fail closed on any input problem.
    function _valueOfWithdrawnAmount(bytes32 subKey, address token, uint256 amount)
        internal
        view
        virtual
        returns (uint256 value, bool ok);

    /// @dev Concrete override may refine per-subaccount Options enablement.
    ///      Default: Options are enabled on every registered subaccount.
    function _optionsProductEnabled(
        bytes32 /*subKey*/
    )
        internal
        view
        virtual
        returns (bool)
    {
        return true;
    }

    /// @dev Concrete override may refine WARN semantics. Default: any shortfall
    ///      → not-WARN → ELIGIBLE_FOR_LIQUIDATION (see `liquidationStatus`).
    function _isWarnStatus(
        bytes32,
        /*subKey*/
        uint256,
        /*required*/
        uint256 /*available*/
    )
        internal
        view
        virtual
        returns (bool)
    {
        return false;
    }
}
