// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IMockRiskModuleView
/// @notice Minimal view surface consumed by `RiskModuleIntegrationVault` in tests.
///         Mirrors the two `IRiskModule` views the WP-04B abstract Vault hooks
///         must consult in production (spec 06 + WP-07 integration point).
interface IMockRiskModuleView {
    function withdrawalAllowed(bytes32 subKey, address token, uint256 amount) external view returns (bool);
    function transferAllowed(bytes32 sourceSubKey, address token, uint256 amount) external view returns (bool);
}

/// @title MockRiskModule
/// @notice Configurable stand-in for the future `RiskModuleV2` (WP-07). Enables
///         WP-04B safety-patch integration tests to prove a concrete Vault
///         inheritor can consult a real external view and roll back on rejection.
contract MockRiskModule is IMockRiskModuleView {
    bool public allowWithdrawals = true;
    bool public allowTransfers = true;

    mapping(bytes32 => mapping(address => bool)) public vetoWithdrawal;
    mapping(bytes32 => mapping(address => bool)) public vetoTransfer;

    function setAllowWithdrawals(bool allowed) external {
        allowWithdrawals = allowed;
    }

    function setAllowTransfers(bool allowed) external {
        allowTransfers = allowed;
    }

    function setVetoWithdrawal(bytes32 subKey, address token, bool veto) external {
        vetoWithdrawal[subKey][token] = veto;
    }

    function setVetoTransfer(bytes32 subKey, address token, bool veto) external {
        vetoTransfer[subKey][token] = veto;
    }

    function withdrawalAllowed(
        bytes32 subKey,
        address token,
        uint256 /*amount*/
    )
        external
        view
        returns (bool)
    {
        if (!allowWithdrawals) return false;
        return !vetoWithdrawal[subKey][token];
    }

    function transferAllowed(
        bytes32 sourceSubKey,
        address token,
        uint256 /*amount*/
    )
        external
        view
        returns (bool)
    {
        if (!allowTransfers) return false;
        return !vetoTransfer[sourceSubKey][token];
    }
}
