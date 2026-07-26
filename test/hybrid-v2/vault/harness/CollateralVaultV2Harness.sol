// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVaultV2} from "../../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {CollateralVaultV2Core} from "../../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";

/// @title CollateralVaultV2Harness
/// @notice Test-only concrete implementation of the WP-04B abstract Vault. Provides
///         two configurable risk hooks so tests can exercise both the happy path
///         (risk-approves) and the reject path (risk-refuses) without deploying a
///         real `RiskModule`.
/// @dev Production Vault MUST NOT default to permissive risk behavior — that is why
///      the abstract holds pure `virtual` hooks. This harness lives under `test/`
///      and is not shipped as production source.
contract CollateralVaultV2Harness is CollateralVaultV2 {
    /// @notice Global permissive/reject switches for the two risk hooks.
    bool public allowWithdrawals = true;
    bool public allowInternalTransfers = true;

    /// @notice Whether the orphaned-release proof hook approves calls by default.
    ///         Tests may toggle to simulate a downstream WP-10 rejection.
    bool public allowOrphanedRelease = true;

    /// @notice Optional per-(subKey, token) veto flags for finer-grained tests.
    mapping(bytes32 => mapping(address => bool)) public vetoWithdrawal;
    mapping(bytes32 => mapping(address => bool)) public vetoInternalTransfer;

    /// @notice Optional per-(subKey, token, engine) veto for orphan-release proof.
    mapping(bytes32 => mapping(address => mapping(address => bool))) public vetoOrphanedRelease;

    constructor(address registry_, address governance_, address guardian_)
        CollateralVaultV2Core(registry_, governance_, guardian_)
    {}

    /*//////////////////////////////////////////////////////////////
                          RISK HOOK OVERRIDES
    //////////////////////////////////////////////////////////////*/

    function _requireWithdrawalAllowed(
        bytes32 subKey,
        address token,
        uint256 /*amount*/
    )
        internal
        view
        override
    {
        if (!allowWithdrawals) revert UnsafeWithdrawal();
        if (vetoWithdrawal[subKey][token]) revert UnsafeWithdrawal();
    }

    function _requireInternalTransferAllowed(
        bytes32 sourceSubKey,
        address token,
        uint256 /*amount*/
    )
        internal
        view
        override
    {
        if (!allowInternalTransfers) revert UnsafeTransfer();
        if (vetoInternalTransfer[sourceSubKey][token]) revert UnsafeTransfer();
    }

    /// @dev Test-only orphan-release proof. Real production wiring in WP-10 will
    ///      consult the positions ledger, recovery state, and settlement queues.
    function _requireOrphanedReleaseProof(bytes32 subKey, address token, address engine, uint256 amount)
        internal
        view
        override
    {
        if (!allowOrphanedRelease) revert UnresolvedOrphanedObligation(subKey, token, engine, amount);
        if (vetoOrphanedRelease[subKey][token][engine]) {
            revert UnresolvedOrphanedObligation(subKey, token, engine, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            TEST CONTROLS
    //////////////////////////////////////////////////////////////*/

    function setAllowWithdrawals(bool allowed) external {
        allowWithdrawals = allowed;
    }

    function setAllowInternalTransfers(bool allowed) external {
        allowInternalTransfers = allowed;
    }

    function setVetoWithdrawal(bytes32 subKey, address token, bool veto) external {
        vetoWithdrawal[subKey][token] = veto;
    }

    function setVetoInternalTransfer(bytes32 subKey, address token, bool veto) external {
        vetoInternalTransfer[subKey][token] = veto;
    }

    function setAllowOrphanedRelease(bool allowed) external {
        allowOrphanedRelease = allowed;
    }

    function setVetoOrphanedRelease(bytes32 subKey, address token, address engine, bool veto) external {
        vetoOrphanedRelease[subKey][token][engine] = veto;
    }

    /// @notice Test-only manual seed for `_balanceOf` + `_totalAccounted`. Lets
    ///         tests short-circuit deposit-then-lock sequences without requiring
    ///         a real ERC-20 mint every time.
    function testForceCredit(bytes32 subKey, address token, uint256 amount) external {
        _balanceOf[subKey][token] += amount;
        _totalAccounted[token] += amount;
    }
}
