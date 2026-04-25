// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IFeesManager} from "../fees/IFeesManager.sol";
import {IOracle} from "../oracle/IOracle.sol";
import "../matching/IPerpEngineTrade.sol";
import "../liquidation/ICollateralSeizer.sol";
import "./PerpEngineViews.sol";

interface IInsuranceFundPerpBackstop {
    function coverVaultShortfall(address token, address toAccount, uint256 requestedAmount)
        external
        returns (uint256 paidAmount);
}

/// @title PerpEngineTrading
/// @notice Matching-engine entrypoint for perpetual trades + liquidation logic.
abstract contract PerpEngineTrading is PerpEngineViews, IPerpEngineTrade {
    using SafeCast for uint256;
    using SafeCast for int256;

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireInsuranceFund() internal view {
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();
    }

    function _hasResidualBadDebt(address trader) internal view returns (bool) {
        return _residualBadDebtOf(trader) != 0;
    }

    function _enforceBadDebtTradingPolicy(address trader, int256 oldSize1e8, int256 newSize1e8) internal view {
        if (!_hasResidualBadDebt(trader)) return;

        if (!_isReduceOnlyTransition(oldSize1e8, newSize1e8)) {
            revert BadDebtOutstanding(trader, _residualBadDebtOf(trader));
        }
    }

    function _tryResolveCollateralSeizer() internal view returns (ICollateralSeizer seizer, bool ok) {
        seizer = _collateralSeizer;
        if (address(seizer) == address(0)) return (ICollateralSeizer(address(0)), false);
        return (seizer, true);
    }

    function _trySeizeViaPlan(address trader, address liquidator, uint256 targetBase)
        internal
        returns (uint256 paidBase)
    {
        if (targetBase == 0) return 0;

        (ICollateralSeizer seizer, bool hasSeizer) = _tryResolveCollateralSeizer();
        if (!hasSeizer) return 0;

        address[] memory tokens;
        uint256[] memory amounts;
        uint256 plannedCoveredBase;

        try seizer.computeSeizurePlan(trader, targetBase) returns (
            address[] memory tokensOut,
            uint256[] memory amountsOut,
            uint256 baseCovered
        ) {
            if (tokensOut.length != amountsOut.length) return 0;
            if (tokensOut.length == 0 || baseCovered == 0) return 0;

            tokens = tokensOut;
            amounts = amountsOut;
            plannedCoveredBase = baseCovered;
        } catch {
            return 0;
        }

        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            uint256 plannedAmount = amounts[i];

            if (token == address(0) || plannedAmount == 0) continue;

            _syncVaultBestEffort(trader, token);

            uint256 bal = _collateralVault.balances(trader, token);
            uint256 transferAmt = plannedAmount <= bal ? plannedAmount : bal;
            if (transferAmt == 0) continue;

            _collateralVault.transferBetweenAccounts(token, trader, liquidator, transferAmt);

            try seizer.previewEffectiveBaseValue(token, transferAmt) returns (
                uint256,
                uint256 effectiveBaseFloor,
                bool okPreview
            ) {
                if (okPreview && effectiveBaseFloor != 0) {
                    paidBase += effectiveBaseFloor;
                }
            } catch {}
        }

        if (paidBase > plannedCoveredBase) {
            paidBase = plannedCoveredBase;
        }
        if (paidBase > targetBase) {
            paidBase = targetBase;
        }
    }

    function _seizePenaltyToLiquidator(address trader, address liquidator, address settlementAsset, uint256 penaltyBase)
        internal
        returns (uint256 paidPenaltyBase)
    {
        if (penaltyBase == 0) return 0;

        paidPenaltyBase = _trySeizeViaPlan(trader, liquidator, penaltyBase);
        if (paidPenaltyBase >= penaltyBase) {
            return penaltyBase;
        }

        uint256 remainingBase = penaltyBase - paidPenaltyBase;

        _syncVaultBestEffort(trader, settlementAsset);

        uint256 penaltyNative = _penaltySettlementNative(settlementAsset, remainingBase);
        if (penaltyNative == 0) return paidPenaltyBase;

        uint256 traderBal = _collateralVault.balances(trader, settlementAsset);
        uint256 paidNative = penaltyNative <= traderBal ? penaltyNative : traderBal;
        if (paidNative == 0) return paidPenaltyBase;

        _collateralVault.transferBetweenAccounts(settlementAsset, trader, liquidator, paidNative);

        if (settlementAsset == _baseToken()) {
            return paidPenaltyBase + paidNative;
        }

        uint256 extraBase = _settlementNativeToBase(settlementAsset, paidNative);
        paidPenaltyBase += extraBase;

        if (paidPenaltyBase > penaltyBase) {
            paidPenaltyBase = penaltyBase;
        }
    }

    function _tryCoverShortfallWithInsurance(address liquidator, uint256 requestedBase)
        internal
        returns (uint256 paidBase)
    {
        if (requestedBase == 0) return 0;
        _requireInsuranceFund();

        address baseToken = _baseToken();

        try IInsuranceFundPerpBackstop(insuranceFund).coverVaultShortfall(baseToken, liquidator, requestedBase) returns (
            uint256 paid
        ) {
            paidBase = paid <= requestedBase ? paid : requestedBase;
        } catch {
            revert InsuranceFundCoverageFailed();
        }
    }

    function _resolveLiquidationShortfall(
        address liquidator,
        address trader,
        uint256 marketId,
        uint256 penaltyTargetBase,
        uint256 seizedPenaltyBase
    ) internal returns (LiquidationResolution memory res) {
        res.penaltyTargetBase = penaltyTargetBase;
        res.seizedPenaltyBase = seizedPenaltyBase;

        uint256 remainingAfterSeizureBase = _remainingShortfall(penaltyTargetBase, seizedPenaltyBase);

        if (remainingAfterSeizureBase != 0) {
            emit LiquidationShortfall(
                liquidator,
                trader,
                marketId,
                penaltyTargetBase,
                seizedPenaltyBase,
                remainingAfterSeizureBase
            );

            uint256 insurancePaidBase = _tryCoverShortfallWithInsurance(liquidator, remainingAfterSeizureBase);
            res.insurancePaidBase = insurancePaidBase;

            if (insurancePaidBase != 0) {
                emit LiquidationInsuranceCoverage(
                    liquidator, trader, marketId, remainingAfterSeizureBase, insurancePaidBase
                );
            }

            uint256 residualShortfallBase = _remainingShortfall(remainingAfterSeizureBase, insurancePaidBase);
            res.residualShortfallBase = residualShortfallBase;

            if (residualShortfallBase != 0) {
                emit LiquidationBadDebtRecorded(liquidator, trader, marketId, residualShortfallBase);
            }
        }
    }

    function _routeIncomingCashflowWithDebtFirst(
        address settlementAsset,
        address payer,
        address receiver,
        uint256 incomingNative
    ) internal {
        if (incomingNative == 0) return;
        if (!_hasResidualBadDebt(receiver) || payer == receiver) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, incomingNative);
            return;
        }

        address recipient = _resolvedBadDebtRepaymentRecipient();
        uint256 outstandingBase = _residualBadDebtOf(receiver);
        if (outstandingBase == 0 || recipient == address(0) || recipient == receiver) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, incomingNative);
            return;
        }

        uint256 incomingBase = _settlementNativeToBase(settlementAsset, incomingNative);
        if (incomingBase == 0) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, incomingNative);
            return;
        }

        uint256 requestedRepayBase = outstandingBase < incomingBase ? outstandingBase : incomingBase;
        if (requestedRepayBase == 0) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, incomingNative);
            return;
        }

        uint256 repayNative;
        if (settlementAsset == _baseToken()) {
            repayNative = requestedRepayBase <= incomingNative ? requestedRepayBase : incomingNative;
        } else {
            repayNative = _penaltySettlementNative(settlementAsset, requestedRepayBase);
            if (repayNative > incomingNative) {
                repayNative = incomingNative;
            }
        }

        if (repayNative == 0) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, incomingNative);
            return;
        }

        uint256 actualRepaidBase = _settlementNativeToBase(settlementAsset, repayNative);
        if (actualRepaidBase > outstandingBase) {
            actualRepaidBase = outstandingBase;
        }

        if (actualRepaidBase == 0) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, incomingNative);
            return;
        }

        _collateralVault.transferBetweenAccounts(settlementAsset, payer, recipient, repayNative);
        _reduceResidualBadDebt(receiver, actualRepaidBase);

        uint256 remainingNative = incomingNative - repayNative;
        if (remainingNative != 0) {
            _collateralVault.transferBetweenAccounts(settlementAsset, payer, receiver, remainingNative);
        }

        emit ResidualBadDebtRepaid(
            payer,
            receiver,
            recipient,
            requestedRepayBase,
            actualRepaidBase,
            _residualBadDebtOf(receiver)
        );
    }

    /*//////////////////////////////////////////////////////////////
                            FUNDING: CORE LOGIC
    //////////////////////////////////////////////////////////////*/

    function _premiumRate1e18(uint256 markPrice1e8, uint256 indexPrice1e8) internal pure returns (int256 premium1e18) {
        if (markPrice1e8 == 0 || indexPrice1e8 == 0) revert OraclePriceUnavailable();

        if (markPrice1e8 >= indexPrice1e8) {
            uint256 diff = markPrice1e8 - indexPrice1e8;
            premium1e18 = int256(Math.mulDiv(diff, uint256(FUNDING_SCALE_1E18), indexPrice1e8, Math.Rounding.Floor));
        } else {
            uint256 diff = indexPrice1e8 - markPrice1e8;
            premium1e18 = -int256(Math.mulDiv(diff, uint256(FUNDING_SCALE_1E18), indexPrice1e8, Math.Rounding.Floor));
        }
    }

    function _applyFundingDeadband(int256 premium1e18, uint256 deadbandBps) internal pure returns (int256 adjusted1e18) {
        if (premium1e18 == 0 || deadbandBps == 0) return premium1e18;

        int256 deadband1e18 = int256(Math.mulDiv(deadbandBps, uint256(FUNDING_SCALE_1E18), BPS, Math.Rounding.Floor));
        int256 absPrem = _absInt256Signed(premium1e18);

        if (absPrem <= deadband1e18) return 0;

        return premium1e18 - (_sign(premium1e18) * deadband1e18);
    }

    function _fundingRatePerInterval1e18(uint256 marketId) internal view returns (int256 rate1e18) {
        PerpMarketRegistry.FundingConfig memory fcfg = _getFundingConfig(marketId);
        if (!fcfg.isEnabled) return 0;

        (uint256 markPrice1e8, bool okMark) = _tryGetMarkPrice1e8(marketId);
        (uint256 indexPrice1e8, bool okIndex) = _tryGetIndexPrice1e8(marketId);

        if (!okMark || !okIndex || markPrice1e8 == 0 || indexPrice1e8 == 0) revert OraclePriceUnavailable();

        int256 premium1e18 = _premiumRate1e18(markPrice1e8, indexPrice1e8);
        int256 adjusted1e18 = _applyFundingDeadband(premium1e18, uint256(fcfg.oracleClampBps));

        int256 cap1e18 =
            int256(Math.mulDiv(uint256(fcfg.maxFundingRateBps), uint256(FUNDING_SCALE_1E18), BPS, Math.Rounding.Floor));

        return _clampSigned(adjusted1e18, -cap1e18, cap1e18);
    }

    function _fundingRateDelta1e18(uint256 marketId) internal view returns (int256 delta1e18, uint64 effectiveTimestamp) {
        PerpMarketRegistry.FundingConfig memory fcfg = _getFundingConfig(marketId);

        effectiveTimestamp = uint64(block.timestamp);

        if (!fcfg.isEnabled) return (0, effectiveTimestamp);
        if (fcfg.fundingInterval == 0) revert InvalidMarket();

        uint256 elapsed = _fundingElapsed(marketId);
        if (elapsed == 0) return (0, effectiveTimestamp);

        int256 ratePerInterval1e18 = _fundingRatePerInterval1e18(marketId);
        if (ratePerInterval1e18 == 0) return (0, effectiveTimestamp);

        delta1e18 = (ratePerInterval1e18 * elapsed.toInt256()) / uint256(fcfg.fundingInterval).toInt256();
    }

    function updateFunding(uint256 marketId)
        public
        whenFundingNotPaused
        returns (int256 fundingRateDelta1e18, int256 nextCumulativeFundingRate1e18)
    {
        _requireMarketExists(marketId);

        MarketState storage s = _marketStates[marketId];

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
        if (r.initialMarginBase > uint256(type(int256).max)) revert MathOverflow();
        if (r.equityBase < int256(r.initialMarginBase)) revert MarginRequirementBreached(trader);
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
            _routeIncomingCashflowWithDebtFirst(settlementAsset, seller, buyer, absNetNative);
        } else {
            _routeIncomingCashflowWithDebtFirst(settlementAsset, buyer, seller, absNetNative);
        }
    }

    function _marginState(address trader) internal view returns (IPerpRiskModule.AccountRisk memory r) {
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();
        r = _riskModule.computeAccountRisk(trader);
    }

    function _isTraderLiquidatable(address trader) internal view returns (bool) {
        IPerpRiskModule.AccountRisk memory r = _marginState(trader);
        if (r.maintenanceMarginBase == 0) return false;
        if (r.equityBase <= 0) return true;
        return _marginRatioBpsFromState(r.equityBase, r.maintenanceMarginBase) < BPS;
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _liquidationClip(
        address trader,
        uint256 marketId,
        uint128 requestedCloseSize1e8,
        uint256 liqPrice1e8,
        int256 currentFunding1e18,
        uint256 closeFactorBps
    ) internal view returns (Position memory newPos, int256 realizedPnl1e8, uint128 executedCloseSize1e8) {
        Position memory oldPos = _positions[trader][marketId];
        if (oldPos.size1e8 == 0) revert LiquidationNothingToDo();

        executedCloseSize1e8 =
            _boundedLiquidationSize1e8(oldPos.size1e8, requestedCloseSize1e8, closeFactorBps);
        if (executedCloseSize1e8 == 0) revert LiquidationNothingToDo();

        int256 deltaForTrader =
            oldPos.size1e8 > 0 ? -_toInt256(uint256(executedCloseSize1e8)) : _toInt256(uint256(executedCloseSize1e8));

        (newPos, realizedPnl1e8) = _computeNextPosition(oldPos, deltaForTrader, liqPrice1e8, currentFunding1e18);
    }

    function _applyLiquidationLegToLiquidator(
        address liquidator,
        uint256 marketId,
        uint128 sizeClosed1e8,
        uint256 liqPrice1e8,
        int256 currentFunding1e18,
        bool traderWasLong
    ) internal view returns (Position memory newLiqPos) {
        Position memory oldLiqPos = _positions[liquidator][marketId];
        int256 deltaForLiquidator =
            traderWasLong ? _toInt256(uint256(sizeClosed1e8)) : -_toInt256(uint256(sizeClosed1e8));

        int256 ignoredRealized;
        (newLiqPos, ignoredRealized) =
            _computeNextPosition(oldLiqPos, deltaForLiquidator, liqPrice1e8, currentFunding1e18);
        ignoredRealized;
    }

    /*//////////////////////////////////////////////////////////////
                                TRADING
    //////////////////////////////////////////////////////////////*/

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
        _requireRiskModuleSet();

        PerpMarketRegistry.Market memory m = _requireMarketExists(t.marketId);
        if (!m.isActive) revert MarketInactive();

        PerpMarketRegistry.RiskConfig memory rcfg = _getRiskConfig(t.marketId);
        _requireSettlementAssetConfigured(m.settlementAsset);

        updateFunding(t.marketId);
        int256 currentFunding = _marketStates[t.marketId].cumulativeFundingRate1e18;

        Position memory oldBuyer = _positions[t.buyer][t.marketId];
        Position memory oldSeller = _positions[t.seller][t.marketId];
        uint256 previousOpenInterest1e8 = _effectiveMarketOpenInterest1e8(t.marketId);

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

        uint8 activationState = marketActivationState[t.marketId];
        if (activationState == MARKET_ACTIVATION_INACTIVE) {
            bool okBuyer = _isCloseToZeroTransition(oldBuyer.size1e8, newBuyer.size1e8);
            bool okSeller = _isCloseToZeroTransition(oldSeller.size1e8, newSeller.size1e8);
            if (!okBuyer || !okSeller) revert ReduceOnlyViolation();
        } else if (m.isCloseOnly || marketEmergencyCloseOnly[t.marketId] || activationState == MARKET_ACTIVATION_RESTRICTED) {
            bool okBuyer = _isReduceOnlyTransition(oldBuyer.size1e8, newBuyer.size1e8);
            bool okSeller = _isReduceOnlyTransition(oldSeller.size1e8, newSeller.size1e8);
            if (!okBuyer || !okSeller) revert ReduceOnlyViolation();
        }

        _enforceBadDebtTradingPolicy(t.buyer, oldBuyer.size1e8, newBuyer.size1e8);
        _enforceBadDebtTradingPolicy(t.seller, oldSeller.size1e8, newSeller.size1e8);

        if (_absInt256(newBuyer.size1e8) > uint256(rcfg.maxPositionSize1e8)) revert SizeTooLarge();
        if (_absInt256(newSeller.size1e8) > uint256(rcfg.maxPositionSize1e8)) revert SizeTooLarge();

        _applyRealizedCashflow(m.settlementAsset, t.buyer, t.seller, buyerRealized, sellerRealized);

        _positions[t.buyer][t.marketId] = newBuyer;
        _positions[t.seller][t.marketId] = newSeller;

        _syncPositionIndexing(t.buyer, t.marketId, oldBuyer.size1e8, newBuyer.size1e8);
        _syncPositionIndexing(t.seller, t.marketId, oldSeller.size1e8, newSeller.size1e8);

        _updateMarketOpenInterest(t.marketId, oldBuyer.size1e8, newBuyer.size1e8);
        _updateMarketOpenInterest(t.marketId, oldSeller.size1e8, newSeller.size1e8);
        _enforceLaunchOpenInterestCapIfIncreasing(t.marketId, previousOpenInterest1e8);

        {
            MarketState memory s = _marketStates[t.marketId];
            uint256 oi =
                s.longOpenInterest1e8 > s.shortOpenInterest1e8 ? s.longOpenInterest1e8 : s.shortOpenInterest1e8;
            if (oi > uint256(rcfg.maxOpenInterest1e8)) revert SizeTooLarge();
        }

        if (address(feesManager) != address(0)) {
            address recipient = _resolvedFeeRecipient();
            if (recipient == address(0)) revert FeesManagerNotSet();
            if (recipient == t.buyer || recipient == t.seller) revert InvalidTrade();

            uint256 notional1e8 =
                Math.mulDiv(uint256(t.sizeDelta1e8), uint256(t.executionPrice1e8), PRICE_1E8, Math.Rounding.Floor);

            uint256 notionalNative = _value1e8ToSettlementNative(m.settlementAsset, notional1e8);

            _chargeTradingFee(t.buyer, t.buyerIsMaker, m.settlementAsset, t.marketId, notionalNative, recipient);
            _chargeTradingFee(t.seller, !t.buyerIsMaker, m.settlementAsset, t.marketId, notionalNative, recipient);
        }

        emit TradeExecuted(t.buyer, t.seller, t.marketId, t.sizeDelta1e8, t.executionPrice1e8, t.buyerIsMaker);

        _enforcePostTradeRisk(t.buyer);
        _enforcePostTradeRisk(t.seller);
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATION V2-CLOSED
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless partial liquidation.
    /// @param trader Account being liquidated
    /// @param marketId Market to reduce
    /// @param requestedCloseSize1e8 Requested clip. If 0, engine uses max clip under close factor.
    function liquidate(address trader, uint256 marketId, uint128 requestedCloseSize1e8)
        external
        whenLiquidationNotPaused
        nonReentrant
    {
        if (trader == address(0)) revert ZeroAddress();
        if (trader == msg.sender) revert LiquidationSelfNotAllowed();

        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);
        if (!m.isActive && !m.isCloseOnly) revert MarketInactive();

        PerpMarketRegistry.RiskConfig memory rcfg = _getRiskConfig(marketId);
        _requireSettlementAssetConfigured(m.settlementAsset);
        _requireInsuranceFund();

        (
            uint256 closeFactorBps,
            uint256 penaltyBps,
            uint256 priceSpreadBps,
            uint256 minImprovementBps,
            uint32 oracleMaxDelay
        ) = _loadEffectiveLiquidationParams(marketId);

        IPerpRiskModule.AccountRisk memory traderBefore = _marginState(trader);
        if (!_isTraderLiquidatable(trader)) revert NotLiquidatable();

        updateFunding(marketId);
        int256 currentFunding = _marketStates[marketId].cumulativeFundingRate1e18;

        Position memory oldTraderPos = _positions[trader][marketId];
        if (oldTraderPos.size1e8 == 0) revert LiquidationNothingToDo();

        uint256 markPrice1e8;
        {
            PerpMarketRegistry.Market memory mm = _requireMarketExists(marketId);
            IOracle o = _marketOracle(mm);

            {
                (bool success, bytes memory data) = address(o).staticcall(
                    abi.encodeWithSignature("getPriceSafe(address,address)", mm.underlying, mm.settlementAsset)
                );

                if (success && data.length >= 96) {
                    (uint256 px, uint256 updatedAt, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
                    if (safeOk && px != 0) {
                        if (oracleMaxDelay != 0) {
                            if (updatedAt == 0) revert OraclePriceStale();
                            if (updatedAt > block.timestamp) revert OraclePriceStale();
                            if (block.timestamp - updatedAt > uint256(oracleMaxDelay)) revert OraclePriceStale();
                        }
                        markPrice1e8 = px;
                    }
                }
            }

            if (markPrice1e8 == 0) {
                (uint256 px, uint256 updatedAt) = o.getPrice(mm.underlying, mm.settlementAsset);
                if (px == 0) revert OraclePriceUnavailable();
                if (oracleMaxDelay != 0) {
                    if (updatedAt == 0) revert OraclePriceStale();
                    if (updatedAt > block.timestamp) revert OraclePriceStale();
                    if (block.timestamp - updatedAt > uint256(oracleMaxDelay)) revert OraclePriceStale();
                }
                markPrice1e8 = px;
            }
        }

        uint256 liqPrice1e8 = _liquidationPrice1e8FromMark(oldTraderPos.size1e8, markPrice1e8, priceSpreadBps);

        Position memory newTraderPos;
        int256 traderRealizedPnl1e8;
        uint128 sizeClosed1e8;

        (newTraderPos, traderRealizedPnl1e8, sizeClosed1e8) =
            _liquidationClip(trader, marketId, requestedCloseSize1e8, liqPrice1e8, currentFunding, closeFactorBps);

        if (sizeClosed1e8 == 0) revert LiquidationNothingToDo();

        address liquidator = msg.sender;
        Position memory oldLiqPos = _positions[liquidator][marketId];
        bool traderWasLong = oldTraderPos.size1e8 > 0;

        Position memory newLiqPos = _applyLiquidationLegToLiquidator(
            liquidator, marketId, sizeClosed1e8, liqPrice1e8, currentFunding, traderWasLong
        );

        if (_absInt256(newLiqPos.size1e8) > uint256(rcfg.maxPositionSize1e8)) {
            revert LiquidatorWouldBreachMargin(liquidator);
        }

        int256 liquidatorRealizedPnl1e8 = 0 - traderRealizedPnl1e8;
        _applyRealizedCashflow(m.settlementAsset, liquidator, trader, liquidatorRealizedPnl1e8, traderRealizedPnl1e8);

        _positions[trader][marketId] = newTraderPos;
        _positions[liquidator][marketId] = newLiqPos;

        _syncPositionIndexing(trader, marketId, oldTraderPos.size1e8, newTraderPos.size1e8);
        _syncPositionIndexing(liquidator, marketId, oldLiqPos.size1e8, newLiqPos.size1e8);

        _updateMarketOpenInterest(marketId, oldTraderPos.size1e8, newTraderPos.size1e8);
        _updateMarketOpenInterest(marketId, oldLiqPos.size1e8, newLiqPos.size1e8);

        {
            MarketState memory s = _marketStates[marketId];
            uint256 oi =
                s.longOpenInterest1e8 > s.shortOpenInterest1e8 ? s.longOpenInterest1e8 : s.shortOpenInterest1e8;
            if (oi > uint256(rcfg.maxOpenInterest1e8)) revert SizeTooLarge();
        }

        uint256 closedNotional1e8 =
            Math.mulDiv(uint256(sizeClosed1e8), liqPrice1e8, PRICE_1E8, Math.Rounding.Floor);

        uint256 closedNotionalBase = _settlementAmount1e8ToBase(m.settlementAsset, closedNotional1e8);
        uint256 penaltyBase = _liquidationPenaltyBaseValue(closedNotionalBase, penaltyBps);

        uint256 seizedPenaltyBase = _seizePenaltyToLiquidator(trader, liquidator, m.settlementAsset, penaltyBase);

        LiquidationResolution memory resolution =
            _resolveLiquidationShortfall(liquidator, trader, marketId, penaltyBase, seizedPenaltyBase);

        if (resolution.residualShortfallBase != 0) {
            _recordResidualBadDebt(trader, resolution.residualShortfallBase);
        }

        IPerpRiskModule.AccountRisk memory traderAfter = _marginState(trader);
        bool improved = _liquidationImproved(
            traderBefore.equityBase,
            traderBefore.maintenanceMarginBase,
            traderAfter.equityBase,
            traderAfter.maintenanceMarginBase,
            minImprovementBps
        );
        if (!improved) revert LiquidationNotImproving();

        _enforcePostTradeRisk(liquidator);

        uint256 totalPenaltyPaidBase = resolution.seizedPenaltyBase + resolution.insurancePaidBase;

        emit Liquidation(liquidator, trader, marketId, sizeClosed1e8, liqPrice1e8, totalPenaltyPaidBase);
        emit LiquidationResolved(
            liquidator,
            trader,
            marketId,
            sizeClosed1e8,
            liqPrice1e8,
            closedNotionalBase,
            penaltyBase,
            resolution.seizedPenaltyBase,
            resolution.insurancePaidBase,
            resolution.residualShortfallBase,
            totalPenaltyPaidBase
        );
        emit LiquidationPenaltyPaid(liquidator, trader, marketId, totalPenaltyPaidBase);
    }
}
