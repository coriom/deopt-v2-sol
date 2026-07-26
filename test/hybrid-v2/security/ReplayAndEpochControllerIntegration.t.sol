// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ReplayAndEpochControllerHarness} from "./harness/ReplayAndEpochControllerHarness.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title ReplayAndEpochControllerIntegration
/// @notice L2 integration suite proving the WP-05 replay + epoch foundation is entirely
///         isolated from the WP-02 Registry + WP-04 Vault canonical state.
///
/// Verifies:
///  - Registry identity is the canonical source of subKey;
///  - replay consumption cannot create Registry accounts;
///  - replay consumption cannot mutate Vault balances / reservations / capabilities;
///  - epoch increments cannot mutate balances or reservations;
///  - Vault capability changes cannot mutate replay state;
///  - Account 1 and Account 2 have isolated replay namespaces (per-subaccount epoch);
///  - owner-wide epoch invalidation affects both accounts;
///  - subaccount epoch invalidation affects only one account.
contract ReplayAndEpochControllerIntegration is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    ReplayAndEpochControllerHarness internal controller;
    MockERC20 internal token;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal recoveryAuthority = address(0xA3);
    address internal engine = address(0xE1);

    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    function setUp() public {
        // Predict controller/vault interdependence: registry needs a capability authority
        // (the vault), and vault needs the registry. Deploy registry, then vault, then
        // separately deploy controller (which needs the registry). Registry does not
        // need a real vault address for the tests here since we do not exercise
        // `registerLazyDefault`; passing the vault post-deploy is safe.
        registry = new SubaccountRegistry(address(0xDEAD));
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        controller =
            new ReplayAndEpochControllerHarness(address(registry), "DeOptV2-TestEngine", "1", recoveryAuthority);
        token = new MockERC20("Mock", "MCK", 18);

        vm.prank(ownerA);
        registry.registerNext(); // Account 1
        vm.prank(ownerA);
        registry.registerNext(); // Account 2
        vm.prank(ownerB);
        registry.registerNext(); // Account 1

        // Enable the token in the vault so we can deposit.
        vm.prank(governance);
        vault.addSupportedToken(address(token));

        token.mint(ownerA, 100 ether);
        vm.prank(ownerA);
        token.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                          REGISTRY IDENTITY SOURCE
    //////////////////////////////////////////////////////////////*/

    function test_registrySubKeyIsCanonicalSource() public view {
        bytes32 direct = registry.subKeyOf(ownerA, 1);
        bytes32 viaLibrary = SubKey.deriveHere(address(registry), ownerA, 1);
        assertEq(direct, viaLibrary);
    }

    /*//////////////////////////////////////////////////////////////
              REPLAY / EPOCH DO NOT MUTATE REGISTRY OR VAULT
    //////////////////////////////////////////////////////////////*/

    function test_replayConsumptionDoesNotCreateRegistryAccounts() public {
        assertFalse(registry.existsOf(address(0xDEAD00), 1));
        // Consume many intents referencing an unregistered subKey. Nothing about the
        // controller can register a subaccount — replay state and registry state are
        // fully isolated.
        for (uint256 i = 0; i < 10; i++) {
            controller.consumeIntent(keccak256(abi.encode("intent", i)), address(0xC1), keccak256("ACTION"));
        }
        assertFalse(registry.existsOf(address(0xDEAD00), 1));
        assertEq(registry.nextIdFor(address(0xDEAD00)), 1); // still at initial value
    }

    function test_replayConsumptionDoesNotMutateVaultBalances() public {
        // Deposit real balance for ownerA subaccount 1.
        vm.prank(ownerA);
        vault.deposit(1, address(token), 5 ether);
        bytes32 subKey1 = registry.subKeyOf(ownerA, 1);
        assertEq(vault.balanceOf(subKey1, address(token)), 5 ether);

        // Now churn the controller — intent + nonce + epoch mutations.
        controller.consumeIntent(keccak256("i1"), address(0xC1), keccak256("A"));
        controller.consumeNonce(address(0xC1), 0);
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();
        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(1);
        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(2);

        // Vault balance untouched.
        assertEq(vault.balanceOf(subKey1, address(token)), 5 ether);
        assertEq(vault.totalAccounted(address(token)), 5 ether);
        assertEq(vault.physicalBalance(address(token)), 5 ether);
        assertEq(vault.lockedOf(subKey1, address(token)), 0);
    }

    function test_epochIncrementsDoNotMutateReservations() public {
        // Deposit + lock via the vault.
        vm.prank(ownerA);
        vault.deposit(1, address(token), 5 ether);
        bytes32 subKey1 = registry.subKeyOf(ownerA, 1);

        // Grant a fake engine LOCK capability and lock 2 ether.
        vm.prank(governance);
        vault.setEngineCapability(engine, Capabilities.CAP_LOCK_COLLATERAL, true);
        vm.prank(engine);
        vault.applyLock(subKey1, address(token), 2 ether);
        assertEq(vault.lockedOf(subKey1, address(token)), 2 ether);
        assertEq(vault.lockedByEngineOf(subKey1, address(token), engine), 2 ether);

        // Now hammer the controller with epoch advances.
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();
        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(1);
        vm.prank(recoveryAuthority);
        controller.authorityAdvanceOwnerRecoveryEpoch(ownerA);

        // Reservation invariants unchanged.
        assertEq(vault.lockedOf(subKey1, address(token)), 2 ether);
        assertEq(vault.lockedByEngineOf(subKey1, address(token), engine), 2 ether);
        assertEq(vault.balanceOf(subKey1, address(token)), 5 ether);
    }

    function test_vaultCapabilityChangesDoNotMutateReplayState() public {
        // Load some replay state.
        bytes32 intent = keccak256("stable");
        controller.consumeIntent(intent, address(0xC1), keccak256("A"));
        controller.consumeNonce(address(0xC1), 0);
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();
        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(1);
        uint256 nonceBefore = controller.nonces(address(0xC1));
        uint256 ownerEpochBefore = controller.ownerRecoveryEpoch(ownerA);
        uint256 subEpochBefore = controller.subaccountRecoveryEpoch(registry.subKeyOf(ownerA, 1));

        // Grant + revoke capabilities on the vault side.
        vm.prank(governance);
        vault.setEngineCapability(engine, Capabilities.CAP_LOCK_COLLATERAL, true);
        vm.prank(governance);
        vault.setEngineCapability(engine, Capabilities.CAP_LOCK_COLLATERAL, false);
        vm.prank(guardian);
        vault.guardianRevokeEngine(engine);

        // Controller state unchanged.
        assertTrue(controller.isIntentConsumed(intent));
        assertEq(controller.nonces(address(0xC1)), nonceBefore);
        assertEq(controller.ownerRecoveryEpoch(ownerA), ownerEpochBefore);
        assertEq(controller.subaccountRecoveryEpoch(registry.subKeyOf(ownerA, 1)), subEpochBefore);
    }

    /*//////////////////////////////////////////////////////////////
                   PER-ACCOUNT EPOCH ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_ownerWideEpochAffectsBothAccountsUnderOwner() public {
        bytes32 subKey1 = registry.subKeyOf(ownerA, 1);
        bytes32 subKey2 = registry.subKeyOf(ownerA, 2);

        // With owner epoch = 0, both subaccount pairs check fresh.
        controller.requireEpochsFresh(ownerA, subKey1, 0, 0);
        controller.requireEpochsFresh(ownerA, subKey2, 0, 0);

        // Advance owner-wide epoch; both accounts must now require ownerEpoch == 1 to pass.
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();

        vm.expectRevert();
        controller.requireEpochsFresh(ownerA, subKey1, 0, 0);
        vm.expectRevert();
        controller.requireEpochsFresh(ownerA, subKey2, 0, 0);

        controller.requireEpochsFresh(ownerA, subKey1, 1, 0);
        controller.requireEpochsFresh(ownerA, subKey2, 1, 0);
    }

    function test_subaccountEpochAffectsOnlyOneAccount() public {
        bytes32 subKey1 = registry.subKeyOf(ownerA, 1);
        bytes32 subKey2 = registry.subKeyOf(ownerA, 2);

        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(1);

        // Account 1 stale at (0,0). Account 2 still fresh.
        vm.expectRevert();
        controller.requireEpochsFresh(ownerA, subKey1, 0, 0);
        controller.requireEpochsFresh(ownerA, subKey2, 0, 0);
        controller.requireEpochsFresh(ownerA, subKey1, 0, 1);
    }

    function test_ownerBEpochUnaffectedByOwnerA() public {
        bytes32 subKeyB1 = registry.subKeyOf(ownerB, 1);
        vm.prank(ownerA);
        controller.advanceMyOwnerRecoveryEpoch();
        assertEq(controller.ownerRecoveryEpoch(ownerA), 1);
        assertEq(controller.ownerRecoveryEpoch(ownerB), 0);
        controller.requireEpochsFresh(ownerB, subKeyB1, 0, 0);
    }

    /*//////////////////////////////////////////////////////////////
                     SMART-WALLET IDENTITY STABLE
    //////////////////////////////////////////////////////////////*/

    function test_smartWalletOwnerIdentityRemainsStable() public {
        // "Smart wallet" here is any address controlled by another mechanism; the
        // controller uses msg.sender as owner. Rotating a wallet's internal controller
        // (a wallet-level event) does not touch on-chain identity here.
        bytes32 subKey = registry.subKeyOf(ownerA, 1);
        assertEq(registry.ownerOf(subKey), ownerA);
        vm.prank(ownerA);
        controller.advanceMySubaccountRecoveryEpoch(1);
        // Registry-side ownership unchanged.
        assertEq(registry.ownerOf(subKey), ownerA);
    }
}
