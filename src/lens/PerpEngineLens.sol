// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {ICollateralSeizer} from "../liquidation/ICollateralSeizer.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IPerpRiskModule} from "../perp/PerpEngineStorage.sol";
import {PerpEngineTypes} from "../perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../perp/PerpMarketRegistry.sol";

interface IPerpEngineLensSource {
    function marketRegistry() external view returns (address);
    function collateralVault() external view returns (address);
    function oracle() external view returns (address);
    function riskModule() external view returns (address);
    function collateralSeizer() external view returns (address);
    function insuranceFund() external view returns (address);
    function feeRecipient() external view returns (address);
    function liquidationCloseFactorBps() external view returns (uint256);
    function liquidationPenaltyBps() external view returns (uint256);
    function liquidationPriceSpreadBps() external view returns (uint256);
    function minLiquidationImprovementBps() external view returns (uint256);
    function liquidationOracleMaxDelay() external view returns (uint32);
    function positions(address trader, uint256 marketId) external view returns (PerpEngineTypes.Position memory);
    function marketState(uint256 marketId) external view returns (PerpEngineTypes.MarketState memory);
    function getTraderMarketsLength(address trader) external view returns (uint256);
    function getTraderMarketsSlice(address trader, uint256 start, uint256 end) external view returns (uint256[] memory);
    function getPositionSize(address trader, uint256 marketId) external view returns (int256);
    function getMarkPrice(uint256 marketId) external view returns (uint256);
    function getUnrealizedPnl(address trader, uint256 marketId) external view returns (int256);
    function getPositionFundingAccrued(address trader, uint256 marketId) external view returns (int256);
    function getRiskConfig(uint256 marketId) external view returns (PerpMarketRegistry.RiskConfig memory);
    function getSettlementAsset(uint256 marketId) external view returns (address);
    function getResidualBadDebt(address trader) external view returns (uint256);
}

interface IPerpRiskModuleBaseView {
    function baseCollateralToken() external view returns (address);
}

