// SPDX-License-Identifier: BSL-1.1
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

    /// @notice Returns the market mark price used across the engine, in 1e8.
    /// @dev
    ///  V1 policy: risk mark == index (oracle spot). This is intentional. A raw orderbook
    ///  midpoint would be manipulable on a thin launch market, especially before deep liquidity
    ///  has accumulated. Consumers that need a "risk mark" (margin / maintenance / liquidation)
    ///  MAY read this function today, but SHOULD read `getRiskMarkPrice1e8` for forward
    ///  compatibility.
    ///
    ///  V2 (PERPS-FUNDING-V2): this function will diverge — a distinct mark = index + bounded/
    ///  smoothed premium will be exposed here, while `getRiskMarkPrice1e8` will keep tracking
    ///  a conservative reference (index or bounded oracle mark) suitable for margin and
    ///  liquidation math. Do NOT assume `getMarkPrice == getRiskMarkPrice1e8` in future versions.
    function getMarkPrice(uint256 marketId) public view returns (uint256) {
        return _getMarkPrice1e8(marketId);
    }

    /// @notice Returns the risk mark price used by margin / maintenance / liquidation logic, in 1e8.
    /// @dev
    ///  V1 policy: `getRiskMarkPrice1e8` is a direct alias for `getMarkPrice` (== oracle index/spot).
    ///  This is the reference price the engine uses for unrealized PnL, initial and maintenance
    ///  margin, liquidation trigger, liquidation execution price, and the
    ///  execution-price deviation guard in `applyTrade`.
    ///
    ///  Intentional invariant for V1: risk mark == index. Using a raw orderbook midpoint would
    ///  be manipulable on a thin launch market. The alias exists so downstream tooling and
    ///  future consumers can already bind to the semantically stable "risk mark" surface today,
    ///  and receive the correct value automatically once PERPS-FUNDING-V2 introduces a
    ///  distinct mark = index + bounded/smoothed premium.
    ///
    ///  For margin / maintenance / liquidation, this "risk mark" is the reference to use.
    ///  The (currently identical) `getMarkPrice` is what will diverge in V2.
    ///
    ///  This function is a pure view alias in V1: it does NOT change any consumer today.
    function getRiskMarkPrice1e8(uint256 marketId) external view returns (uint256) {
        return _getMarkPrice1e8(marketId);
    }

    function getUnrealizedPnl(address trader, uint256 marketId) public view returns (int256) {
        return _positionUnrealizedPnl1e8(trader, marketId, _getMarkPrice1e8(marketId));
    }

    function getPositionFundingAccrued(address trader, uint256 marketId) public view returns (int256) {
        return _positionFundingAccrued1e8(trader, marketId);
    }
}
