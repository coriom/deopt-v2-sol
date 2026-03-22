// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../matching/IPerpEngineTrade.sol";
import "./PerpEngineViews.sol";

/// @title PerpEngineTrading
/// @notice Matching-engine entrypoint for perpetual trades.
/// @dev
///  Current scope:
///   - applies signed size transitions for buyer / seller
///   - maintains openNotional basis
///   - enforces market active / close-only
///   - enforces market caps
///   - charges maker/taker fees through shared CollateralVault
///
///  Important note:
///   - this layer uses an interim realized-PnL cashflow netting model between counterparties:
///       netToBuyer = buyerRealizedPnl - sellerRealizedPnl
///   - this is sufficient to keep one-sided reductions economically meaningful,
///     but a future dedicated mark/funding settlement layer can refine the model further.
abstract contract PerpEngineTrading is PerpEngineViews, IPerpEngineTrade {
    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireSettlementAssetConfigured(address settlementAsset)
        internal
        view
        returns (CollateralVault.CollateralTokenConfig memory cfg)
    {
        cfg = _collateralVault.getCollateralConfig(settlementAsset);
        if (!cfg.isSupported || cfg.decimals == 0) revert InvalidMarket();
        if (uint256(cfg.decimals) > MAX_POW10_EXP) revert MathOverflow();
    }

    function _value1e8ToSettlementNative(address settlementAsset, uint256 amount1e8)
        internal
        view
        returns (uint256 amountNative)
    {
        CollateralVault.CollateralTokenConfig memory cfg = _requireSettlementAssetConfigured(settlementAsset);
        uint256 scale = _pow10(uint256(cfg.decimals));
        amountNative = Math.mulDiv(amount1e8, scale, PRICE_1E8, Math.Rounding.Down);
    }

    function _signedNotional1e8(int256 size1e8, uint256 executionPrice1e8) internal pure returns (int256 notional1e8) {
        return _signedMarkValue1e8(size1e8, executionPrice1e8);
    }

    function _minU(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sameSignNonZero(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    /// @notice Computes the next position state after applying a signed delta.
    /// @dev
    ///  Returns:
    ///   - next position
    ///   - realized PnL from the reduced portion, in quote 1e8 units
    ///
    ///  Conventions:
    ///   - opening / increasing:
    ///       openNotional += signedNotional(delta, px)
    ///   - reducing:
    ///       removed basis = proportional share of old openNotional
    ///       realizedPnL = markValue(closed part at px) - removedBasis
    ///   - flipping:
    ///       closed part is realized
    ///       remainder opens new basis at execution price
    function _computeNextPosition(
        Position memory oldPos,
        int256 deltaSize1e8,
        uint256 executionPrice1e8,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (Position memory nextPos, int256 realizedPnl1e8) {
        int256 oldSize = oldPos.size1e8;
        int256 oldOpenNotional = oldPos.openNotional1e8;

        if (deltaSize1e8 == 0) revert SizeZero();
        if (executionPrice1e8 == 0) revert PriceZero();

        int256 newSize = _checkedAddInt256(oldSize, deltaSize1e8);
        nextPos.size1e8 = newSize;

        // fresh open / pure increase
        if (oldSize == 0 || _sameSignNonZero(oldSize, deltaSize1e8)) {
            nextPos.openNotional1e8 =
                _checkedAddInt256(oldOpenNotional, _signedNotional1e8(deltaSize1e8, executionPrice1e8));

            // funding snapshot:
            // - fresh open => current cumulative
            // - same-side increase => preserve existing snapshot
            nextPos.lastCumulativeFundingRate1e18 =
                oldSize == 0 ? currentCumulativeFundingRate1e18 : oldPos.lastCumulativeFundingRate1e18;

            return (nextPos, 0);
        }

        // reducing / flipping
        uint256 absOld = _absInt256(oldSize);
        uint256 absDelta = _absInt256(deltaSize1e8);
        uint256 closeAbs = _minU(absOld, absDelta);

        int256 closeSizeSigned = oldSize > 0 ? _toInt256(closeAbs) : -_toInt256(closeAbs);

        int256 removedBasis1e8 = (oldOpenNotional * _toInt256(closeAbs)) / _toInt256(absOld);

        int256 closedMarkValue1e8 = _signedMarkValue1e8(closeSizeSigned, executionPrice1e8);
        realizedPnl1e8 = _checkedSubInt256(closedMarkValue1e8, removedBasis1e8);

        // exact close
        if (newSize == 0) {
            nextPos.openNotional1e8 = 0;
            nextPos.lastCumulativeFundingRate1e18 = 0;
            return (nextPos, realizedPnl1e8);
        }

        // partial reduce, same direction remains
        if (_sameSignNonZero(oldSize, newSize)) {
            nextPos.openNotional1e8 = _checkedSubInt256(oldOpenNotional, removedBasis1e8);
            nextPos.lastCumulativeFundingRate1e18 = oldPos.lastCumulativeFundingRate1e18;
            return (nextPos, realizedPnl1e8);
        }

        // flip: leftover opens fresh basis at execution price
        nextPos.openNotional1e8 = _signedNotional1e8(newSize, executionPrice1e8);
        nextPos.lastCumulativeFundingRate1e18 = currentCumulativeFundingRate1e18;
    }

    function _chargeTradingFee(
        address trader,
        bool isMaker,
        address settlementAsset,
        uint256 marketId,
        uint256 notionalNative,
        address recipient
    ) internal {
        IFeesManager fm = feesManager;
        if (address(fm) == address(0)) return;

        if (recipient == address(0)) revert FeesManagerNotSet();
        if (recipient == trader) revert InvalidTrade();

        // For perps, we reuse the hybrid fee module by passing:
        //  premium          = notionalNative
        //  notionalImplicit = notionalNative
        // This effectively applies the lower of the two configured bps caps.
        IFeesManager.FeeQuote memory q = fm.quoteFee(trader, isMaker, notionalNative, notionalNative);

        uint256 fee = q.appliedFee;
        if (fee == 0) return;

        _collateralVault.transferBetweenAccounts(settlementAsset, trader, recipient, fee);

        emit CollateralWithdrawn(trader, settlementAsset, fee, 0);
        marketId;
    }

    function _enforcePostTradeRisk(address trader) internal view {
        if (address(_riskModule) == address(0)) return;

        IPerpRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        if (r.initialMargin1e8 > uint256(type(int256).max)) revert MathOverflow();
        if (r.equity1e8 < int256(r.initialMargin1e8)) revert MarginRequirementBreached(trader);
    }

    function _applyRealizedCashflow(
        address settlementAsset,
        address buyer,
        address seller,
        int256 buyerRealizedPnl1e8,
        int256 sellerRealizedPnl1e8
    ) internal {
        int256 netToBuyer1e8 = _checkedSubInt256(buyerRealizedPnl1e8, sellerRealizedPnl1e8);

        if (netToBuyer1e8 == 0) return;

        uint256 absNetNative = _value1e8ToSettlementNative(settlementAsset, _absInt256(netToBuyer1e8));
        if (absNetNative == 0) return;

        if (netToBuyer1e8 > 0) {
            _collateralVault.transferBetweenAccounts(settlementAsset, seller, buyer, absNetNative);
        } else {
            _collateralVault.transferBetweenAccounts(settlementAsset, buyer, seller, absNetNative);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                TRADING
    //////////////////////////////////////////////////////////////*/

    /// @notice Matching-engine entrypoint.
    /// @dev
    ///  - buyer gains +sizeDelta1e8
    ///  - seller gains -sizeDelta1e8
    function applyTrade(Trade calldata t)
        external
        override
        onlyMatchingEngine
        whenTradingNotPaused
        nonReentrant
    {
        if (t.buyer == address(0) || t.seller == address(0) || t.buyer == t.seller) revert InvalidTrade();
        if (t.sizeDelta1e8 == 0) revert SizeZero();
        if (t.executionPrice1e8 == 0) revert PriceZero();

        PerpMarketRegistry.Market memory m = _requireMarketExists(t.marketId);
        if (!m.isActive) revert MarketInactive();

        PerpMarketRegistry.RiskConfig memory rcfg = _getRiskConfig(t.marketId);
        _requireSettlementAssetConfigured(m.settlementAsset);

        int256 currentFunding = _marketStates[t.marketId].cumulativeFundingRate1e18;

        Position memory oldBuyer = _positions[t.buyer][t.marketId];
        Position memory oldSeller = _positions[t.seller][t.marketId];

        int256 buyerDelta = _toInt256(uint256(t.sizeDelta1e8));
        int256 sellerDelta = -buyerDelta;

        Position memory newBuyer;
        Position memory newSeller;
        int256 buyerRealized;
        int256 sellerRealized;

        (newBuyer, buyerRealized) =
            _computeNextPosition(oldBuyer, buyerDelta, uint256(t.executionPrice1e8), currentFunding);

        (newSeller, sellerRealized) =
            _computeNextPosition(oldSeller, sellerDelta, uint256(t.executionPrice1e8), currentFunding);

        if (m.isCloseOnly) {
            bool okBuyer = _isReduceOnlyTransition(oldBuyer.size1e8, newBuyer.size1e8);
            bool okSeller = _isReduceOnlyTransition(oldSeller.size1e8, newSeller.size1e8);
            if (!okBuyer || !okSeller) revert ReduceOnlyViolation();
        }

        if (_absInt256(newBuyer.size1e8) > uint256(rcfg.maxPositionSize1e8)) revert SizeTooLarge();
        if (_absInt256(newSeller.size1e8) > uint256(rcfg.maxPositionSize1e8)) revert SizeTooLarge();

        // realized cashflow (interim model)
        _applyRealizedCashflow(m.settlementAsset, t.buyer, t.seller, buyerRealized, sellerRealized);

        // write positions
        _positions[t.buyer][t.marketId] = newBuyer;
        _positions[t.seller][t.marketId] = newSeller;

        // update per-trader open market tracking
        _syncPositionIndexing(t.buyer, t.marketId, oldBuyer.size1e8, newBuyer.size1e8);
        _syncPositionIndexing(t.seller, t.marketId, oldSeller.size1e8, newSeller.size1e8);

        // update market OI
        _updateMarketOpenInterest(t.marketId, oldBuyer.size1e8, newBuyer.size1e8);
        _updateMarketOpenInterest(t.marketId, oldSeller.size1e8, newSeller.size1e8);

        {
            MarketState memory s = _marketStates[t.marketId];
            uint256 oi = s.longOpenInterest1e8 > s.shortOpenInterest1e8 ? s.longOpenInterest1e8 : s.shortOpenInterest1e8;
            if (oi > uint256(rcfg.maxOpenInterest1e8)) revert SizeTooLarge();
        }

        // fees on traded notional
        if (address(feesManager) != address(0)) {
            address recipient = _resolvedFeeRecipient();
            if (recipient == address(0)) revert FeesManagerNotSet();
            if (recipient == t.buyer || recipient == t.seller) revert InvalidTrade();

            uint256 notional1e8 = Math.mulDiv(
                uint256(t.sizeDelta1e8), uint256(t.executionPrice1e8), PRICE_1E8, Math.Rounding.Down
            );

            uint256 notionalNative = _value1e8ToSettlementNative(m.settlementAsset, notional1e8);

            _chargeTradingFee(t.buyer, t.buyerIsMaker, m.settlementAsset, t.marketId, notionalNative, recipient);
            _chargeTradingFee(t.seller, !t.buyerIsMaker, m.settlementAsset, t.marketId, notionalNative, recipient);
        }

        emit TradeExecuted(
            t.buyer,
            t.seller,
            t.marketId,
            t.sizeDelta1e8,
            t.executionPrice1e8,
            t.buyerIsMaker
        );

        _enforcePostTradeRisk(t.buyer);
        _enforcePostTradeRisk(t.seller);
    }
}