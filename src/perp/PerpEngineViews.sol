// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PerpEngineAdmin.sol";

/// @title PerpEngineViews
/// @notice Public/view surface for the perpetual engine.
/// @dev
///  Responsibilities:
///   - expose positions / market state / trader open markets
///   - expose core dependency addresses
///   - expose mark price views
///   - expose unrealized pnl / accrued funding / net position metrics
///   - expose optional account risk passthrough when a perp risk module is configured
abstract contract PerpEngineViews is PerpEngineAdmin {
    /*//////////////////////////////////////////////////////////////
                            CORE READS
    //////////////////////////////////////////////////////////////*/

    function positions(address trader, uint256 marketId) external view returns (Position memory) {
        return _positions[trader][marketId];
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
        returns (uint256[] memory slice)
    {
        uint256 len = traderMarkets[trader].length;
        if (start > len) start = len;
        if (end > len) end = len;
        if (end < start) end = start;

        uint256 outLen = end - start;
        slice = new uint256[](outLen);

        for (uint256 i = 0; i < outLen; i++) {
            slice[i] = traderMarkets[trader][start + i];
        }
    }

    function isOpenMarket(address trader, uint256 marketId) external view returns (bool) {
        return traderMarketIndexPlus1[trader][marketId] != 0;
    }

    /*//////////////////////////////////////////////////////////////
                        DEPENDENCY ADDRESS VIEWS
    //////////////////////////////////////////////////////////////*/

    function marketRegistry() external view returns (address) {
        return address(_marketRegistry);
    }

    function collateralVault() external view returns (address) {
        return address(_collateralVault);
    }

    function oracle() external view returns (address) {
        return address(_oracle);
    }

    function riskModule() external view returns (address) {
        return address(_riskModule);
    }

    function getResolvedFeeRecipient() external view returns (address) {
        return _resolvedFeeRecipient();
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET CONFIG VIEWS
    //////////////////////////////////////////////////////////////*/

    function getMarket(uint256 marketId) external view returns (PerpMarketRegistry.Market memory m) {
        return _requireMarketExists(marketId);
    }

    function getRiskConfig(uint256 marketId) external view returns (PerpMarketRegistry.RiskConfig memory cfg) {
        _requireMarketExists(marketId);
        return _getRiskConfig(marketId);
    }

    function getFundingConfig(uint256 marketId) external view returns (PerpMarketRegistry.FundingConfig memory cfg) {
        _requireMarketExists(marketId);
        return _getFundingConfig(marketId);
    }

    function getMarketBundle(uint256 marketId)
        external
        view
        returns (
            PerpMarketRegistry.Market memory market_,
            PerpMarketRegistry.RiskConfig memory riskCfg,
            PerpMarketRegistry.FundingConfig memory fundingCfg,
            MarketState memory state_
        )
    {
        market_ = _requireMarketExists(marketId);
        riskCfg = _getRiskConfig(marketId);
        fundingCfg = _getFundingConfig(marketId);
        state_ = _marketStates[marketId];
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE / FUNDING VIEWS
    //////////////////////////////////////////////////////////////*/

    function getMarkPrice(uint256 marketId) public view returns (uint256 price1e8) {
        return _getMarkPrice1e8(marketId);
    }

    function tryGetMarkPrice(uint256 marketId) external view returns (uint256 price1e8, bool ok) {
        return _tryGetMarkPrice1e8(marketId);
    }

    function getCumulativeFundingRate(uint256 marketId) external view returns (int256 cumulativeFundingRate1e18) {
        _requireMarketExists(marketId);
        return _marketStates[marketId].cumulativeFundingRate1e18;
    }

    function getLastFundingTimestamp(uint256 marketId) external view returns (uint64 lastFundingTimestamp) {
        _requireMarketExists(marketId);
        return _marketStates[marketId].lastFundingTimestamp;
    }

    function previewFundingPayment(address trader, uint256 marketId) external view returns (int256 fundingPayment1e8) {
        _requireMarketExists(marketId);
        return _positionFundingAccrued1e8(trader, marketId);
    }

    /*//////////////////////////////////////////////////////////////
                            POSITION VIEWS
    //////////////////////////////////////////////////////////////*/

    function getPositionSize(address trader, uint256 marketId) external view returns (int256 size1e8) {
        return _positions[trader][marketId].size1e8;
    }

    function getOpenNotional(address trader, uint256 marketId) external view returns (int256 openNotional1e8) {
        return _positions[trader][marketId].openNotional1e8;
    }

    function getLastPositionFundingSnapshot(address trader, uint256 marketId)
        external
        view
        returns (int256 lastCumulativeFundingRate1e18)
    {
        return _positions[trader][marketId].lastCumulativeFundingRate1e18;
    }

    function getPositionValue(address trader, uint256 marketId) external view returns (int256 markValue1e8) {
        Position memory p = _positions[trader][marketId];
        if (p.size1e8 == 0) return 0;

        uint256 markPrice1e8 = _getMarkPrice1e8(marketId);
        return _signedMarkValue1e8(p.size1e8, markPrice1e8);
    }

    function getPositionAbsNotional(address trader, uint256 marketId) external view returns (uint256 notional1e8) {
        Position memory p = _positions[trader][marketId];
        if (p.size1e8 == 0) return 0;

        uint256 markPrice1e8 = _getMarkPrice1e8(marketId);
        return _absNotional1e8(p.size1e8, markPrice1e8);
    }

    function getUnrealizedPnl(address trader, uint256 marketId) public view returns (int256 pnl1e8) {
        Position memory p = _positions[trader][marketId];
        if (p.size1e8 == 0) return 0;

        uint256 markPrice1e8 = _getMarkPrice1e8(marketId);
        return _unrealizedPnl1e8(p.size1e8, p.openNotional1e8, markPrice1e8);
    }

    function getPositionFundingAccrued(address trader, uint256 marketId) public view returns (int256 funding1e8) {
        return _positionFundingAccrued1e8(trader, marketId);
    }

    function getPositionSummary(address trader, uint256 marketId)
        external
        view
        returns (
            int256 size1e8,
            int256 openNotional1e8,
            int256 markValue1e8,
            int256 unrealizedPnl1e8,
            int256 fundingAccrued1e8,
            int256 lastCumulativeFundingRate1e18
        )
    {
        Position memory p = _positions[trader][marketId];
        size1e8 = p.size1e8;
        openNotional1e8 = p.openNotional1e8;
        lastCumulativeFundingRate1e18 = p.lastCumulativeFundingRate1e18;

        if (p.size1e8 == 0) {
            return (
                size1e8,
                openNotional1e8,
                0,
                0,
                0,
                lastCumulativeFundingRate1e18
            );
        }

        uint256 markPrice1e8 = _getMarkPrice1e8(marketId);
        markValue1e8 = _signedMarkValue1e8(p.size1e8, markPrice1e8);
        unrealizedPnl1e8 = _unrealizedPnl1e8(p.size1e8, p.openNotional1e8, markPrice1e8);
        fundingAccrued1e8 =
            _fundingPayment1e8(p.size1e8, _marketStates[marketId].cumulativeFundingRate1e18, p.lastCumulativeFundingRate1e18);
    }

    /*//////////////////////////////////////////////////////////////
                        AGGREGATE ACCOUNT VIEWS
    //////////////////////////////////////////////////////////////*/

    function getTotalAbsLongSize(address trader) external view returns (uint256) {
        return totalAbsLongSize1e8[trader];
    }

    function getTotalAbsShortSize(address trader) external view returns (uint256) {
        return totalAbsShortSize1e8[trader];
    }

    function getTotalMarketsOpen(address trader) external view returns (uint256) {
        return traderMarkets[trader].length;
    }

    function getAccountUnrealizedPnl(address trader) public view returns (int256 totalPnl1e8) {
        uint256[] memory markets = traderMarkets[trader];
        uint256 len = markets.length;

        for (uint256 i = 0; i < len; i++) {
            Position memory p = _positions[trader][markets[i]];
            if (p.size1e8 == 0) continue;

            uint256 markPrice1e8 = _getMarkPrice1e8(markets[i]);
            int256 pnl = _unrealizedPnl1e8(p.size1e8, p.openNotional1e8, markPrice1e8);
            totalPnl1e8 = _checkedAddInt256(totalPnl1e8, pnl);
        }
    }

    function getAccountFundingAccrued(address trader) public view returns (int256 totalFunding1e8) {
        uint256[] memory markets = traderMarkets[trader];
        uint256 len = markets.length;

        for (uint256 i = 0; i < len; i++) {
            Position memory p = _positions[trader][markets[i]];
            if (p.size1e8 == 0) continue;

            int256 f =
                _fundingPayment1e8(p.size1e8, _marketStates[markets[i]].cumulativeFundingRate1e18, p.lastCumulativeFundingRate1e18);
            totalFunding1e8 = _checkedAddInt256(totalFunding1e8, f);
        }
    }

    function getAccountNetPnl(address trader) external view returns (int256 netPnl1e8) {
        int256 upnl = getAccountUnrealizedPnl(trader);
        int256 funding = getAccountFundingAccrued(trader);
        return _checkedSubInt256(upnl, funding);
    }

    /*//////////////////////////////////////////////////////////////
                        RISK PASSTHROUGH VIEWS
    //////////////////////////////////////////////////////////////*/

    function getAccountRisk(address trader)
        external
        view
        returns (IPerpRiskModule.AccountRisk memory risk)
    {
        if (address(_riskModule) == address(0)) {
            return risk;
        }
        return _riskModule.computeAccountRisk(trader);
    }

    function getFreeCollateral(address trader) external view returns (int256 freeCollateral) {
        if (address(_riskModule) == address(0)) return 0;
        return _riskModule.computeFreeCollateral(trader);
    }

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        returns (IPerpRiskModule.WithdrawPreview memory preview)
    {
        if (address(_riskModule) == address(0)) {
            return preview;
        }
        return _riskModule.previewWithdrawImpact(trader, token, amount);
    }

    function getWithdrawableAmount(address trader, address token) external view returns (uint256 amount) {
        if (address(_riskModule) == address(0)) return 0;
        return _riskModule.getWithdrawableAmount(trader, token);
    }

    function getMarginRatioBps(address trader) external view returns (uint256) {
        if (address(_riskModule) == address(0)) return type(uint256).max;

        IPerpRiskModule.AccountRisk memory risk = _riskModule.computeAccountRisk(trader);
        return _marginRatioBpsFromState(risk.equity1e8, risk.maintenanceMargin1e8);
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET OI VIEWS
    //////////////////////////////////////////////////////////////*/

    function getMarketOpenInterest(uint256 marketId)
        external
        view
        returns (uint256 longOpenInterest1e8, uint256 shortOpenInterest1e8)
    {
        _requireMarketExists(marketId);
        MarketState memory s = _marketStates[marketId];
        return (s.longOpenInterest1e8, s.shortOpenInterest1e8);
    }

    function getMarketSkew(uint256 marketId) external view returns (int256 skew1e8) {
        _requireMarketExists(marketId);
        MarketState memory s = _marketStates[marketId];

        if (s.longOpenInterest1e8 >= s.shortOpenInterest1e8) {
            return _toInt256(s.longOpenInterest1e8 - s.shortOpenInterest1e8);
        }
        return -_toInt256(s.shortOpenInterest1e8 - s.longOpenInterest1e8);
    }

    function getMarketUtilizationBps(uint256 marketId) external view returns (uint256 utilizationBps) {
        _requireMarketExists(marketId);

        PerpMarketRegistry.RiskConfig memory rcfg = _getRiskConfig(marketId);
        if (rcfg.maxOpenInterest1e8 == 0) return 0;

        MarketState memory s = _marketStates[marketId];
        uint256 oi = s.longOpenInterest1e8 > s.shortOpenInterest1e8 ? s.longOpenInterest1e8 : s.shortOpenInterest1e8;

        return (oi * BPS) / uint256(rcfg.maxOpenInterest1e8);
    }
}