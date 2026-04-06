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

    /*//////////////////////////////////////////////////////////////
                    INTERNAL PER-CONTRACT MM
    //////////////////////////////////////////////////////////////*/

    /// @dev Computes stress-based MM per short contract in base-token native units.
    ///      Logic:
    ///       - start from a stress scenario on spot / vol proxy
    ///       - convert settlement-side amount to base
    ///       - enforce base MM floor
    ///       - if oracle conversion fails, fallback to oracleDownMmMultiplierBps * floor
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

        // Even if the explicit base floor is zero, keep the oracle-down fallback behavior deterministic.
        if (!cfg.isEnabled) return baseFloor;

        uint256 spotLocal = hasSpot ? spot1e8 : uint256(s.strike);
        uint256 mmPrice1e8;

        if (s.isCall) {
            uint256 shockedSpot =
                Math.mulDiv(spotLocal, (BPS_U + uint256(cfg.spotShockUpBps)), BPS_U, Math.Rounding.Floor);

            uint256 intrinsicShock = shockedSpot > uint256(s.strike) ? (shockedSpot - uint256(s.strike)) : 0;
            uint256 floorPrice = Math.mulDiv(spotLocal, uint256(cfg.volShockUpBps), BPS_U, Math.Rounding.Floor);

            mmPrice1e8 = intrinsicShock > floorPrice ? intrinsicShock : floorPrice;
        } else {
            uint256 shockDownBps = uint256(cfg.spotShockDownBps);
            if (shockDownBps > BPS_U) shockDownBps = BPS_U;

            uint256 shockedSpot = Math.mulDiv(spotLocal, (BPS_U - shockDownBps), BPS_U, Math.Rounding.Floor);
            uint256 intrinsicShock = uint256(s.strike) > shockedSpot ? (uint256(s.strike) - shockedSpot) : 0;
            uint256 floorPrice = Math.mulDiv(uint256(s.strike), uint256(cfg.volShockUpBps), BPS_U, Math.Rounding.Floor);

            mmPrice1e8 = intrinsicShock > floorPrice ? intrinsicShock : floorPrice;
        }

        (uint256 convertedBase, bool okConv) =
            _convert1e8SettlementToBaseWithBase(s.settlementAsset, mmPrice1e8, base, baseScale);

        if (!okConv || convertedBase == 0) {
            return _oracleDownFallbackPerContractBase(s);
        }

        if (convertedBase < baseFloor) convertedBase = baseFloor;
        return convertedBase;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL AGGREGATE LIABILITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Aggregates conservative short intrinsic liability across all open short series.
    ///      Liability is expressed in base-token native units.
    ///      If spot or conversion is unavailable, falls back to oracleDownMmMultiplierBps * base floor.
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

                OptionProductRegistry.UnderlyingConfig memory cfg = _getUnderlyingConfig(s.underlying);
                EffectiveOptionRiskConfig memory riskCfg = _effectiveOptionRiskConfig(s.underlying);

                (uint256 spot1e8, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

                uint256 mmPerContractBase = _computePerContractMM(s, spot1e8, cfg, okSpot, base, baseScale);
                if (mmPerContractBase != 0) {
                    uint256 mmAddBase = shortAbs * mmPerContractBase;
                    if (mmAddBase / mmPerContractBase != shortAbs) revert MathOverflow();
                    snap.maintenanceMarginBase = _addChecked(snap.maintenanceMarginBase, mmAddBase);
                }

                uint256 liabilityPerContractBase;

                if (!okSpot) {
                    liabilityPerContractBase = _oracleDownFallbackPerContractBase(s);
                } else {
                    uint256 intrinsicAmount1e8 = _computePerContractIntrinsicAmount1e8(s, spot1e8);

                    if (intrinsicAmount1e8 == 0) {
                        liabilityPerContractBase = 0;
                    } else {
                        (uint256 intrinsicBase, bool okConv) =
                            _convert1e8SettlementToBaseWithBase(s.settlementAsset, intrinsicAmount1e8, base, baseScale);

                        liabilityPerContractBase =
                            (!okConv || intrinsicBase == 0) ? _oracleDownFallbackPerContractBase(s) : intrinsicBase;
                    }
                }

                if (liabilityPerContractBase != 0) {
                    uint256 liabAddBase = shortAbs * liabilityPerContractBase;
                    if (liabAddBase / liabilityPerContractBase != shortAbs) revert MathOverflow();
                    snap.shortLiabilityBase = _addChecked(snap.shortLiabilityBase, liabAddBase);
                }

                riskCfg;
            }
        }

        if (snap.maintenanceMarginBase == 0) return snap;

        uint256 len2 = marginEngine.getTraderSeriesLength(trader);
        uint256 weightedImBase;
        uint256 totalMmBase;

        for (uint256 start2 = 0; start2 < len2; start2 += SERIES_PAGE) {
            uint256 end2 = start2 + SERIES_PAGE;
            if (end2 > len2) end2 = len2;

            uint256[] memory seriesIds2 = marginEngine.getTraderSeriesSlice(trader, start2, end2);

            for (uint256 j = 0; j < seriesIds2.length; j++) {
                uint256 optionId2 = seriesIds2[j];

                IMarginEngineState.Position memory pos2 = marginEngine.positions(trader, optionId2);
                if (pos2.quantity >= 0) continue;

                uint256 shortAbs2 = _absQuantityU(pos2.quantity);
                if (shortAbs2 == 0) continue;

                OptionProductRegistry.OptionSeries memory s2 = optionRegistry.getSeries(optionId2);
                _requireStandardContractSize(s2);

                OptionProductRegistry.UnderlyingConfig memory ucfg2 = _getUnderlyingConfig(s2.underlying);
                EffectiveOptionRiskConfig memory rcfg2 = _effectiveOptionRiskConfig(s2.underlying);
                (uint256 spot2, bool okSpot2) = _tryGetPrice(s2.underlying, s2.settlementAsset);

                uint256 mmPerContractBase2 = _computePerContractMM(s2, spot2, ucfg2, okSpot2, base, baseScale);
                if (mmPerContractBase2 == 0) continue;

                uint256 mmAddBase2 = shortAbs2 * mmPerContractBase2;
                if (mmAddBase2 / mmPerContractBase2 != shortAbs2) revert MathOverflow();

                totalMmBase = _addChecked(totalMmBase, mmAddBase2);

                uint256 imAddBase2 = Math.mulDiv(mmAddBase2, rcfg2.imFactorBps, BPS_U, Math.Rounding.Ceil);
                weightedImBase = _addChecked(weightedImBase, imAddBase2);
            }
        }

        snap.initialMarginBase = totalMmBase == 0 ? 0 : weightedImBase;
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