/// @notice Read-only PerpEngine diagnostics and UX previews.
/// @dev This lens owns no protocol state and duplicates preview-only calculations from the core.
contract PerpEngineLens is PerpEngineTypes {
    struct AccountPnlBreakdown {
        int256 unrealizedPnl1e8;
        int256 fundingAccrued1e8;
        int256 netPnl1e8;
    }

    struct AccountExposureBreakdown {
        uint256 marketsCount;
        uint256 grossNotional1e8;
        uint256 longNotional1e8;
        uint256 shortNotional1e8;
    }

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

    function getPerpSolvencyState(address perpEngine, address trader)
        external
        view
        returns (uint256 residualBadDebtBase, bool hasOpenPositions, bool liquidatable)
    {
        IPerpEngineLensSource engine = _engine(perpEngine);
        residualBadDebtBase = engine.getResidualBadDebt(trader);
        hasOpenPositions = engine.getTraderMarketsLength(trader) != 0;
        liquidatable = _isLiquidatable(engine, trader);
    }

    function getPerpAccountStatus(address perpEngine, address trader)
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
        IPerpEngineLensSource engine = _engine(perpEngine);
        residualBadDebtBase = engine.getResidualBadDebt(trader);
        hasOpenPositions = engine.getTraderMarketsLength(trader) != 0;
        liquidatable = _isLiquidatable(engine, trader);
        reduceOnly = residualBadDebtBase != 0;
        canIncrease = residualBadDebtBase == 0;
    }

    function getPerpLiquidationState(address perpEngine, address trader)
        external
        view
        returns (PerpLiquidationState memory s)
    {
        IPerpEngineLensSource engine = _engine(perpEngine);
        s.residualBadDebtBase = engine.getResidualBadDebt(trader);
        s.reduceOnly = s.residualBadDebtBase != 0;
        s.canIncreaseExposure = s.residualBadDebtBase == 0;

        address risk = engine.riskModule();
        if (risk == address(0)) {
            s.marginRatioBps = type(uint256).max;
            return s;
        }

        IPerpRiskModule.AccountRisk memory r = IPerpRiskModule(risk).computeAccountRisk(trader);
        s.marginRatioBps = _marginRatioBpsFromState(r.equityBase, r.maintenanceMarginBase);
        s.liquidatable = _accountRiskIsLiquidatable(r);
    }

    function previewResidualBadDebtRepayment(
        address perpEngine,
        address payer,
        address trader,
        uint256 requestedAmountBase
    ) external view returns (BadDebtRepayment memory repayment) {
        IPerpEngineLensSource engine = _engine(perpEngine);
        repayment.requestedBase = requestedAmountBase;
        repayment.outstandingBase = engine.getResidualBadDebt(trader);

        if (requestedAmountBase == 0 || repayment.outstandingBase == 0 || payer == address(0)) {
            repayment.remainingBase = repayment.outstandingBase;
            return repayment;
        }

        address baseToken = _baseToken(engine);
        uint256 payerBal = CollateralVault(engine.collateralVault()).balances(payer, baseToken);
        uint256 cappedToDebt =
            requestedAmountBase < repayment.outstandingBase ? requestedAmountBase : repayment.outstandingBase;

        repayment.repaidBase = payerBal < cappedToDebt ? payerBal : cappedToDebt;
        repayment.remainingBase = repayment.outstandingBase - repayment.repaidBase;
    }

    function getBadDebtRepaymentRecipient(address perpEngine) external view returns (address recipient) {
        IPerpEngineLensSource engine = _engine(perpEngine);
        recipient = engine.insuranceFund();
        if (recipient == address(0)) recipient = engine.feeRecipient();
    }

    function getLiquidationFallbackParams(address perpEngine) external view returns (LiquidationPolicyView memory cfg) {
        IPerpEngineLensSource engine = _engine(perpEngine);
        cfg.closeFactorBps = engine.liquidationCloseFactorBps();
        cfg.penaltyBps = engine.liquidationPenaltyBps();
        cfg.priceSpreadBps = engine.liquidationPriceSpreadBps();
        cfg.minImprovementBps = engine.minLiquidationImprovementBps();
        cfg.oracleMaxDelay = engine.liquidationOracleMaxDelay();
    }

    function getEffectiveLiquidationParams(address perpEngine, uint256 marketId)
        public
        view
        returns (LiquidationPolicyView memory cfg)
    {
        (cfg.closeFactorBps, cfg.penaltyBps, cfg.priceSpreadBps, cfg.minImprovementBps, cfg.oracleMaxDelay) =
            _loadEffectiveLiquidationParams(_engine(perpEngine), marketId);
    }

    function getLiquidationParams(address perpEngine) external view returns (LiquidationPolicyView memory cfg) {
        return this.getLiquidationFallbackParams(perpEngine);
    }

    function previewInsuranceCoverage(address perpEngine, uint256 requestedBaseValue)
        external
        view
        returns (InsuranceCoveragePreview memory p)
    {
        IPerpEngineLensSource engine = _engine(perpEngine);
        p.baseToken = _baseToken(engine);
        p.requestedBase = requestedBaseValue;
        p.insuranceFundConfigured = engine.insuranceFund() != address(0);

        if (!p.insuranceFundConfigured || requestedBaseValue == 0) return p;

        uint256 bal = CollateralVault(engine.collateralVault()).balances(engine.insuranceFund(), p.baseToken);
        p.previewCoveredBase = bal < requestedBaseValue ? bal : requestedBaseValue;
    }

    function previewLiquidation(address perpEngine, address trader, uint256 marketId, uint128 requestedCloseSize1e8)
        external
        view
        returns (LiquidationPreview memory p)
    {
        IPerpEngineLensSource engine = _engine(perpEngine);
        p.requestedCloseSize1e8 = requestedCloseSize1e8;
        p.isLiquidatable = _isLiquidatable(engine, trader);
        if (!p.isLiquidatable) return p;

        Position memory pos = engine.positions(trader, marketId);
        if (pos.size1e8 == 0) return p;

        (uint256 closeFactorBps, uint256 penaltyBps, uint256 priceSpreadBps,,) =
            _loadEffectiveLiquidationParams(engine, marketId);

        p.maxClosableSize1e8 = _boundedLiquidationSize1e8(pos.size1e8, 0, closeFactorBps);

        uint256 mark = engine.getMarkPrice(marketId);
        uint256 liqPrice = _liquidationPrice1e8FromMark(pos.size1e8, mark, priceSpreadBps);
        uint128 size = _boundedLiquidationSize1e8(pos.size1e8, requestedCloseSize1e8, closeFactorBps);
        if (size == 0) return p;

        uint256 closedNotional1e8 = Math.mulDiv(uint256(size), liqPrice, PRICE_1E8, Math.Rounding.Floor);
        uint256 closedNotionalBase =
            _settlementAmount1e8ToBase(engine, engine.getSettlementAsset(marketId), closedNotional1e8);

        p.executedCloseSize1e8 = size;
        p.liquidationPrice1e8 = liqPrice;
        p.notionalClosed1e8 = closedNotional1e8;
        p.penaltyBase = _liquidationPenaltyBaseValue(closedNotionalBase, penaltyBps);
    }

    function previewDetailedLiquidation(
        address perpEngine,
        address trader,
        uint256 marketId,
        uint128 requestedCloseSize1e8
    ) external view returns (DetailedLiquidationPreview memory p) {
        IPerpEngineLensSource engine = _engine(perpEngine);
        p.requestedCloseSize1e8 = requestedCloseSize1e8;
        p.insuranceFundConfigured = engine.insuranceFund() != address(0);

        address riskModule = engine.riskModule();
        if (riskModule == address(0)) {
            p.riskBefore.marginRatioBps = type(uint256).max;
            return p;
        }

        IPerpRiskModule.AccountRisk memory riskBefore = IPerpRiskModule(riskModule).computeAccountRisk(trader);
        p.riskBefore = _liquidationRiskSnapshot(riskBefore);
        p.isLiquidatable = _accountRiskIsLiquidatable(riskBefore);
        if (!p.isLiquidatable) return p;

        Position memory pos = engine.positions(trader, marketId);
        p.hasPosition = pos.size1e8 != 0;
        if (!p.hasPosition) return p;

        (uint256 closeFactorBps, uint256 penaltyBps, uint256 priceSpreadBps,, uint32 oracleMaxDelay) =
            _loadEffectiveLiquidationParams(engine, marketId);

        p.maxClosableSize1e8 = _boundedLiquidationSize1e8(pos.size1e8, 0, closeFactorBps);
        p.executableCloseSize1e8 = _boundedLiquidationSize1e8(pos.size1e8, requestedCloseSize1e8, closeFactorBps);
        if (p.executableCloseSize1e8 == 0) return p;

        p.markPrice1e8 = _getLiquidationMarkPrice1e8(engine, marketId, oracleMaxDelay);
        p.liquidationPrice1e8 = _liquidationPrice1e8FromMark(pos.size1e8, p.markPrice1e8, priceSpreadBps);

        MarketState memory state = engine.marketState(marketId);
        p.traderRealizedPnl1e8 =
            _realizedPnlForClose(pos, p.executableCloseSize1e8, p.liquidationPrice1e8, state.cumulativeFundingRate1e18);

        address settlementAsset = engine.getSettlementAsset(marketId);
        p.notionalClosed1e8 =
            Math.mulDiv(uint256(p.executableCloseSize1e8), p.liquidationPrice1e8, PRICE_1E8, Math.Rounding.Floor);
        p.notionalClosedBase = _settlementAmount1e8ToBase(engine, settlementAsset, p.notionalClosed1e8);
        p.penaltyTargetBase = _liquidationPenaltyBaseValue(p.notionalClosedBase, penaltyBps);
        if (p.penaltyTargetBase == 0) return p;

        uint256 settlementAssetSeizedNative;
        (p.seizerCoveredBase, settlementAssetSeizedNative) =
            _previewSeizerPenaltyCoverage(engine, trader, settlementAsset, p.penaltyTargetBase, p.traderRealizedPnl1e8);

        uint256 remainingAfterSeizerBase = _remainingShortfall(p.penaltyTargetBase, p.seizerCoveredBase);
        p.settlementAssetCoveredBase = _previewSettlementAssetPenaltyCoverage(
            engine,
            trader,
            settlementAsset,
            remainingAfterSeizerBase,
            p.traderRealizedPnl1e8,
            settlementAssetSeizedNative
        );

        if (p.traderRealizedPnl1e8 != 0) {
            int256 liquidatorRealizedPnl1e8 = _checkedSubInt256(0, p.traderRealizedPnl1e8);
            p.realizedCashflowBase = _settlementAmount1e8ToBase(
                engine, settlementAsset, _absInt256(_checkedSubInt256(liquidatorRealizedPnl1e8, p.traderRealizedPnl1e8))
            );
        }

        uint256 remainingAfterCollateralBase =
            _remainingShortfall(remainingAfterSeizerBase, p.settlementAssetCoveredBase);
        p.insuranceCoveredBase = _previewInsuranceCoverageBase(engine, remainingAfterCollateralBase);
        p.residualShortfallBase = _remainingShortfall(remainingAfterCollateralBase, p.insuranceCoveredBase);
        p.residualBadDebtPreviewBase = p.residualShortfallBase;
    }

    function getPositionNotional1e8(address perpEngine, address trader, uint256 marketId)
        external
        view
        returns (uint256)
    {
        IPerpEngineLensSource engine = _engine(perpEngine);
        Position memory p = engine.positions(trader, marketId);
        if (p.size1e8 == 0) return 0;
        return Math.mulDiv(_absInt256(p.size1e8), engine.getMarkPrice(marketId), PRICE_1E8, Math.Rounding.Floor);
    }

    function getPositionDirection(address perpEngine, address trader, uint256 marketId) external view returns (int8) {
        int256 size = _engine(perpEngine).getPositionSize(trader, marketId);
        if (size > 0) return 1;
        if (size < 0) return -1;
        return 0;
    }

    function getAccountUnrealizedPnl(address perpEngine, address trader) public view returns (int256 total) {
        IPerpEngineLensSource engine = _engine(perpEngine);
        uint256[] memory markets = _traderMarkets(engine, trader);
        for (uint256 i = 0; i < markets.length; i++) {
            total += engine.getUnrealizedPnl(trader, markets[i]);
        }
    }

    function getAccountFunding(address perpEngine, address trader) public view returns (int256 total) {
        IPerpEngineLensSource engine = _engine(perpEngine);
        uint256[] memory markets = _traderMarkets(engine, trader);
        for (uint256 i = 0; i < markets.length; i++) {
            total += engine.getPositionFundingAccrued(trader, markets[i]);
        }
    }

    function getAccountNetPnl(address perpEngine, address trader) public view returns (int256) {
        return getAccountUnrealizedPnl(perpEngine, trader) - getAccountFunding(perpEngine, trader);
    }

    function getAccountPnlBreakdown(address perpEngine, address trader)
        external
        view
        returns (AccountPnlBreakdown memory b)
    {
        b.unrealizedPnl1e8 = getAccountUnrealizedPnl(perpEngine, trader);
        b.fundingAccrued1e8 = getAccountFunding(perpEngine, trader);
        b.netPnl1e8 = b.unrealizedPnl1e8 - b.fundingAccrued1e8;
    }

    function getAccountExposureBreakdown(address perpEngine, address trader)
        external
        view
        returns (AccountExposureBreakdown memory b)
    {
        IPerpEngineLensSource engine = _engine(perpEngine);
        uint256[] memory markets = _traderMarkets(engine, trader);
        b.marketsCount = markets.length;

        for (uint256 i = 0; i < markets.length; i++) {
            Position memory p = engine.positions(trader, markets[i]);
            if (p.size1e8 == 0) continue;

            uint256 notional1e8 =
                Math.mulDiv(_absInt256(p.size1e8), engine.getMarkPrice(markets[i]), PRICE_1E8, Math.Rounding.Floor);
            b.grossNotional1e8 += notional1e8;
            if (p.size1e8 > 0) b.longNotional1e8 += notional1e8;
            else b.shortNotional1e8 += notional1e8;
        }
    }

    function getAccountRisk(address perpEngine, address trader)
        external
        view
        returns (IPerpRiskModule.AccountRisk memory)
    {
        address riskModule = _engine(perpEngine).riskModule();
        if (riskModule == address(0)) return IPerpRiskModule.AccountRisk(0, 0, 0);
        return IPerpRiskModule(riskModule).computeAccountRisk(trader);
    }

    function getMarginRatioBps(address perpEngine, address trader) external view returns (uint256) {
        address riskModule = _engine(perpEngine).riskModule();
        if (riskModule == address(0)) return type(uint256).max;
        IPerpRiskModule.AccountRisk memory r = IPerpRiskModule(riskModule).computeAccountRisk(trader);
        return _marginRatioBpsFromState(r.equityBase, r.maintenanceMarginBase);
    }

    function getFreeCollateral(address perpEngine, address trader) external view returns (int256) {
        address riskModule = _engine(perpEngine).riskModule();
        if (riskModule == address(0)) return 0;
        return IPerpRiskModule(riskModule).computeFreeCollateral(trader);
    }

    function getMarketOpenInterest(address perpEngine, uint256 marketId)
        external
        view
        returns (uint256 longOI, uint256 shortOI)
    {
        MarketState memory s = _engine(perpEngine).marketState(marketId);
        return (s.longOpenInterest1e8, s.shortOpenInterest1e8);
    }

    function getMarketSkew(address perpEngine, uint256 marketId) external view returns (int256) {
        MarketState memory s = _engine(perpEngine).marketState(marketId);
        if (s.longOpenInterest1e8 >= s.shortOpenInterest1e8) {
            return int256(s.longOpenInterest1e8 - s.shortOpenInterest1e8);
        }
        return -int256(s.shortOpenInterest1e8 - s.longOpenInterest1e8);
    }

    function _engine(address perpEngine) internal pure returns (IPerpEngineLensSource engine) {
        if (perpEngine == address(0)) revert ZeroAddress();
        return IPerpEngineLensSource(perpEngine);
    }

    function _traderMarkets(IPerpEngineLensSource engine, address trader) internal view returns (uint256[] memory) {
        return engine.getTraderMarketsSlice(trader, 0, engine.getTraderMarketsLength(trader));
    }

    function _isLiquidatable(IPerpEngineLensSource engine, address trader) internal view returns (bool) {
        address risk = engine.riskModule();
        if (risk == address(0)) return false;

        IPerpRiskModule.AccountRisk memory r = IPerpRiskModule(risk).computeAccountRisk(trader);
        return _accountRiskIsLiquidatable(r);
    }

    function _loadEffectiveLiquidationParams(IPerpEngineLensSource engine, uint256 marketId)
        internal
        view
        returns (
            uint256 closeFactorBps,
            uint256 penaltyBps,
            uint256 priceSpreadBps,
            uint256 minImprovementBps,
            uint32 oracleMaxDelay
        )
    {
        PerpMarketRegistry registry = PerpMarketRegistry(engine.marketRegistry());
        try registry.getLiquidationConfig(marketId) returns (PerpMarketRegistry.LiquidationConfig memory cfg) {
            closeFactorBps = cfg.closeFactorBps != 0 ? uint256(cfg.closeFactorBps) : engine.liquidationCloseFactorBps();
            priceSpreadBps = uint256(cfg.priceSpreadBps);
            minImprovementBps = uint256(cfg.minImprovementBps);
            oracleMaxDelay = cfg.oracleMaxDelay;
        } catch {
            closeFactorBps = engine.liquidationCloseFactorBps();
            priceSpreadBps = engine.liquidationPriceSpreadBps();
            minImprovementBps = engine.minLiquidationImprovementBps();
            oracleMaxDelay = engine.liquidationOracleMaxDelay();
        }

        PerpMarketRegistry.RiskConfig memory riskCfg = engine.getRiskConfig(marketId);
        penaltyBps = riskCfg.liquidationPenaltyBps != 0
            ? uint256(riskCfg.liquidationPenaltyBps)
            : engine.liquidationPenaltyBps();

        _validateLiquidationParams(closeFactorBps, penaltyBps, priceSpreadBps, minImprovementBps, oracleMaxDelay);
    }

    function _validateLiquidationParams(
        uint256 closeFactorBps,
        uint256 penaltyBps,
        uint256 priceSpreadBps,
        uint256 minImprovementBps,
        uint256 oracleMaxDelay
    ) internal pure {
        if (closeFactorBps == 0) revert LiquidationCloseFactorZero();
        if (closeFactorBps > BPS) revert LiquidationParamsInvalid();
        if (penaltyBps > BPS) revert LiquidationPenaltyTooLarge();
        if (priceSpreadBps > BPS) revert LiquidationParamsInvalid();
        if (minImprovementBps > BPS) revert LiquidationParamsInvalid();
        if (oracleMaxDelay > 3600) revert LiquidationParamsInvalid();
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

    function _getLiquidationMarkPrice1e8(IPerpEngineLensSource engine, uint256 marketId, uint32 oracleMaxDelay)
        internal
        view
        returns (uint256)
    {
        PerpMarketRegistry.Market memory m = PerpMarketRegistry(engine.marketRegistry()).getMarket(marketId);
        if (!m.exists) revert UnknownMarket();
        IOracle o = m.oracle == address(0) ? IOracle(engine.oracle()) : IOracle(m.oracle);

        (bool success, bytes memory data) = address(o)
            .staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", m.underlying, m.settlementAsset));
        if (success && data.length >= 96) {
            (uint256 safePrice, uint256 safeUpdatedAt, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
            if (safeOk && safePrice != 0) {
                _validateOracleFreshness(safeUpdatedAt, oracleMaxDelay);
                return safePrice;
            }
        }

        (uint256 px, uint256 updatedAt) = o.getPrice(m.underlying, m.settlementAsset);
        if (px == 0) revert OraclePriceUnavailable();
        _validateOracleFreshness(updatedAt, oracleMaxDelay);
        return px;
    }

    function _validateOracleFreshness(uint256 updatedAt, uint32 oracleMaxDelay) internal view {
        if (oracleMaxDelay == 0) return;
        if (updatedAt == 0) revert OraclePriceStale();
        if (updatedAt > block.timestamp) revert OraclePriceStale();
        if (block.timestamp - updatedAt > uint256(oracleMaxDelay)) revert OraclePriceStale();
    }

    function _previewSeizerPenaltyCoverage(
        IPerpEngineLensSource engine,
        address trader,
        address settlementAsset,
        uint256 penaltyTargetBase,
        int256 traderRealizedPnl1e8
    ) internal view returns (uint256 coveredBase, uint256 settlementAssetSeizedNative) {
        address seizer = engine.collateralSeizer();
        if (penaltyTargetBase == 0 || seizer == address(0)) return (0, 0);

        try ICollateralSeizer(seizer).computeSeizurePlan(trader, penaltyTargetBase) returns (
            address[] memory tokens, uint256[] memory amounts, uint256 plannedCoveredBase
        ) {
            if (tokens.length != amounts.length || tokens.length == 0 || plannedCoveredBase == 0) return (0, 0);

            for (uint256 i = 0; i < tokens.length; i++) {
                address token = tokens[i];
                uint256 plannedAmount = amounts[i];
                if (token == address(0) || plannedAmount == 0) continue;

                uint256 bal = token == settlementAsset
                    ? _previewSettlementAssetBalanceAfterRealized(engine, trader, settlementAsset, traderRealizedPnl1e8)
                    : CollateralVault(engine.collateralVault()).balances(trader, token);
                uint256 previewAmount = plannedAmount <= bal ? plannedAmount : bal;
                if (previewAmount == 0) continue;

                try ICollateralSeizer(seizer).previewEffectiveBaseValue(token, previewAmount) returns (
                    uint256, uint256 effectiveBaseFloor, bool okPreview
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
        } catch {
            return (0, 0);
        }
    }

    function _previewSettlementAssetBalanceAfterRealized(
        IPerpEngineLensSource engine,
        address trader,
        address settlementAsset,
        int256 traderRealizedPnl1e8
    ) internal view returns (uint256 availableNative) {
        availableNative = CollateralVault(engine.collateralVault()).balances(trader, settlementAsset);

        int256 liquidatorRealizedPnl1e8 = _checkedSubInt256(0, traderRealizedPnl1e8);
        int256 netToLiquidator1e8 = _checkedSubInt256(liquidatorRealizedPnl1e8, traderRealizedPnl1e8);

        if (netToLiquidator1e8 > 0) {
            uint256 realizedPaidNative =
                _value1e8ToSettlementNative(engine, settlementAsset, _absInt256(netToLiquidator1e8));
            availableNative = realizedPaidNative >= availableNative ? 0 : availableNative - realizedPaidNative;
        } else if (netToLiquidator1e8 < 0) {
            availableNative = _addChecked(
                availableNative, _value1e8ToSettlementNative(engine, settlementAsset, _absInt256(netToLiquidator1e8))
            );
        }
    }

    function _previewSettlementAssetPenaltyCoverage(
        IPerpEngineLensSource engine,
        address trader,
        address settlementAsset,
        uint256 remainingBase,
        int256 traderRealizedPnl1e8,
        uint256 settlementAssetSeizedNative
    ) internal view returns (uint256 coveredBase) {
        if (remainingBase == 0) return 0;

        uint256 availableNative =
            _previewSettlementAssetBalanceAfterRealized(engine, trader, settlementAsset, traderRealizedPnl1e8);
        availableNative =
            settlementAssetSeizedNative >= availableNative ? 0 : availableNative - settlementAssetSeizedNative;

        uint256 penaltyNative = _penaltySettlementNative(engine, settlementAsset, remainingBase);
        if (penaltyNative == 0 || availableNative == 0) return 0;

        uint256 paidNative = penaltyNative <= availableNative ? penaltyNative : availableNative;
        coveredBase = settlementAsset == _baseToken(engine)
            ? paidNative
            : _settlementNativeToBase(engine, settlementAsset, paidNative);
        if (coveredBase > remainingBase) coveredBase = remainingBase;
    }

    function _previewInsuranceCoverageBase(IPerpEngineLensSource engine, uint256 requestedBase)
        internal
        view
        returns (uint256 coveredBase)
    {
        address fund = engine.insuranceFund();
        if (requestedBase == 0 || fund == address(0)) return 0;

        uint256 bal = CollateralVault(engine.collateralVault()).balances(fund, _baseToken(engine));
        coveredBase = bal < requestedBase ? bal : requestedBase;
    }

    function _realizedPnlForClose(
        Position memory oldPos,
        uint128 closeSize1e8,
        uint256 executionPrice1e8,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 realizedPnl1e8) {
        uint256 absOld = _absInt256(oldPos.size1e8);
        uint256 closeAbs = uint256(closeSize1e8);
        int256 closeSizeSigned = oldPos.size1e8 > 0 ? _toInt256(closeAbs) : -_toInt256(closeAbs);
        int256 removedBasis1e8 = (oldPos.openNotional1e8 * _toInt256(closeAbs)) / _toInt256(absOld);
        int256 closedMarkValue1e8 = _signedMarkValue1e8(closeSizeSigned, executionPrice1e8);
        int256 closedFunding1e8 = _closedFundingPortion1e8(oldPos, closeAbs, currentCumulativeFundingRate1e18);
        realizedPnl1e8 = _checkedSubInt256(_checkedSubInt256(closedMarkValue1e8, removedBasis1e8), closedFunding1e8);
    }

    function _closedFundingPortion1e8(Position memory oldPos, uint256 closeAbs, int256 currentCumulativeFundingRate1e18)
        internal
        pure
        returns (int256 closedFunding1e8)
    {
        if (oldPos.size1e8 == 0 || closeAbs == 0) return 0;
        int256 totalAccruedFunding1e8 =
            _fundingPayment1e8(oldPos.size1e8, currentCumulativeFundingRate1e18, oldPos.lastCumulativeFundingRate1e18);
        closedFunding1e8 = (totalAccruedFunding1e8 * _toInt256(closeAbs)) / _toInt256(_absInt256(oldPos.size1e8));
    }

    function _baseToken(IPerpEngineLensSource engine) internal view returns (address) {
        address risk = engine.riskModule();
        if (risk == address(0)) revert RiskModuleNotSet();
        address base = IPerpRiskModuleBaseView(risk).baseCollateralToken();
        if (base == address(0)) revert RiskModuleNotSet();
        return base;
    }

    function _requireSettlementAssetConfigured(IPerpEngineLensSource engine, address settlementAsset)
        internal
        view
        returns (CollateralVault.CollateralTokenConfig memory cfg)
    {
        cfg = CollateralVault(engine.collateralVault()).getCollateralConfig(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert InvalidMarket();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert MathOverflow();
    }

    function _value1e8ToSettlementNative(IPerpEngineLensSource engine, address settlementAsset, uint256 amount1e8)
        internal
        view
        returns (uint256 amountNative)
    {
        CollateralVault.CollateralTokenConfig memory cfg = _requireSettlementAssetConfigured(engine, settlementAsset);
        amountNative = Math.mulDiv(amount1e8, _pow10(uint256(cfg.decimals)), PRICE_1E8, Math.Rounding.Floor);
    }

    function _settlementNativeToBase(
        IPerpEngineLensSource engine,
        address settlementAsset,
        uint256 settlementAmountNative
    ) internal view returns (uint256 baseValue) {
        if (settlementAmountNative == 0) return 0;

        address baseToken = _baseToken(engine);
        CollateralVault vault = CollateralVault(engine.collateralVault());
        CollateralVault.CollateralTokenConfig memory baseCfg = vault.getCollateralConfig(baseToken);
        CollateralVault.CollateralTokenConfig memory setCfg = vault.getCollateralConfig(settlementAsset);
        if (!baseCfg.isSupported || baseCfg.decimals == 0) revert InvalidMarket();
        if (!setCfg.isSupported || setCfg.decimals == 0) revert InvalidMarket();
        if (settlementAsset == baseToken) return settlementAmountNative;

        (uint256 px, bool ok) = _tryGetMarkPrice1e8FromPair(engine, settlementAsset, baseToken);
        if (!ok || px == 0) revert OraclePriceUnavailable();

        uint256 tmp = Math.mulDiv(settlementAmountNative, px, PRICE_1E8, Math.Rounding.Floor);
        if (baseCfg.decimals == setCfg.decimals) return tmp;
        if (baseCfg.decimals > setCfg.decimals) {
            return Math.mulDiv(tmp, _pow10(uint256(baseCfg.decimals - setCfg.decimals)), 1, Math.Rounding.Floor);
        }
        return tmp / _pow10(uint256(setCfg.decimals - baseCfg.decimals));
    }

    function _settlementAmount1e8ToBase(IPerpEngineLensSource engine, address settlementAsset, uint256 amount1e8)
        internal
        view
        returns (uint256)
    {
        if (amount1e8 == 0) return 0;
        return _settlementNativeToBase(
            engine, settlementAsset, _value1e8ToSettlementNative(engine, settlementAsset, amount1e8)
        );
    }

    function _penaltySettlementNative(IPerpEngineLensSource engine, address settlementAsset, uint256 penaltyBase)
        internal
        view
        returns (uint256)
    {
        address baseToken = _baseToken(engine);
        if (penaltyBase == 0) return 0;
        if (settlementAsset == baseToken) return penaltyBase;

        (uint256 px, bool ok) = _tryGetMarkPrice1e8FromPair(engine, settlementAsset, baseToken);
        if (!ok || px == 0) revert OraclePriceUnavailable();
        return _baseValueToTokenAmount(engine, settlementAsset, penaltyBase, px);
    }

    function _baseValueToTokenAmount(IPerpEngineLensSource engine, address token, uint256 baseValue, uint256 price1e8)
        internal
        view
        returns (uint256 tokenAmount)
    {
        CollateralVault vault = CollateralVault(engine.collateralVault());
        CollateralVault.CollateralTokenConfig memory baseCfg = vault.getCollateralConfig(_baseToken(engine));
        CollateralVault.CollateralTokenConfig memory tokCfg = vault.getCollateralConfig(token);
        if (!baseCfg.isSupported || baseCfg.decimals == 0) revert InvalidMarket();
        if (!tokCfg.isSupported || tokCfg.decimals == 0) revert InvalidMarket();

        uint256 tmp = Math.mulDiv(baseValue, PRICE_1E8, price1e8, Math.Rounding.Floor);
        if (baseCfg.decimals == tokCfg.decimals) return tmp;
        if (tokCfg.decimals > baseCfg.decimals) {
            return Math.mulDiv(tmp, _pow10(uint256(tokCfg.decimals - baseCfg.decimals)), 1, Math.Rounding.Floor);
        }
        return tmp / _pow10(uint256(baseCfg.decimals - tokCfg.decimals));
    }

    function _tryGetMarkPrice1e8FromPair(IPerpEngineLensSource engine, address base, address quote)
        internal
        view
        returns (uint256 price1e8, bool ok)
    {
        IOracle o = IOracle(engine.oracle());
        (bool success, bytes memory data) =
            address(o).staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", base, quote));
        if (success && data.length >= 96) {
            (uint256 px,, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
            if (safeOk && px != 0) return (px, true);
        }

        try o.getPrice(base, quote) returns (uint256 px, uint256) {
            if (px == 0) return (0, false);
            return (px, true);
        } catch {
            return (0, false);
        }
    }
}
