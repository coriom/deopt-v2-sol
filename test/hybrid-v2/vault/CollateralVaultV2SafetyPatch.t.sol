// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CollateralVaultV2} from "../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

import {CollateralVaultV2Harness} from "./harness/CollateralVaultV2Harness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title CollateralVaultV2SafetyPatchTest
/// @notice New tests introduced by the WP-04B safety patch. Cover the
///         `_requireOrphanedReleaseProof` gate. Existing V2-B tests remain
///         green because the harness defaults `allowOrphanedRelease = true`.
contract CollateralVaultV2SafetyPatchTest is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    MockERC20 internal usdc;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);
    address internal constant OWNER_A = address(0xA1);
    address internal constant ENGINE_A = address(0xE1);
    address internal constant ENGINE_B = address(0xE2);

    function setUp() external {
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new SubaccountRegistry(predictedVault);
        vault = new CollateralVaultV2Harness(address(registry), GOVERNANCE, GUARDIAN);
        assertEq(address(vault), predictedVault);
        usdc = new MockERC20("USDC", "USDC", 6);

        vm.startPrank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vault.setEngineCapability(
            ENGINE_A, Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_UNLOCK_OWN_RESERVATION, true
        );
        vault.setEngineCapability(
            ENGINE_B, Capabilities.CAP_LOCK_COLLATERAL | Capabilities.CAP_UNLOCK_OWN_RESERVATION, true
        );
        vm.stopPrank();

        // Deposit + lock so the orphan-release path has something to release.
        usdc.mint(OWNER_A, 1000e6);
        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1, address(usdc), 1000e6);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                CAPABILITY REVOCATION ALONE IS INSUFFICIENT
    //////////////////////////////////////////////////////////////*/

    function test_safetyPatch_orphanRelease_globalProofRejectPreservesState() external {
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 300e6);

        // Fully revoke ENGINE_A.
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);
        assertEq(vault.engineCapabilityBits(ENGINE_A), 0);

        // Snapshot state.
        uint256 balBefore = vault.balanceOf(key, address(usdc));
        uint256 accBefore = vault.totalAccounted(address(usdc));
        uint256 aggBefore = vault.lockedOf(key, address(usdc));
        uint256 engBefore = vault.lockedByEngineOf(key, address(usdc), ENGINE_A);
        uint256 availBefore = vault.availableOf(key, address(usdc));

        // Proof hook globally rejects — capability revocation alone MUST NOT release.
        vault.setAllowOrphanedRelease(false);
        vm.prank(GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVaultV2.UnresolvedOrphanedObligation.selector, key, address(usdc), ENGINE_A, uint256(300e6)
            )
        );
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 300e6, "still-open");

        // State fully preserved.
        assertEq(vault.balanceOf(key, address(usdc)), balBefore);
        assertEq(vault.totalAccounted(address(usdc)), accBefore);
        assertEq(vault.lockedOf(key, address(usdc)), aggBefore);
        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), engBefore);
        assertEq(vault.availableOf(key, address(usdc)), availBefore);
    }

    function test_safetyPatch_orphanRelease_perTupleVetoPreservesState() external {
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 200e6);
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);

        // Global allow stays true; per-tuple veto blocks THIS one.
        vault.setVetoOrphanedRelease(key, address(usdc), ENGINE_A, true);

        vm.prank(GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVaultV2.UnresolvedOrphanedObligation.selector, key, address(usdc), ENGINE_A, uint256(200e6)
            )
        );
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 200e6, "position-open");

        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 200e6);
        assertEq(vault.lockedOf(key, address(usdc)), 200e6);
    }

    function test_safetyPatch_orphanRelease_proofApprovalReleases() external {
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 500e6);
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);

        // Default allow = true. Release proceeds.
        vm.prank(GOVERNANCE);
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 500e6, "settled");

        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 0);
        assertEq(vault.lockedOf(key, address(usdc)), 0);
        assertEq(vault.availableOf(key, address(usdc)), 1000e6);
        assertEq(vault.balanceOf(key, address(usdc)), 1000e6);
        assertEq(vault.totalAccounted(address(usdc)), 1000e6);
    }

    function test_safetyPatch_orphanRelease_neverMovesTokens() external {
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 500e6);
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);

        uint256 physicalBefore = usdc.balanceOf(address(vault));
        vm.prank(GOVERNANCE);
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 500e6, "settled");
        assertEq(usdc.balanceOf(address(vault)), physicalBefore, "release MUST NOT move tokens");
    }

    function test_safetyPatch_orphanRelease_neverChangesTotalAccounted() external {
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 500e6);
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);

        uint256 accBefore = vault.totalAccounted(address(usdc));
        vm.prank(GOVERNANCE);
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 500e6, "settled");
        assertEq(vault.totalAccounted(address(usdc)), accBefore, "release MUST NOT change totalAccounted");
    }

    function test_safetyPatch_orphanRelease_cannotReleaseAnotherEnginesReservation() external {
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 300e6);
        vm.prank(ENGINE_B);
        vault.applyLock(key, address(usdc), 200e6);

        // Revoke only ENGINE_A. Attempt to "release" from ENGINE_B (still authorized).
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE_A);

        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2.EngineStillAuthorized.selector, ENGINE_B));
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_B, 200e6, "wrong-engine");

        // ENGINE_A's reservation is still intact (release didn't proceed for either).
        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 300e6);
        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_B), 200e6);
    }

    /*//////////////////////////////////////////////////////////////
                CAPABILITY REVOCATION VIA GOVERNANCE (NOT GUARDIAN)
    //////////////////////////////////////////////////////////////*/

    function test_safetyPatch_governanceCapabilityRevocationAlsoRequiresProof() external {
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        vm.prank(ENGINE_A);
        vault.applyLock(key, address(usdc), 400e6);

        // Governance revokes ENGINE_A's caps (not via guardian).
        vm.prank(GOVERNANCE);
        vault.setEngineCapability(ENGINE_A, Capabilities.ALL_CAPABILITIES, false);
        assertEq(vault.engineCapabilityBits(ENGINE_A), 0);

        // Proof rejects.
        vault.setAllowOrphanedRelease(false);
        vm.prank(GOVERNANCE);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVaultV2.UnresolvedOrphanedObligation.selector, key, address(usdc), ENGINE_A, uint256(400e6)
            )
        );
        vault.governanceReleaseOrphanedLock(key, address(usdc), ENGINE_A, 400e6, "still-obligated");

        assertEq(vault.lockedByEngineOf(key, address(usdc), ENGINE_A), 400e6);
    }
}
