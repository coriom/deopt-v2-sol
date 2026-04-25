// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {IRiskModule} from "../risk/IRiskModule.sol";
import {IMarginEngineState} from "../risk/IMarginEngineState.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";

import {MarginEngineTrading} from "./MarginEngineTrading.sol";

/// @title MarginEngineViews
/// @notice Read-only surface for the options engine.
/// @dev
///  Intended wiring:
///   - MarginEngineViews inherits MarginEngineTrading so it can reuse
///     low-level pure/view helpers already present in the options stack
///   - MarginEngineOps then inherits MarginEngineViews
///
///  Responsibilities:
///   - expose IMarginEngineState reads
///   - expose account-level wrappers around RiskModule
///   - expose settlement accounting / settlement preview surfaces
///   - expose fee preview helpers
///   - expose protocol-level settlement accounting slices
///
///  Canonical conventions:
///   - risk outputs suffixed `Base` are denominated in native units of the protocol base collateral token
///   - settlement accounting amounts are denominated in settlement-asset native units
///   - margin ratios are in basis points
///
///  Design notes:
///   - settlement accounting is intentionally observable at the series level
///   - per-account settled cashflows are NOT fully stored onchain today, so this file
///     exposes a deterministic preview surface instead of inventing fake historical storage
///   - protocol-wide settlement accounting is exposed in paginated form to avoid unbounded scans
abstract contract MarginEngineViews is MarginEngineTrading {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Account-level risk / exposure state.
    /// @dev
    ///  - `equityBase`, `maintenanceMarginBase`, `initialMarginBase`, `freeCollateralBase`
    ///    are denominated in native units of the protocol base collateral token
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

    /// @notice Rich per-series settlement status view.
    /// @dev
    ///  - `settlementPrice` is normalized in 1e8
    ///  - `totalCollected`, `totalPaid`, `totalBadDebt`
    ///    are denominated in settlement-asset native units
    struct SeriesSettlementStatusView {
        uint256 optionId;
        bool isSettled;
        uint64 settledAt;
        uint256 settlementPrice;
        uint256 totalCollected;
        uint256 totalPaid;
        uint256 totalBadDebt;
    }

    struct SeriesSettlementProposalState {
        uint256 optionId;
        uint256 proposedPrice;
        uint64 proposedAt;
        bool exists;
    }

    /// @notice Aggregated protocol settlement accounting across a slice of option ids.
    /// @dev All totals are denominated in each series settlement-asset native units summed naively;
    ///      this is an accounting aggregation helper, not a cross-asset economic normalization.
    struct ProtocolSettlementSliceTotals {
        uint256 seriesCount;
        uint256 totalCollected;
        uint256 totalPaid;
        uint256 totalBadDebt;
    }

    struct LiquidationConfigView {
        uint256 liquidationThresholdBps;
        uint256 liquidationPenaltyBps;
        uint256 liquidationCloseFactorBps;
        uint256 minLiquidationImprovementBps;
        uint256 liquidationPriceSpreadBps;
        uint256 minLiquidationPriceBpsOfIntrinsic;
        uint32 liquidationOracleMaxDelay;
    }

    /// @notice Read-only liquidation preview for an options liquidation request.
    /// @dev
    ///  - risk fields are denominated in base-collateral native units
    ///  - `pricePerContract` and `cashRequestedByAsset` are settlement-asset native units
    ///  - `maxCloseContracts`, `totalContractsPreviewed`, and `executedQuantities` are raw option-contract counts
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

    /// @notice Account-risk style snapshot used by settlement previews.
    /// @dev All amounts are denominated in native units of the protocol base collateral token.
    struct SettlementRiskSnapshot {
        int256 equityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
        uint256 marginRatioBps;
    }

    /// @notice Rich read-only preview for option settlement and settlement-side shortfall paths.
    /// @dev
    ///  - settlement amounts are denominated in settlement-asset native units
    ///  - risk fields suffixed `Base` are denominated in native units of the protocol base collateral token
    ///  - `insuranceCoveragePreview` includes the insurance fund balance when the insurance fund is the canonical sink
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

    /// @notice Cached options-side risk config mirrored from RiskModule.
    /// @dev
    ///  - `baseMaintenanceMarginPerContract` is denominated in native units
    ///    of the protocol base collateral token
    struct RiskCacheView {
        address baseCollateralToken;
        uint256 baseMaintenanceMarginPerContract;
        uint256 imFactorBps;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL SETTLEMENT HELPERS
    //////////////////////////////////////////////////////////////*/

    function _previewPerContractPayoff(OptionProductRegistry.OptionSeries memory series, uint256 settlementPrice)
        internal
        view
        returns (uint256 payoffPerContract)
    {
        _requireStandardContractSize(series);
        if (settlementPrice == 0) return 0;

        uint256 intrinsicPrice1e8;
        if (series.isCall) {
            intrinsicPrice1e8 =
                settlementPrice > uint256(series.strike) ? (settlementPrice - uint256(series.strike)) : 0;
        } else {
            intrinsicPrice1e8 =
                uint256(series.strike) > settlementPrice ? (uint256(series.strike) - settlementPrice) : 0;
        }

        if (intrinsicPrice1e8 == 0) return 0;
        payoffPerContract = _price1e8ToSettlementUnits(series.settlementAsset, intrinsicPrice1e8);
    }

    function _previewAccountSettlementPnl(
        OptionProductRegistry.OptionSeries memory series,
        int128 qty,
        uint256 settlementPrice
    ) internal view returns (uint256 payoffPerContract, int256 pnl) {
        _ensureQtyAllowed(qty);

        payoffPerContract = _previewPerContractPayoff(series, settlementPrice);
        if (qty == 0 || payoffPerContract == 0) {
            return (payoffPerContract, 0);
        }

        int256 q = int256(qty);
        uint256 absQty = _absInt128(qty);

        uint256 amount = _mulChecked(absQty, payoffPerContract);
        if (amount > uint256(type(int256).max)) revert PnlOverflow();

        pnl = q >= 0 ? SafeCast.toInt256(amount) : -SafeCast.toInt256(amount);
    }

    function _previewSettlementResolution(
        uint256 optionId,
        address trader,
        int256 pnl,
        address settlementAsset
    ) internal view returns (SettlementPreview memory p) {
        p.pnl = pnl;
        p.isSettled = isAccountSettled[optionId][trader];

        if (p.isSettled) return p;
        if (pnl == 0) {
            p.canSettle = true;
            return p;
        }

        uint256 grossAmount = pnl > 0 ? SafeCast.toUint256(pnl) : SafeCast.toUint256(-pnl);
        p.grossAmount = grossAmount;

        if (pnl < 0) {
            uint256 traderBal = _collateralVault.balances(trader, settlementAsset);
            p.collectibleAmount = traderBal >= grossAmount ? grossAmount : traderBal;
            p.residualBadDebtPreview = grossAmount - p.collectibleAmount;
            p.canSettle = true;
            return p;
        }

        address sink = insuranceFund != address(0) ? insuranceFund : address(this);

        uint256 sinkBal = _collateralVault.balances(sink, settlementAsset);
        p.payableFromSettlementSink = sinkBal >= grossAmount ? grossAmount : sinkBal;

        uint256 remainingAfterSink = grossAmount - p.payableFromSettlementSink;

        if (remainingAfterSink != 0 && insuranceFund != address(0) && sink != insuranceFund) {
            uint256 fundBal = _collateralVault.balances(insuranceFund, settlementAsset);
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

    function _previewSettlementAmountBase(address settlementAsset, uint256 amountNative)
        internal
        view
        returns (uint256 amountBase, bool available)
    {
        if (amountNative == 0) return (0, true);

        address base = baseCollateralToken;
        if (base == address(0)) return (0, false);

        if (settlementAsset == base) {
            return (amountNative, true);
        }

        (uint256 px, uint256 updatedAt, bool ok) = _oracle.getPriceSafe(settlementAsset, base);
        if (!ok || px == 0) return (0, false);

        uint32 maxDelay = liquidationOracleMaxDelay;
        if (maxDelay > 0) {
            if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > maxDelay) return (0, false);
        }

        return (_tokenAmountToBaseValueDown(settlementAsset, amountNative, px), true);
    }

    function _previewShortRiskRelease(int128 qty) internal view returns (uint256 mmReleaseBase, uint256 imReleaseBase) {
        if (qty >= 0) return (0, 0);

        uint256 shortAbs = _absInt128(qty);
        mmReleaseBase = _mulChecked(shortAbs, baseMaintenanceMarginPerContract);
        imReleaseBase = Math.mulDiv(mmReleaseBase, imFactorBps, BPS, Math.Rounding.Floor);
    }

    function _previewSettlementCashflowDelta(
        SettlementPreview memory settlementPreview,
        bool isShortLiability
    ) internal pure returns (int256 cashflowDelta) {
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
        SettlementRiskSnapshot memory beforeRisk,
        int128 qty,
        int256 cashflowDeltaBase,
        bool cashflowDeltaBaseAvailable
    ) internal view returns (SettlementRiskSnapshot memory afterRisk, bool available) {
        (uint256 mmReleaseBase, uint256 imReleaseBase) = _previewShortRiskRelease(qty);

        afterRisk.maintenanceMarginBase = beforeRisk.maintenanceMarginBase > mmReleaseBase
            ? beforeRisk.maintenanceMarginBase - mmReleaseBase
            : 0;
        afterRisk.initialMarginBase = beforeRisk.initialMarginBase > imReleaseBase
            ? beforeRisk.initialMarginBase - imReleaseBase
            : 0;

        if (!cashflowDeltaBaseAvailable) {
            return (afterRisk, false);
        }

        afterRisk.equityBase = beforeRisk.equityBase + cashflowDeltaBase;
        afterRisk.marginRatioBps = _marginRatioBpsFromRisk(afterRisk.equityBase, afterRisk.maintenanceMarginBase);
        return (afterRisk, true);
    }

    function _previewLiquidationPricePerContract(OptionProductRegistry.OptionSeries memory s)
        internal
        view
        returns (uint256 pricePerContract)
    {
        _requireStandardContractSize(s);

        (uint256 spot, uint256 updatedAt, bool ok) = _oracle.getPriceSafe(s.underlying, s.settlementAsset);
        if (!ok || spot == 0) revert OraclePriceUnavailable();

        uint32 maxDelay = liquidationOracleMaxDelay;
        if (maxDelay > 0) {
            if (updatedAt == 0) revert OraclePriceStale();
            if (updatedAt > block.timestamp) revert OraclePriceStale();
            if (block.timestamp - updatedAt > maxDelay) revert OraclePriceStale();
        }

        uint256 intrinsicPrice1e8 = _intrinsic1e8(s, spot);
        uint256 liqPrice1e8 = intrinsicPrice1e8;

        if (intrinsicPrice1e8 > 0 && minLiquidationPriceBpsOfIntrinsic > 0) {
            uint256 floorPx = (intrinsicPrice1e8 * minLiquidationPriceBpsOfIntrinsic) / BPS;
            if (liqPrice1e8 < floorPx) liqPrice1e8 = floorPx;
        }

        if (liquidationPriceSpreadBps > 0) {
            liqPrice1e8 = (liqPrice1e8 * (BPS + liquidationPriceSpreadBps)) / BPS;
        }

        pricePerContract = _price1e8ToSettlementUnits(s.settlementAsset, liqPrice1e8);
    }

    /*//////////////////////////////////////////////////////////////
                          IMarginEngineState (required)
    //////////////////////////////////////////////////////////////*/

    function positions(address trader, uint256 optionId)
        external
        view
        override
        returns (IMarginEngineState.Position memory)
    {
        return _positionOf(trader, optionId);
    }

    /// @notice OPEN series only.
    function getTraderSeries(address trader) external view override returns (uint256[] memory) {
        return _getTraderSeriesInternal(trader);
    }

    function getTraderSeriesLength(address trader) external view override returns (uint256) {
        return _getTraderSeriesLengthInternal(trader);
    }

    function getTraderSeriesSlice(address trader, uint256 start, uint256 end)
        external
        view
        override
        returns (uint256[] memory slice)
    {
        return _getTraderSeriesSliceInternal(trader, start, end);
    }

    /*//////////////////////////////////////////////////////////////
                    IMarginEngineState (optional helpers)
    //////////////////////////////////////////////////////////////*/

    function optionRegistry() external view override returns (address) {
        return _optionRegistryAddress();
    }

    function collateralVault() external view override returns (address) {
        return _collateralVaultAddress();
    }

    function oracle() external view override returns (address) {
        return _oracleAddress();
    }

    function riskModule() external view override returns (address) {
        return _riskModuleAddress();
    }

    function getPositionQuantity(address trader, uint256 optionId) external view override returns (int128) {
        return _positionQuantityOf(trader, optionId);
    }

    function isOpenSeries(address trader, uint256 optionId) external view override returns (bool) {
        return _isOpenSeriesInternal(trader, optionId);
    }

    /*//////////////////////////////////////////////////////////////
                            ACCOUNT RISK VIEWS
    //////////////////////////////////////////////////////////////*/

    function getAccountRisk(address trader) public view returns (IRiskModule.AccountRisk memory risk) {
        if (address(_riskModule) == address(0)) {
            IRiskModule.AccountRisk memory empty;
            return empty;
        }
        return _riskModule.computeAccountRisk(trader);
    }

    function getFreeCollateral(address trader) public view returns (int256) {
        if (address(_riskModule) == address(0)) return 0;
        return _riskModule.computeFreeCollateral(trader);
    }

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        returns (IRiskModule.WithdrawPreview memory preview)
    {
        if (address(_riskModule) == address(0)) return preview;
        return _riskModule.previewWithdrawImpact(trader, token, amount);
    }

    function getMarginRatioBps(address trader) public view returns (uint256) {
        if (address(_riskModule) == address(0)) return type(uint256).max;
        IRiskModule.AccountRisk memory risk = _riskModule.computeAccountRisk(trader);
        return _marginRatioBpsFromRisk(risk.equityBase, risk.maintenanceMarginBase);
    }

    function isLiquidatable(address trader) public view returns (bool) {
        if (address(_riskModule) == address(0)) return false;

        IRiskModule.AccountRisk memory risk = _riskModule.computeAccountRisk(trader);
        if (risk.maintenanceMarginBase == 0) return false;
        if (risk.equityBase <= 0) return true;

        uint256 ratioBps = (SafeCast.toUint256(risk.equityBase) * BPS) / risk.maintenanceMarginBase;
        return ratioBps < liquidationThresholdBps;
    }

    function previewLiquidation(address trader, uint256[] calldata optionIds, uint128[] calldata quantities)
        external
        view
        returns (OptionsLiquidationPreview memory p)
    {
        if (trader == address(0)) revert ZeroAddress();
        if (optionIds.length == 0 || optionIds.length != quantities.length) revert LengthMismatch();

        p.executedQuantities = new uint128[](optionIds.length);
        p.pricePerContract = new uint256[](optionIds.length);
        p.settlementAssets = new address[](optionIds.length);
        p.cashRequestedByAsset = new uint256[](optionIds.length);

        p.marginRatioBeforeBps = type(uint256).max;
        if (address(_riskModule) == address(0)) return p;

        IRiskModule.AccountRisk memory riskBefore = _riskModule.computeAccountRisk(trader);
        p.equityBeforeBase = riskBefore.equityBase;
        p.maintenanceMarginBeforeBase = riskBefore.maintenanceMarginBase;
        p.initialMarginBeforeBase = riskBefore.initialMarginBase;
        p.marginRatioBeforeBps = _marginRatioBpsFromRisk(riskBefore.equityBase, riskBefore.maintenanceMarginBase);
        p.liquidatable = (riskBefore.maintenanceMarginBase != 0)
            && (riskBefore.equityBase <= 0 || p.marginRatioBeforeBps < liquidationThresholdBps);
        if (!p.liquidatable) return p;

        p.totalShortContracts = totalShortContracts[trader];
        if (p.totalShortContracts == 0 || liquidationCloseFactorBps == 0) return p;

        p.maxCloseContracts = Math.mulDiv(p.totalShortContracts, liquidationCloseFactorBps, BPS, Math.Rounding.Floor);
        if (p.maxCloseContracts == 0) p.maxCloseContracts = 1;

        for (uint256 i = 0; i < optionIds.length; i++) {
            if (p.totalContractsPreviewed >= p.maxCloseContracts) break;

            uint128 requestedQty = quantities[i];
            if (requestedQty == 0) continue;

            uint256 optionId = optionIds[i];
            OptionProductRegistry.OptionSeries memory s = _optionRegistry.getSeries(optionId);
            _requireStandardContractSize(s);

            if (block.timestamp >= s.expiry) continue;
            _requireSettlementAssetConfigured(s.settlementAsset);

            int128 traderQty = _positionQuantityOf(trader, optionId);
            if (traderQty >= 0) continue;

            uint256 traderShortAbs = _absInt128(traderQty);
            uint256 remainingAllowance = p.maxCloseContracts - p.totalContractsPreviewed;

            uint256 liqQtyU = uint256(requestedQty);
            if (liqQtyU > traderShortAbs) liqQtyU = traderShortAbs;
            if (liqQtyU > remainingAllowance) liqQtyU = remainingAllowance;
            if (liqQtyU == 0) continue;
            if (liqQtyU > uint256(uint128(type(int128).max))) revert QuantityTooLarge();

            uint128 liqQty = SafeCast.toUint128(liqQtyU);
            uint256 pricePerContract = _previewLiquidationPricePerContract(s);
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

        uint256 mmBase = _mulChecked(baseMaintenanceMarginPerContract, p.totalContractsPreviewed);
        p.penaltyBase = Math.mulDiv(mmBase, liquidationPenaltyBps, BPS, Math.Rounding.Floor);
    }

    function getAccountState(address trader) external view returns (AccountState memory s) {
        s.openSeriesCount = _getTraderSeriesLengthInternal(trader);
        s.totalShortOpenContracts = totalShortContracts[trader];

        if (address(_riskModule) == address(0)) {
            s.marginRatioBps = type(uint256).max;
            s.liquidatable = false;
            return s;
        }

        IRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        s.equityBase = r.equityBase;
        s.maintenanceMarginBase = r.maintenanceMarginBase;
        s.initialMarginBase = r.initialMarginBase;
        s.freeCollateralBase = _riskModule.computeFreeCollateral(trader);
        s.marginRatioBps = _marginRatioBpsFromRisk(r.equityBase, r.maintenanceMarginBase);
        s.liquidatable =
            (r.maintenanceMarginBase != 0) && (r.equityBase <= 0 || s.marginRatioBps < liquidationThresholdBps);
    }

    /*//////////////////////////////////////////////////////////////
                            SERIES / SETTLEMENT VIEWS
    //////////////////////////////////////////////////////////////*/

    function isSeriesExpired(uint256 optionId) public view returns (bool) {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        return block.timestamp >= series.expiry;
    }

    /// @notice Pure cumulative accounting state for one series.
    /// @dev All amounts are denominated in the series settlement-asset native units.
    function getSeriesSettlementAccounting(uint256 optionId) external view returns (SeriesSettlementState memory s) {
        s.totalCollected = seriesCollected[optionId];
        s.totalPaid = seriesPaid[optionId];
        s.totalBadDebt = seriesBadDebt[optionId];
    }

    function getSeriesSettlementState(uint256 optionId) public view returns (SeriesSettlementStatusView memory s) {
        (uint256 settlementPrice, bool isSet) = _optionRegistry.getSettlementInfo(optionId);

        s.optionId = optionId;
        s.isSettled = isSet;
        s.settledAt = _optionRegistry.getSettlementFinalizedAt(optionId);
        s.settlementPrice = settlementPrice;
        s.totalCollected = seriesCollected[optionId];
        s.totalPaid = seriesPaid[optionId];
        s.totalBadDebt = seriesBadDebt[optionId];
    }

    function getSeriesSettlementProposalState(uint256 optionId)
        external
        view
        returns (SeriesSettlementProposalState memory s)
    {
        (uint256 proposedPrice, uint64 proposedAt, bool exists) = _optionRegistry.getSettlementProposal(optionId);

        s.optionId = optionId;
        s.proposedPrice = proposedPrice;
        s.proposedAt = proposedAt;
        s.exists = exists;
    }

    function isAccountSettledForSeries(uint256 optionId, address trader) external view returns (bool) {
        return isAccountSettled[optionId][trader];
    }

    /// @notice Deterministic preview of what settlement would mean for one account right now.
    /// @dev
    ///  This is not historical realized accounting storage.
    ///  It is a preview derived from:
    ///   - current position
    ///   - official settlement price if already finalized
    ///   - settled flag for the account
    function previewAccountSettlement(uint256 optionId, address trader)
        external
        view
        returns (SettlementPreview memory p)
    {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        (uint256 settlementPrice, bool isSet) = _optionRegistry.getSettlementInfo(optionId);

        bool expired = block.timestamp >= series.expiry;
        if (!expired || !isSet || settlementPrice == 0) {
            p.isSettled = isAccountSettled[optionId][trader];
            return p;
        }

        int128 qty = _positionQuantityOf(trader, optionId);
        if (qty == 0) {
            p.isSettled = isAccountSettled[optionId][trader];
            p.canSettle = true;
            return p;
        }

        (, int256 pnl) = _previewAccountSettlementPnl(series, qty, settlementPrice);
        p = _previewSettlementResolution(optionId, trader, pnl, series.settlementAsset);
    }

    function previewDetailedSettlement(uint256 optionId, address trader)
        external
        view
        returns (DetailedSettlementPreview memory p)
    {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        (uint256 settlementPrice, bool isSet) = _optionRegistry.getSettlementInfo(optionId);
        (uint256 proposedPrice, uint64 proposedAt, bool proposalExists) = _optionRegistry.getSettlementProposal(optionId);

        p.optionId = optionId;
        p.settlementAsset = series.settlementAsset;
        p.seriesActive = series.isActive;
        p.seriesExpired = block.timestamp >= series.expiry;
        p.settlementPaused = _optionRegistry.settlementPaused();
        p.settlementPriceSet = isSet && settlementPrice != 0;
        p.settlementFinalizedAt = _optionRegistry.getSettlementFinalizedAt(optionId);
        p.settlementPrice = settlementPrice;
        p.proposalExists = proposalExists;
        p.proposedSettlementPrice = proposedPrice;
        p.proposalTimestamp = proposedAt;
        p.settlementFinalityDelay = _optionRegistry.settlementFinalityDelay();
        p.proposalReady =
            proposalExists && block.timestamp >= uint256(proposedAt) + p.settlementFinalityDelay;
        p.accountSettled = isAccountSettled[optionId][trader];
        p.positionQuantity = _positionQuantityOf(trader, optionId);

        if (address(_riskModule) != address(0)) {
            IRiskModule.AccountRisk memory beforeRisk = _riskModule.computeAccountRisk(trader);
            p.riskBefore = _settlementRiskSnapshot(beforeRisk);
        } else {
            p.riskBefore.marginRatioBps = type(uint256).max;
        }

        p.settlementReady =
            p.seriesExpired && p.settlementPriceSet && !p.settlementPaused && !p.accountSettled;

        if (!p.settlementReady || p.positionQuantity == 0) {
            p.riskAfter = p.riskBefore;
            p.riskAfterAvailable = true;
            return p;
        }

        (p.payoffPerContract, p.pnl) = _previewAccountSettlementPnl(series, p.positionQuantity, settlementPrice);

        SettlementPreview memory resolution = _previewSettlementResolution(optionId, trader, p.pnl, series.settlementAsset);
        p.grossSettlementAmount = resolution.grossAmount;
        p.isShortLiability = p.pnl < 0;
        p.shortLiabilityAmount = p.isShortLiability ? resolution.grossAmount : 0;
        p.traderSettlementAssetBalance = _collateralVault.balances(trader, series.settlementAsset);

        if (p.isShortLiability) {
            p.collateralCoveragePreview = resolution.collectibleAmount;
        } else {
            address sink = insuranceFund != address(0) ? insuranceFund : address(this);
            p.settlementSinkBalance = _collateralVault.balances(sink, series.settlementAsset);

            if (sink == insuranceFund && insuranceFund != address(0)) {
                p.insuranceCoveragePreview = resolution.payableFromSettlementSink;
            } else {
                p.collateralCoveragePreview = resolution.payableFromSettlementSink;
                p.insuranceCoveragePreview = resolution.insurancePreview;
            }
        }

        p.residualShortfallPreview = resolution.residualBadDebtPreview;
        p.residualBadDebtPreview = resolution.residualBadDebtPreview;

        (p.grossSettlementAmountBase, p.grossSettlementAmountBaseAvailable) =
            _previewSettlementAmountBase(series.settlementAsset, p.grossSettlementAmount);

        int256 cashflowDelta = _previewSettlementCashflowDelta(resolution, p.isShortLiability);
        uint256 absCashflow = cashflowDelta >= 0
            ? SafeCast.toUint256(cashflowDelta)
            : SafeCast.toUint256(-cashflowDelta);
        (uint256 cashflowDeltaBaseAbs, bool cashflowDeltaBaseAvailable) =
            _previewSettlementAmountBase(series.settlementAsset, absCashflow);
        if (cashflowDeltaBaseAvailable) {
            p.accountCashflowDeltaBaseAvailable = true;
            p.accountCashflowDeltaBase = cashflowDelta >= 0
                ? SafeCast.toInt256(cashflowDeltaBaseAbs)
                : -SafeCast.toInt256(cashflowDeltaBaseAbs);
        }

        (p.riskAfter, p.riskAfterAvailable) = _previewRiskAfterSettlement(
            p.riskBefore, p.positionQuantity, p.accountCashflowDeltaBase, p.accountCashflowDeltaBaseAvailable
        );
    }

    /*//////////////////////////////////////////////////////////////
                        PROTOCOL SETTLEMENT ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns cumulative settlement accounting over a slice of registered option ids.
    /// @dev This stays paginated because the registry can grow arbitrarily over time.
    function getProtocolSettlementAccountingSlice(uint256 start, uint256 end)
        external
        view
        returns (ProtocolSettlementSliceTotals memory totals)
    {
        uint256[] memory optionIds = _optionRegistry.getAllOptionIdsSlice(start, end);
        totals.seriesCount = optionIds.length;

        for (uint256 i = 0; i < optionIds.length; i++) {
            uint256 optionId = optionIds[i];
            totals.totalCollected = _addChecked(totals.totalCollected, seriesCollected[optionId]);
            totals.totalPaid = _addChecked(totals.totalPaid, seriesPaid[optionId]);
            totals.totalBadDebt = _addChecked(totals.totalBadDebt, seriesBadDebt[optionId]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FEES / CONFIG VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the currently resolved trading fee recipient.
    /// @dev Explicit feeRecipient has priority; fallback is insuranceFund.
    function getResolvedFeeRecipient() external view returns (address) {
        return _resolvedFeeRecipient();
    }

    /// @notice Preview hybrid trade fees for both counterparties.
    /// @dev Useful for UI / executors / analytics.
    function previewTradeFees(
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

        OptionProductRegistry.OptionSeries memory s = _optionRegistry.getSeries(optionId);
        _requireStandardContractSize(s);
        _requireSettlementAssetConfigured(s.settlementAsset);

        settlementAsset = s.settlementAsset;
        recipient = _resolvedFeeRecipient();
        premium = _mulChecked(uint256(quantity), uint256(price));
        notionalImplicit = _computeStrikeNotionalImplicit(s, uint256(quantity));

        buyerQuote = _quoteHybridFee(buyer, buyerIsMaker, premium, notionalImplicit);
        sellerQuote = _quoteHybridFee(seller, !buyerIsMaker, premium, notionalImplicit);
    }

    function getLiquidationConfigView() external view returns (LiquidationConfigView memory cfg) {
        cfg.liquidationThresholdBps = liquidationThresholdBps;
        cfg.liquidationPenaltyBps = liquidationPenaltyBps;
        cfg.liquidationCloseFactorBps = liquidationCloseFactorBps;
        cfg.minLiquidationImprovementBps = minLiquidationImprovementBps;
        cfg.liquidationPriceSpreadBps = liquidationPriceSpreadBps;
        cfg.minLiquidationPriceBpsOfIntrinsic = minLiquidationPriceBpsOfIntrinsic;
        cfg.liquidationOracleMaxDelay = liquidationOracleMaxDelay;
    }

    function getRiskCacheView() external view returns (RiskCacheView memory cfg) {
        cfg.baseCollateralToken = baseCollateralToken;
        cfg.baseMaintenanceMarginPerContract = baseMaintenanceMarginPerContract;
        cfg.imFactorBps = imFactorBps;
    }

    /*//////////////////////////////////////////////////////////////
                            ORACLE VIEW
    //////////////////////////////////////////////////////////////*/

    function getUnderlyingSpot(uint256 optionId) external view returns (uint256 price, uint256 updatedAt) {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        _requireStandardContractSize(series);
        return _oracle.getPrice(series.underlying, series.settlementAsset);
    }
}
