// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";
import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IRiskModule} from "../risk/IRiskModule.sol";
import {IMarginEngineState} from "../risk/IMarginEngineState.sol";
import {MarginEngineTypes} from "../margin/MarginEngineTypes.sol";

interface IMarginEngineLensSource is IMarginEngineState {
    function baseCollateralToken() external view returns (address);
    function baseMaintenanceMarginPerContract() external view returns (uint256);
    function imFactorBps() external view returns (uint256);
    function liquidationThresholdBps() external view returns (uint256);
    function liquidationPenaltyBps() external view returns (uint256);
    function liquidationCloseFactorBps() external view returns (uint256);
    function liquidationPriceSpreadBps() external view returns (uint256);
    function minLiquidationPriceBpsOfIntrinsic() external view returns (uint256);
    function liquidationOracleMaxDelay() external view returns (uint32);
    function settlementPaused() external view returns (bool);
    function insuranceFund() external view returns (address);
    function feesManager() external view returns (IFeesManager);
    function feeRecipient() external view returns (address);
    function isAccountSettled(uint256 optionId, address trader) external view returns (bool);
    function seriesCollected(uint256 optionId) external view returns (uint256);
    function seriesPaid(uint256 optionId) external view returns (uint256);
    function seriesBadDebt(uint256 optionId) external view returns (uint256);
}

