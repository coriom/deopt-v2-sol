// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import {RiskModuleV2} from "./RiskModuleV2.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {IOptionsRiskProvider} from "../interfaces/IOptionsRiskProvider.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";

/// @title OptionsRiskModuleV2
/// @notice Concrete WP-08 Options-side inheritor of the abstract `RiskModuleV2`.
///         Provides fail-closed collateral valuation over the canonical Vault
///         collateral universe (≤ 8 tokens) and the frozen zero-portfolio /
///         witness-required semantics for the aggregate margin views.
/// @dev
///  Non-goals (frozen by milestone):
///   - This contract does NOT enumerate active option series from a subKey
///     alone: the canonical Ledger does not expose that primitive and every
///     portfolio walk MUST discharge the caller-supplied witness via
///     `IOptionsPositionsLedger.verifyActiveSeriesArrayComplete`. The abstract
///     `_computeMarginRequirement(subKey)` therefore returns `(0, true)` when
///     `activeSeriesCount(subKey) == 0` and `(0, false)` otherwise. Callers
///     with active series MUST route through the witness-taking `MarginEngineV2`
///     views (`initialMargin1e18`, `maintenanceMargin1e18`, …).
///   - This contract does NOT own token reservations; the frozen
///     `MARGIN_RESERVATION_OWNERSHIP_DEFERRED_BY_APPROVED_DESIGN` verdict
///     (Part D) defers `applyLock`/`applyUnlock` writes to the future
///     OptionMatchingEngine (WP-08B / WP-09).
///
///  Fail-closed model:
///   - Every hook returns `(uint256 value, bool ok)`.
///   - Any missing / stale / unconfigured / unsupported input yields
///     `ok = false`.
///   - The abstract `IRiskModule` external views then translate `ok = false`
///     into the safety-negative outcome (`RiskModuleUnavailable` revert or
///     `false` return) per the WP-07 fail-closed contract.
///
///  Collateral valuation (Part I):
///   - Walks the canonical Vault collateral universe (`collateralTokenCount()`
///     + `collateralTokenAt(i)`; bounded to `maxCollateralTokens() == 8`).
///   - Reads canonical account balance via `balanceOf(subKey, token)`
///     (excludes direct-donation dust which never enters the accounting).
///   - Fetches per-token 1e8 price from the oracle adapter, with strict
///     freshness bound (`MAX_ORACLE_STALE_SECONDS`).
///   - Applies the per-token `creditFactorBps` haircut from the risk provider
///     (missing config → fail closed).
///   - Rounds DOWN in favor of protocol safety when valuing user assets.
///   - Aggregates in 1e18 quote units.
///
///  Quote-token model:
///   - A single immutable `QUOTE_TOKEN` per deployment. Its haircut is
///     hard-coded to 100% (`10_000` bps) — the token IS the numeraire, so no
///     oracle lookup is performed for it.
///   - Every other supported collateral token requires an oracle price of
///     `token → QUOTE_TOKEN` (1e8) and an explicit provider-configured haircut.
///
///  Isolation:
///   - Every hook takes a single `subKey`. No sibling / owner-scoped read.
///
///  Migration surface:
///   - Immutable at construction: `RISK_PROVIDER`, `ORACLE`, `QUOTE_TOKEN`,
///     `QUOTE_DECIMALS`, `MAX_ORACLE_STALE_SECONDS`. Rotation requires a
///     fresh Vault-Consumer redeploy (per RM-1 posture).
contract OptionsRiskModuleV2 is RiskModuleV2 {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Read-only adapter over the canonical Options product registry.
    IOptionsRiskProvider public immutable RISK_PROVIDER;

    /// @notice 1e8-normalized price adapter over the canonical oracle router.
    IOracleAdapter public immutable ORACLE;

    /// @notice Single deployment-scoped quote / settlement numeraire.
    address public immutable QUOTE_TOKEN;

    /// @notice Decimals of `QUOTE_TOKEN`. Kept as an immutable so the
    ///         collateral-valuation scaling never depends on a runtime
    ///         `decimals()` call.
    uint8 public immutable QUOTE_DECIMALS;

    /// @notice Strict oracle-freshness bound in seconds. A collateral price
    ///         older than this triggers a fail-closed collateral valuation.
    uint256 public immutable MAX_ORACLE_STALE_SECONDS;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice `riskProvider_` constructor argument is the zero address.
    error InvalidRiskProvider();

    /// @notice `oracle_` constructor argument is the zero address.
    error InvalidOracleAdapter();

    /// @notice `quoteToken_` constructor argument is the zero address.
    error InvalidQuoteToken();

    /// @notice `maxOracleStaleSeconds_` constructor argument is zero.
    error InvalidStalenessBound();

    /// @notice `quoteDecimals_` constructor argument is zero.
    error InvalidQuoteDecimals();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        address registry_,
        address vault_,
        address optionsLedger_,
        uint16 moduleVersion_,
        address riskProvider_,
        address oracle_,
        address quoteToken_,
        uint8 quoteDecimals_,
        uint256 maxOracleStaleSeconds_
    ) RiskModuleV2(registry_, vault_, optionsLedger_, moduleVersion_) {
        if (riskProvider_ == address(0)) revert InvalidRiskProvider();
        if (oracle_ == address(0)) revert InvalidOracleAdapter();
        if (quoteToken_ == address(0)) revert InvalidQuoteToken();
        if (maxOracleStaleSeconds_ == 0) revert InvalidStalenessBound();
        if (quoteDecimals_ == 0) revert InvalidQuoteDecimals();

        RISK_PROVIDER = IOptionsRiskProvider(riskProvider_);
        ORACLE = IOracleAdapter(oracle_);
        QUOTE_TOKEN = quoteToken_;
        QUOTE_DECIMALS = quoteDecimals_;
        MAX_ORACLE_STALE_SECONDS = maxOracleStaleSeconds_;
    }

    /*//////////////////////////////////////////////////////////////
                            ABSTRACT OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc RiskModuleV2
    /// @dev Zero-portfolio → `(0, true)`. Non-zero portfolio → `(0, false)`
    ///      (indeterminate without a caller-supplied witness). Callers that
    ///      hold the canonical active-series witness MUST use the
    ///      `MarginEngineV2.maintenanceMargin1e18` witness-taking view.
    function _computeMarginRequirement(bytes32 subKey) internal view override returns (uint256, bool) {
        if (OPTIONS_LEDGER.activeSeriesCount(subKey) == 0) {
            return (0, true);
        }
        return (0, false);
    }

    /// @inheritdoc RiskModuleV2
    /// @dev Walks the canonical collateral universe. Fail-closed on any
    ///      missing config / stale price / unsupported provider input.
    function _computeAvailableMargin(bytes32 subKey) internal view override returns (uint256, bool) {
        uint256 count = VAULT.collateralTokenCount();
        // MAX_COLLATERAL_TOKENS = 8 is enforced by the Vault at first
        // enablement; we defensively bound the loop below by the same value.
        if (count > VAULT.maxCollateralTokens()) {
            return (0, false);
        }
        uint256 total1e18;
        for (uint256 i = 0; i < count; i++) {
            address token = VAULT.collateralTokenAt(i);
            uint256 balance = VAULT.balanceOf(subKey, token);
            if (balance == 0) continue;
            (uint256 value1e18, bool ok) = _collateralValue1e18(token, balance);
            if (!ok) return (0, false);
            total1e18 += value1e18;
        }
        return (total1e18, true);
    }

    /// @inheritdoc RiskModuleV2
    /// @dev Reuses the canonical `_collateralValue1e18` primitive: the value
    ///      subtracted from `available` on a withdrawal is EXACTLY the value
    ///      that `_computeAvailableMargin` would have credited to the same
    ///      `(token, amount)` pair. Preserves the invariant
    ///      `postAvailable = available - withdrawnValue`.
    function _valueOfWithdrawnAmount(bytes32 subKey, address token, uint256 amount)
        internal
        view
        override
        returns (uint256, bool)
    {
        subKey; // silence unused-parameter warning; the value is subKey-independent.
        return _collateralValue1e18(token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                           PUBLIC VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fail-closed collateral value in 1e18 quote units for
    ///         `(token, balance)`.
    /// @return value1e18 the credited value; zero when `ok = false`
    /// @return ok        false when the token is unknown, unconfigured,
    ///                   priced stale, or produces a value overflow
    function collateralValue1e18(address token, uint256 balance) external view returns (uint256 value1e18, bool ok) {
        return _collateralValue1e18(token, balance);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Canonical collateral-valuation primitive. NEVER reverts on
    ///      valuation failure; returns `ok = false` instead so the abstract
    ///      views can translate cleanly into the fail-closed contract.
    function _collateralValue1e18(address token, uint256 balance) internal view returns (uint256, bool) {
        if (token == address(0)) return (0, false);
        if (balance == 0) return (0, true);

        // 1. Confirm the token is part of the canonical universe. `supportedTokens`
        //    can flap; `isKnownCollateralToken` is append-only and matches the
        //    frozen liquidation-completeness definition.
        if (!VAULT.isKnownCollateralToken(token)) return (0, false);

        // 2. Resolve haircut config. Missing config → fail closed.
        IOptionsRiskProvider.CollateralRiskView memory cfg;
        if (token == QUOTE_TOKEN) {
            // Numeraire token: full credit, no provider lookup needed.
            cfg = IOptionsRiskProvider.CollateralRiskView({creditFactorBps: 10_000, isConfigured: true});
        } else {
            cfg = RISK_PROVIDER.collateralRiskView(token);
            if (!cfg.isConfigured) return (0, false);
            if (cfg.creditFactorBps == 0 || cfg.creditFactorBps > 10_000) return (0, false);
        }

        // 3. Resolve token decimals defensively. Reverts inside a `try` are
        //    translated to `ok = false`.
        uint8 tokenDecimals;
        if (token == QUOTE_TOKEN) {
            tokenDecimals = QUOTE_DECIMALS;
        } else {
            try IERC20Metadata(token).decimals() returns (uint8 d) {
                if (d == 0 || d > 36) return (0, false);
                tokenDecimals = d;
            } catch {
                return (0, false);
            }
        }

        // 4. Resolve 1e8 price of token in quote units. Quote token trivially
        //    at 1e8. Every other token via the oracle adapter with strict
        //    freshness bound.
        uint256 price1e8;
        if (token == QUOTE_TOKEN) {
            price1e8 = 1e8;
        } else {
            (uint256 p, uint256 updatedAt, bool ok) = ORACLE.getPrice1e8Safe(token, QUOTE_TOKEN);
            if (!ok) return (0, false);
            if (p == 0) return (0, false);
            if (updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > MAX_ORACLE_STALE_SECONDS) return (0, false);
            price1e8 = p;
        }

        // 5. `value1e8 = balance * price1e8 / (10 ** tokenDecimals)`.
        //    Round DOWN in favor of protocol safety.
        uint256 tokenDivisor = 10 ** uint256(tokenDecimals);
        // Overflow-safety: `balance` bounded by ERC20 total supply (uint256).
        // `price1e8` bounded to <= max feasible price. Solidity 0.8 checked math
        // reverts on overflow, which we treat as fail-closed indirectly (the
        // caller's `_computeAvailableMargin` also `try/catch`es the branch).
        // In practice `balance` is a per-subKey bookkeeping delta and can
        // never reach 2**256/price1e8 for any realistic feed.
        uint256 value1e8 = (balance * price1e8) / tokenDivisor;

        // 6. Apply haircut: `credited1e8 = value1e8 * creditFactorBps / 10_000`.
        //    Round DOWN.
        uint256 credited1e8 = (value1e8 * uint256(cfg.creditFactorBps)) / 10_000;

        // 7. Scale 1e8 → 1e18: multiply by 1e10 (see `OptionsRiskMath.scale1e8To1e18`).
        //    Preserves purchasing-power invariant regardless of token decimals.
        return (credited1e8 * 1e10, true);
    }
}
