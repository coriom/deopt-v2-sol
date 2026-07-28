// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IOptionsRiskProvider
/// @notice Read-only adapter surface consumed by `OptionsRiskModuleV2` to obtain
///         the frozen Options-risk metadata + parameters needed by the concrete
///         portfolio walk (WP-08).
/// @dev
///  This interface is intentionally minimal: it exposes only the read-only
///  primitives the risk module actually needs, and hides everything else
///  (governance / creation / settlement-lifecycle admin) that lives on the
///  underlying product registry.
///
///  Ownership + separation:
///   - The concrete adapter implementation is a THIN wrapper around whatever
///     canonical product-registry deployment governs series metadata on the
///     target chain. In production the underlying source MUST be a
///     timelock-gated registry (see `contract-spec/06_RISK_MARGIN_MODULE_SPEC.md`
///     §"Concrete risk parameter values (deferred to
///     `ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1`)"). WP-08 does NOT decide
///     which concrete registry is chosen; it only decides that the adapter
///     surface is bounded.
///   - Because the adapter is a THIN read-only view, changing the underlying
///     product-registry deployment requires either (a) redeploying the
///     `OptionsRiskModuleV2` with a new adapter address, which per RM-1 forces
///     a fresh Vault+Consumer cutover, or (b) implementing an adapter that
///     internally routes across multiple registries. Both paths keep the
///     RiskModule's own storage untouched.
///
///  Fail-closed contract:
///   - Every function MUST fail closed on missing / stale / invalid data:
///     either revert OR return `ok = false`.
///   - Callers (`OptionsRiskModuleV2`) MUST treat any reverted call as
///     `ok = false` (via low-level `staticcall`) so a mis-configured adapter
///     cannot authorize an unsafe risk decision.
///
///  Units (frozen):
///   - `strike1e8` — price scale is 1e8 (Chainlink 8-decimals convention).
///   - `contractSize1e8 = 1e8` — LOCKED: 1 contract = 1 underlying unit.
///     Adapters MUST enforce this at series-registration time; the risk
///     module additionally asserts it defensively on every read.
///   - Every basis-points field uses `bps = 10_000` = 100%.
///   - `baseMaintenanceMarginPerContract` is denominated in the protocol
///     central quote numeraire, in NATIVE units of that numeraire (e.g. USDC
///     6-decimals, NOT 1e18-normalized). Callers convert to 1e18 using the
///     quote-token decimals resolved through `IERC20Metadata`.
///
///  Non-goals:
///   - NO settlement-price oracle: settlement finalization is queried through
///     `settlementPriceOf` (returns `(price1e8, isFinalized)`); live oracle
///     price feeds live behind a separate `IOracleAdapter` interface.
///   - NO series creation / configuration surface — that stays entirely on the
///     underlying registry.
///   - NO position mutation, NO reservation mutation, NO fee/premium routing.
interface IOptionsRiskProvider {
    /// @notice Minimal metadata needed by the risk module to price + margin a
    ///         single option series. Fields are copied out of the underlying
    ///         registry to keep this ABI stable across upgrades.
    struct SeriesRiskView {
        address underlying;
        address settlementAsset;
        uint64 expiry;
        uint64 strike1e8;
        uint128 contractSize1e8;
        bool isCall;
        bool isActive;
        bool exists;
    }

    /// @notice Minimal per-underlying stress parameters used by `stressedLiability`.
    ///         Field semantics match `OptionProductRegistry.UnderlyingConfig`.
    struct UnderlyingRiskView {
        uint64 spotShockDownBps;
        uint64 spotShockUpBps;
        uint64 volShockDownBps;
        uint64 volShockUpBps;
        bool isEnabled;
    }

    /// @notice Minimal per-underlying option risk config used by `mmPerContract`.
    ///         Field semantics match `OptionProductRegistry.OptionRiskConfig`.
    struct OptionsRiskConfigView {
        uint128 baseMaintenanceMarginPerContract;
        uint32 imFactorBps;
        uint32 oracleDownMmMultiplierBps;
        bool isConfigured;
    }

    /// @notice Minimal per-collateral-token credit-factor config used by
    ///         `_computeAvailableMargin`. `creditFactorBps` = 10_000 → full
    ///         credit; smaller values apply a proportional haircut.
    /// @dev
    ///  V1 policy (frozen):
    ///   - Quote token: `creditFactorBps = 10_000` (self-numeraire).
    ///   - Every non-quote token MUST have an explicit configured entry —
    ///     absence returns `isConfigured = false` which fails the risk view
    ///     closed. This prevents an oversight from silently over-crediting
    ///     unconfigured tokens at oracle price.
    ///   - `creditFactorBps` upper bound is 10_000 (never over-credit).
    struct CollateralRiskView {
        uint16 creditFactorBps;
        bool isConfigured;
    }

    /// @notice Fetch series metadata for `seriesId`. Returns `exists = false` on
    ///         unknown series without reverting.
    function seriesRiskView(uint256 seriesId) external view returns (SeriesRiskView memory);

    /// @notice Fetch per-underlying stress params. Returns `isEnabled = false`
    ///         on unknown / disabled underlying without reverting.
    function underlyingRiskView(address underlying) external view returns (UnderlyingRiskView memory);

    /// @notice Fetch per-underlying option risk config. Returns
    ///         `isConfigured = false` on missing config without reverting.
    function optionsRiskConfigView(address underlying) external view returns (OptionsRiskConfigView memory);

    /// @notice Fetch canonical settlement price for a series. `isFinalized = false`
    ///         when the series is not yet finalized (still uses live oracle path).
    ///         `price1e8` MUST be zero when `isFinalized = false`.
    function settlementPriceOf(uint256 seriesId) external view returns (uint256 price1e8, bool isFinalized);

    /// @notice Fetch per-collateral-token credit-factor config.
    function collateralRiskView(address token) external view returns (CollateralRiskView memory);
}
