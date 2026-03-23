// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "../matching/IPerpEngineTrade.sol";
import "./PerpEngineViews.sol";

/// @title PerpEngineTrading
/// @notice Matching-engine entrypoint for perpetual trades.
/// @dev
///  Scope:
///   - applies signed size transitions for buyer / seller
///   - maintains openNotional basis
///   - enforces market active / close-only
///   - enforces market caps
///   - charges maker/taker fees through shared CollateralVault
///   - updates lazy funding state and crystallizes funding on the closed portion
///
///  Funding conventions V1:
///   - cumulative funding index is stored per market in 1e18
///   - premium = (mark - index) / index
///   - deadband = oracleClampBps
///   - cap      = maxFundingRateBps
///   - economic interval = fundingInterval seconds (recommended: 8h)
///   - funding accrues lazily on trade / explicit update
///
///  Important:
///   - V1 keeps mark and index equal by default if no richer mark-price model exists yet,
///     which means funding can remain near zero while the architecture is still fully wired.
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

    function _absInt256Signed(int256 x) internal pure returns (int256) {
        return x >= 0 ? x : -x;
    }

    function _sign(int256 x) internal pure returns (int256) {
        if (x > 0) return int256(1);
        if (x < 0) return int256(-1);
        return int256(0);
    }

    function _clampSigned(int256 x, int256 minX, int256 maxX) internal pure returns (int256) {
        if (x < minX) return minX;
        if (x > maxX) return maxX;
        return x;
    }

    /*//////////////////////////////////////////////////////////////
                            FUNDING: CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes the raw premium rate in 1e18.
    /// @dev premium = (mark - index) / index
    function _premiumRate1e18(uint256 markPrice1e8, uint256 indexPrice1e8) internal pure returns (int256 premium1e18) {
        if (markPrice1e8 == 0 || indexPrice1e8 == 0) revert OraclePriceUnavailable();

        if (markPrice1e8 >= indexPrice1e8) {
            uint256 diff = markPrice1e8 - indexPrice1e8;
            premium1e18 = int256(Math.mulDiv(diff, uint256(FUNDING_SCALE_1E18), indexPrice1e8, Math.Rounding.Down));
        } else {
            uint256 diff = indexPrice1e8 - markPrice1e8;
            premium1e18 = -int256(Math.mulDiv(diff, uint256(FUNDING_SCALE_1E18), indexPrice1e8, Math.Rounding.Down));
        }
    }

    /// @notice Applies deadband to the premium rate.
    /// @dev deadband is encoded by fundingConfig.oracleClampBps for V1.
    function _applyFundingDeadband(int256 premium1e18, uint256 deadbandBps) internal pure returns (int256 adjusted1e18) {
        if (premium1e18 == 0 || deadbandBps == 0) return premium1e18;

        int256 deadband1e18 = int256(Math.mulDiv(deadbandBps, uint256(FUNDING_SCALE_1E18), BPS, Math.Rounding.Down));
        int256 absPrem = _absInt256Signed(premium1e18);

        if (absPrem <= deadband1e18) return 0;

        return premium1e18 - (_sign(premium1e18) * deadband1e18);
    }

    /// @notice Computes the capped funding rate per economic interval in 1e18.
    function _fundingRatePerInterval1e18(uint256 marketId) internal view returns (int256 rate1e18) {
        PerpMarketRegistry.FundingConfig memory fcfg = _getFundingConfig(marketId);
        if (!fcfg.isEnabled) return 0;

        (uint256 markPrice1e8, bool okMark) = _tryGetMarkPrice1e8(marketId);
        (uint256 indexPrice1e8, bool okIndex) = _tryGetIndexPrice1e8(marketId);

        if (!okMark || !okIndex || markPrice1e8 == 0 || indexPrice1e8 == 0) revert OraclePriceUnavailable();

        int256 premium1e18 = _premiumRate1e18(markPrice1e8, indexPrice1e8);
        int256 adjusted1e18 = _applyFundingDeadband(premium1e18, uint256(fcfg.oracleClampBps));

        int256 cap1e18 =
            int256(Math.mulDiv(uint256(fcfg.maxFundingRateBps), uint256(FUNDING_SCALE_1E18), BPS, Math.Rounding.Down));

        return _clampSigned(adjusted1e18, -cap1e18, cap1e18);
    }

    /// @notice Computes the funding increment to add to cumulativeFundingRate1e18.
    function _fundingRateDelta1e18(uint256 marketId) internal view returns (int256 delta1e18, uint64 effectiveTimestamp) {
        PerpMarketRegistry.FundingConfig memory fcfg = _getFundingConfig(marketId);

        effectiveTimestamp = uint64(block.timestamp);

        if (!fcfg.isEnabled) return (0, effectiveTimestamp);
        if (fcfg.fundingInterval == 0) revert InvalidMarket();

        uint256 elapsed = _fundingElapsed(marketId);
        if (elapsed == 0) return (0, effectiveTimestamp);

        int256 ratePerInterval1e18 = _fundingRatePerInterval1e18(marketId);
        if (ratePerInterval1e18 == 0) return (0, effectiveTimestamp);

        delta1e18 = (ratePerInterval1e18 * int256(elapsed)) / int256(uint256(fcfg.fundingInterval));
    }

    /// @notice Updates cumulative funding state for a market.
    /// @dev Public so keepers / frontends can force a sync before other actions.
    function updateFunding(uint256 marketId)
        public
        whenFundingNotPaused
        returns (int256 fundingRateDelta1e18, int256 nextCumulativeFundingRate1e18)
    {
        _requireMarketExists(marketId);

        MarketState storage s = _marketStates[marketId];

        // First touch initializes the anchor without changing economics.
        if (s.lastFundingTimestamp == 0) {
            s.lastFundingTimestamp = uint64(block.timestamp);
            emit FundingUpdated(marketId, 0, s.cumulativeFundingRate1e18, s.lastFundingTimestamp);
            return (0, s.cumulativeFundingRate1e18);
        }

        uint64 ts;
        (fundingRateDelta1e18, ts) = _fundingRateDelta1e18(marketId);

        nextCumulativeFundingRate1e18 = s.cumulativeFundingRate1e18 + fundingRateDelta1e18;
        _recordFundingUpdate(marketId, fundingRateDelta1e18, nextCumulativeFundingRate1e18, ts);
    }

    /*//////////////////////////////////////////////////////////////
                    FUNDING: POSITION TRANSITION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Funding accrued on the old position, in quote 1e8 units.
    function _accruedFundingOnPosition(Position memory oldPos, int256 currentCumulativeFundingRate1e18)
        internal
        pure
        returns (int256 funding1e8)
    {
        if (oldPos.size1e8 == 0) return 0;
        return _fundingPayment1e8(
            oldPos.size1e8, currentCumulativeFundingRate1e18, oldPos.lastCumulativeFundingRate1e18
        );
    }

    /// @notice Funding crystallized on the closed portion of a position.
    function _closedFundingPortion1e8(
        Position memory oldPos,
        uint256 closeAbs,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 closedFunding1e8) {
        if (oldPos.size1e8 == 0 || closeAbs == 0) return 0;

        uint256 absOld = _absInt256(oldPos.size1e8);
        int256 totalAccruedFunding1e8 = _accruedFundingOnPosition(oldPos, currentCumulativeFundingRate1e18);

        closedFunding1e8 = (totalAccruedFunding1e8 * _toInt256(closeAbs)) / _toInt256(absOld);
    }

    /// @notice Weighted carry-forward checkpoint for same-side increases.
    /// @dev Preserves accrued funding on the old size, while new size starts at current funding level.
    function _carryForwardFundingCheckpointForIncrease(
        Position memory oldPos,
        int256 newSize1e8,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 nextCheckpoint1e18) {
        if (oldPos.size1e8 == 0) return currentCumulativeFundingRate1e18;

        int256 accruedFunding1e8 = _accruedFundingOnPosition(oldPos, currentCumulativeFundingRate1e18);
        if (accruedFunding1e8 == 0) return currentCumulativeFundingRate1e18;

        int256 deltaRate1e18 = (accruedFunding1e8 * FUNDING_SCALE_1E18) / newSize1e8;
        nextCheckpoint1e18 = currentCumulativeFundingRate1e18 - deltaRate1e18;
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION TRANSITION CORE
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes the next position state after applying a signed delta.
    /// @dev
    ///  Returns:
    ///   - next position
    ///   - realized PnL from the reduced portion, in quote 1e8 units
    ///
    ///  Conventions:
    ///   - opening / increasing:
    ///       openNotional += signedNotional(delta, px)
    ///       funding checkpoint is weighted so new units do not inherit past funding
    ///   - reducing:
    ///       removed basis = proportional share of old openNotional
    ///       realizedPnL = markValue(closed part at px) - removedBasis - realizedFundingOnClosedPortion
    ///   - flipping:
    ///       closed part is realized
    ///       remainder opens new basis at execution price with fresh funding checkpoint
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

            if (oldSize == 0) {
                nextPos.lastCumulativeFundingRate1e18 = currentCumulativeFundingRate1e18;
            } else {
                nextPos.lastCumulativeFundingRate1e18 =
                    _carryForwardFundingCheckpointForIncrease(oldPos, newSize, currentCumulativeFundingRate1e18);
            }

            return (nextPos, 0);
        }

        // reducing / flipping
        uint256 absOld = _absInt256(oldSize);
        uint256 absDelta = _absInt256(deltaSize1e8);
        uint256 closeAbs = _minU(absOld, absDelta);

        int256 closeSizeSigned = oldSize > 0 ? _toInt256(closeAbs) : -_toInt256(closeAbs);

        int256 removedBasis1e8 = (oldOpenNotional * _toInt256(closeAbs)) / _toInt256(absOld);
        int256 closedMarkValue1e8 = _signedMarkValue1e8(closeSizeSigned, executionPrice1e8);
        int256 closedFunding1e8 = _closedFundingPortion1e8(oldPos, closeAbs, currentCumulativeFundingRate1e18);

        realizedPnl1e8 = _checkedSubInt256(_checkedSubInt256(closedMarkValue1e8, removedBasis1e8), closedFunding1e8);

        // exact close
        if (newSize == 0) {
            nextPos.openNotional1e8 = 0;
            nextPos.lastCumulativeFundingRate1e18 = 0;
            return (nextPos, realizedPnl1e8);
        }

        // partial reduce, same direction remains
        if (_sameSignNonZero(oldSize, newSize)) {
            nextPos.openNotional1e8 = _checkedSubInt256(oldOpenNotional, removedBasis1e8);

            // keep old checkpoint: remaining position keeps its remaining accrued funding
            nextPos.lastCumulativeFundingRate1e18 = oldPos.lastCumulativeFundingRate1e18;
            return (nextPos, realizedPnl1e8);
        }

        // flip: leftover opens fresh basis at execution price
        nextPos.openNotional1e8 = _signedNotional1e8(newSize, executionPrice1e8);
        nextPos.lastCumulativeFundingRate1e18 = currentCumulativeFundingRate1e18;
    }

    /*//////////////////////////////////////////////////////////////
                        FEES / RISK / CASHFLOW HELPERS
    //////////////////////////////////////////////////////////////*/

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
    ///  - funding is updated lazily before the trade is applied
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

        // Lazy funding update before reading current cumulative funding level.
        updateFunding(t.marketId);
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

        // Realized cashflow (basis + realized funding on closed portions)
        _applyRealizedCashflow(m.settlementAsset, t.buyer, t.seller, buyerRealized, sellerRealized);

        // Write positions
        _positions[t.buyer][t.marketId] = newBuyer;
        _positions[t.seller][t.marketId] = newSeller;

        // Update per-trader open market tracking
        _syncPositionIndexing(t.buyer, t.marketId, oldBuyer.size1e8, newBuyer.size1e8);
        _syncPositionIndexing(t.seller, t.marketId, oldSeller.size1e8, newSeller.size1e8);

        // Update market OI
        _updateMarketOpenInterest(t.marketId, oldBuyer.size1e8, newBuyer.size1e8);
        _updateMarketOpenInterest(t.marketId, oldSeller.size1e8, newSeller.size1e8);

        {
            MarketState memory s = _marketStates[t.marketId];
            uint256 oi = s.longOpenInterest1e8 > s.shortOpenInterest1e8 ? s.longOpenInterest1e8 : s.shortOpenInterest1e8;
            if (oi > uint256(rcfg.maxOpenInterest1e8)) revert SizeTooLarge();
        }

        // Fees on traded notional
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

        emit TradeExecuted(t.buyer, t.seller, t.marketId, t.sizeDelta1e8, t.executionPrice1e8, t.buyerIsMaker);

        _enforcePostTradeRisk(t.buyer);
        _enforcePostTradeRisk(t.seller);
    }
}