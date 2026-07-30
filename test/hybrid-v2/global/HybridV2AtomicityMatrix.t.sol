// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeploymentManifestV1TestBase} from "../deployment/DeploymentManifestV1TestBase.sol";
import {CollateralVaultV2} from "../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {EscapeControllerV1} from "../../../src/hybrid-v2/recovery/EscapeControllerV1.sol";
import {RecoveryFinalizerV1} from "../../../src/hybrid-v2/recovery/RecoveryFinalizerV1.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {RecoveryState} from "../../../src/hybrid-v2/libraries/RecoveryTypes.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";

/// @title HybridV2AtomicityMatrix
/// @notice WP-12 Part O — snapshots canonical state before each failure-injected
///         call and asserts every affected field is identical after the revert.
///         Proves `GLOBAL_ATOMIC_ROLLBACK_MATRIX_VERIFIED` across the highest-
///         value failure surfaces without depending on the full options
///         engine (which is already covered by its own atomicity suite).
contract HybridV2AtomicityMatrixTest is DeploymentManifestV1TestBase {
    address internal alice = address(0xA71CE);
    address internal bob = address(0xB0B);
    address internal engine = address(0xE1);

    struct Snapshot {
        uint256 aliceUsdcBalance;
        uint256 bobUsdcBalance;
        uint256 vaultUsdcAccounted;
        uint256 vaultUsdcPhysical;
        uint256 aliceLocked;
        uint256 aliceEngineLocked;
        uint8 aliceRecoveryState;
    }

    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        registry.registerNext();
        vm.prank(bob);
        registry.registerNext();

        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(alice);
        vault.deposit(1, address(usdc), 5_000e6);

        vm.startPrank(governance);
        vault.setEngineCapability(engine, Capabilities.CAP_LOCK_COLLATERAL, true);
        vault.setEngineCapability(engine, Capabilities.CAP_UNLOCK_OWN_RESERVATION, true);
        vm.stopPrank();
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        bytes32 skA = registry.subKeyOf(alice, 1);
        bytes32 skB = registry.subKeyOf(bob, 1);
        s.aliceUsdcBalance = vault.balanceOf(skA, address(usdc));
        s.bobUsdcBalance = vault.balanceOf(skB, address(usdc));
        s.vaultUsdcAccounted = vault.totalAccounted(address(usdc));
        s.vaultUsdcPhysical = IERC20(address(usdc)).balanceOf(address(vault));
        s.aliceLocked = vault.lockedOf(skA, address(usdc));
        s.aliceEngineLocked = vault.lockedByEngineOf(skA, address(usdc), engine);
        s.aliceRecoveryState = uint8(escape.recoveryStateOf(skA));
    }

    function _assertSame(Snapshot memory a, Snapshot memory b) internal pure {
        assertEq(a.aliceUsdcBalance, b.aliceUsdcBalance, "alice bal drift");
        assertEq(a.bobUsdcBalance, b.bobUsdcBalance, "bob bal drift");
        assertEq(a.vaultUsdcAccounted, b.vaultUsdcAccounted, "totalAccounted drift");
        assertEq(a.vaultUsdcPhysical, b.vaultUsdcPhysical, "physical drift");
        assertEq(a.aliceLocked, b.aliceLocked, "locked drift");
        assertEq(a.aliceEngineLocked, b.aliceEngineLocked, "engine locked drift");
        assertEq(a.aliceRecoveryState, b.aliceRecoveryState, "state drift");
    }

    /*//////////////////////////////////////////////////////////////
                              FAILURE MATRIX
    //////////////////////////////////////////////////////////////*/

    function test_atomicity_withdrawExceedingBalanceReverts() external {
        Snapshot memory before = _snapshot();
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1, address(usdc), 100_000e6);
        _assertSame(before, _snapshot());
    }

    function test_atomicity_engineLockExceedingAvailableReverts() external {
        bytes32 skA = registry.subKeyOf(alice, 1);
        Snapshot memory before = _snapshot();
        vm.prank(engine);
        vm.expectRevert();
        vault.applyLock(skA, address(usdc), 100_000e6);
        _assertSame(before, _snapshot());
    }

    function test_atomicity_unauthorizedCallerCannotLock() external {
        bytes32 skA = registry.subKeyOf(alice, 1);
        Snapshot memory before = _snapshot();
        vm.prank(address(0xDEAD)); // no capabilities
        vm.expectRevert();
        vault.applyLock(skA, address(usdc), 100e6);
        _assertSame(before, _snapshot());
    }

    function test_atomicity_engineCannotReleaseOtherEnginesReservation() external {
        // Engine A locks 500. Engine B (which holds unlock cap) tries to release
        // A's reservation — must revert with insufficient engine reservation.
        bytes32 skA = registry.subKeyOf(alice, 1);
        vm.prank(engine);
        vault.applyLock(skA, address(usdc), 500e6);

        address engineB = address(0xE2);
        vm.startPrank(governance);
        vault.setEngineCapability(engineB, Capabilities.CAP_UNLOCK_OWN_RESERVATION, true);
        vm.stopPrank();

        Snapshot memory before = _snapshot();
        vm.prank(engineB);
        vm.expectRevert();
        vault.applyUnlock(skA, address(usdc), 100e6);
        _assertSame(before, _snapshot());
    }

    function test_atomicity_finalizeBlockedByOutstandingReservation() external {
        bytes32 skA = registry.subKeyOf(alice, 1);
        // Alice locks a reservation, requests recovery, waits, activates.
        vm.prank(engine);
        vault.applyLock(skA, address(usdc), 500e6);

        vm.prank(alice);
        escape.activateRecovery(1);
        vm.warp(block.timestamp + escape.ACTIVATION_DELAY() + 1);
        escape.finalizePendingActivation(1, alice);

        // Recovery is ACTIVE. Finalize attempt must revert because the lock
        // still exists, and the state MUST NOT transition to RECOVERED.
        Snapshot memory before = _snapshot();
        vm.prank(alice);
        vm.expectRevert();
        finalizer.finalize(1);
        _assertSame(before, _snapshot());
        assertEq(uint8(escape.recoveryStateOf(skA)), uint8(RecoveryState.RECOVERY_ACTIVE));
    }

    function test_atomicity_finalizedSubaccountRejectsDeposit() external {
        // Fully cycle recovery to RECOVERED, then attempt a deposit.
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.warp(block.timestamp + escape.ACTIVATION_DELAY() + 1);
        escape.finalizePendingActivation(1, alice);
        vm.prank(alice);
        finalizer.finalize(1);

        Snapshot memory before = _snapshot();
        vm.prank(alice);
        vm.expectRevert();
        vault.deposit(1, address(usdc), 100e6);
        _assertSame(before, _snapshot());
    }

    function test_atomicity_secondFinalizationImpossible() external {
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.warp(block.timestamp + escape.ACTIVATION_DELAY() + 1);
        escape.finalizePendingActivation(1, alice);
        vm.prank(alice);
        finalizer.finalize(1);

        Snapshot memory before = _snapshot();
        vm.prank(alice);
        vm.expectRevert();
        finalizer.finalize(1);
        _assertSame(before, _snapshot());
    }

    function test_atomicity_guardianRevocationBlocksNewLockButPreservesExisting() external {
        bytes32 skA = registry.subKeyOf(alice, 1);
        // Engine locks first.
        vm.prank(engine);
        vault.applyLock(skA, address(usdc), 500e6);

        // Guardian revokes.
        vm.prank(guardian);
        vault.guardianRevokeEngine(engine);

        // Existing reservation is preserved.
        assertEq(vault.lockedOf(skA, address(usdc)), 500e6);

        // New lock attempt reverts with no state change.
        Snapshot memory before = _snapshot();
        vm.prank(engine);
        vm.expectRevert();
        vault.applyLock(skA, address(usdc), 100e6);
        _assertSame(before, _snapshot());
    }

    function test_atomicity_recoveryActiveRejectsWithdraw() external {
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.warp(block.timestamp + escape.ACTIVATION_DELAY() + 1);
        escape.finalizePendingActivation(1, alice);

        Snapshot memory before = _snapshot();
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1, address(usdc), 100e6);
        _assertSame(before, _snapshot());
    }

    function test_atomicity_donationSurplusUntouchedByFinalization() external {
        bytes32 skA = registry.subKeyOf(alice, 1);
        // Direct ERC-20 donation to the vault (increases physical balance
        // above totalAccounted).
        usdc.mint(address(this), 1_000e6);
        usdc.transfer(address(vault), 1_000e6);
        uint256 accountedBefore = vault.totalAccounted(address(usdc));
        uint256 physicalBefore = IERC20(address(usdc)).balanceOf(address(vault));
        assertEq(physicalBefore - accountedBefore, 1_000e6);

        // Alice finalizes recovery. Her balance is fully withdrawn but the
        // donation surplus MUST remain in the vault (not transferred).
        uint256 aliceBalanceBefore = vault.balanceOf(skA, address(usdc));
        vm.prank(alice);
        escape.activateRecovery(1);
        vm.warp(block.timestamp + escape.ACTIVATION_DELAY() + 1);
        escape.finalizePendingActivation(1, alice);
        vm.prank(alice);
        finalizer.finalize(1);

        uint256 physicalAfter = IERC20(address(usdc)).balanceOf(address(vault));
        uint256 accountedAfter = vault.totalAccounted(address(usdc));
        // Physical dropped by exactly aliceBalanceBefore; accounted dropped by
        // the same amount; donation surplus preserved.
        assertEq(physicalBefore - physicalAfter, aliceBalanceBefore);
        assertEq(accountedBefore - accountedAfter, aliceBalanceBefore);
        assertEq(physicalAfter - accountedAfter, 1_000e6, "donation drained");
    }
}
