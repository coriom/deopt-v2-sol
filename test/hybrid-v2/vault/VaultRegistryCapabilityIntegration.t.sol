// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CollateralVaultV2Core} from "../../../src/hybrid-v2/vault/CollateralVaultV2Core.sol";
import {VaultCapabilityController} from "../../../src/hybrid-v2/vault/VaultCapabilityController.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {ISubaccountRegistry} from "../../../src/hybrid-v2/interfaces/ISubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

import {CollateralVaultV2CoreHarness} from "./harness/CollateralVaultV2CoreHarness.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title VaultRegistryCapabilityIntegrationTest
/// @notice End-to-end wiring for WP-04A: real Registry + real Vault (harness of
///         the abstract V2-A core) + inherited capability subsystem.
contract VaultRegistryCapabilityIntegrationTest is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2CoreHarness internal vault;
    MockERC20 internal usdc;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);
    address internal constant ENGINE = address(0xE1);
    address internal constant OWNER_A = address(0xA1);
    address internal constant OWNER_B = address(0xA2);
    address internal constant OWNER_C = address(0xA3);

    function setUp() external {
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new SubaccountRegistry(predictedVault);
        vault = new CollateralVaultV2CoreHarness(address(registry), GOVERNANCE, GUARDIAN);
        assertEq(address(vault), predictedVault);

        usdc = new MockERC20("USDC", "USDC", 6);
        vm.startPrank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                CAPABILITY VIEWS STILL FUNCTION
    //////////////////////////////////////////////////////////////*/

    function test_capabilityViewsUnaffectedByDeposits() external {
        assertTrue(vault.isAuthorizedEngine(address(vault)));
        assertEq(vault.engineCapabilityBits(address(vault)), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT);

        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);

        assertTrue(vault.isAuthorizedEngine(address(vault)));
        assertEq(vault.engineCapabilityBits(address(vault)), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT);
    }

    /*//////////////////////////////////////////////////////////////
             LAZY ACCOUNT 1 VIA VAULT CAPABILITY PATH
    //////////////////////////////////////////////////////////////*/

    function test_depositLazyRegistersThenCredits() external {
        assertFalse(registry.existsOf(OWNER_A, 1));
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        assertTrue(registry.existsOf(OWNER_A, 1));

        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA1, address(usdc)), 100e6);
    }

    /*//////////////////////////////////////////////////////////////
                     EXTERNAL ENGINE LAZY PATH
    //////////////////////////////////////////////////////////////*/

    function test_externalEngineWithCapabilityCanLazyRegister() external {
        // A hypothetical matching engine holds the capability directly.
        vm.prank(GOVERNANCE);
        vault.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);

        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_B);

        assertTrue(registry.existsOf(OWNER_B, 1));

        // Deposit against the now-registered Account 1 works from the owner.
        _mintApproveDeposit(OWNER_B, 1, usdc, 42e6);
        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_B, 1), address(usdc)), 42e6);
    }

    function test_externalEngineWithoutCapabilityCannotLazyRegister() external {
        vm.prank(ENGINE);
        vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
        registry.registerLazyDefault(OWNER_B);
        assertFalse(registry.existsOf(OWNER_B, 1));
    }

    /*//////////////////////////////////////////////////////////////
                    ACCOUNT 2 REQUIRES EXPLICIT REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_accountTwoRequiresExplicitRegisterNext() external {
        // OWNER_A has Account 1 via lazy path.
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);

        // A deposit into Account 2 without prior explicit registerNext reverts.
        usdc.mint(OWNER_A, 100e6);
        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSelector(CollateralVaultV2Core.SubaccountNotFound.selector, OWNER_A, uint32(2)));
        vault.deposit(2, address(usdc), 100e6);
        vm.stopPrank();

        // After explicit registration, the deposit succeeds.
        vm.prank(OWNER_A);
        registry.registerNext(); // assigns Account 2
        _mintApproveDeposit(OWNER_A, 2, usdc, 50e6);

        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_A, 2), address(usdc)), 50e6);
    }

    /*//////////////////////////////////////////////////////////////
               GUARDIAN REVOCATION BLOCKS LAZY PATH
    //////////////////////////////////////////////////////////////*/

    function test_guardianRevokeBlocksFutureLazyRegistration() external {
        // Register Account 1 for OWNER_A while capability is held.
        _mintApproveDeposit(OWNER_A, 1, usdc, 50e6);
        assertTrue(registry.existsOf(OWNER_A, 1));

        // Guardian revokes the vault's engine capability.
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(address(vault));

        // A fresh owner's lazy-registering deposit now reverts through the registry.
        usdc.mint(OWNER_C, 100e6);
        vm.startPrank(OWNER_C);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(ISubaccountRegistry.NotAuthorized.selector);
        vault.deposit(1, address(usdc), 100e6);
        vm.stopPrank();

        // OWNER_A's existing balance is untouched.
        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        assertEq(vault.balanceOf(keyA1, address(usdc)), 50e6);
    }

    function test_governanceCanRegrantAfterGuardianRevoke() external {
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(address(vault));

        vm.prank(GOVERNANCE);
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);

        // Fresh lazy path now works again.
        _mintApproveDeposit(OWNER_C, 1, usdc, 10e6);
        assertTrue(registry.existsOf(OWNER_C, 1));
    }

    /*//////////////////////////////////////////////////////////////
            CAPABILITY MUTATIONS DON'T CHANGE BALANCES
    //////////////////////////////////////////////////////////////*/

    function test_capabilityMutationsDoNotAlterBalances() external {
        _mintApproveDeposit(OWNER_A, 1, usdc, 500e6);
        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        uint256 balBefore = vault.balanceOf(keyA1, address(usdc));
        uint256 totalBefore = vault.totalAccounted(address(usdc));

        vm.startPrank(GOVERNANCE);
        vault.setEngineCapability(ENGINE, Capabilities.CAP_APPLY_FEE, true);
        vault.setEngineCapability(ENGINE, Capabilities.CAP_LOCK_COLLATERAL, true);
        vault.setEngineCapability(ENGINE, Capabilities.CAP_APPLY_FEE, false);
        vm.stopPrank();
        vm.prank(GUARDIAN);
        vault.guardianRevokeEngine(ENGINE);

        assertEq(vault.balanceOf(keyA1, address(usdc)), balBefore);
        assertEq(vault.totalAccounted(address(usdc)), totalBefore);
    }

    /*//////////////////////////////////////////////////////////////
                    TOKEN POLICY LEAVES REGISTRY INERT
    //////////////////////////////////////////////////////////////*/

    function test_tokenPolicyDoesNotChangeRegistry() external {
        vm.prank(OWNER_A);
        registry.registerNext();
        bytes32 keyA1 = registry.subKeyOf(OWNER_A, 1);
        address ownerBefore = registry.ownerOf(keyA1);
        uint32 nextBefore = registry.nextIdFor(OWNER_A);

        vm.startPrank(GOVERNANCE);
        vault.removeSupportedToken(address(usdc));
        vault.addSupportedToken(address(usdc));
        vm.stopPrank();

        assertEq(registry.ownerOf(keyA1), ownerBefore);
        assertEq(registry.nextIdFor(OWNER_A), nextBefore);
    }

    /*//////////////////////////////////////////////////////////////
                  ISOLATION UNDER MIXED FLOWS
    //////////////////////////////////////////////////////////////*/

    function test_isolationUnderMixedRegistryVaultFlows() external {
        // OWNER_A: lazy register + deposit.
        _mintApproveDeposit(OWNER_A, 1, usdc, 100e6);
        // OWNER_B: explicit register + deposit into Account 2.
        vm.startPrank(OWNER_B);
        registry.registerNext(); // Account 1
        registry.registerNext(); // Account 2
        vm.stopPrank();
        _mintApproveDeposit(OWNER_B, 2, usdc, 250e6);
        // OWNER_C: engine-driven lazy registration only, no deposit.
        vm.prank(GOVERNANCE);
        vault.setEngineCapability(ENGINE, Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vm.prank(ENGINE);
        registry.registerLazyDefault(OWNER_C);

        // Balances match expectations; no cross-contamination.
        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_A, 1), address(usdc)), 100e6);
        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_B, 2), address(usdc)), 250e6);
        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_B, 1), address(usdc)), 0);
        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_C, 1), address(usdc)), 0);
        assertEq(vault.totalAccounted(address(usdc)), 350e6);
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _mintApproveDeposit(address owner, uint32 subaccountId, MockERC20 token, uint256 amount) internal {
        token.mint(owner, amount);
        vm.startPrank(owner);
        token.approve(address(vault), amount);
        vault.deposit(subaccountId, address(token), amount);
        vm.stopPrank();
    }
}
