// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

import {VaultCapabilityController} from "../../../src/hybrid-v2/vault/VaultCapabilityController.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ISubaccountRegistry} from "../../../src/hybrid-v2/interfaces/ISubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {SubKey} from "../../../src/hybrid-v2/libraries/SubKey.sol";

import {VaultCapabilityControllerHarness} from "./harness/VaultCapabilityControllerHarness.sol";

/// @title RegistryCapabilityIntegrationTest
/// @notice End-to-end coverage that the future Vault-owned capability subsystem
///         correctly drives `SubaccountRegistry.registerLazyDefault` authorization.
/// @dev Uses the real `SubaccountRegistry` + the abstract `VaultCapabilityController`
///      (via harness). No modification to the registry is required — the harness IS
///      the authority the registry queries.
contract RegistryCapabilityIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////
                                FIXTURE
    //////////////////////////////////////////////////////////////*/

    VaultCapabilityControllerHarness internal controller;
    SubaccountRegistry internal registry;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);
    address internal constant ENGINE = address(0xE1);
    address internal constant UNRELATED_ENGINE = address(0xE2);
    address internal constant OWNER_A = address(0xA1);
    address internal constant OWNER_B = address(0xA2);

    function setUp() external {
        controller = new VaultCapabilityControllerHarness(GOVERNANCE, GUARDIAN);
        registry = new SubaccountRegistry(address(controller));
    }

    /*//////////////////////////////////////////////////////////////
                        HAPPY-PATH LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    function test_registryFlow_grantRevokeRegrantLifecycle() external {
        // 1. Engine without capability cannot lazy-register.
        vm.prank(ENGINE);
        vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
        registry.registerLazyDefault(OWNER_A);
        assertFalse(registry.existsOf(OWNER_A, 1));

        // 2. Governance grants CAP_REGISTER_DEFAULT_ACCOUNT.
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);

        // 3. Engine can now lazy-register Account 1 for OWNER_A.
        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_A);
        assertTrue(registry.existsOf(OWNER_A, 1));

        // 4. Second call is idempotent (no event).
        vm.recordLogs();
        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_A);
        assertEq(vm.getRecordedLogs().length, 0);

        // 5. Guardian revokes engine.
        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE);

        // 6. Revoked engine cannot lazy-register a NEW owner.
        vm.prank(ENGINE);
        vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
        registry.registerLazyDefault(OWNER_B);
        assertFalse(registry.existsOf(OWNER_B, 1));

        // 7. Governance re-grants.
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);

        // 8. Engine can lazy-register again.
        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_B);
        assertTrue(registry.existsOf(OWNER_B, 1));
    }

    /*//////////////////////////////////////////////////////////////
                    NEGATIVE / AUTHORIZATION EDGES
    //////////////////////////////////////////////////////////////*/

    function test_registryFlow_unrelatedCapabilityDoesNotAuthorize() external {
        // Grant EVERY bit EXCEPT CAP_REGISTER_DEFAULT_ACCOUNT.
        uint256 everythingElse = Capabilities.ALL_CAPABILITIES & ~Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT;
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, everythingElse, true);

        vm.prank(ENGINE);
        vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
        registry.registerLazyDefault(OWNER_A);
    }

    function test_registryFlow_guardianCannotAuthorize() external {
        vm.prank(GUARDIAN);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);

        vm.prank(ENGINE);
        vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
        registry.registerLazyDefault(OWNER_A);
    }

    function test_registryFlow_engineCannotSelfAuthorize() external {
        vm.prank(ENGINE);
        vm.expectRevert(VaultCapabilityController.OnlyGovernance.selector);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
    }

    /*//////////////////////////////////////////////////////////////
                    MULTI-BIT ALL-OF SEMANTICS
    //////////////////////////////////////////////////////////////*/

    function test_registryFlow_multiBitAllOfCheck() external {
        // Grant an unrelated bit + the required bit; require both.
        uint256 combo = Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT | Capabilities.CAP_APPLY_FEE;
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, combo, true);

        // Registry only reads CAP_REGISTER_DEFAULT_ACCOUNT, so this must succeed.
        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_A);
        assertTrue(registry.existsOf(OWNER_A, 1));

        // hasCapabilities for both bits also passes.
        assertTrue(controller.hasCapabilities(ENGINE, combo));

        // Revoke the fee bit; registry authorization unaffected.
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_APPLY_FEE, false);

        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_B);
        assertTrue(registry.existsOf(OWNER_B, 1));
    }

    /*//////////////////////////////////////////////////////////////
                CAPABILITY CHANGES DON'T ALTER IDENTITIES
    //////////////////////////////////////////////////////////////*/

    function test_registryFlow_capabilityChangesDoNotAlterIdentities() external {
        // OWNER_A registers explicitly + lazy engine also registers OWNER_B.
        vm.prank(OWNER_A);
        registry.registerNext();
        bytes32 keyA = SubKey.deriveHere(address(registry), OWNER_A, 1);
        assertEq(registry.ownerOf(keyA), OWNER_A);

        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_B);
        bytes32 keyB = SubKey.deriveHere(address(registry), OWNER_B, 1);

        // Series of capability mutations: none must touch registered identities.
        vm.startPrank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_APPLY_FEE, true);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, false);
        controller.setEngineCapability(UNRELATED_ENGINE, Capabilities.ALL_CAPABILITIES, true);
        vm.stopPrank();
        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(UNRELATED_ENGINE);

        // Registry identities preserved.
        assertEq(registry.ownerOf(keyA), OWNER_A);
        assertEq(registry.subaccountIdOf(keyA), uint32(1));
        assertEq(registry.ownerOf(keyB), OWNER_B);
        assertEq(registry.subaccountIdOf(keyB), uint32(1));
        assertEq(registry.nextIdFor(OWNER_A), uint32(2));
        assertEq(registry.nextIdFor(OWNER_B), uint32(2));
    }

    /*//////////////////////////////////////////////////////////////
                REGISTRY VIEWS UNAFFECTED BY CAPABILITY STATE
    //////////////////////////////////////////////////////////////*/

    function test_registryFlow_registeredAccountsSurviveGuardianRevoke() external {
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_A);

        // Snapshot before revoke.
        bytes32 keyA = SubKey.deriveHere(address(registry), OWNER_A, 1);
        assertTrue(registry.existsOf(OWNER_A, 1));
        assertEq(registry.ownerOf(keyA), OWNER_A);

        // Guardian revokes engine.
        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE);

        // Identity untouched.
        assertTrue(registry.existsOf(OWNER_A, 1));
        assertEq(registry.ownerOf(keyA), OWNER_A);
        assertEq(registry.nextIdFor(OWNER_A), uint32(2));
    }

    function test_registryFlow_ownerRegisterNextIndependentOfCapabilities() external {
        // Owner always can registerNext without any engine capability.
        vm.prank(OWNER_A);
        registry.registerNext();
        assertTrue(registry.existsOf(OWNER_A, 1));

        // Even after arbitrary capability mutations, owner path still works.
        vm.prank(GOVERNANCE);
        controller.setEngineCapability(ENGINE, Capabilities.ALL_CAPABILITIES, true);
        vm.prank(GUARDIAN);
        controller.guardianRevokeEngine(ENGINE);

        vm.prank(OWNER_A);
        registry.registerNext();
        assertEq(registry.nextIdFor(OWNER_A), uint32(3));
    }
}
