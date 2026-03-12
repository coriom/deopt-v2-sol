// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../CollateralVault.sol";
import "../OptionProductRegistry.sol";
import "../oracle/IOracle.sol";
import "./IMarginEngineState.sol";
import "./RiskModuleViews.sol";

contract RiskModule is RiskModuleViews {
    constructor(address _owner, address _vault, address _registry, address _marginEngine, address _oracle) {
        if (
            _owner == address(0) || _vault == address(0) || _registry == address(0) || _marginEngine == address(0)
                || _oracle == address(0)
        ) {
            revert ZeroAddress();
        }

        owner = _owner;
        collateralVault = CollateralVault(_vault);
        optionRegistry = OptionProductRegistry(_registry);
        marginEngine = IMarginEngineState(_marginEngine);
        oracle = IOracle(_oracle);

        emit OwnershipTransferred(address(0), _owner);
        emit MarginEngineSet(_marginEngine);
        emit OracleSet(_oracle);
        emit OracleDownMmMultiplierSet(oracleDownMmMultiplierBps);
    }
}