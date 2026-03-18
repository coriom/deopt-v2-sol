// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskModuleViews.sol";

contract RiskModule is RiskModuleViews {
    constructor(address _owner, address _vault, address _registry, address _marginEngine, address _oracle) {
        _initRiskModuleStorage(_owner, _vault, _registry, _marginEngine, _oracle);
    }
}