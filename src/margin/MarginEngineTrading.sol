// contracts/margin/MarginEngineTrading.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {IMarginEngineState} from "../risk/IMarginEngineState.sol";
import {IMarginEngineTrade} from "../matching/IMarginEngineTrade.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";

import {MarginEngineAdmin} from "./MarginEngineAdmin.sol";

/// @notice Matching-engine entrypoint (applyTrade)
/// @dev
///  - Updates positions (int128) with strict hardening (no int128.min).
///  - Enforces close-only when series is inactive.
///  - Executes premium cashflow in settlementAsset units via CollateralVault.transferBetweenAccounts().
///  - Charges hybrid trading fees when FeesManager + recipient are configured.
///  - Enforces Initial Margin post-trade for both sides.
///
///  Maker/taker convention:
///  - t.buyerIsMaker == true  => buyer = maker, seller = taker
///  - t.buyerIsMaker == false => buyer = taker, seller = maker
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

    /// @inheritdoc IMarginEngineTrade
    function applyTrade(IMarginEngineTrade.Trade calldata t)
        external
        override
        onlyMatchingEngine
        whenNotPaused
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

        // Settlement asset must be vault-supported (premium/payoff ledger)
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

        // Close-only when series inactive (no opening / no flip / no abs increase)
        if (!series.isActive) {
            bool okBuyer = _isCloseOnlyTransition(oldBuyerQty, newBuyerQty);
            bool okSeller = _isCloseOnlyTransition(oldSellerQty, newSellerQty);
            if (!okBuyer || !okSeller) revert SeriesNotActiveCloseOnly();
        }

        // Write positions
        buyerPos.quantity = newBuyerQty;
        sellerPos.quantity = newSellerQty;

        // Maintain short counters + open-series tracking
        _updateTotalShortContracts(t.buyer, oldBuyerQty, newBuyerQty);
        _updateTotalShortContracts(t.seller, oldSellerQty, newSellerQty);

        _updateOpenSeriesOnChange(t.buyer, t.optionId, oldBuyerQty, newBuyerQty);
        _updateOpenSeriesOnChange(t.seller, t.optionId, oldSellerQty, newSellerQty);

        // Premium cashflow: settlement asset native units
        // premium = quantity * pricePerContract
        uint256 premium = _mulChecked(uint256(t.quantity), uint256(t.price));
        _collateralVault.transferBetweenAccounts(series.settlementAsset, t.buyer, t.seller, premium);

        // Hybrid fees
        if (address(feesManager) != address(0)) {
            address recipient = _resolvedFeeRecipient();
            if (recipient == address(0)) revert FeesRecipientNotSet();
            if (recipient == t.buyer || recipient == t.seller) revert FeesRecipientEqualsCounterparty();

            uint256 notionalImplicit = _computeStrikeNotionalImplicit(series, uint256(t.quantity));

            bool buyerIsMaker = t.buyerIsMaker;
            bool sellerIsMaker = !buyerIsMaker;

            _chargeTradingFee(
                t.buyer,
                buyerIsMaker,
                series.settlementAsset,
                t.optionId,
                premium,
                notionalImplicit,
                recipient
            );

            _chargeTradingFee(
                t.seller,
                sellerIsMaker,
                series.settlementAsset,
                t.optionId,
                premium,
                notionalImplicit,
                recipient
            );
        }

        emit TradeExecuted(t.buyer, t.seller, t.optionId, t.quantity, t.price);

        // Post-trade IM enforcement (after premium + fees)
        _enforceInitialMargin(t.buyer);
        _enforceInitialMargin(t.seller);
    }
}