// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./PerpEngineAdmin.sol";

abstract contract PerpEngineViews is PerpEngineAdmin {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Account PnL decomposition in normalized quote 1e8 units.
    struct AccountPnlBreakdown {
        int256 unrealizedPnl1e8;
        int256 fundingAccrued1e8;
        int256 netPnl1e8;
    }

    /// @notice Account exposure decomposition in normalized quote 1e8 units.
    struct AccountExposureBreakdown {
        uint256 marketsCount;
        uint256 grossNotional1e8;
        uint256 longNotional1e8;
        uint256 shortNotional1e8;
    }

    /// @notice Effective liquidation policy resolved for one market.
    /// @dev
    ///  - `penaltyBps` comes from market RiskConfig first, fallback engine default second
    ///  - the other fields come from market LiquidationConfig first, fallback engine defaults second
    struct LiquidationPolicyView {
        uint256 closeFactorBps;
        uint256 penaltyBps;
        uint256 priceSpreadBps;
        uint256 minImprovementBps;
        uint32 oracleMaxDelay;
    }

    struct PerpLiquidationState {
        bool liquidatable;
        uint256 marginRatioBps;
        uint256 residualBadDebtBase;
        bool reduceOnly;
        bool canIncreaseExposure;
    }

    struct InsuranceCoveragePreview {
        address baseToken;
        uint256 requestedBase;
        uint256 previewCoveredBase;
        bool insuranceFundConfigured;
    }

    /*//////////////////////////////////////////////////////////////
                            DEPENDENCY READS
    //////////////////////////////////////////////////////////////*/

    function marketRegistry() external view returns (address) {
        return _marketRegistryAddress();
    }

    function collateralVault() external view returns (address) {
        return _collateralVaultAddress();
    }

    function oracle() external view returns (address) {
        return _oracleAddress();
    }

    function riskModule() external view returns (address) {
        return _riskModuleAddress();
    }

    function collateralSeizer() external view returns (address) {
        return _collateralSeizerAddress();
    }

    /*//////////////////////////////////////////////////////////////
                            CORE READS
    //////////////////////////////////////////////////////////////*/

    function positions(address trader, uint256 marketId) external view returns (Position memory) {
        return _positions[trader][marketId];
    }

    function getPositionSize(address trader, uint256 marketId) external view returns (int256) {
        return _positions[trader][marketId].size1e8;
    }

    function marketState(uint256 marketId) external view returns (MarketState memory s) {
        _requireMarketExists(marketId);
        return _marketStates[marketId];
    }

    function getTraderMarkets(address trader) external view returns (uint256[] memory) {
        return traderMarkets[trader];
    }

    function getTraderMarketsLength(address trader) external view returns (uint256) {
        return traderMarkets[trader].length;
    }

    function getTraderMarketsSlice(address trader, uint256 start, uint256 end)
        external
        view
        returns (uint256[] memory out)
    {
        uint256 len = traderMarkets[trader].length;

        if (start >= len || start >= end) {
            return new uint256[](0);
        }

        if (end > len) end = len;

        uint256 outLen = end - start;
        out = new uint256[](outLen);

        for (uint256 i = 0; i < outLen; i++) {
            out[i] = traderMarkets[trader][start + i];
        }
    }

    function isOpenMarket(address trader, uint256 marketId) external view returns (bool) {
        return traderMarketIndexPlus1[trader][marketId] != 0;
    }

    /*//////////////////////////////////////////////////////////////
                        BAD DEBT / SOLVENCY READS
    //////////////////////////////////////////////////////////////*/

    function getResidualBadDebt(address trader) public view returns (uint256) {
        return _residualBadDebtOf(trader);
    }

    function getTotalResidualBadDebt() external view returns (uint256) {
        return totalResidualBadDebtBase;
    }

    function hasResidualBadDebt(address trader) public view returns (bool) {
        return _residualBadDebtOf(trader) != 0;
    }

    /// @notice Current post-insolvency trading policy for an account.
    /// @dev If account has residual bad debt, engine enforces strict reduce-only.
    function isReduceOnlyByBadDebt(address trader) external view returns (bool) {
        return hasResidualBadDebt(trader);
    }

    /// @notice Whether the account is currently allowed to increase/open exposure.
    function canIncreaseExposure(address trader) external view returns (bool) {
        return !hasResidualBadDebt(trader);
    }

    function getPerpSolvencyState(address trader)
        external
        view
        returns (uint256 residualBadDebtBase, bool hasOpenPositions, bool liquidatable)
    {
        residualBadDebtBase = _residualBadDebtOf(trader);
        hasOpenPositions = traderMarkets[trader].length != 0;
        liquidatable = isLiquidatable(trader);
    }

    function getPerpAccountStatus(address trader)
        external
        view
        returns (
            uint256 residualBadDebtBase,
            bool hasOpenPositions,
            bool liquidatable,
            bool reduceOnly,
            bool canIncrease
        )
    {
        residualBadDebtBase = _residualBadDebtOf(trader);
        hasOpenPositions = traderMarkets[trader].length != 0;
        liquidatable = isLiquidatable(trader);
        reduceOnly = residualBadDebtBase != 0;
        canIncrease = residualBadDebtBase == 0;
    }

    function getPerpLiquidationState(address trader) external view returns (PerpLiquidationState memory s) {
        s.residualBadDebtBase = _residualBadDebtOf(trader);
        s.reduceOnly = s.residualBadDebtBase != 0;
        s.canIncreaseExposure = s.residualBadDebtBase == 0;

        if (address(_riskModule) == address(0)) {
            s.marginRatioBps = type(uint256).max;
            s.liquidatable = false;
            return s;
        }

        IPerpRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        s.marginRatioBps = _marginRatioBpsFromState(r.equityBase, r.maintenanceMarginBase);

        if (r.maintenanceMarginBase == 0) {
            s.liquidatable = false;
        } else if (r.equityBase <= 0) {
            s.liquidatable = true;
        } else {
            s.liquidatable = s.marginRatioBps < BPS;
        }
    }

    function previewResidualBadDebtRepayment(address payer, address trader, uint256 requestedAmountBase)
        external
        view
        returns (BadDebtRepayment memory repayment)
    {
        repayment.requestedBase = requestedAmountBase;
        repayment.outstandingBase = _residualBadDebtOf(trader);

        if (requestedAmountBase == 0 || repayment.outstandingBase == 0 || payer == address(0)) {
            repayment.remainingBase = repayment.outstandingBase;
            return repayment;
        }

        address baseToken = _baseCollateralToken();
        uint256 payerBal = _collateralVault.balances(payer, baseToken);

        uint256 cappedToDebt =
            requestedAmountBase < repayment.outstandingBase ? requestedAmountBase : repayment.outstandingBase;

        repayment.repaidBase = payerBal < cappedToDebt ? payerBal : cappedToDebt;
        repayment.remainingBase = repayment.outstandingBase - repayment.repaidBase;
    }

    function getBadDebtRepaymentRecipient() external view returns (address) {
        return _resolvedBadDebtRepaymentRecipient();
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET CONFIG READS
    //////////////////////////////////////////////////////////////*/

    function getMarket(uint256 marketId) external view returns (PerpMarketRegistry.Market memory) {
        return _requireMarketExists(marketId);
    }

    function getRiskConfig(uint256 marketId) external view returns (PerpMarketRegistry.RiskConfig memory) {
        _requireMarketExists(marketId);
        return _getRiskConfig(marketId);
    }

    function getLiquidationConfig(uint256 marketId) external view returns (PerpMarketRegistry.LiquidationConfig memory) {
        _requireMarketExists(marketId);
        return _getLiquidationConfig(marketId);
    }

    function getFundingConfig(uint256 marketId) external view returns (PerpMarketRegistry.FundingConfig memory) {
        _requireMarketExists(marketId);
        return _getFundingConfig(marketId);
    }

    function getSettlementAsset(uint256 marketId) external view returns (address) {
        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);
        return m.settlementAsset;
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION CORE VIEWS
    //////////////////////////////////////////////////////////////*/

    function isLiquidatable(address trader) public view returns (bool) {
        if (address(_riskModule) == address(0)) return false;

        IPerpRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        if (r.maintenanceMarginBase == 0) return false;
        if (r.equityBase <= 0) return true;

        return _marginRatioBpsFromState(r.equityBase, r.maintenanceMarginBase) < BPS;
    }

    /// @notice Legacy fallback liquidation defaults stored on the engine.
    function getLiquidationFallbackParams() external view returns (LiquidationPolicyView memory cfg) {
        cfg.closeFactorBps = liquidationCloseFactorBps;
        cfg.penaltyBps = liquidationPenaltyBps;
        cfg.priceSpreadBps = liquidationPriceSpreadBps;
        cfg.minImprovementBps = minLiquidationImprovementBps;
        cfg.oracleMaxDelay = liquidationOracleMaxDelay;
    }

    /// @notice Effective liquidation policy resolved for one market.
    function getEffectiveLiquidationParams(uint256 marketId) public view returns (LiquidationPolicyView memory cfg) {
        _requireMarketExists(marketId);

        cfg.closeFactorBps = _liquidationCloseFactorBpsForMarket(marketId);
        cfg.penaltyBps = _liquidationPenaltyBpsForMarket(marketId);
        cfg.priceSpreadBps = _liquidationPriceSpreadBpsForMarket(marketId);
        cfg.minImprovementBps = _minLiquidationImprovementBpsForMarket(marketId);
        cfg.oracleMaxDelay = _liquidationOracleMaxDelayForMarket(marketId);
    }

    /// @notice Backward-compatible alias.
    /// @dev Returns fallback defaults, not the effective per-market policy.
    function getLiquidationParams() external view returns (LiquidationPolicyView memory cfg) {
        cfg.closeFactorBps = liquidationCloseFactorBps;
        cfg.penaltyBps = liquidationPenaltyBps;
        cfg.priceSpreadBps = liquidationPriceSpreadBps;
        cfg.minImprovementBps = minLiquidationImprovementBps;
        cfg.oracleMaxDelay = liquidationOracleMaxDelay;
    }

    function previewInsuranceCoverage(uint256 requestedBaseValue)
        external
        view
        returns (InsuranceCoveragePreview memory p)
    {
        p.baseToken = _baseCollateralToken();
        p.requestedBase = requestedBaseValue;
        p.insuranceFundConfigured = insuranceFund != address(0);

        if (!p.insuranceFundConfigured || requestedBaseValue == 0) {
            return p;
        }

        uint256 bal = _collateralVault.balances(insuranceFund, p.baseToken);
        p.previewCoveredBase = bal < requestedBaseValue ? bal : requestedBaseValue;
    }

    function previewLiquidation(address trader, uint256 marketId, uint128 requestedCloseSize1e8)
        external
        view
        returns (LiquidationPreview memory p)
    {
        p.requestedCloseSize1e8 = requestedCloseSize1e8;
        p.isLiquidatable = isLiquidatable(trader);
        if (!p.isLiquidatable) return p;

        Position memory pos = _positions[trader][marketId];
        if (pos.size1e8 == 0) return p;

        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);

        (uint256 closeFactorBps, uint256 penaltyBps, uint256 priceSpreadBps,,) =
            _loadEffectiveLiquidationParams(marketId);

        p.maxClosableSize1e8 = _boundedLiquidationSize1e8(pos.size1e8, 0, closeFactorBps);

        uint256 mark = _getMarkPrice1e8(marketId);
        uint256 liqPrice = _liquidationPrice1e8FromMark(pos.size1e8, mark, priceSpreadBps);
        uint128 size = _boundedLiquidationSize1e8(pos.size1e8, requestedCloseSize1e8, closeFactorBps);

        if (size == 0) return p;

        uint256 closedNotional1e8 = Math.mulDiv(uint256(size), liqPrice, PRICE_1E8, Math.Rounding.Floor);
        uint256 closedNotionalBase = _settlementAmount1e8ToBase(m.settlementAsset, closedNotional1e8);
        uint256 penaltyBase = _liquidationPenaltyBaseValue(closedNotionalBase, penaltyBps);

        p.executedCloseSize1e8 = size;
        p.liquidationPrice1e8 = liqPrice;
        p.notionalClosed1e8 = closedNotional1e8;
        p.penaltyBase = penaltyBase;
    }

    function previewDetailedLiquidation(address trader, uint256 marketId, uint128 requestedCloseSize1e8)
        external
        view
        returns (DetailedLiquidationPreview memory p)
    {
        p.requestedCloseSize1e8 = requestedCloseSize1e8;
        p.insuranceFundConfigured = insuranceFund != address(0);

        if (address(_riskModule) == address(0)) {
            p.riskBefore.marginRatioBps = type(uint256).max;
            return p;
        }

        IPerpRiskModule.AccountRisk memory riskBefore = _riskModule.computeAccountRisk(trader);
        p.riskBefore = _liquidationRiskSnapshot(riskBefore);
        p.isLiquidatable = _accountRiskIsLiquidatable(riskBefore);
        if (!p.isLiquidatable) return p;

        Position memory pos = _positions[trader][marketId];
        p.hasPosition = pos.size1e8 != 0;
        if (!p.hasPosition) return p;

        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);

        (uint256 closeFactorBps, uint256 penaltyBps, uint256 priceSpreadBps,, uint32 oracleMaxDelay) =
            _loadEffectiveLiquidationParams(marketId);

        p.maxClosableSize1e8 = _boundedLiquidationSize1e8(pos.size1e8, 0, closeFactorBps);
        p.executableCloseSize1e8 = _boundedLiquidationSize1e8(pos.size1e8, requestedCloseSize1e8, closeFactorBps);
        if (p.executableCloseSize1e8 == 0) return p;

        p.markPrice1e8 = _getLiquidationMarkPrice1e8(marketId, oracleMaxDelay);
        p.liquidationPrice1e8 = _liquidationPrice1e8FromMark(pos.size1e8, p.markPrice1e8, priceSpreadBps);

        int256 deltaForTrader = pos.size1e8 > 0
            ? -_toInt256(uint256(p.executableCloseSize1e8))
            : _toInt256(uint256(p.executableCloseSize1e8));
        (, p.traderRealizedPnl1e8) = _computeNextPosition(
            pos, deltaForTrader, p.liquidationPrice1e8, _marketStates[marketId].cumulativeFundingRate1e18
        );

        p.notionalClosed1e8 =
            Math.mulDiv(uint256(p.executableCloseSize1e8), p.liquidationPrice1e8, PRICE_1E8, Math.Rounding.Floor);
        p.notionalClosedBase = _settlementAmount1e8ToBase(m.settlementAsset, p.notionalClosed1e8);
        p.penaltyTargetBase = _liquidationPenaltyBaseValue(p.notionalClosedBase, penaltyBps);

        if (p.penaltyTargetBase == 0) return p;

        uint256 settlementAssetSeizedNative;
        (p.seizerCoveredBase, settlementAssetSeizedNative) =
            _previewSeizerPenaltyCoverage(trader, m.settlementAsset, p.penaltyTargetBase, p.traderRealizedPnl1e8);

        uint256 remainingAfterSeizerBase = _remainingShortfall(p.penaltyTargetBase, p.seizerCoveredBase);
        p.settlementAssetCoveredBase = _previewSettlementAssetPenaltyCoverage(
            trader, m.settlementAsset, remainingAfterSeizerBase, p.traderRealizedPnl1e8, settlementAssetSeizedNative
        );

        if (p.traderRealizedPnl1e8 != 0) {
            int256 liquidatorRealizedPnl1e8 = _checkedSubInt256(0, p.traderRealizedPnl1e8);
            p.realizedCashflowBase = _settlementAmount1e8ToBase(
                m.settlementAsset, _absInt256(_checkedSubInt256(liquidatorRealizedPnl1e8, p.traderRealizedPnl1e8))
            );
        }

        uint256 remainingAfterCollateralBase = _remainingShortfall(
            remainingAfterSeizerBase,
            p.settlementAssetCoveredBase
        );
        p.insuranceCoveredBase = _previewInsuranceCoverageBase(remainingAfterCollateralBase);
        p.residualShortfallBase = _remainingShortfall(remainingAfterCollateralBase, p.insuranceCoveredBase);
        p.residualBadDebtPreviewBase = p.residualShortfallBase;
    }

    function _liquidationRiskSnapshot(IPerpRiskModule.AccountRisk memory risk)
        internal
        pure
        returns (LiquidationRiskSnapshot memory snapshot)
    {
        snapshot.equityBase = risk.equityBase;
        snapshot.maintenanceMarginBase = risk.maintenanceMarginBase;
        snapshot.initialMarginBase = risk.initialMarginBase;
        snapshot.marginRatioBps = _marginRatioBpsFromState(risk.equityBase, risk.maintenanceMarginBase);
    }

    function _accountRiskIsLiquidatable(IPerpRiskModule.AccountRisk memory risk) internal pure returns (bool) {
        if (risk.maintenanceMarginBase == 0) return false;
        if (risk.equityBase <= 0) return true;
        return _marginRatioBpsFromState(risk.equityBase, risk.maintenanceMarginBase) < BPS;
    }

    function _getLiquidationMarkPrice1e8(uint256 marketId, uint32 oracleMaxDelay)
        internal
        view
        returns (uint256 markPrice1e8)
    {
        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);
        IOracle o = _marketOracle(m);

        {
            (bool success, bytes memory data) = address(o).staticcall(
                abi.encodeWithSignature("getPriceSafe(address,address)", m.underlying, m.settlementAsset)
            );

            if (success && data.length >= 96) {
                (uint256 safePrice, uint256 safeUpdatedAt, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
                if (safeOk && safePrice != 0) {
                    if (oracleMaxDelay != 0) {
                        if (safeUpdatedAt == 0) revert OraclePriceStale();
                        if (safeUpdatedAt > block.timestamp) revert OraclePriceStale();
                        if (block.timestamp - safeUpdatedAt > uint256(oracleMaxDelay)) revert OraclePriceStale();
                    }
                    return safePrice;
                }
            }
        }

        (uint256 px, uint256 updatedAt) = o.getPrice(m.underlying, m.settlementAsset);
        if (px == 0) revert OraclePriceUnavailable();
        if (oracleMaxDelay != 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (updatedAt > block.timestamp) revert OraclePriceStale();
            if (block.timestamp - updatedAt > uint256(oracleMaxDelay)) revert OraclePriceStale();
        }
        return px;
    }

    function _previewSeizerPenaltyCoverage(
        address trader,
        address settlementAsset,
        uint256 penaltyTargetBase,
        int256 traderRealizedPnl1e8
    )
        internal
        view
        returns (uint256 coveredBase, uint256 settlementAssetSeizedNative)
    {
        if (penaltyTargetBase == 0 || address(_collateralSeizer) == address(0)) return (0, 0);

        address[] memory tokens;
        uint256[] memory amounts;
        uint256 plannedCoveredBase;

        try _collateralSeizer.computeSeizurePlan(trader, penaltyTargetBase) returns (
            address[] memory tokensOut,
            uint256[] memory amountsOut,
            uint256 baseCovered
        ) {
            if (tokensOut.length != amountsOut.length || tokensOut.length == 0 || baseCovered == 0) {
                return (0, 0);
            }

            tokens = tokensOut;
            amounts = amountsOut;
            plannedCoveredBase = baseCovered;
        } catch {
            return (0, 0);
        }

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint256 plannedAmount = amounts[i];
            if (token == address(0) || plannedAmount == 0) continue;

            uint256 bal = token == settlementAsset
                ? _previewSettlementAssetBalanceAfterRealized(trader, settlementAsset, traderRealizedPnl1e8)
                : _collateralVault.balances(trader, token);
            uint256 previewAmount = plannedAmount <= bal ? plannedAmount : bal;
            if (previewAmount == 0) continue;

            try _collateralSeizer.previewEffectiveBaseValue(token, previewAmount) returns (
                uint256,
                uint256 effectiveBaseFloor,
                bool okPreview
            ) {
                if (okPreview && effectiveBaseFloor != 0) {
                    coveredBase = _addChecked(coveredBase, effectiveBaseFloor);
                    if (token == settlementAsset) {
                        settlementAssetSeizedNative = _addChecked(settlementAssetSeizedNative, previewAmount);
                    }
                }
            } catch {}
        }

        if (coveredBase > plannedCoveredBase) coveredBase = plannedCoveredBase;
        if (coveredBase > penaltyTargetBase) coveredBase = penaltyTargetBase;
    }

    function _previewSettlementAssetBalanceAfterRealized(
        address trader,
        address settlementAsset,
        int256 traderRealizedPnl1e8
    ) internal view returns (uint256 availableNative) {
        availableNative = _collateralVault.balances(trader, settlementAsset);

        int256 liquidatorRealizedPnl1e8 = _checkedSubInt256(0, traderRealizedPnl1e8);
        int256 netToLiquidator1e8 = _checkedSubInt256(liquidatorRealizedPnl1e8, traderRealizedPnl1e8);

        if (netToLiquidator1e8 > 0) {
            uint256 realizedPaidNative = _value1e8ToSettlementNative(settlementAsset, _absInt256(netToLiquidator1e8));
            availableNative = realizedPaidNative >= availableNative ? 0 : availableNative - realizedPaidNative;
        } else if (netToLiquidator1e8 < 0) {
            availableNative = _addChecked(
                availableNative,
                _value1e8ToSettlementNative(settlementAsset, _absInt256(netToLiquidator1e8))
            );
        }
    }

    function _previewSettlementAssetPenaltyCoverage(
        address trader,
        address settlementAsset,
        uint256 remainingBase,
        int256 traderRealizedPnl1e8,
        uint256 settlementAssetSeizedNative
    ) internal view returns (uint256 coveredBase) {
        if (remainingBase == 0) return 0;

        uint256 availableNative =
            _previewSettlementAssetBalanceAfterRealized(trader, settlementAsset, traderRealizedPnl1e8);

        if (settlementAssetSeizedNative >= availableNative) {
            availableNative = 0;
        } else {
            availableNative -= settlementAssetSeizedNative;
        }

        uint256 penaltyNative = _penaltySettlementNative(settlementAsset, remainingBase);
        if (penaltyNative == 0 || availableNative == 0) return 0;

        uint256 paidNative = penaltyNative <= availableNative ? penaltyNative : availableNative;
        coveredBase = settlementAsset == _baseToken() ? paidNative : _settlementNativeToBase(settlementAsset, paidNative);
        if (coveredBase > remainingBase) coveredBase = remainingBase;
    }

    function _previewInsuranceCoverageBase(uint256 requestedBase) internal view returns (uint256 coveredBase) {
        if (requestedBase == 0 || insuranceFund == address(0)) return 0;

        uint256 bal = _collateralVault.balances(insuranceFund, _baseToken());
        coveredBase = bal < requestedBase ? bal : requestedBase;
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE / POSITION VIEWS
    //////////////////////////////////////////////////////////////*/

    function getMarkPrice(uint256 marketId) public view returns (uint256) {
        return _getMarkPrice1e8(marketId);
    }

    function getUnrealizedPnl(address trader, uint256 marketId) public view returns (int256) {
        return _positionUnrealizedPnl1e8(trader, marketId, _getMarkPrice1e8(marketId));
    }

    function getPositionFundingAccrued(address trader, uint256 marketId) public view returns (int256) {
        return _positionFundingAccrued1e8(trader, marketId);
    }

    function getPositionNotional1e8(address trader, uint256 marketId) public view returns (uint256) {
        Position memory p = _positions[trader][marketId];
        if (p.size1e8 == 0) return 0;

        uint256 absSize = p.size1e8 >= 0 ? uint256(p.size1e8) : uint256(-p.size1e8);
        uint256 mark = _getMarkPrice1e8(marketId);
        return Math.mulDiv(absSize, mark, PRICE_1E8, Math.Rounding.Floor);
    }

    function getPositionDirection(address trader, uint256 marketId) external view returns (int8) {
        int256 size = _positions[trader][marketId].size1e8;
        if (size > 0) return 1;
        if (size < 0) return -1;
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNT AGGREGATION
    //////////////////////////////////////////////////////////////*/

    function getAccountUnrealizedPnl(address trader) public view returns (int256 total) {
        uint256[] memory markets = traderMarkets[trader];

        for (uint256 i = 0; i < markets.length; i++) {
            total += getUnrealizedPnl(trader, markets[i]);
        }
    }

    function getAccountFunding(address trader) public view returns (int256 total) {
        uint256[] memory markets = traderMarkets[trader];

        for (uint256 i = 0; i < markets.length; i++) {
            total += getPositionFundingAccrued(trader, markets[i]);
        }
    }

    function getAccountNetPnl(address trader) public view returns (int256) {
        return getAccountUnrealizedPnl(trader) - getAccountFunding(trader);
    }

    function getAccountPnlBreakdown(address trader) external view returns (AccountPnlBreakdown memory b) {
        b.unrealizedPnl1e8 = getAccountUnrealizedPnl(trader);
        b.fundingAccrued1e8 = getAccountFunding(trader);
        b.netPnl1e8 = b.unrealizedPnl1e8 - b.fundingAccrued1e8;
    }

    function getAccountExposureBreakdown(address trader)
        external
        view
        returns (AccountExposureBreakdown memory b)
    {
        uint256[] memory markets = traderMarkets[trader];
        b.marketsCount = markets.length;

        for (uint256 i = 0; i < markets.length; i++) {
            uint256 marketId = markets[i];
            Position memory p = _positions[trader][marketId];
            if (p.size1e8 == 0) continue;

            uint256 absSize = p.size1e8 >= 0 ? uint256(p.size1e8) : uint256(-p.size1e8);
            uint256 mark = _getMarkPrice1e8(marketId);
            uint256 notional1e8 = Math.mulDiv(absSize, mark, PRICE_1E8, Math.Rounding.Floor);

            b.grossNotional1e8 += notional1e8;
            if (p.size1e8 > 0) {
                b.longNotional1e8 += notional1e8;
            } else {
                b.shortNotional1e8 += notional1e8;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        RISK PASSTHROUGH
    //////////////////////////////////////////////////////////////*/

    function getAccountRisk(address trader) external view returns (IPerpRiskModule.AccountRisk memory) {
        if (address(_riskModule) == address(0)) {
            return IPerpRiskModule.AccountRisk(0, 0, 0);
        }

        return _riskModule.computeAccountRisk(trader);
    }

    function getMarginRatioBps(address trader) external view returns (uint256) {
        if (address(_riskModule) == address(0)) return type(uint256).max;

        IPerpRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        return _marginRatioBpsFromState(r.equityBase, r.maintenanceMarginBase);
    }

    function getFreeCollateral(address trader) external view returns (int256) {
        if (address(_riskModule) == address(0)) return 0;
        return _riskModule.computeFreeCollateral(trader);
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET METRICS
    //////////////////////////////////////////////////////////////*/

    function getMarketOpenInterest(uint256 marketId) external view returns (uint256 longOI, uint256 shortOI) {
        MarketState memory s = _marketStates[marketId];
        return (s.longOpenInterest1e8, s.shortOpenInterest1e8);
    }

    function getMarketSkew(uint256 marketId) external view returns (int256) {
        MarketState memory s = _marketStates[marketId];

        if (s.longOpenInterest1e8 >= s.shortOpenInterest1e8) {
            return int256(s.longOpenInterest1e8 - s.shortOpenInterest1e8);
        }

        return -int256(s.shortOpenInterest1e8 - s.longOpenInterest1e8);
    }
}
