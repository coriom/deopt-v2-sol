// contracts/margin/MarginEngine.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {OptionProductRegistry} from "../OptionProductRegistry.sol";
import {CollateralVault} from "../CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";

import {MarginEngineOps} from "./MarginEngineOps.sol";

/// @title MarginEngine
/// @notice Façade finale (hérite MarginEngineOps)
contract MarginEngine is MarginEngineOps {
    constructor(address _owner, address registry_, address vault_, address oracle_) {
        if (_owner == address(0) || registry_ == address(0) || vault_ == address(0) || oracle_ == address(0)) {
            revert ZeroAddress();
        }

        owner = _owner;
        _optionRegistry = OptionProductRegistry(registry_);
        _collateralVault = CollateralVault(vault_);
        _oracle = IOracle(oracle_);

        emit OwnershipTransferred(address(0), _owner);
        emit OracleSet(oracle_);
        emit LiquidationOracleMaxDelaySet(0, liquidationOracleMaxDelay);
    }
}
