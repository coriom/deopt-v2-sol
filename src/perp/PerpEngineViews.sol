// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import "./PerpEngineAdmin.sol";

abstract contract PerpEngineViews is PerpEngineAdmin {
    /*//////////////////////////////////////////////////////////////
                            DEPENDENCY READS
    //////////////////////////////////////////////////////////////*/

    function marketRegistry() external view returns (address) {
        return _marketRegistryAddress();
    }

    function collateralVault() external view returns (address) {
        return _collateralVaultAddress();
    }

    function oracle() external view returns (address) {
        return _oracleAddress();
    }

    function riskModule() external view returns (address) {
        return _riskModuleAddress();
    }

    function collateralSeizer() external view returns (address) {
        return _collateralSeizerAddress();
    }

    /*//////////////////////////////////////////////////////////////
                            CORE READS
    //////////////////////////////////////////////////////////////*/

    function positions(address trader, uint256 marketId) external view returns (Position memory) {
        return _positions[trader][marketId];
    }

    function getPositionSize(address trader, uint256 marketId) external view returns (int256) {
        return _positions[trader][marketId].size1e8;
    }

    function marketState(uint256 marketId) external view returns (MarketState memory s) {
        _requireMarketExists(marketId);
        return _marketStates[marketId];
    }

    function getTraderMarkets(address trader) external view returns (uint256[] memory) {
        return traderMarkets[trader];
    }

    function getTraderMarketsLength(address trader) external view returns (uint256) {
        return traderMarkets[trader].length;
    }

    function getTraderMarketsSlice(address trader, uint256 start, uint256 end)
        external
        view
        returns (uint256[] memory out)
    {
        uint256 len = traderMarkets[trader].length;

        if (start >= len || start >= end) {
            return new uint256;
        }

        if (end > len) end = len;

        uint256 outLen = end - start;
        out = new uint256[](outLen);

        for (uint256 i = 0; i < outLen; i++) {
            out[i] = traderMarkets[trader][start + i];
        }
    }

    function isOpenMarket(address trader, uint256 marketId) external view returns (bool) {
        return traderMarketIndexPlus1[trader][marketId] != 0;
    }

    /*//////////////////////////////////////////////////////////////
                        BAD DEBT / SOLVENCY READS
    //////////////////////////////////////////////////////////////*/

    function getResidualBadDebt(address trader) public view returns (uint256) {
        return _residualBadDebtOf(trader);
    }

    function getTotalResidualBadDebt() external view returns (uint256) {
        return totalResidualBadDebtBase;
    }

    function hasResidualBadDebt(address trader) public view returns (bool) {
        return _residualBadDebtOf(trader) != 0;
    }

    /// @notice Current post-insolvency trading policy for an account.
    /// @dev If account has residual bad debt, engine enforces strict reduce-only.
    function isReduceOnlyByBadDebt(address trader) external view returns (bool) {
        return hasResidualBadDebt(trader);
    }

    /// @notice Whether the account is currently allowed to increase/open exposure.
    function canIncreaseExposure(address trader) external view returns (bool) {
        return !hasResidualBadDebt(trader);
    }

    function getPerpSolvencyState(address trader)
        external
        view
        returns (uint256 residualBadDebtBase, bool hasOpenPositions, bool liquidatable)
    {
        residualBadDebtBase = _residualBadDebtOf(trader);
        hasOpenPositions = traderMarkets[trader].length != 0;
        liquidatable = isLiquidatable(trader);
    }

    function getPerpAccountStatus(address trader)
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
        residualBadDebtBase = _residualBadDebtOf(trader);
        hasOpenPositions = traderMarkets[trader].length != 0;
        liquidatable = isLiquidatable(trader);
        reduceOnly = residualBadDebtBase != 0;
        canIncrease = residualBadDebtBase == 0;
    }

    function previewResidualBadDebtRepayment(address payer, address trader, uint256 requestedAmountBase)
        external
        view
        returns (BadDebtRepayment memory repayment)
    {
        repayment.requestedBaseValue = requestedAmountBase;
        repayment.outstandingBaseValue = _residualBadDebtOf(trader);

        if (requestedAmountBase == 0 || repayment.outstandingBaseValue == 0 || payer == address(0)) {
            repayment.remainingBaseValue = repayment.outstandingBaseValue;
            return repayment;
        }

        address baseToken = _baseCollateralToken();
        uint256 payerBal = _collateralVault.balances(payer, baseToken);

        uint256 cappedToDebt = requestedAmountBase < repayment.outstandingBaseValue
            ? requestedAmountBase
            : repayment.outstandingBaseValue;

        repayment.repaidBaseValue = payerBal < cappedToDebt ? payerBal : cappedToDebt;
        repayment.remainingBaseValue = repayment.outstandingBaseValue - repayment.repaidBaseValue;
    }

    function getBadDebtRepaymentRecipient() external view returns (address) {
        return _resolvedBadDebtRepaymentRecipient();
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET CONFIG READS
    //////////////////////////////////////////////////////////////*/

    function getMarket(uint256 marketId) external view returns (PerpMarketRegistry.Market memory) {
        return _requireMarketExists(marketId);
    }

    function getRiskConfig(uint256 marketId) external view returns (PerpMarketRegistry.RiskConfig memory) {
        _requireMarketExists(marketId);
        return _getRiskConfig(marketId);
    }

    function getFundingConfig(uint256 marketId) external view returns (PerpMarketRegistry.FundingConfig memory) {
        _requireMarketExists(marketId);
        return _getFundingConfig(marketId);
    }

    function getSettlementAsset(uint256 marketId) external view returns (address) {
        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);
        return m.settlementAsset;
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION CORE VIEWS
    //////////////////////////////////////////////////////////////*/

    function isLiquidatable(address trader) public view returns (bool) {
        if (address(_riskModule) == address(0)) return false;

        IPerpRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        if (r.maintenanceMargin1e8 == 0) return false;
        if (r.equity1e8 <= 0) return true;

        return _marginRatioBpsFromState(r.equity1e8, r.maintenanceMargin1e8) < BPS;
    }

    function getLiquidationParams()
        external
        view
        returns (
            uint256 closeFactorBps,
            uint256 penaltyBps,
            uint256 priceSpreadBps,
            uint256 minImprovementBps
        )
    {
        return (
            liquidationCloseFactorBps,
            liquidationPenaltyBps,
            liquidationPriceSpreadBps,
            minLiquidationImprovementBps
        );
    }

    function previewLiquidation(address trader, uint256 marketId, uint128 requestedCloseSize1e8)
        external
        view
        returns (
            uint128 executedSize,
            uint256 liqPrice1e8,
            int256 pnlImpact1e8,
            uint256 penaltyBaseValue,
            bool valid
        )
    {
        if (!isLiquidatable(trader)) return (0, 0, 0, 0, false);

        Position memory p = _positions[trader][marketId];
        if (p.size1e8 == 0) return (0, 0, 0, 0, false);

        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);

        uint256 mark = _getMarkPrice1e8(marketId);
        uint256 liqPrice = _liquidationPrice1e8FromMark(p.size1e8, mark, liquidationPriceSpreadBps);
        uint128 size = _boundedLiquidationSize1e8(p.size1e8, requestedCloseSize1e8, liquidationCloseFactorBps);

        if (size == 0) return (0, 0, 0, 0, false);

        int256 delta = p.size1e8 > 0 ? -_toInt256(uint256(size)) : _toInt256(uint256(size));

        Position memory next;
        int256 realized;

        (next, realized) = _computeNextPosition(p, delta, liqPrice, _marketStates[marketId].cumulativeFundingRate1e18);
        next;

        uint256 closedNotional1e8 = Math.mulDiv(uint256(size), liqPrice, PRICE_1E8, Math.Rounding.Down);
        uint256 closedNotionalBaseValue = _settlementAmount1e8ToBaseValue(m.settlementAsset, closedNotional1e8);
        uint256 penalty = _liquidationPenaltyBaseValue(closedNotionalBaseValue, liquidationPenaltyBps);

        return (size, liqPrice, realized, penalty, true);
    }

    /*//////////////////////////////////////////////////////////////
                        PRICE / POSITION VIEWS
    //////////////////////////////////////////////////////////////*/

    function getMarkPrice(uint256 marketId) public view returns (uint256) {
        return _getMarkPrice1e8(marketId);
    }

    function getUnrealizedPnl(address trader, uint256 marketId) public view returns (int256) {
        return _positionUnrealizedPnl1e8(trader, marketId, _getMarkPrice1e8(marketId));
    }

    function getPositionFundingAccrued(address trader, uint256 marketId) public view returns (int256) {
        return _positionFundingAccrued1e8(trader, marketId);
    }

    /*//////////////////////////////////////////////////////////////
                        ACCOUNT AGGREGATION
    //////////////////////////////////////////////////////////////*/

    function getAccountUnrealizedPnl(address trader) public view returns (int256 total) {
        uint256[] memory markets = traderMarkets[trader];

        for (uint256 i = 0; i < markets.length; i++) {
            total += getUnrealizedPnl(trader, markets[i]);
        }
    }

    function getAccountFunding(address trader) public view returns (int256 total) {
        uint256[] memory markets = traderMarkets[trader];

        for (uint256 i = 0; i < markets.length; i++) {
            total += getPositionFundingAccrued(trader, markets[i]);
        }
    }

    function getAccountNetPnl(address trader) external view returns (int256) {
        return getAccountUnrealizedPnl(trader) - getAccountFunding(trader);
    }

    /*//////////////////////////////////////////////////////////////
                        RISK PASSTHROUGH
    //////////////////////////////////////////////////////////////*/

    function getAccountRisk(address trader) external view returns (IPerpRiskModule.AccountRisk memory) {
        if (address(_riskModule) == address(0)) {
            return IPerpRiskModule.AccountRisk(0, 0, 0);
        }

        return _riskModule.computeAccountRisk(trader);
    }

    function getMarginRatioBps(address trader) external view returns (uint256) {
        if (address(_riskModule) == address(0)) return type(uint256).max;

        IPerpRiskModule.AccountRisk memory r = _riskModule.computeAccountRisk(trader);
        return _marginRatioBpsFromState(r.equity1e8, r.maintenanceMargin1e8);
    }

    /*//////////////////////////////////////////////////////////////
                        MARKET METRICS
    //////////////////////////////////////////////////////////////*/

    function getMarketOpenInterest(uint256 marketId) external view returns (uint256 longOI, uint256 shortOI) {
        MarketState memory s = _marketStates[marketId];
        return (s.longOpenInterest1e8, s.shortOpenInterest1e8);
    }

    function getMarketSkew(uint256 marketId) external view returns (int256) {
        MarketState memory s = _marketStates[marketId];

        if (s.longOpenInterest1e8 >= s.shortOpenInterest1e8) {
            return int256(s.longOpenInterest1e8 - s.shortOpenInterest1e8);
        }

        return -int256(s.shortOpenInterest1e8 - s.longOpenInterest1e8);
    }
}