// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {VaultCapabilityController} from "../../../../src/hybrid-v2/vault/VaultCapabilityController.sol";

/// @title VaultCapabilityControllerHarness
/// @notice Minimal test-only concrete of the abstract capability subsystem.
/// @dev Adds only what tests need — no economic behavior. Exposes the internal
///      `_requireCapability` gate so its behavior can be asserted, and provides a
///      test-only "reservation" counter so tests can prove that guardian revocation
///      does NOT touch reservation accounting (mirroring the production invariant
///      that release is owned by governance, not guardian).
contract VaultCapabilityControllerHarness is VaultCapabilityController {
    /// @dev Test-only "reservation" counter. Never touched by the abstract itself.
    ///      A production Vault owns real per-engine reservations; this harness only
    ///      proves the capability layer never modifies unrelated state on its own.
    mapping(address => uint256) public testReservationOf;

    constructor(address governance_, address guardian_) VaultCapabilityController(governance_, guardian_) {}

    /// @notice Test-only reservation top-up. Never called by the abstract.
    function testSeedReservation(address engine, uint256 amount) external {
        testReservationOf[engine] = amount;
    }

    /// @notice Test-only helper exposing the internal `_requireCapability` gate.
    /// @dev Any caller may invoke; the gate checks capabilities of `msg.sender`.
    ///      Reverts `MissingCapability(mask, msg.sender)` on failure.
    function testRequireCapability(uint256 requiredMask) external view {
        _requireCapability(requiredMask);
    }
}
