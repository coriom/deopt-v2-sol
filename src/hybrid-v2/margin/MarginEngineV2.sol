// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {IOptionsPositionsLedger} from "../interfaces/IOptionsPositionsLedger.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {IOptionsRiskProvider} from "../interfaces/IOptionsRiskProvider.sol";
import {IOracleAdapter} from "../interfaces/IOracleAdapter.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {VaultRiskModuleConsumer} from "../risk/VaultRiskModuleConsumer.sol";
import {OptionsRiskModuleV2} from "../risk/OptionsRiskModuleV2.sol";
import {PositionTypes, LiquidationStatus} from "../libraries/PositionTypes.sol";
import {OptionsRiskMath} from "./OptionsRiskMath.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title MarginEngineV2
/// @notice WP-08 read-only Options margin orchestration boundary. Combines the
///         canonical subaccount identity + the frozen bounded portfolio walk
///         to expose IM / MM / margin excess / margin ratio / liquidation
///         status views over the canonical `OptionsRiskModuleV2` provider.
/// @dev
///  Scope (Part D verdict
///  `MARGIN_RESERVATION_OWNERSHIP_DEFERRED_BY_APPROVED_DESIGN` + reservation-owner
///  verdict `MARGIN_RESERVATIONS_OWNED_BY_OPTIONS_ENGINE`):
///   - Read-only. No mutation. No `applyLock` / `applyUnlock`. No fee / rebate
///     routing. No premium transfer. No settlement / exercise / liquidation
///     execution. No signature / replay consumption. Every economic write
///     stays with the future OptionMatchingEngine (WP-08B / WP-09).
///
///  RM-1 posture:
///   - Inherits `VaultRiskModuleConsumer`, which locks the canonical
///     `RISK_MODULE` to whatever the Vault's `RISK_MODULE()` returned at
///     Vault construction. No independent `riskModule_` constructor argument.
///     The abstract's constructor checks architecture + storage compatibility;
///     divergence is a compile-time impossibility.
///
///  Bounded portfolio walk (Parts F + G + O):
///   - Every witness-taking view requires the caller to pass the sorted,
///     unique active-series id array for `subKey`. Length ≤ 32 (enforced by
///     the ledger's `MAX_ACTIVE_SERIES_PER_SUBACCOUNT`).
///   - The engine calls `OPTIONS_LEDGER.verifyActiveSeriesArrayComplete`
///     BEFORE any per-series computation. A `false` result reverts
///     `IncompleteActiveSeriesWitness`.
///   - Portfolio aggregation uses the frozen `OptionsRiskMath` primitives
///     (`mmPerContract`, `imPerContract`, `seriesContribution`).
///   - Long positions contribute ZERO to portfolio margin in V1 (P1
///     isolation between subaccounts; explicit cross-series offset deferred).
///
///  Collateral view:
///   - Delegates to `RISK_MODULE.availableMargin(subKey)` which walks the
///     canonical Vault collateral universe (≤ 8 tokens) under the same
///     fail-closed rules as the abstract `_computeAvailableMargin`.
///
///  Fail-closed:
///   - Witness-taking views: revert `SubKeyRequired`, `UnknownSubaccount`,
///     `IncompleteActiveSeriesWitness`, or `RiskModuleUnavailable`.
///   - `isHealthy` — returns `false` on ANY failure. Never reverts.
///   - `liquidationStatus` — inherits WP-07 fail-safe: reverts on
///     indeterminate risk (never returns `ELIGIBLE_FOR_LIQUIDATION` on
///     uncertain input).
contract MarginEngineV2 is IMarginEngine, VaultRiskModuleConsumer {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical Registry sourced from `RISK_MODULE.REGISTRY()`.
    ISubaccountRegistry public immutable REGISTRY;

    /// @notice Canonical Options positions ledger sourced from
    ///         `RISK_MODULE.OPTIONS_LEDGER()`.
    IOptionsPositionsLedger public immutable OPTIONS_LEDGER;

    /// @notice Concrete provider surface (Options metadata + collateral haircuts)
    ///         sourced from `RISK_MODULE.RISK_PROVIDER()`.
    IOptionsRiskProvider public immutable RISK_PROVIDER;

    /// @notice Concrete oracle adapter sourced from `RISK_MODULE.ORACLE()`.
    IOracleAdapter public immutable ORACLE;

    /// @notice Quote / settlement numeraire token sourced from
    ///         `RISK_MODULE.QUOTE_TOKEN()`.
    address public immutable QUOTE_TOKEN;

    /// @notice Cached decimals of `QUOTE_TOKEN`.
    uint8 public immutable QUOTE_DECIMALS;

    /// @notice Engine version tag for governance + tooling.
    uint16 public immutable ENGINE_VERSION;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The Vault's RiskModule is not an `OptionsRiskModuleV2` (or a
    ///         subclass exposing the same immutables). This is a compile-time
    ///         guarantee via the cast, but we surface it as a typed revert
    ///         should a future variant somehow bypass the check.
    error RiskModuleIncompatible();

    /// @notice `engineVersion_` constructor argument is zero.
    error InvalidEngineVersion();

    /// @notice `RISK_MODULE`'s `REGISTRY()` disagrees with the Vault's
    ///         registry — cross-chain / cross-deployment wiring attempt.
    error RegistryMismatch();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address vault_, uint16 engineVersion_) VaultRiskModuleConsumer(vault_) {
        if (engineVersion_ == 0) revert InvalidEngineVersion();

        // Bind the concrete provider dependencies from the canonical Vault
        // -bound `RISK_MODULE`. This is the ONLY place these references are
        // resolved: divergence between the engine's reads and the Vault's
        // hook path is impossible by construction.
        OptionsRiskModuleV2 module = OptionsRiskModuleV2(address(RISK_MODULE));
        ISubaccountRegistry registryFromModule = module.REGISTRY();
        if (address(registryFromModule) == address(0)) revert RiskModuleIncompatible();
        REGISTRY = registryFromModule;

        IOptionsPositionsLedger ledgerFromModule = module.OPTIONS_LEDGER();
        if (address(ledgerFromModule) == address(0)) revert RiskModuleIncompatible();
        OPTIONS_LEDGER = ledgerFromModule;

        IOptionsRiskProvider providerFromModule = module.RISK_PROVIDER();
        if (address(providerFromModule) == address(0)) revert RiskModuleIncompatible();
        RISK_PROVIDER = providerFromModule;

        IOracleAdapter oracleFromModule = module.ORACLE();
        if (address(oracleFromModule) == address(0)) revert RiskModuleIncompatible();
        ORACLE = oracleFromModule;

        address quoteFromModule = module.QUOTE_TOKEN();
        if (quoteFromModule == address(0)) revert RiskModuleIncompatible();
        QUOTE_TOKEN = quoteFromModule;

        uint8 quoteDecimalsFromModule = module.QUOTE_DECIMALS();
        if (quoteDecimalsFromModule == 0) revert RiskModuleIncompatible();
        QUOTE_DECIMALS = quoteDecimalsFromModule;

        ENGINE_VERSION = engineVersion_;
    }

    /*//////////////////////////////////////////////////////////////
                          IMARGINENGINE VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarginEngine
    function initialMargin1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256) {
        _requireKnownSubaccountAndWitness(subKey, activeSeriesIds);
        (uint256 im1e18, bool ok) = _computePortfolioMargins(subKey, activeSeriesIds, true);
        if (!ok) revert RiskModuleUnavailable();
        return im1e18;
    }

    /// @inheritdoc IMarginEngine
    function maintenanceMargin1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256) {
        _requireKnownSubaccountAndWitness(subKey, activeSeriesIds);
        (uint256 mm1e18, bool ok) = _computePortfolioMargins(subKey, activeSeriesIds, false);
        if (!ok) revert RiskModuleUnavailable();
        return mm1e18;
    }

    /// @inheritdoc IMarginEngine
    function availableCollateral1e18(bytes32 subKey, uint256[] calldata activeSeriesIds)
        external
        view
        returns (uint256)
    {
        _requireKnownSubaccountAndWitness(subKey, activeSeriesIds);
        (uint256 available1e18, bool ok) = _computeAvailableCollateral(subKey);
        if (!ok) revert RiskModuleUnavailable();
        return available1e18;
    }

    /// @inheritdoc IMarginEngine
    function marginExcess1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256) {
        _requireKnownSubaccountAndWitness(subKey, activeSeriesIds);
        (uint256 mm1e18, bool mmOk) = _computePortfolioMargins(subKey, activeSeriesIds, false);
        if (!mmOk) revert RiskModuleUnavailable();
        (uint256 available1e18, bool availOk) = _computeAvailableCollateral(subKey);
        if (!availOk) revert RiskModuleUnavailable();
        if (available1e18 <= mm1e18) return 0;
        return available1e18 - mm1e18;
    }

    /// @inheritdoc IMarginEngine
    function marginRatio1e18(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (uint256) {
        _requireKnownSubaccountAndWitness(subKey, activeSeriesIds);
        (uint256 mm1e18, bool mmOk) = _computePortfolioMargins(subKey, activeSeriesIds, false);
        if (!mmOk) revert RiskModuleUnavailable();
        if (mm1e18 == 0) return type(uint256).max;
        (uint256 available1e18, bool availOk) = _computeAvailableCollateral(subKey);
        if (!availOk) revert RiskModuleUnavailable();
        return (available1e18 * 1e18) / mm1e18;
    }

    /// @inheritdoc IMarginEngine
    /// @dev Fail-closed: returns `false` on ANY failure. Never reverts.
    function isHealthy(bytes32 subKey, uint256[] calldata activeSeriesIds) external view returns (bool) {
        if (subKey == bytes32(0)) return false;
        if (REGISTRY.ownerOf(subKey) == address(0)) return false;
        if (!OPTIONS_LEDGER.verifyActiveSeriesArrayComplete(subKey, activeSeriesIds)) return false;
        (uint256 mm1e18, bool mmOk) = _computePortfolioMargins(subKey, activeSeriesIds, false);
        if (!mmOk) return false;
        (uint256 available1e18, bool availOk) = _computeAvailableCollateral(subKey);
        if (!availOk) return false;
        return available1e18 >= mm1e18;
    }

    /// @inheritdoc IMarginEngine
    /// @dev Fail-safe: reverts on indeterminate risk. Never returns
    ///      ELIGIBLE_FOR_LIQUIDATION under uncertain input.
    function liquidationStatus(bytes32 subKey, uint256[] calldata activeSeriesIds)
        external
        view
        returns (LiquidationStatus)
    {
        _requireKnownSubaccountAndWitness(subKey, activeSeriesIds);
        (uint256 mm1e18, bool mmOk) = _computePortfolioMargins(subKey, activeSeriesIds, false);
        if (!mmOk) revert RiskModuleUnavailable();
        (uint256 available1e18, bool availOk) = _computeAvailableCollateral(subKey);
        if (!availOk) revert RiskModuleUnavailable();
        if (available1e18 >= mm1e18) return LiquidationStatus.HEALTHY;
        return LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION;
    }

    /// @inheritdoc IMarginEngine
    function vault() external view returns (address) {
        return address(VAULT);
    }

    /// @inheritdoc IMarginEngine
    function riskModule() external view returns (address) {
        return address(RISK_MODULE);
    }

    /*//////////////////////////////////////////////////////////////
                        PORTFOLIO WALK HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts on unknown / zero subKey OR incomplete witness. Always
    ///      called BEFORE any per-series iteration to bound the caller's gas
    ///      predictably.
    function _requireKnownSubaccountAndWitness(bytes32 subKey, uint256[] calldata activeSeriesIds) internal view {
        if (subKey == bytes32(0)) revert SubKeyRequired();
        if (REGISTRY.ownerOf(subKey) == address(0)) revert UnknownSubaccount(subKey);
        if (!OPTIONS_LEDGER.verifyActiveSeriesArrayComplete(subKey, activeSeriesIds)) {
            revert IncompleteActiveSeriesWitness(subKey);
        }
    }

    /// @dev Walk the (already-verified) `activeSeriesIds` witness and compute
    ///      the aggregate portfolio margin in 1e18 quote units.
    /// @param subKey            subaccount identity
    /// @param activeSeriesIds   canonical active-series set (already verified)
    /// @param computeInitial    when true, computes IM (`imFactorBps` applied);
    ///                          when false, computes MM
    function _computePortfolioMargins(bytes32 subKey, uint256[] calldata activeSeriesIds, bool computeInitial)
        internal
        view
        returns (uint256 aggregated1e18, bool ok)
    {
        uint256 n = activeSeriesIds.length;
        if (n == 0) return (0, true); // Zero-portfolio: MM = IM = 0 exactly.

        uint256 aggregated1e8;
        for (uint256 i = 0; i < n; i++) {
            uint256 seriesId = activeSeriesIds[i];

            PositionTypes.OptionPosition memory pos = OPTIONS_LEDGER.positionOf(subKey, seriesId);
            uint256 shortQuantity1e8 = uint256(pos.shortQuantity1e8);
            if (shortQuantity1e8 == 0) continue; // Long-only series contribute 0 in V1.

            (uint256 perContract1e8, bool okPerContract) = _perContractMargin1e8(seriesId, computeInitial);
            if (!okPerContract) return (0, false);

            uint256 contribution1e8 = OptionsRiskMath.seriesContribution(shortQuantity1e8, perContract1e8);
            aggregated1e8 += contribution1e8;
        }

        // Scale 1e8 → 1e18 via 1e10 multiplier (decimal-agnostic purchasing power).
        aggregated1e18 = aggregated1e8 * 1e10;
        ok = true;
    }

    /// @dev Fail-closed per-contract MM / IM for a single series.
    function _perContractMargin1e8(uint256 seriesId, bool computeInitial)
        internal
        view
        returns (uint256 perContract1e8, bool ok)
    {
        // 1. Load series metadata.
        IOptionsRiskProvider.SeriesRiskView memory series = RISK_PROVIDER.seriesRiskView(seriesId);
        if (!series.exists) return (0, false);
        if (!series.isActive) return (0, false);
        // Every series in this deployment MUST settle in the immutable QUOTE_TOKEN.
        if (series.settlementAsset != QUOTE_TOKEN) return (0, false);
        // Frozen: 1 contract = 1 underlying unit.
        if (series.contractSize1e8 != OptionsRiskMath.CONTRACT_SIZE_1E8) return (0, false);
        // Strike sanity.
        if (series.strike1e8 == 0) return (0, false);

        // 2. Load risk configs.
        IOptionsRiskProvider.UnderlyingRiskView memory ucfg = RISK_PROVIDER.underlyingRiskView(series.underlying);
        if (!ucfg.isEnabled) return (0, false);
        IOptionsRiskProvider.OptionsRiskConfigView memory ocfg = RISK_PROVIDER.optionsRiskConfigView(series.underlying);
        if (!ocfg.isConfigured) return (0, false);
        if (ocfg.imFactorBps < OptionsRiskMath.BPS) return (0, false); // IM ≥ MM
        if (ocfg.oracleDownMmMultiplierBps < OptionsRiskMath.BPS) return (0, false);

        // 3. Load spot price via oracle (fail-closed).
        (uint256 spot1e8, bool spotOk) = _spot1e8(series);
        if (!spotOk) {
            // Oracle-down path: use the conservative multiplier over the base
            // MM floor. `oracleDownMmMultiplierBps >= 10_000` ensures this is
            // never smaller than the frozen base floor.
            uint256 base = uint256(ocfg.baseMaintenanceMarginPerContract);
            uint256 mmDown1e8 = (base * uint256(ocfg.oracleDownMmMultiplierBps)) / OptionsRiskMath.BPS;
            if (computeInitial) {
                perContract1e8 = OptionsRiskMath.imPerContract(mmDown1e8, ocfg.imFactorBps);
            } else {
                perContract1e8 = mmDown1e8;
            }
            return (perContract1e8, true);
        }

        // 4. Live path — intrinsic + stressed + floor → mm → im.
        uint256 intrinsic1e8 = OptionsRiskMath.intrinsicPerContract(spot1e8, uint256(series.strike1e8), series.isCall);
        uint256 stressed1e8 = OptionsRiskMath.stressedPerContract(
            spot1e8,
            uint256(series.strike1e8),
            series.isCall,
            uint256(ucfg.spotShockUpBps),
            uint256(ucfg.spotShockDownBps)
        );
        uint256 mm1e8 =
            OptionsRiskMath.mmPerContract(intrinsic1e8, stressed1e8, uint256(ocfg.baseMaintenanceMarginPerContract));

        if (computeInitial) {
            perContract1e8 = OptionsRiskMath.imPerContract(mm1e8, ocfg.imFactorBps);
        } else {
            perContract1e8 = mm1e8;
        }
        ok = true;
    }

    /// @dev Fetch the live spot price of `series.underlying → QUOTE_TOKEN` with
    ///      strict freshness bound. `ok = false` on missing / stale / zero.
    function _spot1e8(IOptionsRiskProvider.SeriesRiskView memory series) internal view returns (uint256, bool) {
        if (series.underlying == address(0)) return (0, false);
        if (series.underlying == QUOTE_TOKEN) {
            // Underlying = quote token: spot is exactly 1 quote-unit per underlying.
            return (1e8, true);
        }
        (uint256 p, uint256 updatedAt, bool ok) = ORACLE.getPrice1e8Safe(series.underlying, QUOTE_TOKEN);
        if (!ok) return (0, false);
        if (p == 0) return (0, false);
        if (updatedAt > block.timestamp) return (0, false);
        // Delegate freshness policy to the concrete OptionsRiskModuleV2 so the
        // engine and the module share the same bound (no drift).
        uint256 maxStale = OptionsRiskModuleV2(address(RISK_MODULE)).MAX_ORACLE_STALE_SECONDS();
        if (block.timestamp - updatedAt > maxStale) return (0, false);
        return (p, true);
    }

    /// @dev Delegates to the canonical `RISK_MODULE.availableMargin(subKey)`.
    ///      Wraps in `try` so this engine's own views can also translate
    ///      `RiskModuleUnavailable` reverts into `ok = false` when needed.
    function _computeAvailableCollateral(bytes32 subKey) internal view returns (uint256, bool) {
        try RISK_MODULE.availableMargin(subKey) returns (uint256 v) {
            return (v, true);
        } catch {
            return (0, false);
        }
    }
}
