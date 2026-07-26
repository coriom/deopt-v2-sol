// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CollateralVaultV2} from "../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

import {CollateralVaultV2Harness} from "./harness/CollateralVaultV2Harness.sol";
import {CollateralVaultV2Handler} from "./handlers/CollateralVaultV2Handler.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title CollateralVaultV2Invariants
/// @notice VAULT-B-I1..I14 (some combined). Bounded handler drives deposits,
///         locks, unlocks, cross-unlock attempts, withdrawals, and internal
///         transfers. Invariants prove per-subaccount conservation, engine
///         isolation, and event/state reconciliation.
///
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 64
contract CollateralVaultV2Invariants is StdInvariant, Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    CollateralVaultV2Handler internal handler;
    MockERC20 internal usdc;
    MockERC20 internal weth;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);
    address internal constant ENGINE_A = address(0xE001);
    address internal constant ENGINE_B = address(0xE002);

    function setUp() external {
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new SubaccountRegistry(predictedVault);
        vault = new CollateralVaultV2Harness(address(registry), GOVERNANCE, GUARDIAN);

        usdc = new MockERC20("USDC", "USDC", 6);
        weth = new MockERC20("WETH", "WETH", 18);

        vm.startPrank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));
        vault.addSupportedToken(address(weth));
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vault.setEngineCapability(
            ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_UNLOCK_OWN_RESERVATION, true
        );
        vault.setEngineCapability(
            ENGINE_B, Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_UNLOCK_OWN_RESERVATION, true
        );
        vm.stopPrank();

        handler = new CollateralVaultV2Handler(vault, registry, usdc, weth, GOVERNANCE, GUARDIAN);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.depositAccountTwo.selector;
        selectors[2] = handler.engineLock.selector;
        selectors[3] = handler.engineUnlock.selector;
        selectors[4] = handler.engineTryCrossUnlock.selector;
        selectors[5] = handler.withdraw.selector;
        selectors[6] = handler.internalTransfer.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /* -------------------------- VAULT-B-I1 -------------------------- */

    /// @notice For every (subKey, token), totalLocked <= balance.
    function invariant_vault_b_i1_totalLockedLeBalance() external view {
        _forEach(_check_totalLockedLeBalance);
    }

    /* -------------------------- VAULT-B-I2 -------------------------- */

    /// @notice sum of ghost engine reservations == totalLocked per (subKey, token).
    function invariant_vault_b_i2_engineReservationsSum() external view {
        _forEach(_check_engineReservationsSum);
    }

    /* -------------------------- VAULT-B-I3 -------------------------- */

    /// @notice available == balance - totalLocked.
    function invariant_vault_b_i3_availableFormula() external view {
        _forEach(_check_availableFormula);
    }

    /* -------------------------- VAULT-B-I4 -------------------------- */

    /// @notice Engine A never accumulates reservation for Engine B (and vice versa) —
    ///         the storage per-engine slot must equal the ghost per-engine slot.
    function invariant_vault_b_i4_engineReservationOwnership() external view {
        _forEach(_check_engineReservationOwnership);
    }

    /* -------------------------- VAULT-B-I5 -------------------------- */

    /// @notice Physical token balance >= totalAccounted.
    function invariant_vault_b_i5_physicalCoversAccounted() external view {
        _assertPhysicalCovers(address(usdc));
        _assertPhysicalCovers(address(weth));
    }

    /* -------------------------- VAULT-B-I6 -------------------------- */

    /// @notice Sum of ghost per-subaccount balances equals totalAccounted per token.
    function invariant_vault_b_i6_ghostSumMatchesTotalAccounted() external view {
        _assertGhostSumMatchesAccounted(address(usdc));
        _assertGhostSumMatchesAccounted(address(weth));
    }

    /* -------------------------- VAULT-B-I7 -------------------------- */

    /// @notice Storage per-subaccount balance == ghost per-subaccount balance for every
    ///         tracked (owner, id, token). Internal transfers conserve; cross-subaccount
    ///         drains would surface here.
    function invariant_vault_b_i7_ghostBalancesMatchStorage() external view {
        _forEach(_check_ghostBalanceMatches);
    }

    /* -------------------------- VAULT-B-I8 -------------------------- */

    /// @notice Withdrawals reduce physical + accounted + balance by same amount.
    ///         Reconstructed via ghost: initial mints via deposits (tracked in
    ///         totalAccounted) minus withdrawn == current totalAccounted.
    ///         Because our handler only mutates ghost on success, mismatch would
    ///         reveal a physical/aggregate drift.
    function invariant_vault_b_i8_withdrawalConsistency() external view {
        // Physical balance today == totalAccounted (donations disabled in handler).
        assertEq(IERC20(address(usdc)).balanceOf(address(vault)), vault.totalAccounted(address(usdc)));
        assertEq(IERC20(address(weth)).balanceOf(address(vault)), vault.totalAccounted(address(weth)));
    }

    /* -------------------------- VAULT-B-I9 -------------------------- */

    /// @notice Failed / rejected operations MUST NOT partially mutate state. Enforced
    ///         by handler using vm.expectRevert on cross-unlock attempts and by
    ///         invariants above.
    function invariant_vault_b_i9_noPartialStateOnFailure() external view {
        _forEach(_check_ghostBalanceMatches);
        _forEach(_check_engineReservationOwnership);
    }

    /* -------------------------- VAULT-B-I10 ------------------------- */

    /// @notice Guardian revocation does not release reservations. Spot-check at
    ///         invariant time: guardian-revoke a random engine and confirm storage
    ///         reservations do not decrease.
    function invariant_vault_b_i10_capabilityRevocationDoesNotReleaseReservations() external {
        uint256 nOwners = handler.ownerCount();
        uint256 nEngines = handler.engineCount();
        for (uint256 i = 0; i < nOwners; i++) {
            address owner = handler.ownerAt(i);
            for (uint32 id = 1; id <= 2; id++) {
                if (!registry.existsOf(owner, id)) continue;
                bytes32 key = registry.subKeyOf(owner, id);
                for (uint256 e = 0; e < nEngines; e++) {
                    address engine = handler.engineAt(e);
                    uint256 before_ = vault.lockedByEngineOf(key, address(usdc), engine);
                    // Snapshot capability bits so we can restore.
                    uint256 bits = vault.engineCapabilityBits(engine);
                    if (bits == 0) continue;
                    vm.prank(GUARDIAN);
                    vault.guardianRevokeEngine(engine);
                    assertEq(
                        vault.lockedByEngineOf(key, address(usdc), engine),
                        before_,
                        "guardian revoke released a reservation"
                    );
                    // Restore capability bits for subsequent handler calls.
                    vm.prank(GOVERNANCE);
                    vault.setEngineCapability(engine, bits, true);
                }
            }
        }
    }

    /* -------------------------- VAULT-B-I11 ------------------------- */

    /// @notice No sibling subaccount collateral consumed. Covered structurally by
    ///         subKey-keyed storage and by VAULT-B-I7 mirror match.
    function invariant_vault_b_i11_noSiblingCollateralConsumed() external view {
        _forEach(_check_ghostBalanceMatches);
    }

    /* -------------------------- VAULT-B-I12 ------------------------- */

    /// @notice Pause state cannot rewrite economic accounting. Pause + unpause and
    ///         confirm balances / aggregates / reservations unchanged.
    function invariant_vault_b_i12_pauseDoesNotRewriteAccounting() external {
        uint256 accountedUsdcBefore = vault.totalAccounted(address(usdc));
        uint256 accountedWethBefore = vault.totalAccounted(address(weth));

        vm.prank(GUARDIAN);
        vault.pauseDeposits();
        vm.prank(GUARDIAN);
        vault.pauseWithdrawals();
        vm.prank(GUARDIAN);
        vault.pauseInternalTransfers();

        assertEq(vault.totalAccounted(address(usdc)), accountedUsdcBefore);
        assertEq(vault.totalAccounted(address(weth)), accountedWethBefore);
        _forEach(_check_ghostBalanceMatches);
        _forEach(_check_engineReservationOwnership);

        // Restore.
        vm.prank(GOVERNANCE);
        vault.unpauseDeposits();
        vm.prank(GOVERNANCE);
        vault.unpauseWithdrawals();
        vm.prank(GOVERNANCE);
        vault.unpauseInternalTransfers();
    }

    /* -------------------------- VAULT-B-I13 ------------------------- */

    /// @notice Events + ghost state reconstruct canonical balances and reservations.
    ///         Since the handler synchronously updates the ghost only on successful
    ///         mutations (mirroring the emitted events), any divergence proves the
    ///         event stream is incomplete or the handler assumption is wrong.
    ///         Covered by I6, I7, I2 combined.
    function invariant_vault_b_i13_reconstructionHolds() external view {
        _assertGhostSumMatchesAccounted(address(usdc));
        _assertGhostSumMatchesAccounted(address(weth));
        _forEach(_check_ghostBalanceMatches);
        _forEach(_check_engineReservationOwnership);
    }

    /* -------------------------- VAULT-B-I14 ------------------------- */

    /// @notice Account 0 (and any other unregistered identity) never acquires
    ///         balance or reservation. subKey for Account 0 must return zero.
    function invariant_vault_b_i14_accountZeroUncredited() external view {
        uint256 nOwners = handler.ownerCount();
        for (uint256 i = 0; i < nOwners; i++) {
            address owner = handler.ownerAt(i);
            bytes32 key0 = registry.subKeyOf(owner, 0);
            assertEq(vault.balanceOf(key0, address(usdc)), 0);
            assertEq(vault.balanceOf(key0, address(weth)), 0);
            assertEq(vault.lockedOf(key0, address(usdc)), 0);
            assertEq(vault.lockedOf(key0, address(weth)), 0);
        }
    }

    /* -------------------------- VAULT-B-I15 ------------------------- */

    /// @notice Safety-patch invariant: capability revocation alone (via either
    ///         guardian or governance) is INSUFFICIENT to release or consume an
    ///         outstanding engine reservation. We revoke a random engine, hold
    ///         the orphan-release proof globally rejecting, and confirm the
    ///         governance release cannot succeed.
    function invariant_vault_b_i15_capabilityRevocationCannotReleaseReservations() external {
        uint256 nOwners = handler.ownerCount();
        uint256 nEngines = handler.engineCount();
        // Reject all orphan-release proof calls during this check.
        vault.setAllowOrphanedRelease(false);
        for (uint256 i = 0; i < nOwners; i++) {
            address owner = handler.ownerAt(i);
            for (uint32 id = 1; id <= 2; id++) {
                if (!registry.existsOf(owner, id)) continue;
                bytes32 key = registry.subKeyOf(owner, id);
                for (uint256 e = 0; e < nEngines; e++) {
                    address engine = handler.engineAt(e);
                    uint256 reserved = vault.lockedByEngineOf(key, address(usdc), engine);
                    if (reserved == 0) continue;
                    uint256 bitsBefore = vault.engineCapabilityBits(engine);
                    if (bitsBefore != 0) {
                        // Fully revoke and confirm release still refuses.
                        vm.prank(GUARDIAN);
                        vault.guardianRevokeEngine(engine);
                    }
                    uint256 aggBefore = vault.lockedOf(key, address(usdc));
                    vm.prank(GOVERNANCE);
                    vm.expectRevert(
                        abi.encodeWithSelector(
                            CollateralVaultV2.UnresolvedOrphanedObligation.selector,
                            key,
                            address(usdc),
                            engine,
                            reserved
                        )
                    );
                    vault.governanceReleaseOrphanedLock(key, address(usdc), engine, reserved, "vault-b-i15");
                    // State preserved.
                    assertEq(vault.lockedByEngineOf(key, address(usdc), engine), reserved);
                    assertEq(vault.lockedOf(key, address(usdc)), aggBefore);
                    // Restore capability bits for subsequent handler calls.
                    if (bitsBefore != 0) {
                        vm.prank(GOVERNANCE);
                        vault.setEngineCapability(engine, bitsBefore, true);
                    }
                }
            }
        }
        // Restore permissive default.
        vault.setAllowOrphanedRelease(true);
    }

    /* -------------------------- VAULT-B-I16 ------------------------- */

    /// @notice Safety-patch invariant: a failed objective orphan-proof check
    ///         produces NO partial accounting mutation. Balance, aggregate,
    ///         per-engine reservation, totalAccounted, and physical custody
    ///         all remain identical across a reject-and-recover cycle.
    function invariant_vault_b_i16_orphanProofFailureIsAtomic() external {
        // Snapshot the entire mirror set BEFORE the reject attempt.
        (uint256 aggBefore, uint256 accountedBefore, uint256 physicalBefore) = _snapshotForV(address(usdc));

        // Try to release for every current reservation with proof rejecting.
        vault.setAllowOrphanedRelease(false);
        uint256 nOwners = handler.ownerCount();
        uint256 nEngines = handler.engineCount();
        for (uint256 i = 0; i < nOwners; i++) {
            address owner = handler.ownerAt(i);
            for (uint32 id = 1; id <= 2; id++) {
                if (!registry.existsOf(owner, id)) continue;
                bytes32 key = registry.subKeyOf(owner, id);
                for (uint256 e = 0; e < nEngines; e++) {
                    address engine = handler.engineAt(e);
                    uint256 reserved = vault.lockedByEngineOf(key, address(usdc), engine);
                    if (reserved == 0) continue;
                    uint256 bits = vault.engineCapabilityBits(engine);
                    if (bits != 0) {
                        vm.prank(GUARDIAN);
                        vault.guardianRevokeEngine(engine);
                    }
                    vm.prank(GOVERNANCE);
                    (bool ok,) = address(vault)
                        .call(
                            abi.encodeWithSelector(
                                CollateralVaultV2.governanceReleaseOrphanedLock.selector,
                                key,
                                address(usdc),
                                engine,
                                reserved,
                                "vault-b-i16"
                            )
                        );
                    assertFalse(ok, "rejected release MUST NOT succeed");
                    if (bits != 0) {
                        vm.prank(GOVERNANCE);
                        vault.setEngineCapability(engine, bits, true);
                    }
                }
            }
        }
        vault.setAllowOrphanedRelease(true);

        // Confirm nothing changed.
        (uint256 aggAfter, uint256 accountedAfter, uint256 physicalAfter) = _snapshotForV(address(usdc));
        assertEq(aggAfter, aggBefore, "aggregate locked changed after rejected release");
        assertEq(accountedAfter, accountedBefore, "totalAccounted changed after rejected release");
        assertEq(physicalAfter, physicalBefore, "physical custody changed after rejected release");
    }

    function _snapshotForV(address token) internal view returns (uint256 agg, uint256 accounted, uint256 physical) {
        uint256 nOwners = handler.ownerCount();
        for (uint256 i = 0; i < nOwners; i++) {
            address owner = handler.ownerAt(i);
            for (uint32 id = 1; id <= 2; id++) {
                bytes32 key = registry.subKeyOf(owner, id);
                agg += vault.lockedOf(key, token);
            }
        }
        accounted = vault.totalAccounted(token);
        physical = IERC20(token).balanceOf(address(vault));
    }

    /* ---------------------------------------------------------------- */
    /* helpers                                                          */
    /* ---------------------------------------------------------------- */

    function _forEach(function(address, uint32, address) internal view fn) internal view {
        uint256 n = handler.ownerCount();
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.ownerAt(i);
            for (uint32 id = 1; id <= 2; id++) {
                fn(owner, id, address(usdc));
                fn(owner, id, address(weth));
            }
        }
    }

    function _check_totalLockedLeBalance(address owner, uint32 id, address token) internal view {
        bytes32 key = registry.subKeyOf(owner, id);
        assertLe(vault.lockedOf(key, token), vault.balanceOf(key, token), "totalLocked > balance");
    }

    function _check_engineReservationsSum(address owner, uint32 id, address token) internal view {
        bytes32 key = registry.subKeyOf(owner, id);
        uint256 sum;
        uint256 n = handler.engineCount();
        for (uint256 e = 0; e < n; e++) {
            sum += vault.lockedByEngineOf(key, token, handler.engineAt(e));
        }
        assertEq(vault.lockedOf(key, token), sum, "totalLocked != sum of engine reservations");
    }

    function _check_availableFormula(address owner, uint32 id, address token) internal view {
        bytes32 key = registry.subKeyOf(owner, id);
        uint256 balance = vault.balanceOf(key, token);
        uint256 locked = vault.lockedOf(key, token);
        assertEq(vault.availableOf(key, token), balance - locked, "available formula broken");
    }

    function _check_engineReservationOwnership(address owner, uint32 id, address token) internal view {
        bytes32 key = registry.subKeyOf(owner, id);
        uint256 n = handler.engineCount();
        for (uint256 e = 0; e < n; e++) {
            address engine = handler.engineAt(e);
            assertEq(
                vault.lockedByEngineOf(key, token, engine),
                handler.ghostEngineLocked(owner, id, token, engine),
                "engine reservation storage != ghost"
            );
        }
    }

    function _check_ghostBalanceMatches(address owner, uint32 id, address token) internal view {
        bytes32 key = registry.subKeyOf(owner, id);
        assertEq(vault.balanceOf(key, token), handler.ghostBalance(owner, id, token), "balance storage != ghost");
    }

    function _assertPhysicalCovers(address token) internal view {
        assertGe(IERC20(token).balanceOf(address(vault)), vault.totalAccounted(token));
    }

    function _assertGhostSumMatchesAccounted(address token) internal view {
        uint256 sum;
        uint256 n = handler.ownerCount();
        for (uint256 i = 0; i < n; i++) {
            address owner = handler.ownerAt(i);
            for (uint32 id = 1; id <= 2; id++) {
                sum += handler.ghostBalance(owner, id, token);
            }
        }
        assertEq(vault.totalAccounted(token), sum, "totalAccounted != sum of ghost balances");
    }
}
