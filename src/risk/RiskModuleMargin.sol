// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./RiskModuleCollateral.sol";

/// @notice Margin / liability layer for RiskModule.
/// @dev
///  Responsibilities:
///   - per-contract maintenance-margin floor
///   - conservative intrinsic liability for short options
///   - stress-based per-contract maintenance margin
///   - aggregate short liability / MM / IM across all open option series
///
///  Canonical conventions:
///   - all outputs suffixed `Base` are denominated in native units of the protocol base collateral token
///   - all normalized prices / notionals remain in protocol 1e8 units until explicitly converted
///   - `shortLiabilityBase` is a conservative liability measure for short options
///   - `maintenanceMarginBase` / `initialMarginBase` are margin requirements, not cashflows
///
///  Economic architecture:
///   - primary source of truth for options risk policy is now:
///       OptionProductRegistry.optionRiskConfigs(underlying)
///   - global RiskModule params remain available as fallback legacy defaults
///
///  Invariant targeted here:
///   MM_per_contract =
—     max(
///         current intrinsic liability,
///         stressed oracle/shock liability,
///         base MM floor
///     )
///
///  Emergency note:
///   - This layer only exposes internal helpers.
///   - External/public pause enforcement is expected in upper layers
///     (typically RiskModuleViews / public entrypoints).
abstract contract RiskModuleMargin is RiskModuleCollateral {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Aggregated options-side margin/liability snapshot.
    /// @dev All fields are denominated in native units of the protocol base collateral token.
    struct OptionsMarginSnapshot {
        uint256 shortLiabilityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
    }

    /// @notice Effective options risk policy for one underlying.
    /// @dev All values are post-fallback effective values.
    struct EffectiveOptionRiskConfig {
        uint256 baseMaintenanceMarginPerContract;
        uint256 imFactorBps;
        uint256 oracleDownMmMultiplierBps;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL OPTION RISK POLICY HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Loads the effective options risk config for one underlying.
    ///      Primary source of truth:
    ///       - OptionProductRegistry.optionRiskConfigs(underlying)
    ///      Fallback:
    ///       - global RiskModule params
    function _effectiveOptionRiskConfig(address underlying)
        internal
        view
        returns (EffectiveOptionRiskConfig memory cfg)
    {
        (
            uint128 baseMmFloorPerContract,
            uint32 imFactorBpsLocal,
            uint32 oracleDownMmMultiplierBpsLocal,
            bool isConfigured
        ) = optionRegistry.optionRiskConfigs(underlying);

        if (isConfigured) {
            cfg.baseMaintenanceMarginPerContract = uint256(baseMmFloorPerContract);
            cfg.imFactorBps = uint256(imFactorBpsLocal);
            cfg.oracleDownMmMultiplierBps = uint256(oracleDownMmMultiplierBpsLocal);
            return cfg;
        }

        cfg.baseMaintenanceMarginPerContract = baseMaintenanceMarginPerContract;
        cfg.imFactorBps = imFactorBps;
        cfg.oracleDownMmMultiplierBps = oracleDownMmMultiplierBps;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL SMALL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _max2(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function _max3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return _max2(_max2(a, b), c);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MM FLOOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Base maintenance-margin floor per contract in base-token native units.
    ///      With contract size hard-locked to 1e8, this is a direct constant floor.
    function _baseMmFloorPerContract(OptionProductRegistry.OptionSeries memory s) internal view returns (uint256) {
        _requireStandardContractSize(s);

        EffectiveOptionRiskConfig memory cfg = _effectiveOptionRiskConfig(s.underlying);
        return cfg.baseMaintenanceMarginPerContract;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL INTRINSIC LIABILITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns conservative per-contract intrinsic amount in normalized settlement 1e8 units.
    ///      Because contractSize is fixed to 1e8, intrinsic amount == intrinsic price.
    function _computePerContractIntrinsicAmount1e8(OptionProductRegistry.OptionSeries memory s, uint256 spot1e8)
        internal
        pure
        returns (uint256 intrinsicAmount1e8)
    {
        _requireStandardContractSize(s);

        if (s.isCall) {
            return spot1e8 > uint256(s.strike) ? (spot1e8 - uint256(s.strike)) : 0;
        }

        return uint256(s.strike) > spot1e8 ? (uint256(s.strike) - spot1e8) : 0;
    }

    /// @dev Converts current intrinsic liability per contract to base-token native units.
    ///      Returns (0,false) if conversion path is unavailable.
    function _computeCurrentIntrinsicPerContractBase(
        OptionProductRegistry.OptionSeries memory s,
        uint256 spot1e8,
        address base,
        uint256 baseScale
    ) internal view returns (uint256 intrinsicBase, bool ok) {
        uint256 intrinsicAmount1e8 = _computePerContractIntrinsicAmount1e8(s, spot1e8);
        if (intrinsicAmount1e8 == 0) {
            return (0, true);
        }

        return _convert1e8SettlementToBaseWithBase(s.settlementAsset, intrinsicAmount1e8, base, baseScale);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL FALLBACK / STRESS HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Conservative fallback amount in base-token native units when oracle path is unavailable.
    function _oracleDownFallbackPerContractBase(OptionProductRegistry.OptionSeries memory s)
        internal
        view
        returns (uint256 fallbackBase)
    {
        uint256 baseFloor = _baseMmFloorPerContract(s);
        if (baseFloor == 0) return 0;

        EffectiveOptionRiskConfig memory cfg = _effectiveOptionRiskConfig(s.underlying);
        fallbackBase = Math.mulDiv(baseFloor, cfg.oracleDownMmMultiplierBps, BPS_U, Math.Rounding.Ceil);
    }

    /// @dev Computes stressed per-contract settlement-side amount in normalized 1e8 units.
    function _computeStressedPerContractAmount1e8(
        OptionProductRegistry.OptionSeries memory s,
        uint256 spot1e8,
        OptionProductRegistry.UnderlyingConfig memory cfg
    ) internal pure returns (uint256 stressedAmount1e8) {
        uint256 spotLocal = spot1e8;

        if (s.isCall) {
            uint256 shockedSpot =
                Math.mulDiv(spotLocal, (BPS_U + uint256(cfg.spotShockUpBps)), BPS_U, Math.Rounding.Floor);

            uint256 intrinsicShock = shockedSpot > uint256(s.strike) ? (shockedSpot - uint256(s.strike)) : 0;
            uint256 volFloor = Math.mulDiv(spotLocal, uint256(cfg.volShockUpBps), BPS_U, Math.Rounding.Floor);

            stressedAmount1e8 = _max2(intrinsicShock, volFloor);
        } else {
            uint256 shockDownBps = uint256(cfg.spotShockDownBps);
            if (shockDownBps > BPS_U) shockDownBps = BPS_U;

            uint256 shockedSpot = Math.mulDiv(spotLocal, (BPS_U - shockDownBps), BPS_U, Math.Rounding.Floor);
            uint256 intrinsicShock = uint256(s.strike) > shockedSpot ? (uint256(s.strike) - shockedSpot) : 0;
            uint256 volFloor = Math.mulDiv(uint256(s.strike), uint256(cfg.volShockUpBps), BPS_U, Math.Rounding.Floor);

            stressedAmount1e8 = _max2(intrinsicShock, volFloor);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL PER-CONTRACT MM
    //////////////////////////////////////////////////////////////*/

    /// @dev Computes stress-based MM per short contract in base-token native units.
    ///      Invariant:
    ///       MM_per_contract = max(current intrinsic, stressed liability, base floor)
    ///
    ///      Fallback behavior:
    ///       - if spot is unavailable => fallback conservatively to oracleDownFallback
    ///       - if conversion of stress/current intrinsic is unavailable => fallback conservatively
    function _computePerContractMM(
        OptionProductRegistry.OptionSeries memory s,
        uint256 spot1e8,
        OptionProductRegistry.UnderlyingConfig memory cfg,
        bool hasSpot,
        address base,
        uint256 baseScale
    ) internal view returns (uint256 mmBase) {
        if (base == address(0)) return 0;

        uint256 baseFloor = _baseMmFloorPerContract(s);
        uint256 oracleDownFallback = _oracleDownFallbackPerContractBase(s);

        // Underlying disabled or no spot => deterministic conservative fallback.
        if (!cfg.isEnabled || !hasSpot) {
            return _max2(baseFloor, oracleDownFallback);
        }

        (uint256 intrinsicBase, bool okIntrinsic) =
            _computeCurrentIntrinsicPerContractBase(s, spot1e8, base, baseScale);

        uint256 stressedAmount1e8 = _computeStressedPerContractAmount1e8(s, spot1e8, cfg);
        (uint256 stressedBase, bool okStress) =
            _convert1e8SettlementToBaseWithBase(s.settlementAsset, stressedAmount1e8, base, baseScale);

        if (!okIntrinsic || !okStress) {
            return _max3(baseFloor, intrinsicBase, oracleDownFallback);
        }

        return _max3(baseFloor, intrinsicBase, stressedBase);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL AGGREGATE LIABILITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Aggregates conservative short intrinsic liability across all open short series.
    ///      Liability is expressed in base-token native units.
    ///      If spot or conversion is unavailable, falls back conservatively.
    function _computeShortLiabilityBase(address trader, address base, uint256 baseScale)
        internal
        view
        returns (uint256 liabilityBase)
    {
        OptionsMarginSnapshot memory snap = _computeOptionsMarginSnapshot(trader, base, baseScale);
        return snap.shortLiabilityBase;
    }

    /// @dev Aggregates short-options liability / MM / IM in one pass.
    ///      This is the preferred internal helper for upper layers.
    function _computeOptionsMarginSnapshot(address trader, address base, uint256 baseScale)
        internal
        view
        returns (OptionsMarginSnapshot memory snap)
    {
        if (base == address(0)) return snap;

        uint256 len = marginEngine.getTraderSeriesLength(trader);

        for (uint256 start = 0; start < len; start += SERIES_PAGE) {
            uint256 end = start + SERIES_PAGE;
            if (end > len) end = len;

            uint256[] memory seriesIds = marginEngine.getTraderSeriesSlice(trader, start, end);

            for (uint256 i = 0; i < seriesIds.length; i++) {
                uint256 optionId = seriesIds[i];

                IMarginEngineState.Position memory pos = marginEngine.positions(trader, optionId);
                if (pos.quantity >= 0) continue;

                uint256 shortAbs = _absQuantityU(pos.quantity);
                if (shortAbs == 0) continue;

                OptionProductRegistry.OptionSeries memory s = optionRegistry.getSeries(optionId);
                _requireStandardContractSize(s);

                OptionProductRegistry.UnderlyingConfig memory ucfg = _getUnderlyingConfig(s.underlying);
                EffectiveOptionRiskConfig memory rcfg = _effectiveOptionRiskConfig(s.underlying);

                (uint256 spot1e8, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

                uint256 mmPerContractBase = _computePerContractMM(s, spot1e8, ucfg, okSpot, base, baseScale);
                if (mmPerContractBase != 0) {
                    uint256 mmAddBase = shortAbs * mmPerContractBase;
                    if (mmAddBase / mmPerContractBase != shortAbs) revert MathOverflow();

                    snap.maintenanceMarginBase = _addChecked(snap.maintenanceMarginBase, mmAddBase);

                    uint256 imAddBase = Math.mulDiv(mmAddBase, rcfg.imFactorBps, BPS_U, Math.Rounding.Ceil);
                    snap.initialMarginBase = _addChecked(snap.initialMarginBase, imAddBase);
                }

                uint256 liabilityPerContractBase;

                if (!okSpot) {
                    liabilityPerContractBase = _oracleDownFallbackPerContractBase(s);
                } else {
                    (uint256 intrinsicBase, bool okIntrinsic) =
                        _computeCurrentIntrinsicPerContractBase(s, spot1e8, base, baseScale);

                    liabilityPerContractBase = okIntrinsic ? intrinsicBase : _oracleDownFallbackPerContractBase(s);
                }

                if (liabilityPerContractBase != 0) {
                    uint256 liabAddBase = shortAbs * liabilityPerContractBase;
                    if (liabAddBase / liabilityPerContractBase != shortAbs) revert MathOverflow();
                    snap.shortLiabilityBase = _addChecked(snap.shortLiabilityBase, liabAddBase);
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL CONSOLIDATED OPTION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Convenience helper used by upper view layers that only need
    ///      the options-side MM/IM pair without rebuilding the full snapshot manually.
    function _computeOptionsMargins(address trader, address base, uint256 baseScale)
        internal
        view
        returns (uint256 maintenanceMarginBase, uint256 initialMarginBase)
    {
        OptionsMarginSnapshot memory snap = _computeOptionsMarginSnapshot(trader, base, baseScale);
        return (snap.maintenanceMarginBase, snap.initialMarginBase);
    }
}