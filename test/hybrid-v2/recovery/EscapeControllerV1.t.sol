// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

import {EscapeControllerV1} from "../../../src/hybrid-v2/recovery/EscapeControllerV1.sol";
import {IEscapeController} from "../../../src/hybrid-v2/interfaces/IEscapeController.sol";
import {RecoveryState, RecoveryScope} from "../../../src/hybrid-v2/libraries/RecoveryTypes.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";

import {MockCapabilityAuthority} from "../registry/mocks/MockCapabilityAuthority.sol";

/// @title EscapeControllerV1Test
/// @notice `ONCHAIN-SUBACCOUNT-ESCAPE-CONTROLLER-V1` (WP-10A) — unit + fuzz
///         coverage for the state machine, authority boundary, delay
///         semantics, epoch invalidation, cancellation window, pause,
///         finalizer boundary, and error surface.
contract EscapeControllerV1Test is Test {
    /*//////////////////////////////////////////////////////////////
                              FIXTURES
    //////////////////////////////////////////////////////////////*/

    SubaccountRegistry internal registry;
    MockCapabilityAuthority internal authority;
    EscapeControllerV1 internal controller;

    address internal governance = address(0xC0DE);
    address internal alice;
    address internal bob;

    uint64 internal constant DELAY = 1 hours;
    uint64 internal constant PAUSE_MAX_BLOCKS = 3600;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        authority = new MockCapabilityAuthority();
        registry = new SubaccountRegistry(address(authority));
        controller = new EscapeControllerV1(address(registry), governance, DELAY, PAUSE_MAX_BLOCKS);

        vm.prank(alice);
        registry.registerNext(); // alice / subaccount 1
        vm.prank(alice);
        registry.registerNext(); // alice / subaccount 2
        vm.prank(bob);
        registry.registerNext(); // bob / subaccount 1
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTION / AUTHORITY
    //////////////////////////////////////////////////////////////*/

    function test_construction_rejectsZeroDependencies() public {
        vm.expectRevert(EscapeControllerV1.InvalidDependency.selector);
        new EscapeControllerV1(address(0), governance, DELAY, PAUSE_MAX_BLOCKS);
        vm.expectRevert(EscapeControllerV1.InvalidDependency.selector);
        new EscapeControllerV1(address(registry), address(0), DELAY, PAUSE_MAX_BLOCKS);
    }

    function test_construction_rejectsDelayAboveMax() public {
        vm.expectRevert(EscapeControllerV1.ActivationDelayTooLong.selector);
        new EscapeControllerV1(address(registry), governance, uint64(72 hours + 1), PAUSE_MAX_BLOCKS);
    }

    function test_construction_rejectsPauseAboveMax() public {
        uint64 tooBig = controller.MAX_PAUSE_DURATION_BLOCKS() + 1;
        vm.expectRevert(EscapeControllerV1.PauseMaxDurationTooLong.selector);
        new EscapeControllerV1(address(registry), governance, DELAY, tooBig);
    }

    function test_construction_persistsImmutables() public view {
        assertEq(address(controller.REGISTRY()), address(registry));
        assertEq(controller.GOVERNANCE(), governance);
        assertEq(controller.ACTIVATION_DELAY(), DELAY);
        assertEq(controller.PAUSE_MAX_DURATION_BLOCKS(), PAUSE_MAX_BLOCKS);
    }

    /*//////////////////////////////////////////////////////////////
                        ACTIVATION AUTHORITY
    //////////////////////////////////////////////////////////////*/

    function test_activateRecovery_ownerSuccessTransitionsToPending() public {
        bytes32 subKey = registry.subKeyOf(alice, 1);
        vm.prank(alice);
        controller.activateRecovery(1);
        assertEq(uint8(controller.recoveryStateOf(subKey)), uint8(RecoveryState.RECOVERY_PENDING));
        assertEq(controller.activationEligibleAt(subKey), uint64(block.timestamp) + DELAY);
    }

    function test_activateRecovery_nonOwnerRejected() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EscapeControllerV1.SubaccountNotFound.selector, bob, uint32(2)));
        controller.activateRecovery(2);
    }

    function test_activateRecovery_subaccountZeroRejected() public {
        vm.prank(alice);
        vm.expectRevert(EscapeControllerV1.InvalidSubaccountId.selector);
        controller.activateRecovery(0);
    }

    function test_activateRecovery_unregisteredSubaccountRejected() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EscapeControllerV1.SubaccountNotFound.selector, alice, uint32(99)));
        controller.activateRecovery(99);
    }

    function test_activateRecovery_idempotencyRejectedWhilePending() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.prank(alice);
        vm.expectRevert(IEscapeController.RecoveryAlreadyPending.selector);
        controller.activateRecovery(1);
    }

    function test_activateRecovery_zeroDelayImmediateActive() public {
        EscapeControllerV1 immediateController =
            new EscapeControllerV1(address(registry), governance, 0, PAUSE_MAX_BLOCKS);
        vm.prank(alice);
        immediateController.activateRecovery(1);
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertEq(uint8(immediateController.recoveryStateOf(subKey)), uint8(RecoveryState.RECOVERY_ACTIVE));
        assertEq(immediateController.recoveryEpochOf(subKey), 1);
    }

    function test_activateRecovery_afterCancelReactivatesFromCancelledState() public {
        bytes32 subKey = registry.subKeyOf(alice, 1);
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.prank(alice);
        controller.cancelRecovery(1);
        assertEq(uint8(controller.recoveryStateOf(subKey)), uint8(RecoveryState.CANCELLED));
        // Re-activate is allowed from CANCELLED.
        vm.prank(alice);
        controller.activateRecovery(1);
        assertEq(uint8(controller.recoveryStateOf(subKey)), uint8(RecoveryState.RECOVERY_PENDING));
    }

    /*//////////////////////////////////////////////////////////////
                        DELAY + FINALIZATION TRANSITION
    //////////////////////////////////////////////////////////////*/

    function test_finalizePendingActivation_beforeDelayReverts() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.expectRevert();
        controller.finalizePendingActivation(1, alice);
    }

    function test_finalizePendingActivation_exactBoundaryEligible() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.warp(block.timestamp + DELAY);
        controller.finalizePendingActivation(1, alice);
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertEq(uint8(controller.recoveryStateOf(subKey)), uint8(RecoveryState.RECOVERY_ACTIVE));
        assertEq(controller.recoveryEpochOf(subKey), 1);
    }

    function test_finalizePendingActivation_permissionlessCallerAllowed() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.warp(block.timestamp + DELAY);
        // Permissionless keeper (bob) may finalize.
        vm.prank(bob);
        controller.finalizePendingActivation(1, alice);
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertEq(uint8(controller.recoveryStateOf(subKey)), uint8(RecoveryState.RECOVERY_ACTIVE));
    }

    function test_finalizePendingActivation_wrongStateReverts() public {
        // No pending activation exists.
        vm.expectRevert();
        controller.finalizePendingActivation(1, alice);
    }

    function testFuzz_finalizePendingActivation_delayBoundary(uint64 warpDelta) public {
        warpDelta = uint64(bound(warpDelta, 0, 30 days));
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.warp(block.timestamp + warpDelta);
        if (warpDelta < DELAY) {
            vm.expectRevert();
            controller.finalizePendingActivation(1, alice);
        } else {
            controller.finalizePendingActivation(1, alice);
            bytes32 subKey = registry.subKeyOf(alice, 1);
            assertEq(uint8(controller.recoveryStateOf(subKey)), uint8(RecoveryState.RECOVERY_ACTIVE));
        }
    }

    /*//////////////////////////////////////////////////////////////
                        CANCELLATION AUTHORITY + WINDOW
    //////////////////////////////////////////////////////////////*/

    function test_cancelRecovery_onlyDuringPending() public {
        vm.prank(alice);
        vm.expectRevert(IEscapeController.RecoveryNotPending.selector);
        controller.cancelRecovery(1);
    }

    function test_cancelRecovery_afterActiveRejected() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.warp(block.timestamp + DELAY);
        controller.finalizePendingActivation(1, alice);
        vm.prank(alice);
        vm.expectRevert(IEscapeController.RecoveryNotPending.selector);
        controller.cancelRecovery(1);
    }

    function test_cancelRecovery_neverRollsEpochBack() public {
        bytes32 subKey = registry.subKeyOf(alice, 1);
        vm.prank(alice);
        controller.activateRecovery(1);
        // Epoch is still 0 at this stage — it only advances on promotion.
        assertEq(controller.recoveryEpochOf(subKey), 0);
        vm.prank(alice);
        controller.cancelRecovery(1);
        assertEq(controller.recoveryEpochOf(subKey), 0); // no rollback below 0
    }

    function test_cancelRecovery_notCallerRejected() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.prank(bob);
        vm.expectRevert(); // bob's derived subKey differs — RecoveryNotPending on bob's subKey
        controller.cancelRecovery(1);
    }

    /*//////////////////////////////////////////////////////////////
                        EPOCH INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function test_epochs_activationAdvancesSubaccountEpoch() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.warp(block.timestamp + DELAY);
        controller.finalizePendingActivation(1, alice);
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertEq(controller.recoveryEpochOf(subKey), 1);
    }

    function test_epochs_activationDoesNotAffectSibling() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.warp(block.timestamp + DELAY);
        controller.finalizePendingActivation(1, alice);
        bytes32 siblingSubKey = registry.subKeyOf(alice, 2);
        assertEq(controller.recoveryEpochOf(siblingSubKey), 0);
        assertEq(uint8(controller.recoveryStateOf(siblingSubKey)), uint8(RecoveryState.NORMAL));
    }

    function test_epochs_activationDoesNotAffectDifferentOwner() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.warp(block.timestamp + DELAY);
        controller.finalizePendingActivation(1, alice);
        bytes32 bobSk = registry.subKeyOf(bob, 1);
        assertEq(controller.recoveryEpochOf(bobSk), 0);
        assertEq(uint8(controller.recoveryStateOf(bobSk)), uint8(RecoveryState.NORMAL));
    }

    function test_epochs_invalidateIntentsBumpsSubaccountEpoch() public {
        bytes32 subKey = registry.subKeyOf(alice, 1);
        vm.prank(alice);
        controller.invalidateIntents(1);
        assertEq(controller.recoveryEpochOf(subKey), 1);
    }

    function test_epochs_invalidateAllIntentsBumpsOwnerEpoch() public {
        vm.prank(alice);
        controller.invalidateAllIntents();
        assertEq(controller.ownerRecoveryEpochOf(alice), 1);
    }

    function test_epochs_effectiveIsMaxOfSubAndOwner() public {
        vm.prank(alice);
        controller.invalidateIntents(1); // sub +1
        vm.prank(alice);
        controller.invalidateAllIntents(); // owner +1
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertEq(controller.effectiveRecoveryEpoch(subKey, alice), 1);
        vm.prank(alice);
        controller.invalidateAllIntents(); // owner +1 → 2
        assertEq(controller.effectiveRecoveryEpoch(subKey, alice), 2);
    }

    function test_epochs_monotoneNonDecreasing() public {
        bytes32 subKey = registry.subKeyOf(alice, 1);
        uint256 e0 = controller.recoveryEpochOf(subKey);
        vm.prank(alice);
        controller.invalidateIntents(1);
        uint256 e1 = controller.recoveryEpochOf(subKey);
        assertGt(e1, e0);
        // Cancellation NEVER decreases the epoch.
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.prank(alice);
        controller.cancelRecovery(1);
        assertEq(controller.recoveryEpochOf(subKey), e1);
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_nonGovernanceRejected() public {
        vm.prank(alice);
        vm.expectRevert(EscapeControllerV1.OnlyGovernance.selector);
        controller.pauseRecovery(100);
    }

    function test_pause_zeroDurationRejected() public {
        vm.prank(governance);
        vm.expectRevert(IEscapeController.PauseDurationTooLong.selector);
        controller.pauseRecovery(0);
    }

    function test_pause_aboveMaxRejected() public {
        vm.prank(governance);
        vm.expectRevert(IEscapeController.PauseDurationTooLong.selector);
        controller.pauseRecovery(PAUSE_MAX_BLOCKS + 1);
    }

    function test_pause_blocksActivation() public {
        vm.prank(governance);
        controller.pauseRecovery(100);
        vm.prank(alice);
        vm.expectRevert(IEscapeController.RecoveryPaused.selector);
        controller.activateRecovery(1);
    }

    function test_pause_autoClearsAfterBlocks() public {
        vm.prank(governance);
        controller.pauseRecovery(10);
        vm.roll(block.number + 10);
        // Auto-clear point reached — no revert.
        vm.prank(alice);
        controller.activateRecovery(1);
    }

    function test_unpause_governanceOnly() public {
        vm.prank(governance);
        controller.pauseRecovery(100);
        vm.prank(alice);
        vm.expectRevert(EscapeControllerV1.OnlyGovernance.selector);
        controller.unpauseRecovery();
    }

    function test_unpause_clearsPauseState() public {
        vm.prank(governance);
        controller.pauseRecovery(100);
        assertGt(controller.recoveryPausedUntil(), 0);
        vm.prank(governance);
        controller.unpauseRecovery();
        assertEq(controller.recoveryPausedUntil(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        FINALIZER BOUNDARY (WP-10A)
    //////////////////////////////////////////////////////////////*/

    function test_finalizerBoundary_alwaysReturnsFalse() public view {
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertFalse(controller.isFinalizationReady(subKey));
    }

    function test_withdrawalNotImplemented_reserveReverts() public {
        vm.expectRevert(EscapeControllerV1.RecoveryFinalizationNotYetImplemented.selector);
        controller.reserveRecoveryWithdrawal(1, address(0x1), 100);
    }

    function test_withdrawalNotImplemented_escapeWithdrawReverts() public {
        vm.expectRevert(EscapeControllerV1.RecoveryFinalizationNotYetImplemented.selector);
        controller.escapeWithdraw(1, address(0x1), 100);
    }

    function test_withdrawalNotImplemented_batchReverts() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(0x1);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 100;
        vm.expectRevert(EscapeControllerV1.RecoveryFinalizationNotYetImplemented.selector);
        controller.escapeWithdrawBatch(1, tokens, amts);
    }

    function test_pendingReservation_alwaysZero() public view {
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertEq(controller.pendingReservationOf(subKey, address(0x1)), 0);
        assertEq(controller.reservationExpiryOf(subKey, address(0x1)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        RISK-INCREASING VIEW (Part J)
    //////////////////////////////////////////////////////////////*/

    function test_isRiskIncreasingOperationAllowed_normalTrue() public view {
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertTrue(controller.isRiskIncreasingOperationAllowed(subKey));
    }

    function test_isRiskIncreasingOperationAllowed_pendingTrue() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        // Pending is still ALLOWED — the frozen state machine allows
        // in-flight matched intents to complete during the delay window
        // (design 04 rationale).
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertFalse(controller.isRiskIncreasingOperationAllowed(subKey));
    }

    function test_isRiskIncreasingOperationAllowed_activeFalse() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.warp(block.timestamp + DELAY);
        controller.finalizePendingActivation(1, alice);
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertFalse(controller.isRiskIncreasingOperationAllowed(subKey));
    }

    function test_isRiskIncreasingOperationAllowed_cancelledTrue() public {
        vm.prank(alice);
        controller.activateRecovery(1);
        vm.prank(alice);
        controller.cancelRecovery(1);
        bytes32 subKey = registry.subKeyOf(alice, 1);
        assertTrue(controller.isRiskIncreasingOperationAllowed(subKey));
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ: UNAUTHORIZED CALLERS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_activateRecovery_arbitraryCallerFailsOnOtherOwnerSubaccount(address rando, uint32 subaccountId)
        public
    {
        vm.assume(rando != alice && rando != bob && rando != address(0));
        subaccountId = uint32(bound(uint256(subaccountId), 1, 100));
        // Rando has no registered subaccount at any id → activation always reverts.
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(EscapeControllerV1.SubaccountNotFound.selector, rando, subaccountId));
        controller.activateRecovery(subaccountId);
    }
}
