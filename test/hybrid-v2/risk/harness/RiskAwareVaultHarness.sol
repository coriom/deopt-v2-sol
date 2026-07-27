// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVaultV2RiskIntegrated} from "../../../../src/hybrid-v2/risk/CollateralVaultV2RiskIntegrated.sol";
import {CollateralVaultV2Core} from "../../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";

/// @title RiskAwareVaultHarness
/// @notice Test-only concrete inheritor of the abstract WP-07 risk-integrated
///         Vault. Provides a permissive orphan-release proof (WP-10 stub) so
///         the WP-04B constructor + WP-07 risk hooks compile into a deployable
///         contract for tests.
/// @dev Not shipped as production source. Production uses a real WP-10 concrete
///      override for `_requireOrphanedReleaseProof`.
contract RiskAwareVaultHarness is CollateralVaultV2RiskIntegrated {
    /// @notice When true, `_requireOrphanedReleaseProof` reverts
    ///         `UnresolvedOrphanedObligation`. Default: false (permissive) so
    ///         pre-existing Vault tests continue to pass through the harness.
    bool public rejectOrphanRelease;

    constructor(address registry_, address governance_, address guardian_, address riskModule_)
        CollateralVaultV2Core(registry_, governance_, guardian_)
        CollateralVaultV2RiskIntegrated(riskModule_)
    {}

    function setRejectOrphanRelease(bool reject) external {
        rejectOrphanRelease = reject;
    }

    /// @notice Test-only manual seed for `_balanceOf` + `_totalAccounted`. Lets
    ///         tests short-circuit deposit sequences.
    function testForceCredit(bytes32 subKey, address token, uint256 amount) external {
        _balanceOf[subKey][token] += amount;
        _totalAccounted[token] += amount;
    }

    function _requireOrphanedReleaseProof(bytes32 subKey, address token, address engine, uint256 amount)
        internal
        view
        override
    {
        if (rejectOrphanRelease) {
            revert UnresolvedOrphanedObligation(subKey, token, engine, amount);
        }
    }
}
