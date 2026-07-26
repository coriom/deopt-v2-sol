// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {CollateralVaultV2} from "../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {VaultCapabilityController} from "../../../src/hybrid-v2/vault/VaultCapabilityController.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ISubaccountRegistry} from "../../../src/hybrid-v2/interfaces/ISubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

import {CollateralVaultV2Harness} from "./harness/CollateralVaultV2Harness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantToken} from "./mocks/MaliciousTokens.sol";

/// @title CollateralVaultV2Test
/// @notice Unit + fuzz coverage for WP-04B reservations, withdrawal, internal transfer,
///         pause, and orphaned-lock release.
contract CollateralVaultV2Test is Test {
    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);
    address internal constant OWNER_A = address(0xA1);
    address internal constant OWNER_B = address(0xB2);
    address internal constant ENGINE_A = address(0xE1);
    address internal constant ENGINE_B = address(0xE2);
    address internal constant ATTACKER = address(0xBAD);

    function setUp() external {
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new SubaccountRegistry(predictedVault);
        vault = new CollateralVaultV2Harness(address(registry), GOVERNANCE, GUARDIAN);
        assertEq(address(vault), predictedVault);

        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);

        vm.startPrank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));
        vault.addSupportedToken(address(weth));
        // Vault holds lazy-registration capability for `deposit(subaccountId=1)`.
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        // Engines A and B receive lock + unlock capabilities.
        vault.setEngineCapability(
            ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_UNLOCK_OWN_RESERVATION, true
        );
        vault.setEngineCapability(
            ENGINE_B, Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_UNLOCK_OWN_RESERVATION, true
        );
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               LOCKS
    //////////////////////////////////////////////////////////////*/

    function test_lock_exactAvailable() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);

        vm.expectEmit(true, true, true, true);
        emit CollateralVaultV2.CollateralLocked(key, address(usdc), ENGINE_A, 1000e6, Versions.EVENT_VERSION);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 1000e6);

        assertEq(vault.lockedOf(key, address(usdc)), 1000e6);
        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 1000e6);
        assertEq(vault.availableOf(key, address(usdc)), 0);
        assertEq(vault.balanceOf(key, address(usdc)), 1000e6);
    }

    function test_lock_aboveAvailableReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 100e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);

        vm.prank(ENGINE_A);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVaultV2.InsufficientAvailableCollateral.selector, 101e6, 100e6)
        );
        vault.applyLock(key, address(usdc), 101e6);
    }

    function test_lock_multiEngineReservationsIsolated() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);

        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 300e6);
        vm.prank(ENGINE_B);
        vault.applyLock(key, address(usdc), 200e6);

        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 300e6);
        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_B), 200e6);
        assertEq(vault.lockedOf(key, address(usdc)), 500e6);
        assertEq(vault.availableOf(key, address(usdc)), 500e6);
    }

    function test_lock_missingCapabilityReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 100e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);

        vm.prank(ATTACKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultCapabilityController.MissingCapability.selector, Capabilities.CAP_LOCK_COLLATERAL, ATTACKER
            )
        );
        vault.applyLock(key, address(usdc), 10e6);
    }

    function test_lock_zeroSubKeyReverts() external {
        vm.prank(ENGINE_A);
        vm.expectRevert(CollateralVaultV2.SubKeyRequired.selector);
        vault.applyLock(bytes32(0), address(usdc), 1e6);
    }

    function test_lock_zeroAmountReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 100e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vm.expectRevert(CollateralVaultV2Core.AmountZero.selector);
        vault.applyLock(key, address(usdc), 0);
    }

    /*//////////////////////////////////////////////////////////////
                               UNLOCKS
    //////////////////////////////////////////////////////////////*/

    function test_unlock_partial() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 500e6);

        vm.expectEmit(true, true, true, true);
        emit CollateralVaultV2.CollateralUnlocked(key, address(usdc), ENGINE_A, 200e6, Versions.EVENT_VERSION);
        vm.prank(ENGINE_A);
        vault.applyUnlock(key, address(usdc), 200e6);

        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 300e6);
        assertEq(vault.lockedOf(key, address(usdc)), 300e6);
        assertEq(vault.availableOf(key, address(usdc)), 700e6);
    }

    function test_unlock_full() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 500e6);
        vm.prank(ENGINE_A);
        vault.applyUnlock(key, address(usdc), 500e6);

        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 0);
        assertEq(vault.lockedOf(key, address(usdc)), 0);
        assertEq(vault.availableOf(key, address(usdc)), 1000e6);
    }

    function test_unlock_excessiveReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 200e6);

        vm.prank(ENGINE_A);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2.InsufficientEngineReservation.selector, 300e6, 200e6));
        vault.applyUnlock(key, address(usdc), 300e6);
    }

    function test_unlock_crossEngineForbidden() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 300e6);

        // Engine B has unlock capability but no reservation on this key.
        vm.prank(ENGINE_B);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2.InsufficientEngineReservation.selector, 100e6, 0));
        vault.applyUnlock(key, address(usdc), 100e6);

        // Engine A's reservation is untouched.
        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 300e6);
    }

    function test_unlock_missingCapabilityReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 100e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);

        // Revoke ENGINE_A's unlock capability but not lock.
        vm.prank(GOVERNANCE);
        vault.setEngineCapability(ENGINE_A, Capabilities.CAP_UNLOCK_OWN_RESERVATION, false);

        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 50e6);

        vm.prank(ENGINE_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultCapabilityController.MissingCapability.selector, Capabilities.CAP_UNLOCK_OWN_RESERVATION, ENGINE_A
            )
        );
        vault.applyUnlock(key, address(usdc), 50e6);
    }

    function test_guardianRevokePreservesReservation() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 200e6);

        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);

        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 200e6, "reservation survives guardian revoke");
        assertEq(vault.lockedOf(key, address(usdc)), 200e6);

        // Engine A can no longer unlock (capability revoked).
        vm.prank(ENGINE_A);
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultCapabilityController.MissingCapability.selector, Capabilities.CAP_UNLOCK_OWN_RESERVATION, ENGINE_A
            )
        );
        vault.applyUnlock(key, address(usdc), 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                    GOVERNANCE ORPHANED LOCK RELEASE
    //////////////////////////////////////////////////////////////*/

    function test_orphanedLockRelease_reducesReservationAfterRevoke() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 400e6);

        // Guardian revokes engine A entirely.
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);
        assertEq(vault.engineCapabilityBits(ENGINE_A), 0);

        // Governance releases the orphaned reservation.
        vm.expectEmit(true, true, true, true);
        emit CollateralVaultV2.OrphanedLockReleased(
            key, address(usdc), ENGINE_A, 400e6, "post-incident cleanup", Versions.EVENT_VERSION
        );
        vm.prank(GOVERNANCE);
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 400e6, "post-incident cleanup");

        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 0);
        assertEq(vault.lockedOf(key, address(usdc)), 0);
        assertEq(vault.availableOf(key, address(usdc)), 1000e6);
        // Balance + aggregate liability untouched.
        assertEq(vault.balanceOf(key, address(usdc)), 1000e6);
        assertEq(vault.totalAccounted(address(usdc)), 1000e6);
    }

    function test_orphanedLockRelease_refusesIfEngineStillAuthorized() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 100e6);

        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2.EngineStillAuthorized.selector, ENGINE_A));
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 100e6, "premature");
    }

    function test_orphanedLockRelease_refusesForNonGovernance() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 100e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);

        vm.prank(GUARDIAN);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 100e6, "guardian try");
    }

    function test_orphanedLockRelease_refusesExcessive() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 100e6);
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);

        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2.InsufficientEngineReservation.selector, 200e6, 100e6));
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 200e6, "over");
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_ownerHappyPath() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        uint256 physicalBefore = usdc.balanceOf(address(vault));
        uint256 ownerBefore = usdc.balanceOf(OWNER_A);

        vm.expectEmit(true, true, true, true);
        emit CollateralVaultV2.Withdraw(key, OWNER_A, 1, address(usdc), 200e6, OWNER_A, Versions.EVENT_VERSION);
        vm.prank(OWNER_A);
        vault.withdraw(1, address(usdc), 200e6);

        assertEq(vault.balanceOf(key, address(usdc)), 300e6);
        assertEq(vault.totalAccounted(address(usdc)), 300e6);
        assertEq(usdc.balanceOf(address(vault)), physicalBefore - 200e6);
        assertEq(usdc.balanceOf(OWNER_A), ownerBefore + 200e6);
    }

    function test_withdraw_lockedCollateralCannotBeWithdrawn() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 700e6);

        vm.prank(OWNER_A);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVaultV2.InsufficientAvailableCollateral.selector, 400e6, 300e6)
        );
        vault.withdraw(1, address(usdc), 400e6);

        // Locked amount can never leave until the engine unlocks.
        vm.prank(OWNER_A);
        vault.withdraw(1, address(usdc), 300e6);
        assertEq(vault.balanceOf(key, address(usdc)), 700e6);
        assertEq(vault.lockedOf(key, address(usdc)), 700e6);
        assertEq(vault.availableOf(key, address(usdc)), 0);
    }

    function test_withdraw_riskHookReject() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        vault.setAllowWithdrawals(false);
        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2.UnsafeWithdrawal.selector);
        vault.withdraw(1, address(usdc), 100e6);

        // Restore.
        vault.setAllowWithdrawals(true);
        vm.prank(OWNER_A);
        vault.withdraw(1, address(usdc), 100e6);
    }

    function test_withdraw_riskHookVetoPerSubKeyToken() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vault.setVetoWithdrawal(key, address(usdc), true);
        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2.UnsafeWithdrawal.selector);
        vault.withdraw(1, address(usdc), 100e6);

        // Different owner unaffected.
        _depositOwnerAccountOne(OWNER_B, usdc, 500e6);
        vm.prank(OWNER_B);
        vault.withdraw(1, address(usdc), 100e6);
    }

    function test_withdraw_unknownAccountReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        vm.prank(OWNER_A);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2Core.SubaccountNotFound.selector, OWNER_A, uint32(5)));
        vault.withdraw(5, address(usdc), 10e6);
    }

    function test_withdraw_zeroAmountReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2Core.AmountZero.selector);
        vault.withdraw(1, address(usdc), 0);
    }

    function test_withdraw_disabledTokenStillAllowsExit() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        vm.prank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));

        // Existing balance can still be withdrawn (Part L — exits must remain possible).
        vm.prank(OWNER_A);
        vault.withdraw(1, address(usdc), 500e6);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(key, address(usdc)), 0);
    }

    function test_withdraw_pauseBlocksThenUnpauseAllows() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);

        // Guardian can pause.
        vm.prank(GUARDIAN);
        vault.pauseWithdrawals();
        assertTrue(vault.withdrawalsPaused());

        vm.prank(OWNER_A);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2.PausedOperation.selector, bytes32("withdrawals")));
        vault.withdraw(1, address(usdc), 100e6);

        // Guardian CANNOT unpause.
        vm.prank(GUARDIAN);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        vault.unpauseWithdrawals();

        // Governance can.
        vm.prank(GOVERNANCE);
        vault.unpauseWithdrawals();
        assertFalse(vault.withdrawalsPaused());

        vm.prank(OWNER_A);
        vault.withdraw(1, address(usdc), 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL TRANSFER
    //////////////////////////////////////////////////////////////*/

    function test_internalTransfer_accountOneToAccountTwo() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        vm.prank(OWNER_A);
        registry.registerNext(); // Account 2

        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        bytes32 keyA2 = registry.subKeyOf(OWNER_A, 2);
        uint256 physicalBefore = usdc.balanceOf(address(vault));

        vm.expectEmit(true, true, true, true);
        emit CollateralVaultV2.InternalTransfer(
            keyA1, keyA2, address(usdc), 400e6, OWNER_A, uint32(1), uint32(2), Versions.EVENT_VERSION
        );
        vm.prank(OWNER_A);
        vault.internalTransfer(address(usdc), 1, 2, 400e6);

        assertEq(vault.balanceOf(keyA1, address(usdc)), 600e6);
        assertEq(vault.balanceOf(keyA2, address(usdc)), 400e6);
        assertEq(vault.totalAccounted(address(usdc)), 1000e6, "totalAccounted MUST be unchanged");
        assertEq(usdc.balanceOf(address(vault)), physicalBefore, "physical custody unchanged");
    }

    function test_internalTransfer_lazyDestinationAccountOne() external {
        // OWNER_B: register Account 2 first, deposit into it, then transfer to Account 1 (lazy).
        vm.startPrank(OWNER_B);
        registry.registerNext(); // Account 1
        registry.registerNext(); // Account 2
        vm.stopPrank();
        _depositAsOwner(OWNER_B, 2, usdc, 500e6);

        // Zero destination account 1 already registered because we called registerNext.
        // Test the lazy path by using OWNER_A: register account 1 lazily via internal transfer target.
        vm.prank(OWNER_A);
        registry.registerNext(); // Account 1 exists explicitly.
        vm.prank(OWNER_A);
        registry.registerNext(); // Account 2

        // Force credit Account 2 (skip full deposit flow).
        bytes32 keyA2 = registry.subKeyOf(OWNER_A, 2);
        usdc.mint(OWNER_A, 100e6);
        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 100e6);
        vault.depositFor(OWNER_A, 2, address(usdc), 100e6);
        vault.internalTransfer(address(usdc), 2, 1, 50e6);
        vm.stopPrank();

        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_A, 1), address(usdc)), 50e6);
        assertEq(vault.balanceOf(keyA2, address(usdc)), 50e6);
    }

    function test_internalTransfer_sameSubaccountReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2.InternalTransferSameSubaccount.selector);
        vault.internalTransfer(address(usdc), 1, 1, 10e6);
    }

    function test_internalTransfer_crossOwnerImpossible() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        vm.prank(OWNER_B);
        registry.registerNext();

        // OWNER_A cannot reference OWNER_B's subaccount — the check
        // `existsOf(msg.sender, toSubaccountId)` inherently forces same-owner.
        vm.prank(OWNER_A);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2Core.SubaccountNotFound.selector, OWNER_A, uint32(2)));
        vault.internalTransfer(address(usdc), 1, 2, 10e6);
    }

    function test_internalTransfer_lockedNotTransferable() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        vm.prank(OWNER_A);
        registry.registerNext();
        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(keyA1, address(usdc), 700e6);

        vm.prank(OWNER_A);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVaultV2.InsufficientAvailableCollateral.selector, 400e6, 300e6)
        );
        vault.internalTransfer(address(usdc), 1, 2, 400e6);
    }

    function test_internalTransfer_riskHookReject() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        vm.prank(OWNER_A);
        registry.registerNext();
        vault.setAllowInternalTransfers(false);

        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2.UnsafeTransfer.selector);
        vault.internalTransfer(address(usdc), 1, 2, 100e6);

        vault.setAllowInternalTransfers(true);
        vm.prank(OWNER_A);
        vault.internalTransfer(address(usdc), 1, 2, 100e6);
    }

    function test_internalTransfer_disabledTokenReverts() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        vm.prank(OWNER_A);
        registry.registerNext();
        vm.prank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));

        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2Core.TokenNotSupported.selector);
        vault.internalTransfer(address(usdc), 1, 2, 10e6);
    }

    function test_internalTransfer_pauseBlocks() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 500e6);
        vm.prank(OWNER_A);
        registry.registerNext();

        vm.prank(GUARDIAN);
        vault.pauseInternalTransfers();

        vm.prank(OWNER_A);
        vm.expectRevert(
            abi.encodeWithSelector(CollateralVaultV2.PausedOperation.selector, bytes32("internalTransfers"))
        );
        vault.internalTransfer(address(usdc), 1, 2, 10e6);
    }

    function test_internalTransfer_locksUnchangedOnBothSides() external {
        _depositOwnerAccountOne(OWNER_A, usdc, 1000e6);
        vm.prank(OWNER_A);
        registry.registerNext();
        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        bytes32 keyA2 = registry.subKeyOf(OWNER_A, 2);

        vm.prank(ENGINE_A);
        vault.applyLock(keyA1, address(usdc), 200e6);

        vm.prank(OWNER_A);
        vault.internalTransfer(address(usdc), 1, 2, 100e6);

        // Locks on source unchanged.
        assertEq(vault.lockedByEngineOf(keyA1, address(usdc), ENGINE_A), 200e6);
        assertEq(vault.lockedOf(keyA1, address(usdc)), 200e6);
        // Destination has no locks.
        assertEq(vault.lockedOf(keyA2, address(usdc)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSES
    //////////////////////////////////////////////////////////////*/

    function test_pauseDeposits_blocksNewDeposits() external {
        vm.prank(GUARDIAN);
        vault.pauseDeposits();

        usdc.mint(OWNER_A, 100e6);
        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2.PausedOperation.selector, bytes32("deposits")));
        vault.deposit(1, address(usdc), 100e6);
        vm.stopPrank();
    }

    function test_pauseDeposits_governanceCanUnpause() external {
        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        vm.prank(GOVERNANCE);
        vault.unpauseDeposits();
        assertFalse(vault.depositsPaused());
    }

    function test_pauseIdempotent() external {
        vm.prank(GUARDIAN);
        vault.pauseWithdrawals();

        vm.recordLogs();
        vm.prank(GUARDIAN);
        vault.pauseWithdrawals(); // idempotent
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_pauseByGovernance() external {
        vm.prank(GOVERNANCE);
        vault.pauseDeposits();
        assertTrue(vault.depositsPaused());
    }

    function test_pauseByAttackerReverts() external {
        vm.prank(ATTACKER);
        vm.expectRevert(CollateralVaultV2.OnlyGuardianOrGovernance.selector);
        vault.pauseDeposits();
    }

    /*//////////////////////////////////////////////////////////////
                            REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_reentrancyBlocked() external {
        // Deploy a reentrant token, add to allowlist, deposit, then withdraw.
        ReentrantToken evil = new ReentrantToken();
        vm.prank(GOVERNANCE);
        vault.addSupportedToken(address(evil));

        // Register Account 1 for OWNER_A and mint tokens.
        vm.prank(OWNER_A);
        registry.registerNext();
        evil.mint(address(vault), 1000e18);
        vault.testForceCredit(registry.subKeyOf(OWNER_A, 1), address(evil), 1000e18);

        // Arm the token to re-enter withdraw during transfer.
        bytes memory reentry =
            abi.encodeWithSignature("withdraw(uint32,address,uint256)", uint32(1), address(evil), uint256(1e18));
        evil.armReentry(address(vault), reentry);

        vm.prank(OWNER_A);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.withdraw(1, address(evil), 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_lockUnlockRoundTrip(uint128 depositAmount, uint128 lockAmount) external {
        vm.assume(depositAmount > 0);
        vm.assume(lockAmount > 0 && lockAmount <= depositAmount);

        _depositOwnerAccountOne(OWNER_A, usdc, depositAmount);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);

        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), lockAmount);
        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), lockAmount);
        assertEq(vault.availableOf(key, address(usdc)), depositAmount - lockAmount);

        vm.prank(ENGINE_A);
        vault.applyUnlock(key, address(usdc), lockAmount);
        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 0);
        assertEq(vault.availableOf(key, address(usdc)), depositAmount);
    }

    function testFuzz_withdrawRespectsLocks(uint96 depositAmount, uint96 lockAmount, uint96 withdrawAmount) external {
        vm.assume(depositAmount > 0);
        vm.assume(lockAmount <= depositAmount);
        vm.assume(withdrawAmount > 0);

        _depositOwnerAccountOne(OWNER_A, usdc, depositAmount);
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        if (lockAmount > 0) {
            vm.prank(ENGINE_A);
            vault.applyLock(key, address(usdc), lockAmount);
        }

        uint256 available = uint256(depositAmount) - lockAmount;
        vm.prank(OWNER_A);
        if (withdrawAmount > available) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    CollateralVaultV2.InsufficientAvailableCollateral.selector, uint256(withdrawAmount), available
                )
            );
            vault.withdraw(1, address(usdc), withdrawAmount);
        } else {
            vault.withdraw(1, address(usdc), withdrawAmount);
            assertEq(vault.balanceOf(key, address(usdc)), uint256(depositAmount) - withdrawAmount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _depositOwnerAccountOne(address owner, MockERC20 token, uint256 amount) internal {
        token.mint(owner, amount);
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vault.deposit(1, address(token), amount);
        vm.stopPrank();
    }

    function _depositAsOwner(address owner, uint32 subaccountId, MockERC20 token, uint256 amount) internal {
        token.mint(owner, amount);
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vault.deposit(subaccountId, address(token), amount);
        vm.stopPrank();
    }
}
