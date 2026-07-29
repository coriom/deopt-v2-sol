// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {VaultCapabilityController} from "../../../src/hybrid-v2/vault/VaultCapabilityController.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

import {VaultCapabilityControllerHarness} from "./harness/VaultCapabilityControllerHarness.sol";

/// @title VaultCapabilityControllerTest
/// @notice Unit + fuzz coverage for WP-03 abstract capability subsystem.
contract VaultCapabilityControllerTest is Test {
    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    VaultCapabilityControllerHarness internal controller;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);
    address internal constant NEW_GUARDIAN = address(0xFACE);
    address internal constant ENGINE_A = address(0xE1);
    address internal constant ENGINE_B = address(0xE2);
    address internal constant ATTACKER = address(0xBAD);

    function setUp() external {
        controller = new VaultCapabilityControllerHarness(GOVERNANCE, GUARDIAN);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_pinsGovernanceAndGuardian() external view {
        assertEq(controller.governance(), GOVERNANCE);
        assertEq(controller.guardian(), GUARDIAN);
    }

    function test_constructor_rejectsZeroGovernance() external {
        vm.expectRevert(VaultCapabilityController.InvalidGovernance.selector);
        new VaultCapabilityControllerHarness(address(0), GUARDIAN);
    }

    function test_constructor_rejectsZeroGuardian() external {
        vm.expectRevert(VaultCapabilityController.InvalidGuardian.selector);
        new VaultCapabilityControllerHarness(GOVERNANCE, address(0));
    }

    function test_constructor_emitsInitialGuardianAssignment() external {
        vm.expectEmit(true, true, false, true);
        emit VaultCapabilityController.GuardianChanged(address(0), GUARDIAN, Versions.EVENT_VERSION);
        new VaultCapabilityControllerHarness(GOVERNANCE, GUARDIAN);
    }

    /*//////////////////////////////////////////////////////////////
                        setEngineCapability — grant
    //////////////////////////////////////////////////////////////*/

    function test_setEngineCapability_grantsSingleBit() external {
        vm.expectEmit(true, false, false, true);
        emit VaultCapabilityController.EngineCapabilityChanged(
            ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL, 0, Versions.EVENT_VERSION
        );
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL, true);

        assertEq(controller.engineCapabilityBits(ENGINE_A), Capabilities.CAP_LOCK_COLLATERAL);
        assertTrue(controller.isAuthorizedEngine(ENGINE_A));
    }

    function test_setEngineCapability_grantsMultipleBits() external {
        uint256 mask =
            Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_UNLOCK_OWN_RESERVATION | Capabilities.CAP_APPLY_FEE;
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, mask, true);
        assertEq(controller.engineCapabilityBits(ENGINE_A), mask);
    }

    function test_setEngineCapability_grantIsCumulative() external {
        vm.startPrank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL, true);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
        vm.stopPrank();

        assertEq(
            controller.engineCapabilityBits(ENGINE_A), Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_APPLY_FEE
        );
    }

    function test_setEngineCapability_grantsAllCapabilitiesExactly() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.ALL_CAPABILITIES, true);
        assertEq(controller.engineCapabilityBits(ENGINE_A), Capabilities.ALL_CAPABILITIES);
    }

    function test_setEngineCapability_noopSkipsEvent() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);

        vm.recordLogs();
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
        assertEq(vm.getRecordedLogs().length, 0, "no-op grant must not emit");
    }

    /*//////////////////////////////////////////////////////////////
                       setEngineCapability — revoke
    //////////////////////////////////////////////////////////////*/

    function test_setEngineCapability_revokesSingleBit() external {
        vm.startPrank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.ALL_CAPABILITIES, true);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL, false);
        vm.stopPrank();

        assertEq(
            controller.engineCapabilityBits(ENGINE_A), Capabilities.ALL_CAPABILITIES & ~Capabilities.CAP_LOCK_COLLATERAL
        );
        assertTrue(controller.isAuthorizedEngine(ENGINE_A), "other bits remain");
    }

    function test_setEngineCapability_revokesAllViaExactMask() external {
        vm.startPrank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.ALL_CAPABILITIES, true);
        controller.setEngineCapability(ENGINE_A, Capabilities.ALL_CAPABILITIES, false);
        vm.stopPrank();

        assertEq(controller.engineCapabilityBits(ENGINE_A), 0);
        assertFalse(controller.isAuthorizedEngine(ENGINE_A));
    }

    function test_setEngineCapability_revokeAbsentBitIsNoop() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);

        vm.recordLogs();
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL, false);
        assertEq(vm.getRecordedLogs().length, 0, "no-op revoke must not emit");
        assertEq(controller.engineCapabilityBits(ENGINE_A), Capabilities.CAP_APPLY_FEE);
    }

    function test_setEngineCapability_emitsAddedAndRemovedCorrectly() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_APPLY_FEE, true);

        // Grant one new + already-present: added should be JUST the new one.
        vm.expectEmit(true, false, false, true);
        emit VaultCapabilityController.EngineCapabilityChanged(
            ENGINE_A, Capabilities.CAP_UNLOCK_OWN_RESERVATION, 0, Versions.EVENT_VERSION
        );
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(
            ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_UNLOCK_OWN_RESERVATION, true
        );
    }

    /*//////////////////////////////////////////////////////////////
                    setEngineCapability — validation
    //////////////////////////////////////////////////////////////*/

    function test_setEngineCapability_revertsForZeroEngine() external {
        vm.prank(GOVERNANCE);
        vm.expectRevert(VaultCapabilityController.InvalidEngine.selector);
        controller.setEngineCapability(address(0), Capabilities.CAP_APPLY_FEE, true);
    }

    function test_setEngineCapability_revertsForZeroMask() external {
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(VaultCapabilityController.InvalidCapabilityMask.selector, 0));
        controller.setEngineCapability(ENGINE_A, 0, true);
    }

    function test_setEngineCapability_revertsForReservedBit() external {
        // Bumped from bit 15 → bit 16 by
        // `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` (WP-08B) — bit 15
        // is now `CAP_APPLY_OPTIONS_PREMIUM`.
        uint256 reserved = 1 << 16;
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(VaultCapabilityController.InvalidCapabilityMask.selector, reserved));
        controller.setEngineCapability(ENGINE_A, reserved, true);
    }

    function test_setEngineCapability_revertsForMixedReservedAndDefined() external {
        uint256 mixed = Capabilities.CAP_APPLY_FEE | (1 << 200);
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(VaultCapabilityController.InvalidCapabilityMask.selector, mixed));
        controller.setEngineCapability(ENGINE_A, mixed, true);
    }

    function test_setEngineCapability_revertsForNonGovernanceCaller() external {
        vm.prank(ATTACKER);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
    }

    function test_setEngineCapability_engineCannotSelfGrant() external {
        vm.prank(ENGINE_A);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
    }

    function test_setEngineCapability_guardianCannotGrant() external {
        vm.prank(GUARDIAN);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
    }

    /*//////////////////////////////////////////////////////////////
                        guardianRevokeEngine
    //////////////////////////////////////////////////////////////*/

    function test_guardianRevokeEngine_clearsAllBits() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.ALL_CAPABILITIES, true);

        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE_A);

        assertEq(controller.engineCapabilityBits(ENGINE_A), 0);
        assertFalse(controller.isAuthorizedEngine(ENGINE_A));
    }

    function test_guardianRevokeEngine_emitsCorrectEvents() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE | Capabilities.CAP_LOCK_COLLATERAL, true);

        vm.expectEmit(true, false, false, true);
        emit VaultCapabilityController.EngineCapabilityChanged(
            ENGINE_A, 0, Capabilities.CAP_APPLY_FEE | Capabilities.CAP_LOCK_COLLATERAL, Versions.EVENT_VERSION
        );
        vm.expectEmit(true, true, false, true);
        emit VaultCapabilityController.EngineGuardianRevoked(ENGINE_A, GUARDIAN, Versions.EVENT_VERSION);

        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE_A);
    }

    function test_guardianRevokeEngine_idempotentOnAlreadyEmpty() external {
        // Only the audit event fires (no capability change event).
        vm.expectEmit(true, true, false, true);
        emit VaultCapabilityController.EngineGuardianRevoked(ENGINE_A, GUARDIAN, Versions.EVENT_VERSION);
        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE_A);

        assertEq(controller.engineCapabilityBits(ENGINE_A), 0);
    }

    function test_guardianRevokeEngine_revertsForNonGuardian() external {
        vm.prank(ATTACKER);
        vm.expectRevert(VaultCapabilityController.OnlyGuardian.selector);
        controller.guardianRevokeEngine(ENGINE_A);
    }

    function test_guardianRevokeEngine_governanceIsNotGuardian() external {
        vm.prank(GOVERNANCE);
        vm.expectRevert(VaultCapabilityController.OnlyGuardian.selector);
        controller.guardianRevokeEngine(ENGINE_A);
    }

    function test_guardianRevokeEngine_revertsForZeroEngine() external {
        vm.prank(GUARDIAN);
        vm.expectRevert(VaultCapabilityController.InvalidEngine.selector);
        controller.guardianRevokeEngine(address(0));
    }

    function test_guardianRevokeEngine_doesNotTouchReservations() external {
        controller.testSeedReservation(ENGINE_A, 42 ether);
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL, true);

        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE_A);

        assertEq(controller.testReservationOf(ENGINE_A), 42 ether, "reservations MUST survive guardian revoke");
    }

    function test_guardianRevokeEngine_governanceCanRegrantAfter() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE_A);
        assertEq(controller.engineCapabilityBits(ENGINE_A), 0);

        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
        assertEq(controller.engineCapabilityBits(ENGINE_A), Capabilities.CAP_APPLY_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                            setGuardian
    //////////////////////////////////////////////////////////////*/

    function test_setGuardian_rotatesAndEmits() external {
        vm.expectEmit(true, true, false, true);
        emit VaultCapabilityController.GuardianChanged(GUARDIAN, NEW_GUARDIAN, Versions.EVENT_VERSION);
        vm.prank(GOVERNANCE);
        controller.setGuardian(NEW_GUARDIAN);

        assertEq(controller.guardian(), NEW_GUARDIAN);
    }

    function test_setGuardian_oldGuardianLosesAuthority() external {
        vm.prank(GOVERNANCE);
        controller.setGuardian(NEW_GUARDIAN);

        vm.prank(GUARDIAN);
        vm.expectRevert(VaultCapabilityController.OnlyGuardian.selector);
        controller.guardianRevokeEngine(ENGINE_A);
    }

    function test_setGuardian_newGuardianCanRevoke() external {
        vm.prank(GOVERNANCE);
        controller.setGuardian(NEW_GUARDIAN);

        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);

        vm.prank(NEW_GUARDIAN);
        controller.guardianRevokeEngine(ENGINE_A);
        assertEq(controller.engineCapabilityBits(ENGINE_A), 0);
    }

    function test_setGuardian_revertsForZeroAddress() external {
        vm.prank(GOVERNANCE);
        vm.expectRevert(VaultCapabilityController.InvalidGuardian.selector);
        controller.setGuardian(address(0));
    }

    function test_setGuardian_revertsForNonGovernance() external {
        vm.prank(GUARDIAN);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setGuardian(NEW_GUARDIAN);

        vm.prank(ATTACKER);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setGuardian(NEW_GUARDIAN);
    }

    function test_setGuardian_sameAddressIsNoop() external {
        vm.recordLogs();
        vm.prank(GOVERNANCE);
        controller.setGuardian(GUARDIAN);
        assertEq(vm.getRecordedLogs().length, 0, "no-op rotation must not emit");
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_engineCapabilityBits_unknownEngineIsZero() external view {
        assertEq(controller.engineCapabilityBits(ENGINE_B), 0);
    }

    function test_isAuthorizedEngine_derivedFromBitmap() external {
        assertFalse(controller.isAuthorizedEngine(ENGINE_A));

        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
        assertTrue(controller.isAuthorizedEngine(ENGINE_A));

        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, false);
        assertFalse(controller.isAuthorizedEngine(ENGINE_A));
    }

    function test_hasCapabilities_zeroMaskFalse() external view {
        assertFalse(controller.hasCapabilities(ENGINE_A, 0));
    }

    function test_hasCapabilities_reservedMaskFalse() external view {
        assertFalse(controller.hasCapabilities(ENGINE_A, 1 << 15));
        assertFalse(controller.hasCapabilities(ENGINE_A, Capabilities.CAP_APPLY_FEE | (1 << 15)));
    }

    function test_hasCapabilities_allOfSemantics() external {
        uint256 mask = Capabilities.CAP_APPLY_FEE | Capabilities.CAP_LOCK_COLLATERAL;

        // No bits granted.
        assertFalse(controller.hasCapabilities(ENGINE_A, mask));

        // Only one bit granted.
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);
        assertFalse(controller.hasCapabilities(ENGINE_A, mask), "partial mask must not satisfy all-of");
        assertTrue(controller.hasCapabilities(ENGINE_A, Capabilities.CAP_APPLY_FEE));

        // Both bits granted.
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL, true);
        assertTrue(controller.hasCapabilities(ENGINE_A, mask));
    }

    function test_hasCapabilities_extraBitsDoNotBreakSubsetCheck() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.ALL_CAPABILITIES, true);
        assertTrue(controller.hasCapabilities(ENGINE_A, Capabilities.CAP_APPLY_FEE));
        assertTrue(controller.hasCapabilities(ENGINE_A, Capabilities.ALL_CAPABILITIES));
    }

    /*//////////////////////////////////////////////////////////////
                     _requireCapability harness gate
    //////////////////////////////////////////////////////////////*/

    function test_requireCapability_revertsWhenBitAbsent() external {
        vm.prank(ENGINE_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultCapabilityController.MissingCapability.selector, Capabilities.CAP_APPLY_FEE, ENGINE_A
            )
        );
        controller.testRequireCapability(Capabilities.CAP_APPLY_FEE);
    }

    function test_requireCapability_succeedsWhenAllBitsPresent() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE | Capabilities.CAP_LOCK_COLLATERAL, true);

        vm.prank(ENGINE_A);
        controller.testRequireCapability(Capabilities.CAP_APPLY_FEE | Capabilities.CAP_LOCK_COLLATERAL);
    }

    function test_requireCapability_zeroMaskReverts() external {
        vm.prank(ENGINE_A);
        vm.expectRevert(abi.encodeWithSelector(VaultCapabilityController.MissingCapability.selector, 0, ENGINE_A));
        controller.testRequireCapability(0);
    }

    function test_requireCapability_reservedMaskReverts() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, Capabilities.CAP_APPLY_FEE, true);

        vm.prank(ENGINE_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultCapabilityController.MissingCapability.selector, Capabilities.CAP_APPLY_FEE | (1 << 15), ENGINE_A
            )
        );
        controller.testRequireCapability(Capabilities.CAP_APPLY_FEE | (1 << 15));
    }

    /*//////////////////////////////////////////////////////////////
                          NATIVE + TOKEN
    //////////////////////////////////////////////////////////////*/

    function test_controllerHoldsNoNativeBalance() external view {
        assertEq(address(controller).balance, uint256(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_validMaskGrantThenReadBack(uint256 rawMask) external {
        // Restrict mask to defined bits.
        uint256 mask = rawMask & Capabilities.ALL_CAPABILITIES;
        vm.assume(mask != 0);

        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, mask, true);
        assertEq(controller.engineCapabilityBits(ENGINE_A) & mask, mask);
    }

    function testFuzz_invalidReservedMaskReverts(uint256 rawMask) external {
        // Force at least one reserved bit. Bumped from bit 15 → 16 by WP-08B.
        uint256 mask = rawMask | (1 << 16);
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(VaultCapabilityController.InvalidCapabilityMask.selector, mask));
        controller.setEngineCapability(ENGINE_A, mask, true);
    }

    function testFuzz_hasCapabilities_matchesManualComputation(uint256 grantedRaw, uint256 requiredRaw) external {
        uint256 granted = grantedRaw & Capabilities.ALL_CAPABILITIES;
        uint256 required = requiredRaw & Capabilities.ALL_CAPABILITIES;

        if (granted != 0) {
            vm.prank(GOVERNANCE);
            controller.setEngineCapability(ENGINE_A, granted, true);
        }

        bool expected = required != 0 && ((granted & required) == required);
        assertEq(controller.hasCapabilities(ENGINE_A, required), expected);
    }

    function testFuzz_guardianRevokeAlwaysClears(uint256 rawMask) external {
        uint256 mask = rawMask & Capabilities.ALL_CAPABILITIES;
        vm.assume(mask != 0);
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE_A, mask, true);

        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE_A);
        assertEq(controller.engineCapabilityBits(ENGINE_A), 0);
        assertFalse(controller.isAuthorizedEngine(ENGINE_A));
    }
}
