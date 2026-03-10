// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./RiskModuleCollateral.sol";

abstract contract RiskModuleMargin is RiskModuleCollateral {
    function _baseMmFloorPerContract(OptionProductRegistry.OptionSeries memory s) internal view returns (uint256) {
        if (baseMaintenanceMarginPerContract == 0) return 0;
        _requireStandardContractSize(s);
        return baseMaintenanceMarginPerContract;
    }

    function _computePerContractIntrinsicAmount1e8(OptionProductRegistry.OptionSeries memory s, uint256 spot1e8)
        internal
        pure
        returns (uint256 intrinsicAmount1e8)
    {
        _requireStandardContractSize(s);

        uint256 intrinsicPrice1e8;
        if (s.isCall) {
            intrinsicPrice1e8 = spot1e8 > uint256(s.strike) ? (spot1e8 - uint256(s.strike)) : 0;
        } else {
            intrinsicPrice1e8 = uint256(s.strike) > spot1e8 ? (uint256(s.strike) - spot1e8) : 0;
        }

        intrinsicAmount1e8 = intrinsicPrice1e8;
    }

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
        if (baseFloor == 0) return 0;

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
            return Math.mulDiv(baseFloor, oracleDownMmMultiplierBps, BPS_U, Math.Rounding.Ceil);
        }

        if (converted < baseFloor) converted = baseFloor;
        return converted;
    }

    function _computeShortLiabilityBase(address trader, address base, uint256 baseScale)
        internal
        view
        returns (uint256 liabilityBase)
    {
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

                OptionProductRegistry.OptionSeries memory s = optionRegistry.getSeries(optionId);
                _requireStandardContractSize(s);

                (uint256 spot, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

                if (!okSpot) {
                    uint256 baseFloor = _baseMmFloorPerContract(s);
                    uint256 liabPerContract =
                        Math.mulDiv(baseFloor, oracleDownMmMultiplierBps, BPS_U, Math.Rounding.Ceil);
                    uint256 add = shortAbs * liabPerContract;
                    if (liabPerContract != 0 && add / liabPerContract != shortAbs) revert MathOverflow();
                    liabilityBase = _addChecked(liabilityBase, add);
                    continue;
                }

                uint256 intrinsicAmount1e8 = _computePerContractIntrinsicAmount1e8(s, spot);
                if (intrinsicAmount1e8 == 0) continue;

                (uint256 intrinsicBase, bool okConv) =
                    _convert1e8SettlementToBaseWithBase(s.settlementAsset, intrinsicAmount1e8, base, baseScale);

                if (!okConv || intrinsicBase == 0) {
                    uint256 baseFloor2 = _baseMmFloorPerContract(s);
                    intrinsicBase = Math.mulDiv(baseFloor2, oracleDownMmMultiplierBps, BPS_U, Math.Rounding.Ceil);
                }

                uint256 add2 = shortAbs * intrinsicBase;
                if (intrinsicBase != 0 && add2 / intrinsicBase != shortAbs) revert MathOverflow();
                liabilityBase = _addChecked(liabilityBase, add2);
            }
        }

        return liabilityBase;
    }
}