/// @title MarginEngineLens
/// @notice Read-only diagnostics and preview helper for the options MarginEngine.
/// @dev Owns no protocol state. All data is read from MarginEngine and other modules through external views.
contract MarginEngineLens is MarginEngineTypes {
    struct AccountState {
        int256 equityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
        int256 freeCollateralBase;
        uint256 marginRatioBps;
        uint256 openSeriesCount;
        uint256 totalShortOpenContracts;
        bool liquidatable;
    }

    struct ProtocolSettlementSliceTotals {
        uint256 seriesCount;
        uint256 totalCollected;
        uint256 totalPaid;
        uint256 totalBadDebt;
    }

    struct OptionsLiquidationPreview {
        bool liquidatable;
        uint256 marginRatioBeforeBps;
        int256 equityBeforeBase;
        uint256 maintenanceMarginBeforeBase;
        uint256 initialMarginBeforeBase;
        uint256 totalShortContracts;
        uint256 maxCloseContracts;
        uint256 totalContractsPreviewed;
        uint128[] executedQuantities;
        uint256[] pricePerContract;
        address[] settlementAssets;
        uint256[] cashRequestedByAsset;
        uint256 cashAssetCount;
        uint256 penaltyBase;
    }

    struct SettlementRiskSnapshot {
        int256 equityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
        uint256 marginRatioBps;
    }

    struct DetailedSettlementPreview {
        uint256 optionId;
        address settlementAsset;
        bool seriesActive;
        bool seriesExpired;
        bool settlementPaused;
        bool settlementPriceSet;
        uint64 settlementFinalizedAt;
        uint256 settlementPrice;
        bool proposalExists;
        uint256 proposedSettlementPrice;
        uint64 proposalTimestamp;
        uint256 settlementFinalityDelay;
        bool proposalReady;
        bool settlementReady;
        bool accountSettled;
        int128 positionQuantity;
        uint256 payoffPerContract;
        int256 pnl;
        uint256 grossSettlementAmount;
        bool isShortLiability;
        uint256 shortLiabilityAmount;
        uint256 traderSettlementAssetBalance;
        uint256 settlementSinkBalance;
        uint256 collateralCoveragePreview;
        uint256 insuranceCoveragePreview;
        uint256 residualShortfallPreview;
        uint256 residualBadDebtPreview;
        bool grossSettlementAmountBaseAvailable;
        uint256 grossSettlementAmountBase;
        bool accountCashflowDeltaBaseAvailable;
        int256 accountCashflowDeltaBase;
        bool riskAfterAvailable;
        SettlementRiskSnapshot riskBefore;
        SettlementRiskSnapshot riskAfter;
    }

    function getAccountState(address marginEngine, address trader) external view returns (AccountState memory s) {
        IMarginEngineLensSource engine = IMarginEngineLensSource(marginEngine);
        IRiskModule riskModule = IRiskModule(engine.riskModule());

        s.openSeriesCount = engine.getTraderSeriesLength(trader);
        s.totalShortOpenContracts = engine.totalShortContracts(trader);

        if (address(riskModule) == address(0)) {
            s.marginRatioBps = type(uint256).max;
            return s;
        }

        IRiskModule.AccountRisk memory r = riskModule.computeAccountRisk(trader);
        s.equityBase = r.equityBase;
        s.maintenanceMarginBase = r.maintenanceMarginBase;
        s.initialMarginBase = r.initialMarginBase;
        s.freeCollateralBase = riskModule.computeFreeCollateral(trader);
        s.marginRatioBps = _marginRatioBpsFromRisk(r.equityBase, r.maintenanceMarginBase);
        s.liquidatable =
            (r.maintenanceMarginBase != 0) && (r.equityBase <= 0 || s.marginRatioBps < engine.liquidationThresholdBps());
    }

    /// @notice Deterministic preview of account settlement. Diagnostic only; settlement execution remains in MarginEngine.
    function previewAccountSettlement(address marginEngine, uint256 optionId, address trader)
        external
        view
        returns (SettlementPreview memory p)
    {
        IMarginEngineLensSource engine = IMarginEngineLensSource(marginEngine);
        OptionProductRegistry registry = OptionProductRegistry(engine.optionRegistry());
        OptionProductRegistry.OptionSeries memory series = registry.getSeries(optionId);
        (uint256 settlementPrice, bool isSet) = registry.getSettlementInfo(optionId);

        bool expired = block.timestamp >= series.expiry;
        if (!expired || !isSet || settlementPrice == 0) {
            p.isSettled = engine.isAccountSettled(optionId, trader);
            return p;
        }

        int128 qty = engine.getPositionQuantity(trader, optionId);
        if (qty == 0) {
            p.isSettled = engine.isAccountSettled(optionId, trader);
            p.canSettle = true;
            return p;
        }

        (, int256 pnl) = _previewAccountSettlementPnl(engine, series, qty, settlementPrice);
        p = _previewSettlementResolution(engine, optionId, trader, pnl, series.settlementAsset);
    }

    /// @notice Rich settlement preview. Diagnostic only; it duplicates read-only math from the state-changing path.
    function previewDetailedSettlement(address marginEngine, uint256 optionId, address trader)
        external
        view
        returns (DetailedSettlementPreview memory p)
    {
        IMarginEngineLensSource engine = IMarginEngineLensSource(marginEngine);
        OptionProductRegistry registry = OptionProductRegistry(engine.optionRegistry());
        CollateralVault vault = CollateralVault(engine.collateralVault());
        OptionProductRegistry.OptionSeries memory series = registry.getSeries(optionId);
        (uint256 settlementPrice, bool isSet) = registry.getSettlementInfo(optionId);
        (uint256 proposedPrice, uint64 proposedAt, bool proposalExists) = registry.getSettlementProposal(optionId);

        p.optionId = optionId;
        p.settlementAsset = series.settlementAsset;
        p.seriesActive = series.isActive;
        p.seriesExpired = block.timestamp >= series.expiry;
        p.settlementPaused = engine.settlementPaused() || registry.settlementPaused();
        p.settlementPriceSet = isSet && settlementPrice != 0;
        p.settlementFinalizedAt = registry.getSettlementFinalizedAt(optionId);
        p.settlementPrice = settlementPrice;
        p.proposalExists = proposalExists;
        p.proposedSettlementPrice = proposedPrice;
        p.proposalTimestamp = proposedAt;
        p.settlementFinalityDelay = registry.settlementFinalityDelay();
        p.proposalReady = proposalExists && block.timestamp >= uint256(proposedAt) + p.settlementFinalityDelay;
        p.accountSettled = engine.isAccountSettled(optionId, trader);
        p.positionQuantity = engine.getPositionQuantity(trader, optionId);

        IRiskModule riskModule = IRiskModule(engine.riskModule());
        if (address(riskModule) != address(0)) {
            IRiskModule.AccountRisk memory beforeRisk = riskModule.computeAccountRisk(trader);
            p.riskBefore = _settlementRiskSnapshot(beforeRisk);
        } else {
            p.riskBefore.marginRatioBps = type(uint256).max;
        }

        p.settlementReady = p.seriesExpired && p.settlementPriceSet && !p.settlementPaused && !p.accountSettled;

        if (!p.settlementReady || p.positionQuantity == 0) {
            p.riskAfter = p.riskBefore;
            p.riskAfterAvailable = true;
            return p;
        }

        (p.payoffPerContract, p.pnl) =
            _previewAccountSettlementPnl(engine, series, p.positionQuantity, settlementPrice);

        SettlementPreview memory resolution =
            _previewSettlementResolution(engine, optionId, trader, p.pnl, series.settlementAsset);
        p.grossSettlementAmount = resolution.grossAmount;
        p.isShortLiability = p.pnl < 0;
        p.shortLiabilityAmount = p.isShortLiability ? resolution.grossAmount : 0;
        p.traderSettlementAssetBalance = vault.balances(trader, series.settlementAsset);

        if (p.isShortLiability) {
            p.collateralCoveragePreview = resolution.collectibleAmount;
        } else {
            address sink = engine.insuranceFund() != address(0) ? engine.insuranceFund() : marginEngine;
            p.settlementSinkBalance = vault.balances(sink, series.settlementAsset);

            if (sink == engine.insuranceFund() && engine.insuranceFund() != address(0)) {
                p.insuranceCoveragePreview = resolution.payableFromSettlementSink;
            } else {
                p.collateralCoveragePreview = resolution.payableFromSettlementSink;
                p.insuranceCoveragePreview = resolution.insurancePreview;
            }
        }

        p.residualShortfallPreview = resolution.residualBadDebtPreview;
        p.residualBadDebtPreview = resolution.residualBadDebtPreview;

        (p.grossSettlementAmountBase, p.grossSettlementAmountBaseAvailable) =
            _previewSettlementAmountBase(engine, series.settlementAsset, p.grossSettlementAmount);

        int256 cashflowDelta = _previewSettlementCashflowDelta(resolution, p.isShortLiability);
        uint256 absCashflow = cashflowDelta >= 0
            ? SafeCast.toUint256(cashflowDelta)
            : SafeCast.toUint256(-cashflowDelta);
        (uint256 cashflowDeltaBaseAbs, bool cashflowDeltaBaseAvailable) =
            _previewSettlementAmountBase(engine, series.settlementAsset, absCashflow);
        if (cashflowDeltaBaseAvailable) {
            p.accountCashflowDeltaBaseAvailable = true;
            p.accountCashflowDeltaBase = cashflowDelta >= 0
                ? SafeCast.toInt256(cashflowDeltaBaseAbs)
                : -SafeCast.toInt256(cashflowDeltaBaseAbs);
        }

        (p.riskAfter, p.riskAfterAvailable) = _previewRiskAfterSettlement(
            engine, p.riskBefore, p.positionQuantity, p.accountCashflowDeltaBase, p.accountCashflowDeltaBaseAvailable
        );
    }

    function previewLiquidation(address marginEngine, address trader, uint256[] calldata optionIds, uint128[] calldata quantities)
        external
        view
        returns (OptionsLiquidationPreview memory p)
    {
        if (trader == address(0)) revert ZeroAddress();
        if (optionIds.length == 0 || optionIds.length != quantities.length) revert LengthMismatch();

        IMarginEngineLensSource engine = IMarginEngineLensSource(marginEngine);
        IRiskModule riskModule = IRiskModule(engine.riskModule());
        p.executedQuantities = new uint128[](optionIds.length);
        p.pricePerContract = new uint256[](optionIds.length);
        p.settlementAssets = new address[](optionIds.length);
        p.cashRequestedByAsset = new uint256[](optionIds.length);

        p.marginRatioBeforeBps = type(uint256).max;
        if (address(riskModule) == address(0)) return p;

        IRiskModule.AccountRisk memory riskBefore = riskModule.computeAccountRisk(trader);
        p.equityBeforeBase = riskBefore.equityBase;
        p.maintenanceMarginBeforeBase = riskBefore.maintenanceMarginBase;
        p.initialMarginBeforeBase = riskBefore.initialMarginBase;
        p.marginRatioBeforeBps = _marginRatioBpsFromRisk(riskBefore.equityBase, riskBefore.maintenanceMarginBase);
        p.liquidatable = (riskBefore.maintenanceMarginBase != 0)
            && (riskBefore.equityBase <= 0 || p.marginRatioBeforeBps < engine.liquidationThresholdBps());
        if (!p.liquidatable) return p;

        p.totalShortContracts = engine.totalShortContracts(trader);
        if (p.totalShortContracts == 0 || engine.liquidationCloseFactorBps() == 0) return p;

        p.maxCloseContracts =
            Math.mulDiv(p.totalShortContracts, engine.liquidationCloseFactorBps(), BPS, Math.Rounding.Floor);
        if (p.maxCloseContracts == 0) p.maxCloseContracts = 1;

        OptionProductRegistry registry = OptionProductRegistry(engine.optionRegistry());
        for (uint256 i = 0; i < optionIds.length; i++) {
            if (p.totalContractsPreviewed >= p.maxCloseContracts) break;

            uint128 requestedQty = quantities[i];
            if (requestedQty == 0) continue;

            uint256 optionId = optionIds[i];
            OptionProductRegistry.OptionSeries memory s = registry.getSeries(optionId);
            _requireStandardContractSize(s);

            if (block.timestamp >= s.expiry) continue;
            _requireSettlementAssetConfigured(engine, s.settlementAsset);

            int128 traderQty = engine.getPositionQuantity(trader, optionId);
            if (traderQty >= 0) continue;

            uint256 traderShortAbs = _absInt128(traderQty);
            uint256 remainingAllowance = p.maxCloseContracts - p.totalContractsPreviewed;

            uint256 liqQtyU = uint256(requestedQty);
            if (liqQtyU > traderShortAbs) liqQtyU = traderShortAbs;
            if (liqQtyU > remainingAllowance) liqQtyU = remainingAllowance;
            if (liqQtyU == 0) continue;
            if (liqQtyU > uint256(uint128(type(int128).max))) revert QuantityTooLarge();

            uint128 liqQty = SafeCast.toUint128(liqQtyU);
            uint256 pricePerContract = _previewLiquidationPricePerContract(engine, s);
            uint256 requestedCash = _mulChecked(pricePerContract, uint256(liqQty));

            p.executedQuantities[i] = liqQty;
            p.pricePerContract[i] = pricePerContract;
            p.totalContractsPreviewed = _addChecked(p.totalContractsPreviewed, uint256(liqQty));

            bool found;
            for (uint256 k = 0; k < p.cashAssetCount; k++) {
                if (p.settlementAssets[k] == s.settlementAsset) {
                    p.cashRequestedByAsset[k] = _addChecked(p.cashRequestedByAsset[k], requestedCash);
                    found = true;
                    break;
                }
            }

            if (!found) {
                p.settlementAssets[p.cashAssetCount] = s.settlementAsset;
                p.cashRequestedByAsset[p.cashAssetCount] = requestedCash;
                p.cashAssetCount++;
            }
        }

        uint256 mmBase = _mulChecked(engine.baseMaintenanceMarginPerContract(), p.totalContractsPreviewed);
        p.penaltyBase = Math.mulDiv(mmBase, engine.liquidationPenaltyBps(), BPS, Math.Rounding.Floor);
    }

    function getProtocolSettlementAccountingSlice(address marginEngine, uint256 start, uint256 end)
        external
        view
        returns (ProtocolSettlementSliceTotals memory totals)
    {
        IMarginEngineLensSource engine = IMarginEngineLensSource(marginEngine);
        uint256[] memory optionIds = OptionProductRegistry(engine.optionRegistry()).getAllOptionIdsSlice(start, end);
        totals.seriesCount = optionIds.length;

        for (uint256 i = 0; i < optionIds.length; i++) {
            uint256 optionId = optionIds[i];
            totals.totalCollected = _addChecked(totals.totalCollected, engine.seriesCollected(optionId));
            totals.totalPaid = _addChecked(totals.totalPaid, engine.seriesPaid(optionId));
            totals.totalBadDebt = _addChecked(totals.totalBadDebt, engine.seriesBadDebt(optionId));
        }
    }

    function previewTradeFees(
        address marginEngine,
        uint256 optionId,
        uint128 quantity,
        uint128 price,
        address buyer,
        address seller,
        bool buyerIsMaker
    )
        external
        view
        returns (
            address settlementAsset,
            address recipient,
            uint256 premium,
            uint256 notionalImplicit,
            IFeesManager.FeeQuote memory buyerQuote,
            IFeesManager.FeeQuote memory sellerQuote
        )
    {
        if (buyer == address(0) || seller == address(0) || buyer == seller) revert InvalidTrade();
        if (quantity == 0 || price == 0) revert InvalidTrade();

        IMarginEngineLensSource engine = IMarginEngineLensSource(marginEngine);
        OptionProductRegistry.OptionSeries memory s =
            OptionProductRegistry(engine.optionRegistry()).getSeries(optionId);
        _requireStandardContractSize(s);
        _requireSettlementAssetConfigured(engine, s.settlementAsset);

        settlementAsset = s.settlementAsset;
        recipient = engine.feeRecipient();
        if (recipient == address(0)) recipient = engine.insuranceFund();
        premium = _mulChecked(uint256(quantity), uint256(price));
        notionalImplicit = _computeStrikeNotionalImplicit(engine, s, uint256(quantity));

        IFeesManager fm = engine.feesManager();
        if (address(fm) == address(0)) return (settlementAsset, recipient, premium, notionalImplicit, buyerQuote, sellerQuote);

        buyerQuote = fm.quoteFee(buyer, buyerIsMaker, premium, notionalImplicit);
        sellerQuote = fm.quoteFee(seller, !buyerIsMaker, premium, notionalImplicit);
    }

    function _previewPerContractPayoff(
        IMarginEngineLensSource engine,
        OptionProductRegistry.OptionSeries memory series,
        uint256 settlementPrice
    ) internal view returns (uint256 payoffPerContract) {
        _requireStandardContractSize(series);
        if (settlementPrice == 0) return 0;

        uint256 intrinsicPrice1e8 = _intrinsic1e8(series, settlementPrice);
        if (intrinsicPrice1e8 == 0) return 0;
        payoffPerContract = _price1e8ToSettlementUnits(engine, series.settlementAsset, intrinsicPrice1e8);
    }

    function _previewAccountSettlementPnl(
        IMarginEngineLensSource engine,
        OptionProductRegistry.OptionSeries memory series,
        int128 qty,
        uint256 settlementPrice
    ) internal view returns (uint256 payoffPerContract, int256 pnl) {
        _ensureQtyAllowed(qty);

        payoffPerContract = _previewPerContractPayoff(engine, series, settlementPrice);
        if (qty == 0 || payoffPerContract == 0) return (payoffPerContract, 0);

        int256 q = int256(qty);
        uint256 absQty = _absInt128(qty);
        uint256 amount = _mulChecked(absQty, payoffPerContract);
        if (amount > uint256(type(int256).max)) revert PnlOverflow();

        pnl = q >= 0 ? SafeCast.toInt256(amount) : -SafeCast.toInt256(amount);
    }

    function _previewSettlementResolution(
        IMarginEngineLensSource engine,
        uint256 optionId,
        address trader,
        int256 pnl,
        address settlementAsset
    ) internal view returns (SettlementPreview memory p) {
        p.pnl = pnl;
        p.isSettled = engine.isAccountSettled(optionId, trader);

        if (p.isSettled) return p;
        if (pnl == 0) {
            p.canSettle = true;
            return p;
        }

        CollateralVault vault = CollateralVault(engine.collateralVault());
        uint256 grossAmount = pnl > 0 ? SafeCast.toUint256(pnl) : SafeCast.toUint256(-pnl);
        p.grossAmount = grossAmount;

        if (pnl < 0) {
            uint256 traderBal = vault.balances(trader, settlementAsset);
            p.collectibleAmount = traderBal >= grossAmount ? grossAmount : traderBal;
            p.residualBadDebtPreview = grossAmount - p.collectibleAmount;
            p.canSettle = true;
            return p;
        }

        address insuranceFund = engine.insuranceFund();
        address sink = insuranceFund != address(0) ? insuranceFund : address(engine);
        uint256 sinkBal = vault.balances(sink, settlementAsset);
        p.payableFromSettlementSink = sinkBal >= grossAmount ? grossAmount : sinkBal;

        uint256 remainingAfterSink = grossAmount - p.payableFromSettlementSink;

        if (remainingAfterSink != 0 && insuranceFund != address(0) && sink != insuranceFund) {
            uint256 fundBal = vault.balances(insuranceFund, settlementAsset);
            p.insurancePreview = fundBal >= remainingAfterSink ? remainingAfterSink : fundBal;
            remainingAfterSink -= p.insurancePreview;
        }

        p.residualBadDebtPreview = remainingAfterSink;
        p.canSettle = true;
    }

    function _settlementRiskSnapshot(IRiskModule.AccountRisk memory risk)
        internal
        pure
        returns (SettlementRiskSnapshot memory snapshot)
    {
        snapshot.equityBase = risk.equityBase;
        snapshot.maintenanceMarginBase = risk.maintenanceMarginBase;
        snapshot.initialMarginBase = risk.initialMarginBase;
        snapshot.marginRatioBps = _marginRatioBpsFromRisk(risk.equityBase, risk.maintenanceMarginBase);
    }

    function _previewSettlementAmountBase(
        IMarginEngineLensSource engine,
        address settlementAsset,
        uint256 amountNative
    ) internal view returns (uint256 amountBase, bool available) {
        if (amountNative == 0) return (0, true);

        address base = engine.baseCollateralToken();
        if (base == address(0)) return (0, false);
        if (settlementAsset == base) return (amountNative, true);

        (uint256 px, uint256 updatedAt, bool ok) =
            IOracle(engine.oracle()).getPriceSafe(settlementAsset, base);
        if (!ok || px == 0) return (0, false);

        uint32 maxDelay = engine.liquidationOracleMaxDelay();
        if (maxDelay > 0) {
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > maxDelay) return (0, false);
        }

        return (_tokenAmountToBaseValueDown(engine, settlementAsset, amountNative, px), true);
    }

    function _previewShortRiskRelease(IMarginEngineLensSource engine, int128 qty)
        internal
        view
        returns (uint256 mmReleaseBase, uint256 imReleaseBase)
    {
        if (qty >= 0) return (0, 0);

        uint256 shortAbs = _absInt128(qty);
        mmReleaseBase = _mulChecked(shortAbs, engine.baseMaintenanceMarginPerContract());
        imReleaseBase = Math.mulDiv(mmReleaseBase, engine.imFactorBps(), BPS, Math.Rounding.Floor);
    }

    function _previewSettlementCashflowDelta(SettlementPreview memory settlementPreview, bool isShortLiability)
        internal
        pure
        returns (int256 cashflowDelta)
    {
        if (isShortLiability) {
            if (settlementPreview.collectibleAmount == 0) return 0;
            cashflowDelta = -SafeCast.toInt256(settlementPreview.collectibleAmount);
        } else {
            uint256 credited = settlementPreview.payableFromSettlementSink + settlementPreview.insurancePreview;
            if (credited == 0) return 0;
            cashflowDelta = SafeCast.toInt256(credited);
        }
    }

    function _previewRiskAfterSettlement(
        IMarginEngineLensSource engine,
        SettlementRiskSnapshot memory beforeRisk,
        int128 qty,
        int256 cashflowDeltaBase,
        bool cashflowDeltaBaseAvailable
    ) internal view returns (SettlementRiskSnapshot memory afterRisk, bool available) {
        (uint256 mmReleaseBase, uint256 imReleaseBase) = _previewShortRiskRelease(engine, qty);

        afterRisk.maintenanceMarginBase = beforeRisk.maintenanceMarginBase > mmReleaseBase
            ? beforeRisk.maintenanceMarginBase - mmReleaseBase
            : 0;
        afterRisk.initialMarginBase = beforeRisk.initialMarginBase > imReleaseBase
            ? beforeRisk.initialMarginBase - imReleaseBase
            : 0;

        if (!cashflowDeltaBaseAvailable) return (afterRisk, false);

        afterRisk.equityBase = beforeRisk.equityBase + cashflowDeltaBase;
        afterRisk.marginRatioBps = _marginRatioBpsFromRisk(afterRisk.equityBase, afterRisk.maintenanceMarginBase);
        return (afterRisk, true);
    }

    function _previewLiquidationPricePerContract(
        IMarginEngineLensSource engine,
        OptionProductRegistry.OptionSeries memory s
    ) internal view returns (uint256 pricePerContract) {
        _requireStandardContractSize(s);

        (uint256 spot, uint256 updatedAt, bool ok) = IOracle(engine.oracle()).getPriceSafe(s.underlying, s.settlementAsset);
        if (!ok || spot == 0) revert OraclePriceUnavailable();

        uint32 maxDelay = engine.liquidationOracleMaxDelay();
        if (maxDelay > 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (updatedAt > block.timestamp) revert OraclePriceStale();
            if (block.timestamp - updatedAt > maxDelay) revert OraclePriceStale();
        }

        uint256 intrinsicPrice1e8 = _intrinsic1e8(s, spot);
        uint256 liqPrice1e8 = intrinsicPrice1e8;

        if (intrinsicPrice1e8 > 0 && engine.minLiquidationPriceBpsOfIntrinsic() > 0) {
            uint256 floorPx = (intrinsicPrice1e8 * engine.minLiquidationPriceBpsOfIntrinsic()) / BPS;
            if (liqPrice1e8 < floorPx) liqPrice1e8 = floorPx;
        }

        if (engine.liquidationPriceSpreadBps() > 0) {
            liqPrice1e8 = (liqPrice1e8 * (BPS + engine.liquidationPriceSpreadBps())) / BPS;
        }

        pricePerContract = _price1e8ToSettlementUnits(engine, s.settlementAsset, liqPrice1e8);
    }

    function _computeStrikeNotionalImplicit(
        IMarginEngineLensSource engine,
        OptionProductRegistry.OptionSeries memory s,
        uint256 quantity
    ) internal view returns (uint256 notionalImplicit) {
        _requireStandardContractSize(s);
        if (quantity == 0) return 0;

        uint256 strikePerContractNative = _price1e8ToSettlementUnits(engine, s.settlementAsset, uint256(s.strike));
        notionalImplicit = _mulChecked(quantity, strikePerContractNative);
    }

    function _requireSettlementAssetConfigured(IMarginEngineLensSource engine, address settlementAsset) internal view {
        CollateralVault.CollateralTokenConfig memory cfg =
            CollateralVault(engine.collateralVault()).getCollateralConfig(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert SettlementAssetNotConfigured();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(settlementAsset);
    }

    function _price1e8ToSettlementUnits(
        IMarginEngineLensSource engine,
        address settlementAsset,
        uint256 value1e8
    ) internal view returns (uint256 valueNative) {
        CollateralVault.CollateralTokenConfig memory cfg =
            CollateralVault(engine.collateralVault()).getCollateralConfig(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert SettlementAssetNotConfigured();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(settlementAsset);

        uint256 scale = _pow10(uint256(cfg.decimals));
        valueNative = Math.mulDiv(value1e8, scale, PRICE_1E8, Math.Rounding.Floor);
    }

    function _tokenAmountToBaseValueDown(
        IMarginEngineLensSource engine,
        address token,
        uint256 tokenAmount,
        uint256 pxTokBase
    ) internal view returns (uint256 baseValue) {
        if (tokenAmount == 0) return 0;
        if (token == engine.baseCollateralToken()) return tokenAmount;

        CollateralVault vault = CollateralVault(engine.collateralVault());
        CollateralVault.CollateralTokenConfig memory baseCfg = vault.getCollateralConfig(engine.baseCollateralToken());
        CollateralVault.CollateralTokenConfig memory tokCfg = vault.getCollateralConfig(token);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) return 0;
        if (!tokCfg.isSupported || tokCfg.decimals == 0) return 0;
        if (uint256(baseCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(engine.baseCollateralToken());
        if (uint256(tokCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokDec = tokCfg.decimals;

        uint256 num = Math.mulDiv(tokenAmount, pxTokBase, PRICE_1E8, Math.Rounding.Floor);
        if (tokDec == baseDec) return num;

        if (baseDec > tokDec) {
            return _mulChecked(num, _pow10(uint256(baseDec - tokDec)));
        }

        return num / _pow10(uint256(tokDec - baseDec));
    }
}
