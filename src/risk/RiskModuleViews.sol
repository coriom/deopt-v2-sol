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
///   - expose decomposed collateral / product risk state
///   - expose effective options risk policy by underlying
///
///  Canonical conventions:
///   - all `...Base` fields are denominated in native units of the protocol base collateral token
///   - all `...Bps` fields are denominated in basis points
///   - token withdrawal amounts remain denominated in token-native units
///
///  Design notes:
///   - conservative valuation: short intrinsic liability is included, longs ignored
///   - pagination over trader series avoids unbounded memory growth
///   - if base collateral is not configured, views degrade gracefully
///   - perp contribution is consumed best-effort through `perpRiskModule` / `perpEngine` when configured
///   - options-side IM/MM/liability are sourced from `_computeOptionsMarginSnapshot(...)`
///     so they automatically reflect per-underlying `OptionRiskConfig`
abstract contract RiskModuleViews is RiskModuleAdmin {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Public-facing effective options risk policy for one underlying.
    /// @dev
    ///  - values are post-fallback effective values
    ///  - `usesGlobalFallback` tells whether registry-level config was absent
    struct EffectiveOptionRiskPolicyView {
        address underlying;
        uint256 baseMaintenanceMarginPerContract;
        uint256 imFactorBps;
        uint256 oracleDownMmMultiplierBps;
        bool usesGlobalFallback;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL PERP HELPERS
    //////////////////////////////////////////////////////////////*/

    function _hasPerpRiskModule() internal view returns (bool) {
        return address(perpRiskModule) != address(0);
    }

    function _tryGetPerpAccountRisk(address trader)
        internal
        view
        returns (bool ok, IPerpRiskModule.AccountRisk memory risk)
    {
        if (!_hasPerpRiskModule()) {
            return (false, risk);
        }

        try perpRiskModule.computeAccountRisk(trader) returns (IPerpRiskModule.AccountRisk memory r) {
            return (true, r);
        } catch {
            return (false, risk);
        }
    }

    function _tryGetPerpNetPnl(address trader) internal view returns (bool ok, int256 netPnlBase) {
        if (perpEngine == address(0)) return (false, 0);

        try IPerpEngineViews(perpEngine).getAccountNetPnl(trader) returns (int256 n) {
            return (true, n);
        } catch {
            return (false, 0);
        }
    }

    function _tryGetPerpFunding(address trader) internal view returns (bool ok, int256 fundingAccruedBase) {
        if (perpEngine == address(0)) return (false, 0);

        try IPerpEngineViews(perpEngine).getAccountFunding(trader) returns (int256 f) {
            return (true, f);
        } catch {
            return (false, 0);
        }
    }

    function _tryGetPerpResidualBadDebt(address trader) internal view returns (bool ok, uint256 residualBadDebtBase) {
        if (perpEngine == address(0)) return (false, 0);

        try IPerpEngineViews(perpEngine).getResidualBadDebt(trader) returns (uint256 d) {
            return (true, d);
        } catch {
            return (false, 0);
        }
    }

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

    function computeCollateralState(address trader)
        public
        view
        override
        whenRiskChecksNotPaused
        returns (CollateralState memory state)
    {
        address base = baseCollateralToken;
        if (base == address(0)) return state;

        (, uint8 baseDec,) = _loadBase();

        uint256 adjustedBase = _computeCollateralEquityBase(trader, base, baseDec);
        state.adjustedCollateralValueBase = adjustedBase;

        uint256 len = collateralTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = collateralTokens[i];
            CollateralConfig memory rcfg = collateralConfigs[token];

            if (!rcfg.isEnabled) continue;

            uint256 bal = _effectiveBalanceOf(trader, token);
            if (bal == 0) continue;

            uint256 valueBase;
            if (token == base) {
                valueBase = bal;
            } else {
                (uint256 price, bool okPrice) = _tryGetPrice(token, base);
                if (!okPrice) continue;
                valueBase = _tokenAmountToBaseValue(token, bal, price);
            }

            state.grossCollateralValueBase = _addChecked(state.grossCollateralValueBase, valueBase);
        }
    }

    function computeProductRiskState(address trader)
        public
        view
        override
        whenRiskChecksNotPaused
        returns (ProductRiskState memory state)
    {
        address base = baseCollateralToken;
        if (base == address(0)) return state;

        (, , uint256 baseScale) = _loadBase();

        OptionsMarginSnapshot memory optSnap = _computeOptionsMarginSnapshot(trader, base, baseScale);
        state.optionsMaintenanceMarginBase = optSnap.maintenanceMarginBase;
        state.optionsInitialMarginBase = optSnap.initialMarginBase;

        if (_hasPerpRiskModule()) {
            (bool okPerpRisk, IPerpRiskModule.AccountRisk memory perpRisk) = _tryGetPerpAccountRisk(trader);
            if (okPerpRisk) {
                state.perpsMaintenanceMarginBase = perpRisk.maintenanceMarginBase;
                state.perpsInitialMarginBase = perpRisk.initialMarginBase;
            }

            (bool okNetPnl, int256 netPnlBase) = _tryGetPerpNetPnl(trader);
            if (okNetPnl) {
                state.unrealizedPnlBase = netPnlBase;
            }

            (bool okFunding, int256 fundingAccruedBase) = _tryGetPerpFunding(trader);
            if (okFunding) {
                state.fundingAccruedBase = fundingAccruedBase;
            }

            (bool okDebt, uint256 residualBadDebtBase) = _tryGetPerpResidualBadDebt(trader);
            if (okDebt) {
                state.residualBadDebtBase = residualBadDebtBase;
            }
        }
    }

    function computeAccountRiskBreakdown(address trader)
        public
        view
        override
        whenRiskChecksNotPaused
        returns (AccountRiskBreakdown memory breakdown)
    {
        address base = baseCollateralToken;
        if (base == address(0)) return breakdown;

        breakdown.collateral = computeCollateralState(trader);
        breakdown.products = computeProductRiskState(trader);

        uint256 shortLiabilityBase = _computeShortLiabilityBase(trader, base, _pow10(_vaultCfg(base).decimals));

        if (shortLiabilityBase >= breakdown.collateral.adjustedCollateralValueBase) {
            breakdown.equityBase =
                _negUintToInt256Sat(shortLiabilityBase - breakdown.collateral.adjustedCollateralValueBase);
        } else {
            breakdown.equityBase =
                _uintToInt256Sat(breakdown.collateral.adjustedCollateralValueBase - shortLiabilityBase);
        }

        if (breakdown.products.unrealizedPnlBase != 0) {
            breakdown.equityBase = _subInt256Sat(breakdown.equityBase, -breakdown.products.unrealizedPnlBase);
        }

        breakdown.maintenanceMarginBase = _addChecked(
            breakdown.products.optionsMaintenanceMarginBase,
            breakdown.products.perpsMaintenanceMarginBase
        );

        breakdown.initialMarginBase = _addChecked(
            breakdown.products.optionsInitialMarginBase,
            breakdown.products.perpsInitialMarginBase
        );

        if (breakdown.products.residualBadDebtBase != 0) {
            breakdown.equityBase =
                _subInt256Sat(breakdown.equityBase, _uintToInt256Sat(breakdown.products.residualBadDebtBase));
        }
    }

    function computeAccountRisk(address trader)
        public
        view
        override
        whenRiskChecksNotPaused
        returns (AccountRisk memory risk)
    {
        AccountRiskBreakdown memory b = computeAccountRiskBreakdown(trader);
        risk.equityBase = b.equityBase;
        risk.maintenanceMarginBase = b.maintenanceMarginBase;
        risk.initialMarginBase = b.initialMarginBase;
    }

    function computeFreeCollateral(address trader)
        public
        view
        override
        whenRiskChecksNotPaused
        returns (int256 freeCollateralBase)
    {
        AccountRisk memory risk = computeAccountRisk(trader);
        if (risk.initialMarginBase == 0) return risk.equityBase;

        int256 imBase = _uintToInt256Sat(risk.initialMarginBase);
        return _subInt256Sat(risk.equityBase, imBase);
    }

    function getResidualBadDebt(address trader)
        external
        view
        override
        returns (uint256 amountBase)
    {
        if (!_hasPerpRiskModule() || perpEngine == address(0)) return 0;

        (, uint256 debtBase) = _tryGetPerpResidualBadDebt(trader);
        amountBase = debtBase;
    }

    function getWithdrawableAmount(address trader, address token)
        public
        view
        override
        whenWithdrawPreviewNotPaused
        returns (uint256 withdrawable)
    {
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

        int256 freeBase = (risk.initialMarginBase == 0)
            ? risk.equityBase
            : _subInt256Sat(risk.equityBase, _uintToInt256Sat(risk.initialMarginBase));

        if (freeBase <= 0) return 0;
        if (risk.maintenanceMarginBase == 0) return avail;

        uint256 freeBaseU = uint256(freeBase);

        // adjustedRemoved = valueBaseRemoved * weight / BPS <= freeBase
        // => valueBaseRemoved <= freeBase * BPS / weight
        uint256 valueBaseMax = Math.mulDiv(freeBaseU, BPS_U, uint256(rcfg.weightBps), Math.Rounding.Floor);

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

    function computeMarginRatioBps(address trader)
        external
        view
        override
        whenRiskChecksNotPaused
        returns (uint256)
    {
        if (baseCollateralToken == address(0)) return type(uint256).max;

        AccountRisk memory risk = computeAccountRisk(trader);

        if (risk.maintenanceMarginBase == 0) return type(uint256).max;
        if (risk.equityBase <= 0) return 0;

        return (uint256(risk.equityBase) * BPS_U) / risk.maintenanceMarginBase;
    }

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        override
        whenWithdrawPreviewNotPaused
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
        if (riskBefore.maintenanceMarginBase == 0) {
            mrBefore = type(uint256).max;
        } else if (riskBefore.equityBase <= 0) {
            mrBefore = 0;
        } else {
            mrBefore = (uint256(riskBefore.equityBase) * BPS_U) / riskBefore.maintenanceMarginBase;
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
                        uint256 valueBase = _tokenAmountToBaseValue(token, effectiveAmount, price);
                        deltaEquityBase = Math.mulDiv(valueBase, uint256(rcfg.weightBps), BPS_U, Math.Rounding.Floor);
                    } else {
                        // Unknown conversion => worst-case preview.
                        deltaEquityBase = uint256(type(int256).max);
                    }
                }
            }
        }

        int256 equityAfterBase = _subInt256Sat(riskBefore.equityBase, _uintToInt256Sat(deltaEquityBase));

        uint256 mrAfter;
        if (riskBefore.maintenanceMarginBase == 0) {
            mrAfter = type(uint256).max;
        } else if (equityAfterBase <= 0) {
            mrAfter = 0;
        } else {
            mrAfter = (uint256(equityAfterBase) * BPS_U) / riskBefore.maintenanceMarginBase;
        }

        preview.marginRatioAfterBps = mrAfter;

        bool breach = (amount > maxAllowed);

        // Extra IM guard for rounding / estimation hardening.
        if (!breach && riskBefore.initialMarginBase != 0) {
            int256 imBase = _uintToInt256Sat(riskBefore.initialMarginBase);
            if (equityAfterBase < imBase) breach = true;
        }

        preview.wouldBreachMargin = breach;
    }

    /*//////////////////////////////////////////////////////////////
                    OPTION RISK POLICY VIEWS
    //////////////////////////////////////////////////////////////*/

    function getEffectiveOptionRiskPolicy(address underlying)
        external
        view
        returns (EffectiveOptionRiskPolicyView memory policy)
    {
        policy.underlying = underlying;

        (
            uint128 baseMmFloorPerContract,
            uint32 imFactorBpsLocal,
            uint32 oracleDownMmMultiplierBpsLocal,
            bool isConfigured
        ) = optionRegistry.optionRiskConfigs(underlying);

        if (isConfigured) {
            policy.baseMaintenanceMarginPerContract = uint256(baseMmFloorPerContract);
            policy.imFactorBps = uint256(imFactorBpsLocal);
            policy.oracleDownMmMultiplierBps = uint256(oracleDownMmMultiplierBpsLocal);
            policy.usesGlobalFallback = false;
            return policy;
        }

        policy.baseMaintenanceMarginPerContract = baseMaintenanceMarginPerContract;
        policy.imFactorBps = imFactorBps;
        policy.oracleDownMmMultiplierBps = oracleDownMmMultiplierBps;
        policy.usesGlobalFallback = true;
    }


    function getOptionRiskConfig(address underlying)
        external
        view
        returns (
            uint128 baseMaintenanceMarginPerContract,
            uint32 optionImFactorBps,
            uint32 optionOracleDownMmMultiplierBps,
            bool isConfigured
        )
    {
        return optionRegistry.optionRiskConfigs(underlying);
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