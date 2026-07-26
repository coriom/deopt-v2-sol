// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {CollateralVaultV2} from "../../../src/hybrid-v2/vault/CollateralVaultV2.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

import {RiskModuleIntegrationVault} from "./harness/RiskModuleIntegrationVault.sol";
import {MockRiskModule} from "./mocks/MockRiskModule.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title RiskModuleIntegrationTest
/// @notice WP-04B safety-patch Part D. Proves the abstract risk hooks are
///         compatible with a concrete inheritor that stores an immutable
///         `IRiskModule` reference and consults it via external view calls.
///         Rejected operations MUST roll back all Vault accounting.
contract RiskModuleIntegrationTest is Test {
    SubaccountRegistry internal registry;
    RiskModuleIntegrationVault internal vault;
    MockRiskModule internal riskModule;
    MockERC20 internal usdc;

    address internal constant GOVERNANCE = address(0x60);
    address internal constant GUARDIAN = address(0xE0DE);
    address internal constant OWNER_A = address(0xA1);

    function setUp() external {
        // Predict vault address (nonce+2: MockRiskModule + registry + vault).
        // Actually: mockRiskModule (nonce n), registry (nonce n+1), vault (nonce n+2).
        riskModule = new MockRiskModule();
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        registry = new SubaccountRegistry(predictedVault);
        vault = new RiskModuleIntegrationVault(address(registry), GOVERNANCE, GUARDIAN, address(riskModule));
        assertEq(address(vault), predictedVault);

        usdc = new MockERC20("USDC", "USDC", 6);
        vm.startPrank(GOVERNANCE);
        vault.addSupportedToken(address(usdc));
        vault.setEngineCapability(address(vault), Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT, true);
        vm.stopPrank();

        // Fund OWNER_A.
        usdc.mint(OWNER_A, 1000e6);
        vm.startPrank(OWNER_A);
        usdc.approve(address(vault), 1000e6);
        vault.deposit(1, address(usdc), 1000e6);
        vm.stopPrank();
    }

    function test_riskModule_withdrawalAllowedApproves() external {
        vm.prank(OWNER_A);
        vault.withdraw(1, address(usdc), 100e6);
        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_A, 1), address(usdc)), 900e6);
    }

    function test_riskModule_withdrawalGloballyRejectedRollsBack() external {
        riskModule.setAllowWithdrawals(false);

        uint256 physicalBefore = usdc.balanceOf(address(vault));
        uint256 balBefore = vault.balanceOf(registry.subKeyOf(OWNER_A, 1), address(usdc));
        uint256 accBefore = vault.totalAccounted(address(usdc));
        uint256 ownerBefore = usdc.balanceOf(OWNER_A);

        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2.UnsafeWithdrawal.selector);
        vault.withdraw(1, address(usdc), 200e6);

        assertEq(usdc.balanceOf(address(vault)), physicalBefore, "physical MUST NOT change");
        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_A, 1), address(usdc)), balBefore, "balance MUST NOT change");
        assertEq(vault.totalAccounted(address(usdc)), accBefore, "totalAccounted MUST NOT change");
        assertEq(usdc.balanceOf(OWNER_A), ownerBefore, "owner MUST NOT receive tokens");
    }

    function test_riskModule_withdrawalPerKeyVetoRollsBack() external {
        bytes32 key = registry.subKeyOf(OWNER_A, 1);
        riskModule.setVetoWithdrawal(key, address(usdc), true);

        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2.UnsafeWithdrawal.selector);
        vault.withdraw(1, address(usdc), 50e6);

        assertEq(vault.balanceOf(key, address(usdc)), 1000e6);
    }

    function test_riskModule_transferAllowedApproves() external {
        vm.prank(OWNER_A);
        registry.registerNext(); // Account 2
        vm.prank(OWNER_A);
        vault.internalTransfer(address(usdc), 1, 2, 200e6);

        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_A, 1), address(usdc)), 800e6);
        assertEq(vault.balanceOf(registry.subKeyOf(OWNER_A, 2), address(usdc)), 200e6);
    }

    function test_riskModule_transferGloballyRejectedRollsBack() external {
        vm.prank(OWNER_A);
        registry.registerNext();
        riskModule.setAllowTransfers(false);

        bytes32 key1 = registry.subKeyOf(OWNER_A, 1);
        bytes32 key2 = registry.subKeyOf(OWNER_A, 2);
        uint256 bal1Before = vault.balanceOf(key1, address(usdc));
        uint256 bal2Before = vault.balanceOf(key2, address(usdc));
        uint256 accBefore = vault.totalAccounted(address(usdc));

        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2.UnsafeTransfer.selector);
        vault.internalTransfer(address(usdc), 1, 2, 300e6);

        assertEq(vault.balanceOf(key1, address(usdc)), bal1Before);
        assertEq(vault.balanceOf(key2, address(usdc)), bal2Before);
        assertEq(vault.totalAccounted(address(usdc)), accBefore);
    }

    function test_riskModule_transferPerKeyVetoRollsBack() external {
        vm.prank(OWNER_A);
        registry.registerNext();
        bytes32 key1 = registry.subKeyOf(OWNER_A, 1);
        riskModule.setVetoTransfer(key1, address(usdc), true);

        vm.prank(OWNER_A);
        vm.expectRevert(CollateralVaultV2.UnsafeTransfer.selector);
        vault.internalTransfer(address(usdc), 1, 2, 100e6);

        assertEq(vault.balanceOf(key1, address(usdc)), 1000e6);
    }

    function test_riskModule_addressIsImmutable() external view {
        assertEq(address(vault.RISK_MODULE()), address(riskModule));
    }
}
