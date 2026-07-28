// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IOptionsRiskProvider} from "../../../../src/hybrid-v2/interfaces/IOptionsRiskProvider.sol";

/// @title MockOptionsRiskProvider
/// @notice Test-only concrete adapter for `IOptionsRiskProvider`. Every field is
///         directly settable so tests can exercise the WP-08 fail-closed paths
///         without deploying a full `OptionProductRegistry` behind it.
/// @dev Not shipped as production source.
contract MockOptionsRiskProvider is IOptionsRiskProvider {
    mapping(uint256 => SeriesRiskView) internal _series;
    mapping(address => UnderlyingRiskView) internal _underlying;
    mapping(address => OptionsRiskConfigView) internal _optionsRisk;
    mapping(uint256 => uint256) internal _settlementPrice1e8;
    mapping(uint256 => bool) internal _settlementFinalized;
    mapping(address => CollateralRiskView) internal _collateralRisk;

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setSeries(uint256 seriesId, SeriesRiskView calldata view_) external {
        _series[seriesId] = view_;
    }

    function setUnderlying(address underlying, UnderlyingRiskView calldata view_) external {
        _underlying[underlying] = view_;
    }

    function setOptionsRiskConfig(address underlying, OptionsRiskConfigView calldata view_) external {
        _optionsRisk[underlying] = view_;
    }

    function setSettlementPrice(uint256 seriesId, uint256 price1e8, bool finalized) external {
        _settlementPrice1e8[seriesId] = price1e8;
        _settlementFinalized[seriesId] = finalized;
    }

    function setCollateralRisk(address token, CollateralRiskView calldata view_) external {
        _collateralRisk[token] = view_;
    }

    /*//////////////////////////////////////////////////////////////
                            IOPTIONSRISKPROVIDER
    //////////////////////////////////////////////////////////////*/

    function seriesRiskView(uint256 seriesId) external view returns (SeriesRiskView memory) {
        return _series[seriesId];
    }

    function underlyingRiskView(address underlying) external view returns (UnderlyingRiskView memory) {
        return _underlying[underlying];
    }

    function optionsRiskConfigView(address underlying) external view returns (OptionsRiskConfigView memory) {
        return _optionsRisk[underlying];
    }

    function settlementPriceOf(uint256 seriesId) external view returns (uint256 price1e8, bool isFinalized) {
        return (_settlementPrice1e8[seriesId], _settlementFinalized[seriesId]);
    }

    function collateralRiskView(address token) external view returns (CollateralRiskView memory) {
        return _collateralRisk[token];
    }
}
