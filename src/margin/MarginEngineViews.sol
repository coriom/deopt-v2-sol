// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRiskModule} from "../risk/IRiskModule.sol";
import {IMarginEngineState} from "../risk/IMarginEngineState.sol";

import {MarginEngineTrading} from "./MarginEngineTrading.sol";

/// @title MarginEngineViews
/// @notice Minimal core read surface required by protocol contracts and deployment verification.
/// @dev Rich account, settlement, fee and liquidation previews live in `MarginEngineLens`.
abstract contract MarginEngineViews is MarginEngineTrading {
    function positions(address trader, uint256 optionId)
        external
        view
        override
        returns (IMarginEngineState.Position memory)
    {
        return _positionOf(trader, optionId);
    }

    function getTraderSeries(address trader) external view override returns (uint256[] memory) {
        return _getTraderSeriesInternal(trader);
    }

    function getTraderSeriesLength(address trader) external view override returns (uint256) {
        return _getTraderSeriesLengthInternal(trader);
    }

    function getTraderSeriesSlice(address trader, uint256 start, uint256 end)
        external
        view
        override
        returns (uint256[] memory slice)
    {
        return _getTraderSeriesSliceInternal(trader, start, end);
    }

    function optionRegistry() external view override returns (address) {
        return _optionRegistryAddress();
    }

    function collateralVault() external view override returns (address) {
        return _collateralVaultAddress();
    }

    function oracle() external view override returns (address) {
        return _oracleAddress();
    }

    function riskModule() external view override returns (address) {
        return _riskModuleAddress();
    }

    function getPositionQuantity(address trader, uint256 optionId) external view override returns (int128) {
        return _positionQuantityOf(trader, optionId);
    }

    function isOpenSeries(address trader, uint256 optionId) external view override returns (bool) {
        return _isOpenSeriesInternal(trader, optionId);
    }

    function _isLiquidatableAccount(address trader) internal view returns (bool) {
        if (address(_riskModule) == address(0)) return false;

        IRiskModule.AccountRisk memory risk = _riskModule.computeAccountRisk(trader);
        if (risk.maintenanceMarginBase == 0) return false;
        if (risk.equityBase <= 0) return true;

        return _marginRatioBpsFromRisk(risk.equityBase, risk.maintenanceMarginBase) < liquidationThresholdBps;
    }
}
