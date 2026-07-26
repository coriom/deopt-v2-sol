// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVaultV2} from "../../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {CollateralVaultV2Core} from "../../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";

import {IMockRiskModuleView} from "../mocks/MockRiskModule.sol";

/// @title RiskModuleIntegrationVault
/// @notice Test-only concrete Vault that overrides `_requireWithdrawalAllowed`,
///         `_requireInternalTransferAllowed`, and `_requireOrphanedReleaseProof`
///         to consult an EXTERNAL view contract. Proves the WP-04B abstract
///         boundary is compatible with the WP-07 pattern: an immutable
///         `IRiskModule` reference + `view`-only hook overrides.
/// @dev The mock `IMockRiskModuleView` mirrors the two views the real
///      `IRiskModule` exposes. This harness is not shipped as production source.
contract RiskModuleIntegrationVault is CollateralVaultV2 {
    /// @notice Immutable risk-module reference — the pattern WP-07 must reproduce.
    IMockRiskModuleView public immutable RISK_MODULE;

    constructor(address registry_, address governance_, address guardian_, address riskModule_)
        CollateralVaultV2Core(registry_, governance_, guardian_)
    {
        require(riskModule_ != address(0), "risk-module zero");
        RISK_MODULE = IMockRiskModuleView(riskModule_);
    }

    function _requireWithdrawalAllowed(bytes32 subKey, address token, uint256 amount) internal view override {
        if (!RISK_MODULE.withdrawalAllowed(subKey, token, amount)) revert UnsafeWithdrawal();
    }

    function _requireInternalTransferAllowed(bytes32 sourceSubKey, address token, uint256 amount)
        internal
        view
        override
    {
        if (!RISK_MODULE.transferAllowed(sourceSubKey, token, amount)) revert UnsafeTransfer();
    }

    /// @dev Orphan-proof hook is out of RiskModule scope; keep it permissive here
    ///      so we can exercise the risk-module views in isolation. Real WP-10
    ///      integration will wire this hook against the escape controller +
    ///      positions ledger.
    function _requireOrphanedReleaseProof(
        bytes32, /*subKey*/
        address, /*token*/
        address, /*engine*/
        uint256 /*amount*/
    )
        internal
        view
        override
    {
        // no-op — permissive for this harness only
    }
}
