// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CollateralVaultActions.sol";

/// @title CollateralVault
/// @notice Final shared collateral vault for DeOpt v2.
/// @dev
///  Inheritance stack:
///   CollateralVault
///     -> CollateralVaultActions
///     -> CollateralVaultViews
///     -> CollateralVaultYield
///     -> CollateralVaultAdmin
///     -> CollateralVaultStorage
///
///  Role in protocol:
///   - shared collateral substrate for options + perps
///   - multi-token collateral accounting
///   - cross-product internal account transfers
///   - optional yield routing through adapters
///   - risk-aware withdrawals through RiskModule hooks
///   - insurance fund compatible as a normal in-vault account
///
///  Constructor wires only owner/bootstrap state.
///  Remaining dependencies are configured later via admin:
///   - marginEngine
///   - authorized engines
///   - riskModule
///   - collateral token configs
///   - token strategies
///   - guardian / emergency modes
contract CollateralVault is CollateralVaultActions {
    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();

        owner = _owner;

        emit OwnershipTransferred(address(0), _owner);
        emit EmergencyModeUpdated(false, false, false, false);
    }
}