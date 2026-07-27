// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {RiskModuleV2} from "../../../../src/hybrid-v2/risk/RiskModuleV2.sol";

/// @title RiskModuleV2Harness
/// @notice Test-only concrete inheritor of the abstract WP-07 RiskModuleV2.
///         Exposes configurable deterministic values so the tests can exercise:
///           - the interface fail-closed semantics;
///           - Vault-integration rollback on unsafe withdrawal / transfer;
///           - post-withdrawal available-margin arithmetic without inventing a
///             DeOpt-specific margin formula (deferred to WP-08).
/// @dev
///  The harness is NOT a claim about the DeOpt margin model. It stores per-subKey
///  required + available margin values that tests set directly; the withdrawn
///  amount valuation returns `amount * priceSet[token] / 1e8` in 1e18 units
///  (safely: intermediate math uses `uint256`).
contract RiskModuleV2Harness is RiskModuleV2 {
    /// @notice Global stale switch — when true, every `_compute*` hook returns
    ///         `ok = false`, forcing every external view to fail closed.
    bool public providerStale;

    /// @notice Per-subKey stale flag. Toggled from tests for finer control.
    mapping(bytes32 => bool) public subKeyStale;

    /// @notice Per-subKey required maintenance margin in 1e18 units.
    mapping(bytes32 => uint256) public requiredMarginOf;

    /// @notice Per-subKey aggregate available collateral value in 1e18 units.
    mapping(bytes32 => uint256) public availableMarginOf;

    /// @notice Per-token price in 1e8 units (1e8 = one quote unit per token unit).
    mapping(address => uint256) public tokenPrice1e8Of;

    /// @notice Per-token stale flag (overrides `tokenPrice1e8Of` when true).
    mapping(address => bool) public tokenStale;

    /// @notice Per-subKey Options-enablement override. Default: true.
    mapping(bytes32 => bool) public optionsDisabled;

    constructor(address registry_, address vault_, address optionsLedger_, uint16 moduleVersion_)
        RiskModuleV2(registry_, vault_, optionsLedger_, moduleVersion_)
    {}

    /*//////////////////////////////////////////////////////////////
                              TEST HOOKS
    //////////////////////////////////////////////////////////////*/

    function setProviderStale(bool stale) external {
        providerStale = stale;
    }

    function setSubKeyStale(bytes32 subKey, bool stale) external {
        subKeyStale[subKey] = stale;
    }

    function setRequiredMargin(bytes32 subKey, uint256 required1e18) external {
        requiredMarginOf[subKey] = required1e18;
    }

    function setAvailableMargin(bytes32 subKey, uint256 available1e18) external {
        availableMarginOf[subKey] = available1e18;
    }

    function setTokenPrice1e8(address token, uint256 price1e8) external {
        tokenPrice1e8Of[token] = price1e8;
    }

    function setTokenStale(address token, bool stale) external {
        tokenStale[token] = stale;
    }

    function setOptionsDisabled(bytes32 subKey, bool disabled) external {
        optionsDisabled[subKey] = disabled;
    }

    /*//////////////////////////////////////////////////////////////
                            ABSTRACT OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _computeMarginRequirement(bytes32 subKey) internal view override returns (uint256, bool) {
        if (providerStale || subKeyStale[subKey]) return (0, false);
        return (requiredMarginOf[subKey], true);
    }

    function _computeAvailableMargin(bytes32 subKey) internal view override returns (uint256, bool) {
        if (providerStale || subKeyStale[subKey]) return (0, false);
        return (availableMarginOf[subKey], true);
    }

    function _valueOfWithdrawnAmount(bytes32 subKey, address token, uint256 amount)
        internal
        view
        override
        returns (uint256, bool)
    {
        if (providerStale || subKeyStale[subKey] || tokenStale[token]) return (0, false);
        uint256 price = tokenPrice1e8Of[token];
        if (price == 0) return (0, false);
        // Convention: 1e18-scaled value = amount * price1e8 / 1e8.
        return ((amount * price) / 1e8, true);
    }

    function _optionsProductEnabled(bytes32 subKey) internal view override returns (bool) {
        return !optionsDisabled[subKey];
    }
}
