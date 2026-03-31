// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./RiskModuleCollateral.sol";

/// @notice Margin / liability layer for RiskModule.
/// @dev
///  Responsibilities:
///   - per-contract MM floor
///   - conservative intrinsic liability for shorts
///   - stress-based per-contract maintenance margin
///   - aggregate short liability / MM / IM across all open option series
///
///  Emergency note:
///   - This layer only exposes internal helpers.
///   - External/public pause enforcement is expected in upper layers
///     (typically RiskModuleViews / public entrypoints).
abstract contract RiskModuleMargin is RiskModuleCollateral {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct OptionsMarginSnapshot {
        uint256 shortLiabilityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MM FLOOR
    //////////////////////////////////////////////////////////////*/

    /// @dev Base MM floor per contract in base token units.
    ///      With contract size hard-locked to 1e8, this is a direct constant floor.
    function _baseMmFloorPerContract(OptionProductRegistry.OptionSeries memory s) internal view returns (uint256) {
        _requireStandardContractSize(s);
        return baseMaintenanceMarginPerContract;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL INTRINSIC LIABILITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns conservative per-contract intrinsic amount in settlement 1e8 units.
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

    /// @dev Conservative fallback amount in base token units when oracle path is unavailable.
    function _oracleDownFallbackPerContractBase(OptionProductRegistry.OptionSeries memory s)
        internal
        view
        returns (uint256 fallbackBase)
    {
        uint256 baseFloor = _baseMmFloorPerContract(s);
        if (baseFloor == 0) return 0;

        fallbackBase = Math.mulDiv(baseFloor, oracleDownMmMultiplierBps, BPS_U, Math.Rounding.Ceil);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL PER-CONTRACT MM
    //////////////////////////////////////////////////////////////*/

    /// @dev Computes stress-based MM per short contract in base token units.
    ///      Logic:
    ///       - start from stress scenario on spot / vol proxy
    ///       - convert settlement amount to base
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

        (uint256 converted, bool okConv) =
            _convert1e8SettlementToBaseWithBase(s.settlementAsset, mmPrice1e8, base, baseScale);

        if (!okConv || converted == 0) {
            return _oracleDownFallbackPerContractBase(s);
        }

        if (converted < baseFloor) converted = baseFloor;
        return converted;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL AGGREGATE LIABILITY
    //////////////////////////////////////////////////////////////*/

    /// @dev Aggregates conservative short intrinsic liability across all open short series.
    ///      Liability is expressed in base token units.
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
                (uint256 spot, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

                uint256 mmPerContract = _computePerContractMM(s, spot, cfg, okSpot, base, baseScale);
                if (mmPerContract != 0) {
                    uint256 mmAdd = shortAbs * mmPerContract;
                    if (mmAdd / mmPerContract != shortAbs) revert MathOverflow();
                    snap.maintenanceMarginBase = _addChecked(snap.maintenanceMarginBase, mmAdd);
                }

                uint256 liabilityPerContract;

                if (!okSpot) {
                    liabilityPerContract = _oracleDownFallbackPerContractBase(s);
                } else {
                    uint256 intrinsicAmount1e8 = _computePerContractIntrinsicAmount1e8(s, spot);

                    if (intrinsicAmount1e8 == 0) {
                        liabilityPerContract = 0;
                    } else {
                        (uint256 intrinsicBase, bool okConv) =
                            _convert1e8SettlementToBaseWithBase(s.settlementAsset, intrinsicAmount1e8, base, baseScale);

                        liabilityPerContract = (!okConv || intrinsicBase == 0)
                            ? _oracleDownFallbackPerContractBase(s)
                            : intrinsicBase;
                    }
                }

                if (liabilityPerContract != 0) {
                    uint256 liabAdd = shortAbs * liabilityPerContract;
                    if (liabAdd / liabilityPerContract != shortAbs) revert MathOverflow();
                    snap.shortLiabilityBase = _addChecked(snap.shortLiabilityBase, liabAdd);
                }
            }
        }

        if (snap.maintenanceMarginBase == 0 || imFactorBps == 0) return snap;

        snap.initialMarginBase =
            Math.mulDiv(snap.maintenanceMarginBase, imFactorBps, BPS_U, Math.Rounding.Ceil);
    }
}