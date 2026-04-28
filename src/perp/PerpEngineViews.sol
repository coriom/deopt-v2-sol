// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./PerpEngineAdmin.sol";

abstract contract PerpEngineViews is PerpEngineAdmin {
    /*//////////////////////////////////////////////////////////////
                            DEPENDENCY READS
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

    function collateralSeizer() external view returns (address) {
        return address(_collateralSeizer);
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

    function marketState(uint256 marketId) external view returns (MarketState memory) {
        _requireMarketExists(marketId);
        return _marketStates[marketId];
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
        if (start >= len || start >= end) return new uint256[](0);
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

    /*//////////////////////////////////////////////////////////////
                        MARKET CONFIG READS
    //////////////////////////////////////////////////////////////*/

    function getRiskConfig(uint256 marketId) external view returns (PerpMarketRegistry.RiskConfig memory) {
        _requireMarketExists(marketId);
        return _getRiskConfig(marketId);
    }

    function getSettlementAsset(uint256 marketId) external view returns (address) {
        PerpMarketRegistry.Market memory m = _requireMarketExists(marketId);
        return m.settlementAsset;
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
}
