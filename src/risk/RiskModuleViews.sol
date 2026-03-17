// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./RiskModuleAdmin.sol";

/// @notice Public/view surface for RiskModule.
/// @dev
///  Responsibilities:
///   - expose collateral token universe
///   - compute account risk / free collateral / withdraw previews
///   - expose margin ratio and oracle helper views
///
///  Design notes:
///   - conservative valuation: short intrinsic liability is included, longs ignored
///   - pagination over trader series avoids unbounded memory growth
///   - if base collateral is not configured, views degrade gracefully
abstract contract RiskModuleViews is RiskModuleAdmin {
    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function getCollateralTokens() external view returns (address[] memory) {
        return collateralTokens;
    }

    function baseDecimals() external view override returns (uint8) {
        address base = baseCollateralToken;
        if (base == address(0)) return 0;

        CollateralVault.CollateralTokenConfig memory cfg = _vaultCfg(base);
        return cfg.decimals;
    }

    function computeAccountRisk(address trader) public view override returns (AccountRisk memory risk) {
        address base = baseCollateralToken;
        if (base == address(0)) return risk;

        (, uint8 baseDec, uint256 baseScale) = _loadBase();

        uint256 collatEquityBase = _computeCollateralEquityBase(trader, base, baseDec);
        uint256 shortLiabilityBase = _computeShortLiabilityBase(trader, base, baseScale);

        if (shortLiabilityBase >= collatEquityBase) {
            risk.equity = _negUintToInt256Sat(shortLiabilityBase - collatEquityBase);
        } else {
            risk.equity = _uintToInt256Sat(collatEquityBase - shortLiabilityBase);
        }

        uint256 mm;
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

                OptionProductRegistry.UnderlyingConfig memory ucfg = _getUnderlyingConfig(s.underlying);
                (uint256 spot, bool okSpot) = _tryGetPrice(s.underlying, s.settlementAsset);

                uint256 mmPerContract = _computePerContractMM(s, spot, ucfg, okSpot, base, baseScale);

                uint256 add = shortAbs * mmPerContract;
                if (mmPerContract != 0 && add / mmPerContract != shortAbs) revert MathOverflow();

                mm = _addChecked(mm, add);
            }
        }

        risk.maintenanceMargin = mm;
        risk.initialMargin =
            (mm > 0 && imFactorBps > 0) ? Math.mulDiv(mm, imFactorBps, BPS_U, Math.Rounding.Ceil) : 0;
    }

    function computeFreeCollateral(address trader) public view override returns (int256 freeCollateral) {
        AccountRisk memory risk = computeAccountRisk(trader);
        if (risk.initialMargin == 0) return risk.equity;

        int256 im = _uintToInt256Sat(risk.initialMargin);
        return _subInt256Sat(risk.equity, im);
    }

    function getWithdrawableAmount(address trader, address token) public view override returns (uint256 withdrawable) {
        uint256 avail = _effectiveBalanceOf(trader, token);
        if (avail == 0) return 0;

        // If base is not configured yet, remain permissive.
        if (baseCollateralToken == address(0)) return avail;

        (address base, uint8 baseDec,) = _loadBase();

        CollateralConfig memory rcfg = collateralConfigs[token];

        // Non-enabled tokens do not contribute to collateral, so withdrawing them is unrestricted.
        if (!rcfg.isEnabled || rcfg.weightBps == 0) return avail;

        _requireTokenConfiguredIfEnabled(token, baseDec);

        AccountRisk memory risk = computeAccountRisk(trader);

        int256 free =
            (risk.initialMargin == 0) ? risk.equity : _subInt256Sat(risk.equity, _uintToInt256Sat(risk.initialMargin));

        if (free <= 0) return 0;
        if (risk.maintenanceMargin == 0) return avail;

        uint256 freeBase = uint256(free);

        // adjustedRemoved = valueBaseRemoved * weight / BPS <= freeBase
        // => valueBaseRemoved <= freeBase * BPS / weight
        uint256 valueBaseMax = Math.mulDiv(freeBase, BPS_U, uint256(rcfg.weightBps), Math.Rounding.Floor);

        uint256 maxToken;
        if (token == base) {
            maxToken = valueBaseMax;
        } else {
            (uint256 price, bool okPrice) = _tryGetPrice(token, base);
            if (!okPrice) return 0;
            maxToken = _baseValueToTokenAmount(token, valueBaseMax, price);
        }

        withdrawable = maxToken < avail ? maxToken : avail;
    }

    function computeMarginRatioBps(address trader) external view override returns (uint256) {
        if (baseCollateralToken == address(0)) return type(uint256).max;

        AccountRisk memory risk = computeAccountRisk(trader);

        if (risk.maintenanceMargin == 0) return type(uint256).max;
        if (risk.equity <= 0) return 0;

        return (uint256(risk.equity) * BPS_U) / risk.maintenanceMargin;
    }

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        override
        returns (IRiskModule.WithdrawPreview memory preview)
    {
        preview.requestedAmount = amount;

        uint256 avail = _effectiveBalanceOf(trader, token);

        // Graceful behavior before base config is set.
        if (baseCollateralToken == address(0)) {
            preview.maxWithdrawable = avail;
            preview.marginRatioBeforeBps = type(uint256).max;
            preview.marginRatioAfterBps = type(uint256).max;
            preview.wouldBreachMargin = (amount > avail);
            return preview;
        }

        AccountRisk memory riskBefore = computeAccountRisk(trader);

        uint256 mrBefore;
        if (riskBefore.maintenanceMargin == 0) {
            mrBefore = type(uint256).max;
        } else if (riskBefore.equity <= 0) {
            mrBefore = 0;
        } else {
            mrBefore = (uint256(riskBefore.equity) * BPS_U) / riskBefore.maintenanceMargin;
        }

        uint256 maxAllowed = getWithdrawableAmount(trader, token);
        preview.maxWithdrawable = maxAllowed;
        preview.marginRatioBeforeBps = mrBefore;

        uint256 cappedReq = amount > avail ? avail : amount;
        uint256 effectiveAmount = cappedReq > maxAllowed ? maxAllowed : cappedReq;

        uint256 deltaEquityBase;

        if (effectiveAmount > 0) {
            CollateralConfig memory rcfg = collateralConfigs[token];

            if (rcfg.isEnabled && rcfg.weightBps > 0) {
                (address base, uint8 baseDec,) = _loadBase();
                _requireTokenConfiguredIfEnabled(token, baseDec);

                if (token == base) {
                    deltaEquityBase =
                        Math.mulDiv(effectiveAmount, uint256(rcfg.weightBps), BPS_U, Math.Rounding.Floor);
                } else {
                    (uint256 price, bool ok) = _tryGetPrice(token, base);
                    if (ok) {
                        uint256 valueBase = _baseValueToTokenAmount(token, effectiveAmount, price);
                        // Correction: token -> base value, then haircut.
                        valueBase = _tokenAmountToBaseValue(token, effectiveAmount, price);
                        deltaEquityBase = Math.mulDiv(valueBase, uint256(rcfg.weightBps), BPS_U, Math.Rounding.Floor);
                    } else {
                        // Unknown conversion => worst-case preview.
                        deltaEquityBase = uint256(type(int256).max);
                    }
                }
            }
        }

        int256 equityAfter = _subInt256Sat(riskBefore.equity, _uintToInt256Sat(deltaEquityBase));

        uint256 mrAfter;
        if (riskBefore.maintenanceMargin == 0) {
            mrAfter = type(uint256).max;
        } else if (equityAfter <= 0) {
            mrAfter = 0;
        } else {
            mrAfter = (uint256(equityAfter) * BPS_U) / riskBefore.maintenanceMargin;
        }

        preview.marginRatioAfterBps = mrAfter;

        bool breach = (amount > maxAllowed);

        // Extra IM guard for rounding / estimation hardening.
        if (!breach && riskBefore.initialMargin != 0) {
            int256 im = _uintToInt256Sat(riskBefore.initialMargin);
            if (equityAfter < im) breach = true;
        }

        preview.wouldBreachMargin = breach;
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE VIEW
    //////////////////////////////////////////////////////////////*/

    function getUnderlyingSpot(address underlying, address settlementAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt)
    {
        return oracle.getPrice(underlying, settlementAsset);
    }
}