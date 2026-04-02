// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    function _requireInsuranceFund() internal view {
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();
    }

    function _baseToken() internal view returns (address) {
        address token = _marketRegistry.baseCollateralToken();
        if (token == address(0)) revert InvalidMarket();
        return token;
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

    function _baseValueToTokenAmount(address token, uint256 baseValue, uint256 price1e8)
        internal
        view
        returns (uint256 tokenAmount)
    {
        CollateralVault.CollateralTokenConfig memory baseCfg = _collateralVault.getCollateralConfig(_baseToken());
        CollateralVault.CollateralTokenConfig memory tokCfg = _collateralVault.getCollateralConfig(token);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) revert InvalidMarket();
        if (!tokCfg.isSupported || tokCfg.decimals == 0) revert InvalidMarket();

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        uint256 tmp = Math.mulDiv(baseValue, PRICE_1E8, price1e8, Math.Rounding.Down);

        if (baseDec == tokenDec) return tmp;

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Down);
        }

        uint256 factor2 = _pow10(uint256(baseDec - tokenDec));
        return tmp / factor2;
    }

    function _settlementNativeToBaseValue(address settlementAsset, uint256 settlementAmountNative)
        internal
        view
        returns (uint256 baseValue)
    {
        if (settlementAmountNative == 0) return 0;

        address baseToken = _baseToken();

        CollateralVault.CollateralTokenConfig memory baseCfg = _collateralVault.getCollateralConfig(baseToken);
        CollateralVault.CollateralTokenConfig memory setCfg = _collateralVault.getCollateralConfig(settlementAsset);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) revert InvalidMarket();
        if (!setCfg.isSupported || setCfg.decimals == 0) revert InvalidMarket();

        if (settlementAsset == baseToken) {
            return settlementAmountNative;
        }

        (uint256 px, bool ok) = _tryGetMarkPrice1e8FromPair(settlementAsset, baseToken);
        if (!ok || px == 0) revert OraclePriceUnavailable();

        uint256 tmp = Math.mulDiv(settlementAmountNative, px, PRICE_1E8, Math.Rounding.Down);

        if (baseCfg.decimals == setCfg.decimals) return tmp;

        if (baseCfg.decimals > setCfg.decimals) {
            uint256 factor = _pow10(uint256(baseCfg.decimals - setCfg.decimals));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Down);
        }

        uint256 factor2 = _pow10(uint256(setCfg.decimals - baseCfg.decimals));
        return tmp / factor2;
    }

    function _settlementAmount1e8ToBaseValue(address settlementAsset, uint256 amount1e8)
        internal
        view
        returns (uint256 baseValue)
    {
        if (amount1e8 == 0) return 0;

        uint256 settlementNative = _value1e8ToSettlementNative(settlementAsset, amount1e8);
        return _settlementNativeToBaseValue(settlementAsset, settlementNative);
    }

    function _penaltySettlementNative(address settlementAsset, uint256 penaltyBaseValue)
        internal
        view
        returns (uint256 penaltyNative)
    {
        address baseToken = _baseToken();
        if (penaltyBaseValue == 0) return 0;

        if (settlementAsset == baseToken) {
            return penaltyBaseValue;
        }

        (uint256 px, bool ok) = _tryGetMarkPrice1e8FromPair(settlementAsset, baseToken);
        if (!ok || px == 0) revert OraclePriceUnavailable();
        penaltyNative = _baseValueToTokenAmount(settlementAsset, penaltyBaseValue, px);
    }

    function _tryGetMarkPrice1e8FromPair(address base, address quote) internal view returns (uint256 price1e8, bool ok) {
        {
            (bool success, bytes memory data) =
                address(_oracle).staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", base, quote));

            if (success && data.length >= 96) {
                (uint256 px,, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
                if (safeOk && px != 0) return (px, true);
            }
        }

        try _oracle.getPrice(base, quote) returns (uint256 px, uint256) {
            if (px == 0) return (0, false);
            return (px, true);
        } catch {
            return (0, false);
        }
    }

    function _tryResolveCollateralSeizer() internal view returns (ICollateralSeizer seizer, bool ok) {
        seizer = _collateralSeizer;
        if (address(seizer) == address(0)) return (ICollateralSeizer(address(0)), false);
        return (seizer, true);
    }

    function _trySeizeViaPlan(address trader, address liquidator, uint256 targetBaseValue)
        internal
        returns (uint256 paidBaseValue)
    {
        if (targetBaseValue == 0) return 0;

        (ICollateralSeizer seizer, bool hasSeizer) = _tryResolveCollateralSeizer();
        if (!hasSeizer) return 0;

        address[] memory tokens;
        uint256[] memory amounts;
        uint256 plannedCovered;

        try seizer.computeSeizurePlan(trader, targetBaseValue) returns (
            address[] memory tokensOut,
            uint256[] memory amountsOut,
            uint256 baseCovered
        ) {
            if (tokensOut.length != amountsOut.length) return 0;
            if (tokensOut.length == 0 || baseCovered == 0) return 0;

            tokens = tokensOut;
            amounts = amountsOut;
            plannedCovered = baseCovered;
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
                    paidBaseValue += effectiveBaseFloor;
                }
            } catch {}
        }

        if (paidBaseValue > plannedCovered) {
            paidBaseValue = plannedCovered;
        }
        if (paidBaseValue > targetBaseValue) {
            paidBaseValue = targetBaseValue;
        }
    }

    function _seizePenaltyToLiquidator(
        address trader,
        address liquidator,
        address settlementAsset,
        uint256 penaltyBaseValue
    ) internal returns (uint256 paidPenaltyBaseValue) {
        if (penaltyBaseValue == 0) return 0;

        paidPenaltyBaseValue = _trySeizeViaPlan(trader, liquidator, penaltyBaseValue);
        if (paidPenaltyBaseValue >= penaltyBaseValue) {
            return penaltyBaseValue;
        }

        uint256 remainingBase = penaltyBaseValue - paidPenaltyBaseValue;

        _syncVaultBestEffort(trader, settlementAsset);

        uint256 penaltyNative = _penaltySettlementNative(settlementAsset, remainingBase);
        if (penaltyNative == 0) return paidPenaltyBaseValue;

        uint256 traderBal = _collateralVault.balances(trader, settlementAsset);
        uint256 paidNative = penaltyNative <= traderBal ? penaltyNative : traderBal;
        if (paidNative == 0) return paidPenaltyBaseValue;

        _collateralVault.transferBetweenAccounts(settlementAsset, trader, liquidator, paidNative);

        if (settlementAsset == _baseToken()) {
            return paidPenaltyBaseValue + paidNative;
        }

        uint256 extraBase = _settlementNativeToBaseValue(settlementAsset, paidNative);
        paidPenaltyBaseValue += extraBase;

        if (paidPenaltyBaseValue > penaltyBaseValue) {
            paidPenaltyBaseValue = penaltyBaseValue;
        }
    }

    function _tryCoverShortfallWithInsurance(address liquidator, uint256 requestedBaseValue)
        internal
        returns (uint256 paidBaseValue)
    {
        if (requestedBaseValue == 0) return 0;
        _requireInsuranceFund();

        address baseToken = _baseToken();

        try IInsuranceFundPerpBackstop(insuranceFund).coverVaultShortfall(baseToken, liquidator, requestedBaseValue)
        returns (uint256 paid) {
            paidBaseValue = paid <= requestedBaseValue ? paid : requestedBaseValue;
        } catch {
            revert InsuranceFundCoverageFailed();
        }
    }

    function _resolveLiquidationShortfall(
        address liquidator,
        address trader,
        uint256 marketId,
        uint256 penaltyTargetBaseValue,
        uint256 seizedPenaltyBaseValue
    ) internal returns (LiquidationResolution memory res) {
        res.penaltyTargetBaseValue = penaltyTargetBaseValue;
        res.seizedPenaltyBaseValue = seizedPenaltyBaseValue;

        uint256 remainingAfterSeizure = _remainingShortfall(penaltyTargetBaseValue, seizedPenaltyBaseValue);

        if (remainingAfterSeizure != 0) {
            emit LiquidationShortfall(
                liquidator,
                trader,
                marketId,
                penaltyTargetBaseValue,
                seizedPenaltyBaseValue,
                remainingAfterSeizure
            );

            uint256 insurancePaid = _tryCoverShortfallWithInsurance(liquidator, remainingAfterSeizure);
            res.insurancePaidBaseValue = insurancePaid;

            if (insurancePaid != 0) {
                emit LiquidationInsuranceCoverage(liquidator, trader, marketId, remainingAfterSeizure, insurancePaid);
            }

            uint256 residual = _remainingShortfall(remainingAfterSeizure, insurancePaid);
            res.residualShortfallBaseValue = residual;

            if (residual != 0) {
                emit LiquidationBadDebtRecorded(liquidator, trader, marketId, residual);
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

        uint256 incomingBase = _settlementNativeToBaseValue(settlementAsset, incomingNative);
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

        uint256 actualRepaidBase = _settlementNativeToBaseValue(settlementAsset, repayNative);
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
            premium1e18 = int256(Math.mulDiv(diff, uint256(FUNDING_SCALE_1E18), indexPrice1e8, Math.Rounding.Down));
        } else {
            uint256 diff = indexPrice1e8 - markPrice1e8;
            premium1e18 = -int256(Math.mulDiv(diff, uint256(FUNDING_SCALE_1E18), indexPrice1e8, Math.Rounding.Down));
        }
    }

    function _applyFundingDeadband(int256 premium1e18, uint256 deadbandBps) internal pure returns (int256 adjusted1e18) {
        if (premium1e18 == 0 || deadbandBps == 0) return premium1e18;

        int256 deadband1e18 = int256(Math.mulDiv(deadbandBps, uint256(FUNDING_SCALE_1E18), BPS, Math.Rounding.Down));
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
            int256(Math.mulDiv(uint256(fcfg.maxFundingRateBps), uint256(FUNDING_SCALE_1E18), BPS, Math.Rounding.Down));

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

        delta1e18 = (ratePerInterval1e18 * int256(elapsed)) / int256(uint256(fcfg.fundingInterval));
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
                    FUNDING: POSITION TRANSITION HELPERS
    //////////////////////////////////////////////////////////////*/

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

    function _carryForwardFundingCheckpointForIncrease(
        Position memory oldPos,
        int256 newSize1e8,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 nextCheckpoint1e18) {
        if (oldPos.size1e8 == 0) return currentCumulativeFundingRate1e18;

        int256 accruedFunding1e8 = _accruedFundingOnPosition(oldPos, currentCumulativeFundingRate1e18);
        if (accruedFunding1e8 == 0) return currentCumulativeFundingRate1e18;

        int256 deltaRate1e18 = (accruedFunding1e8 * int256(FUNDING_SCALE_1E18)) / newSize1e8;
        nextCheckpoint1e18 = currentCumulativeFundingRate1e18 - deltaRate1e18;
    }

    /*//////////////////////////////////////////////////////////////
                        POSITION TRANSITION CORE
    //////////////////////////////////////////////////////////////*/

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

        uint256 absOld = _absInt256(oldSize);
        uint256 absDelta = _absInt256(deltaSize1e8);
        uint256 closeAbs = _minU(absOld, absDelta);

        int256 closeSizeSigned = oldSize > 0 ? _toInt256(closeAbs) : -_toInt256(closeAbs);

        int256 removedBasis1e8 = (oldOpenNotional * _toInt256(closeAbs)) / _toInt256(absOld);
        int256 closedMarkValue1e8 = _signedMarkValue1e8(closeSizeSigned, executionPrice1e8);
        int256 closedFunding1e8 = _closedFundingPortion1e8(oldPos, closeAbs, currentCumulativeFundingRate1e18);

        realizedPnl1e8 = _checkedSubInt256(_checkedSubInt256(closedMarkValue1e8, removedBasis1e8), closedFunding1e8);

        if (newSize == 0) {
            nextPos.openNotional1e8 = 0;
            nextPos.lastCumulativeFundingRate1e18 = 0;
            return (nextPos, realizedPnl1e8);
        }

        if (_sameSignNonZero(oldSize, newSize)) {
            nextPos.openNotional1e8 = _checkedSubInt256(oldOpenNotional, removedBasis1e8);
            nextPos.lastCumulativeFundingRate1e18 = oldPos.lastCumulativeFundingRate1e18;
            return (nextPos, realizedPnl1e8);
        }

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
        if (r.maintenanceMargin1e8 == 0) return false;
        if (r.equity1e8 <= 0) return true;
        return _marginRatioBpsFromState(r.equity1e8, r.maintenanceMargin1e8) < BPS;
    }

    /*//////////////////////////////////////////////////////////////
                            LIQUIDATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function _liquidationClip(
        address trader,
        uint256 marketId,
        uint128 requestedCloseSize1e8,
        uint256 liqPrice1e8,
        int256 currentFunding1e18
    ) internal view returns (Position memory newPos, int256 realizedPnl1e8, uint128 executedCloseSize1e8) {
        Position memory oldPos = _positions[trader][marketId];
        if (oldPos.size1e8 == 0) revert LiquidationNothingToDo();

        executedCloseSize1e8 =
            _boundedLiquidationSize1e8(oldPos.size1e8, requestedCloseSize1e8, liquidationCloseFactorBps);
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
    ) internal returns (Position memory newLiqPos) {
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

        PerpMarketRegistry.Market memory m = _requireMarketExists(t.marketId);
        if (!m.isActive) revert MarketInactive();

        PerpMarketRegistry.RiskConfig memory rcfg = _getRiskConfig(t.marketId);
        _requireSettlementAssetConfigured(m.settlementAsset);

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

        {
            MarketState memory s = _marketStates[t.marketId];
            uint256 oi = s.longOpenInterest1e8 > s.shortOpenInterest1e8 ? s.longOpenInterest1e8 : s.shortOpenInterest1e8;
            if (oi > uint256(rcfg.maxOpenInterest1e8)) revert SizeTooLarge();
        }

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

        IPerpRiskModule.AccountRisk memory traderBefore = _marginState(trader);
        if (!_isTraderLiquidatable(trader)) revert NotLiquidatable();

        updateFunding(marketId);
        int256 currentFunding = _marketStates[marketId].cumulativeFundingRate1e18;

        Position memory oldTraderPos = _positions[trader][marketId];
        if (oldTraderPos.size1e8 == 0) revert LiquidationNothingToDo();

        uint256 markPrice1e8 = _getMarkPrice1e8(marketId);
        uint256 liqPrice1e8 = _liquidationPrice1e8FromMark(
            oldTraderPos.size1e8, markPrice1e8, liquidationPriceSpreadBps
        );

        Position memory newTraderPos;
        int256 traderRealizedPnl1e8;
        uint128 sizeClosed1e8;

        (newTraderPos, traderRealizedPnl1e8, sizeClosed1e8) =
            _liquidationClip(trader, marketId, requestedCloseSize1e8, liqPrice1e8, currentFunding);

        if (sizeClosed1e8 == 0) revert LiquidationNothingToDo();

        address liquidator = msg.sender;
        Position memory oldLiqPos = _positions[liquidator][marketId];
        bool traderWasLong = oldTraderPos.size1e8 > 0;

        Position memory newLiqPos =
            _applyLiquidationLegToLiquidator(liquidator, marketId, sizeClosed1e8, liqPrice1e8, currentFunding, traderWasLong);

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
            uint256 oi = s.longOpenInterest1e8 > s.shortOpenInterest1e8 ? s.longOpenInterest1e8 : s.shortOpenInterest1e8;
            if (oi > uint256(rcfg.maxOpenInterest1e8)) revert SizeTooLarge();
        }

        uint256 closedNotional1e8 =
            Math.mulDiv(uint256(sizeClosed1e8), liqPrice1e8, PRICE_1E8, Math.Rounding.Down);

        uint256 closedNotionalBaseValue = _settlementAmount1e8ToBaseValue(m.settlementAsset, closedNotional1e8);
        uint256 penaltyBaseValue = _liquidationPenaltyBaseValue(closedNotionalBaseValue, liquidationPenaltyBps);

        uint256 seizedPenaltyBaseValue =
            _seizePenaltyToLiquidator(trader, liquidator, m.settlementAsset, penaltyBaseValue);

        LiquidationResolution memory resolution =
            _resolveLiquidationShortfall(liquidator, trader, marketId, penaltyTargetBaseValue: penaltyBaseValue, seizedPenaltyBaseValue: seizedPenaltyBaseValue);

        if (resolution.residualShortfallBaseValue != 0) {
            _recordResidualBadDebt(trader, resolution.residualShortfallBaseValue);
        }

        IPerpRiskModule.AccountRisk memory traderAfter = _marginState(trader);
        bool improved = _liquidationImproved(
            traderBefore.equity1e8,
            traderBefore.maintenanceMargin1e8,
            traderAfter.equity1e8,
            traderAfter.maintenanceMargin1e8,
            minLiquidationImprovementBps
        );
        if (!improved) revert LiquidationNotImproving();

        _enforcePostTradeRisk(liquidator);

        uint256 totalPenaltyPaidBaseValue = resolution.seizedPenaltyBaseValue + resolution.insurancePaidBaseValue;

        emit Liquidation(liquidator, trader, marketId, sizeClosed1e8, liqPrice1e8, totalPenaltyPaidBaseValue);
        emit LiquidationPenaltyPaid(liquidator, trader, marketId, totalPenaltyPaidBaseValue);
    }
}