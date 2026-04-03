// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
///   - MarginEngineOps should then inherit MarginEngineViews
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

    /// @notice Per-series settlement accounting state.
    /// @dev
    ///  - `settlementPrice` is normalized in 1e8
    ///  - `totalCollected`, `totalPaid`, `totalBadDebt`
    ///    are denominated in settlement-asset native units
    struct SeriesSettlementState {
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

    /// @notice Deterministic settlement preview for one account.
    /// @dev
    ///  - `settlementPrice` and `payoffPerContract` are price-like values / cash values
    ///    derived from the series settlement asset
    ///  - `pnl` is denominated in settlement-asset native units
    struct AccountSettlementPreview {
        uint256 optionId;
        address trader;
        address settlementAsset;
        bool isExpired;
        bool settlementSet;
        bool alreadySettled;
        int128 quantity;
        uint256 settlementPrice;
        uint256 payoffPerContract;
        int256 pnl;
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
        uint256 absQty = q >= 0 ? uint256(q) : uint256(-q);

        uint256 amount = _mulChecked(absQty, payoffPerContract);
        if (amount > uint256(type(int256).max)) revert PnlOverflow();

        pnl = q >= 0 ? int256(amount) : -int256(amount);
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

        uint256 ratioBps = (uint256(risk.equityBase) * BPS) / risk.maintenanceMarginBase;
        return ratioBps < liquidationThresholdBps;
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

    function getSeriesSettlementState(uint256 optionId) public view returns (SeriesSettlementState memory s) {
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
        returns (AccountSettlementPreview memory p)
    {
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(optionId);
        (uint256 settlementPrice, bool isSet) = _optionRegistry.getSettlementInfo(optionId);

        p.optionId = optionId;
        p.trader = trader;
        p.settlementAsset = series.settlementAsset;
        p.isExpired = block.timestamp >= series.expiry;
        p.settlementSet = isSet;
        p.alreadySettled = isAccountSettled[optionId][trader];
        p.quantity = _positionQuantityOf(trader, optionId);
        p.settlementPrice = settlementPrice;

        if (!isSet || settlementPrice == 0 || p.quantity == 0) {
            return p;
        }

        (p.payoffPerContract, p.pnl) = _previewAccountSettlementPnl(series, p.quantity, settlementPrice);
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