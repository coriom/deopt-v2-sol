// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {IMarginEngineState} from "../risk/IMarginEngineState.sol";
import {IMarginEngineTrade} from "../matching/IMarginEngineTrade.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";
import {IFeesManagerV2} from "../fees/IFeesManagerV2.sol";

import {MarginEngineAdmin} from "./MarginEngineAdmin.sol";

/// @title MarginEngineTrading
/// @notice Matching-engine entrypoint for option trades.
/// @dev
///  Responsibilities:
///   - update option positions with strict int128 hardening
///   - maintain open-series / short aggregates
///   - transfer premium in settlement-asset native units
///   - charge hybrid trading fees when configured
///   - enforce initial margin after state mutation
///
///  Architectural note:
///   - this layer is intentionally state-changing only
///   - read aggregation / settlement observability should live in MarginEngineViews
///
///  Canonical conventions:
///   - prices normalized by the protocol remain in 1e8 only where explicitly stated
///   - trade `price` here is premium per contract in settlement-asset native units
///   - `premium` / fees are in settlement-asset native units
///   - risk checks are delegated to RiskModule and interpreted in base-token native units
///
///  Maker/taker convention:
///   - t.buyerIsMaker == true  => buyer = maker, seller = taker
///   - t.buyerIsMaker == false => buyer = taker, seller = maker
abstract contract MarginEngineTrading is MarginEngineAdmin {
    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _chargeTradingFee(
        address trader,
        bool isMaker,
        address settlementAsset,
        uint256 optionId,
        uint256 premium,
        uint256 notionalImplicit,
        address recipient
    ) internal {
        IFeesManager fm = feesManager;
        if (address(fm) == address(0)) return;

        if (recipient == address(0)) revert FeesRecipientNotSet();
        if (recipient == trader) revert FeesRecipientEqualsTrader();

        IFeesManager.FeeQuote memory q = _quoteHybridFee(trader, isMaker, premium, notionalImplicit);
        uint256 fee = q.appliedFee;
        if (fee == 0) return;

        _collateralVault.transferBetweenAccounts(settlementAsset, trader, recipient, fee);

        emit TradingFeeCharged(
            trader,
            recipient,
            settlementAsset,
            optionId,
            isMaker,
            premium,
            notionalImplicit,
            q.notionalFee,
            q.premiumCapFee,
            q.appliedFee,
            q.cappedByPremium
        );
    }

    function _chargeTradingFeeV2(
        address trader,
        address counterparty,
        bool isMaker,
        address settlementAsset,
        uint256 optionId,
        uint256 premium
    ) internal {
        IFeesManagerV2 fm = feesManagerV2;
        if (address(fm) == address(0)) revert ZeroAddress();

        IFeesManagerV2.FeeQuote memory q = fm.consumeFees(
            trader,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            isMaker,
            settlementAsset,
            premium
        );

        if (
            q.product != IFeesManagerV2.ProductKind.OPTION || q.flow != IFeesManagerV2.FlowKind.ORDERBOOK
                || q.feeBasis != IFeesManagerV2.FeeBasis.PREMIUM || q.isMaker != isMaker
                || q.settlementAsset != settlementAsset || q.basisAmount != premium
        ) {
            revert FeesManagerV2QuoteInvalid();
        }

        uint256 feeAmount = q.feeAmount;
        if (feeAmount == 0) return;

        if (q.isRebate) {
            if (q.recipient != trader) revert FeesManagerV2QuoteInvalid();

            address fundingAccount = fm.rebateFundingAccount();
            if (fundingAccount == address(0)) revert FeesManagerV2RebateFundingNotSet();

            _collateralVault.transferBetweenAccounts(settlementAsset, fundingAccount, trader, feeAmount);
            return;
        }

        address recipient = q.recipient;
        if (recipient == address(0)) revert FeesRecipientNotSet();
        if (recipient == trader) revert FeesRecipientEqualsTrader();
        if (recipient == counterparty) revert FeesRecipientEqualsCounterparty();

        _collateralVault.transferBetweenAccounts(settlementAsset, trader, recipient, feeAmount);

        emit TradingFeeCharged(
            trader, recipient, settlementAsset, optionId, isMaker, premium, 0, feeAmount, feeAmount, feeAmount, false
        );
    }

    /*//////////////////////////////////////////////////////////////
                                TRADING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMarginEngineTrade
    function applyTrade(IMarginEngineTrade.Trade calldata t)
        external
        override
        onlyMatchingEngine
        whenTradingNotPaused
        nonReentrant
    {
        // Basic validation
        if (t.buyer == address(0) || t.seller == address(0) || t.buyer == t.seller || t.quantity == 0 || t.price == 0) {
            revert InvalidTrade();
        }

        // Risk module required for IM enforcement
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        _requireBaseConfigured();
        _requireRiskParamsSynced();

        // Load series
        OptionProductRegistry.OptionSeries memory series = _optionRegistry.getSeries(t.optionId);
        _requireStandardContractSize(series);

        // Expiry guard
        if (block.timestamp >= series.expiry) revert SeriesExpired();

        // Settlement asset must be vault-supported (premium / payoff ledger)
        _requireSettlementAssetConfigured(series.settlementAsset);

        // Read positions
        IMarginEngineState.Position storage buyerPos = _positions[t.buyer][t.optionId];
        IMarginEngineState.Position storage sellerPos = _positions[t.seller][t.optionId];

        int128 oldBuyerQty = buyerPos.quantity;
        int128 oldSellerQty = sellerPos.quantity;

        _ensureQtyAllowed(oldBuyerQty);
        _ensureQtyAllowed(oldSellerQty);

        // Apply delta
        int128 delta = _toInt128(t.quantity);

        int128 newBuyerQty = _checkedAddInt128(oldBuyerQty, delta);
        int128 newSellerQty = _checkedSubInt128(oldSellerQty, delta);

        _ensureQtyAllowed(newBuyerQty);
        _ensureQtyAllowed(newSellerQty);

        uint8 activationState = seriesActivationState[t.optionId];
        if (activationState == SERIES_ACTIVATION_INACTIVE) {
            bool okBuyer = _isCloseToZeroTransition(oldBuyerQty, newBuyerQty);
            bool okSeller = _isCloseToZeroTransition(oldSellerQty, newSellerQty);
            if (!okBuyer || !okSeller) revert SeriesNotActiveCloseOnly();
        } else if (
            !series.isActive || seriesEmergencyCloseOnly[t.optionId] || activationState == SERIES_ACTIVATION_RESTRICTED
        ) {
            // Close-only: no opening, no flip, no absolute exposure increase.
            bool okBuyer = _isCloseOnlyTransition(oldBuyerQty, newBuyerQty);
            bool okSeller = _isCloseOnlyTransition(oldSellerQty, newSellerQty);
            if (!okBuyer || !okSeller) revert SeriesNotActiveCloseOnly();
        }

        // Write positions
        buyerPos.quantity = newBuyerQty;
        sellerPos.quantity = newSellerQty;

        // Maintain canonical open-series tracking + short aggregates
        _syncPositionIndexes(t.buyer, t.optionId, oldBuyerQty, newBuyerQty);
        _syncPositionIndexes(t.seller, t.optionId, oldSellerQty, newSellerQty);
        _enforceSeriesShortOpenInterestCap(t.optionId);

        // Premium cashflow: settlement-asset native units
        // premium = quantity * pricePerContract
        uint256 premium = _mulChecked(uint256(t.quantity), uint256(t.price));
        _collateralVault.transferBetweenAccounts(series.settlementAsset, t.buyer, t.seller, premium);

        bool buyerIsMaker = t.buyerIsMaker;
        bool sellerIsMaker = !buyerIsMaker;

        // Option fees
        if (useFeesManagerV2) {
            _chargeTradingFeeV2(t.buyer, t.seller, buyerIsMaker, series.settlementAsset, t.optionId, premium);
            _chargeTradingFeeV2(t.seller, t.buyer, sellerIsMaker, series.settlementAsset, t.optionId, premium);
        } else if (address(feesManager) != address(0)) {
            address recipient = _resolvedFeeRecipient();
            if (recipient == address(0)) revert FeesRecipientNotSet();
            if (recipient == t.buyer || recipient == t.seller) revert FeesRecipientEqualsCounterparty();

            uint256 notionalImplicit = _computeStrikeNotionalImplicit(series, uint256(t.quantity));

            _chargeTradingFee(
                t.buyer, buyerIsMaker, series.settlementAsset, t.optionId, premium, notionalImplicit, recipient
            );

            _chargeTradingFee(
                t.seller, sellerIsMaker, series.settlementAsset, t.optionId, premium, notionalImplicit, recipient
            );
        }

        emit TradeExecuted(t.buyer, t.seller, t.optionId, t.quantity, t.price);

        // Post-trade IM enforcement (after premium + fees)
        _enforceInitialMargin(t.buyer);
        _enforceInitialMargin(t.seller);
    }
}
