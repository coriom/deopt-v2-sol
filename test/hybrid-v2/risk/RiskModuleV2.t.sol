// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RiskModuleV2} from "../../../src/hybrid-v2/risk/RiskModuleV2.sol";
import {RiskModuleV2Harness} from "./harness/RiskModuleV2Harness.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title RiskModuleV2UnitFuzz
/// @notice L1 unit + L3 fuzz suite for the WP-07 abstract RiskModule + concrete harness.
contract RiskModuleV2UnitFuzz is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    OptionsPositionsLedger internal ledger;
    RiskModuleV2Harness internal module;
    MockERC20 internal token;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    uint16 internal constant MODULE_VERSION = 1;

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        ledger = new OptionsPositionsLedger(address(registry), address(vault));
        module = new RiskModuleV2Harness(address(registry), address(vault), address(ledger), MODULE_VERSION);
        token = new MockERC20("Mock", "MCK", 18);

        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerB);
        registry.registerNext();

        vm.prank(governance);
        vault.addSupportedToken(address(token));

        module.setTokenPrice1e8(address(token), 1e8); // token quoted 1:1
    }

    function _sk(address o, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(o, id);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_recordsImmutables() public view {
        assertEq(address(module.REGISTRY()), address(registry));
        assertEq(address(module.VAULT()), address(vault));
        assertEq(address(module.OPTIONS_LEDGER()), address(ledger));
        assertEq(module.ARCHITECTURE_VERSION(), Versions.ARCHITECTURE_VERSION);
        assertEq(module.SUPPORTED_STORAGE_VERSION(), Versions.STORAGE_VERSION);
        assertEq(module.MODULE_VERSION(), MODULE_VERSION);
        assertEq(module.moduleVersion(), MODULE_VERSION);
    }

    function test_constructor_rejectsZeroRegistry() public {
        vm.expectRevert(RiskModuleV2.InvalidRegistry.selector);
        new RiskModuleV2Harness(address(0), address(vault), address(ledger), MODULE_VERSION);
    }

    function test_constructor_rejectsZeroVault() public {
        vm.expectRevert(RiskModuleV2.InvalidVault.selector);
        new RiskModuleV2Harness(address(registry), address(0), address(ledger), MODULE_VERSION);
    }

    function test_constructor_rejectsZeroLedger() public {
        vm.expectRevert(RiskModuleV2.InvalidOptionsLedger.selector);
        new RiskModuleV2Harness(address(registry), address(vault), address(0), MODULE_VERSION);
    }

    function test_constructor_rejectsZeroModuleVersion() public {
        vm.expectRevert(RiskModuleV2.InvalidModuleVersion.selector);
        new RiskModuleV2Harness(address(registry), address(vault), address(ledger), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       COMPATIBILITY IDENTIFIER
    //////////////////////////////////////////////////////////////*/

    function test_supportsCanonicalStorageVersion_matches() public view {
        assertTrue(module.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION));
    }

    function test_supportsCanonicalStorageVersion_rejectsOthers() public view {
        assertFalse(module.supportsCanonicalStorageVersion(0));
        assertFalse(module.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION + 1));
        assertFalse(module.supportsCanonicalStorageVersion(999));
    }

    function test_productsEnabled_optionsOnlyInV1() public view {
        (bool optionsEnabled, bool perpsEnabled) = module.productsEnabled(_sk(ownerA, 1));
        assertTrue(optionsEnabled);
        assertFalse(perpsEnabled);
    }

    function test_productsEnabled_failsClosedOnZeroSubKey() public view {
        (bool optionsEnabled, bool perpsEnabled) = module.productsEnabled(bytes32(0));
        assertFalse(optionsEnabled);
        assertFalse(perpsEnabled);
    }

    function test_productsEnabled_failsClosedOnUnknownSubaccount() public view {
        bytes32 fake = registry.subKeyOf(ownerA, 99);
        (bool optionsEnabled, bool perpsEnabled) = module.productsEnabled(fake);
        assertFalse(optionsEnabled);
        assertFalse(perpsEnabled);
    }

    function test_productsEnabled_disabledOverrideRespected() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setOptionsDisabled(sk, true);
        (bool optionsEnabled, bool perpsEnabled) = module.productsEnabled(sk);
        assertFalse(optionsEnabled);
        assertFalse(perpsEnabled);
    }

    /*//////////////////////////////////////////////////////////////
                       AGGREGATE MARGIN VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_marginRequirement_returnsHarnessValue() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 1000e18);
        assertEq(module.marginRequirement(sk), 1000e18);
    }

    function test_marginRequirement_revertsOnStaleProvider() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setProviderStale(true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.marginRequirement(sk);
    }

    function test_marginRequirement_revertsOnZeroSubKey() public {
        vm.expectRevert(RiskModuleV2.SubKeyRequired.selector);
        module.marginRequirement(bytes32(0));
    }

    function test_marginRequirement_revertsOnUnknownSubKey() public {
        bytes32 fake = registry.subKeyOf(ownerA, 99);
        vm.expectRevert(abi.encodeWithSelector(RiskModuleV2.UnknownSubaccount.selector, fake));
        module.marginRequirement(fake);
    }

    function test_availableMargin_returnsHarnessValue() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setAvailableMargin(sk, 500e18);
        assertEq(module.availableMargin(sk), 500e18);
    }

    function test_availableMargin_revertsOnStale() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setSubKeyStale(sk, true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.availableMargin(sk);
    }

    function test_marginHealthy_trueWhenAvailableEqualsRequired() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 100e18);
        assertTrue(module.marginHealthy(sk));
    }

    function test_marginHealthy_falseWhenBelow() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 99e18);
        assertFalse(module.marginHealthy(sk));
    }

    function test_marginHealthy_failsClosedOnStale() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 200e18);
        module.setSubKeyStale(sk, true);
        assertFalse(module.marginHealthy(sk));
    }

    function test_marginHealthy_falseOnZeroSubKey() public view {
        assertFalse(module.marginHealthy(bytes32(0)));
    }

    function test_marginHealthy_falseOnUnknownSubKey() public view {
        assertFalse(module.marginHealthy(registry.subKeyOf(ownerA, 99)));
    }

    function test_marginRatio_maxWhenRequiredZero() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 0);
        module.setAvailableMargin(sk, 1e18);
        assertEq(module.marginRatio(sk), type(uint256).max);
    }

    function test_marginRatio_normalCase() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 200e18);
        module.setAvailableMargin(sk, 100e18);
        assertEq(module.marginRatio(sk), 0.5e18);
    }

    function test_marginRatio_revertsOnStale() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 100e18);
        module.setProviderStale(true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.marginRatio(sk);
    }

    /*//////////////////////////////////////////////////////////////
                       WITHDRAWAL SAFETY
    //////////////////////////////////////////////////////////////*/

    function _seedWithdrawContext(bytes32 sk, uint256 balance, uint256 required, uint256 available) internal {
        vault.testForceCredit(sk, address(token), balance);
        module.setRequiredMargin(sk, required);
        module.setAvailableMargin(sk, available);
    }

    function test_withdrawalAllowed_falseOnZeroInputs() public view {
        bytes32 sk = _sk(ownerA, 1);
        assertFalse(module.withdrawalAllowed(bytes32(0), address(token), 1));
        assertFalse(module.withdrawalAllowed(sk, address(0), 1));
        assertFalse(module.withdrawalAllowed(sk, address(token), 0));
    }

    function test_withdrawalAllowed_falseOnUnknownSubKey() public view {
        assertFalse(module.withdrawalAllowed(registry.subKeyOf(ownerA, 99), address(token), 1));
    }

    function test_withdrawalAllowed_falseOnUnsupportedToken() public {
        bytes32 sk = _sk(ownerA, 1);
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        assertFalse(module.withdrawalAllowed(sk, address(other), 1));
    }

    function test_withdrawalAllowed_falseWhenExceedsAvailableToken() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 0, 100e18);
        assertFalse(module.withdrawalAllowed(sk, address(token), 101e18));
    }

    function test_withdrawalAllowed_trueWhenBufferSuffices() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 40e18, 100e18);
        // Withdraw 50 → post-avail 50; required 40 → true.
        assertTrue(module.withdrawalAllowed(sk, address(token), 50e18));
    }

    function test_withdrawalAllowed_falseWhenBufferInsufficient() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 60e18, 100e18);
        // Withdraw 50 → post-avail 50; required 60 → false.
        assertFalse(module.withdrawalAllowed(sk, address(token), 50e18));
    }

    function test_withdrawalAllowed_falseOnStaleProvider() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 0, 100e18);
        module.setProviderStale(true);
        assertFalse(module.withdrawalAllowed(sk, address(token), 10e18));
    }

    function test_withdrawalAllowed_falseOnStaleToken() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 0, 100e18);
        module.setTokenStale(address(token), true);
        assertFalse(module.withdrawalAllowed(sk, address(token), 10e18));
    }

    function test_withdrawalAllowed_falseWhenTokenPriceZero() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 0, 100e18);
        module.setTokenPrice1e8(address(token), 0);
        assertFalse(module.withdrawalAllowed(sk, address(token), 10e18));
    }

    function test_withdrawalAllowed_falseWhenLockedExceedsRequested() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 0, 100e18);
        // Lock 60 out of 100 → available token balance = 40. Withdraw > 40 rejected.
        vm.prank(governance);
        vault.setEngineCapability(address(this), 1 << 3, true); // CAP_LOCK_COLLATERAL
        vault.applyLock(sk, address(token), 60e18);
        assertFalse(module.withdrawalAllowed(sk, address(token), 50e18));
        assertTrue(module.withdrawalAllowed(sk, address(token), 40e18));
    }

    /*//////////////////////////////////////////////////////////////
                     INTERNAL-TRANSFER SAFETY
    //////////////////////////////////////////////////////////////*/

    function test_transferAllowed_sourceMirrorsWithdrawal() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 40e18, 100e18);
        assertTrue(module.transferAllowed(sk, address(token), 50e18));
        assertFalse(module.transferAllowed(sk, address(token), 61e18));
    }

    function test_transferAllowed_failsClosedOnStale() public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 100e18, 0, 100e18);
        module.setProviderStale(true);
        assertFalse(module.transferAllowed(sk, address(token), 1e18));
    }

    /*//////////////////////////////////////////////////////////////
                     LIQUIDATION STATUS
    //////////////////////////////////////////////////////////////*/

    function test_liquidationStatus_healthyWhenAvailableExceedsRequired() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 100e18);
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.HEALTHY));
    }

    function test_liquidationStatus_eligibleWhenBelowThreshold() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 50e18);
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION));
    }

    function test_liquidationStatus_revertsOnStale() public {
        // Superseded by BOUNDEDNESS-AND-LIQUIDATION-SAFETY-PATCH (2026-07-27):
        // stale provider → RiskModuleUnavailable revert (not ELIGIBLE). See
        // RiskModuleV2 NatSpec + `RISK-LIQ-I1`.
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 100e18);
        module.setProviderStale(true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(sk);
    }

    function test_liquidationStatus_revertsOnZeroSubKey() public {
        vm.expectRevert(RiskModuleV2.SubKeyRequired.selector);
        module.liquidationStatus(bytes32(0));
    }

    function test_liquidationStatus_revertsOnUnknownSubaccount() public {
        bytes32 fake = registry.subKeyOf(address(0x99999), 42);
        vm.expectRevert(abi.encodeWithSelector(RiskModuleV2.UnknownSubaccount.selector, fake));
        module.liquidationStatus(fake);
    }

    /*//////////////////////////////////////////////////////////////
                              ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_isolation_siblingSubaccountRiskIndependent() public {
        bytes32 sk1 = _sk(ownerA, 1);
        bytes32 sk2 = _sk(ownerA, 2);
        module.setRequiredMargin(sk1, 100e18);
        module.setAvailableMargin(sk1, 50e18);
        // sk2 has no state → available 0, required 0, healthy.
        assertFalse(module.marginHealthy(sk1));
        assertTrue(module.marginHealthy(sk2));
    }

    function test_isolation_siblingOwnerRiskIndependent() public {
        bytes32 skA = _sk(ownerA, 1);
        bytes32 skB = _sk(ownerB, 1);
        module.setRequiredMargin(skA, 100e18);
        module.setAvailableMargin(skA, 50e18);
        assertFalse(module.marginHealthy(skA));
        assertTrue(module.marginHealthy(skB));
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_marginHealthy_matchesComparison(uint128 required, uint128 available) public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, uint256(required));
        module.setAvailableMargin(sk, uint256(available));
        assertEq(module.marginHealthy(sk), available >= required);
    }

    function testFuzz_withdrawalAllowed_conservativeUnderStale(uint64 amount) public {
        bytes32 sk = _sk(ownerA, 1);
        _seedWithdrawContext(sk, 1000e18, 0, 1000e18);
        module.setProviderStale(true);
        assertFalse(module.withdrawalAllowed(sk, address(token), amount == 0 ? 1 : uint256(amount)));
    }

    function testFuzz_withdrawalAllowed_thresholdBoundary(uint96 required96, uint96 amount96) public {
        bytes32 sk = _sk(ownerA, 1);
        uint256 balance = 1_000_000e18;
        uint256 required = uint256(required96);
        uint256 amount = uint256(amount96) + 1;
        vm.assume(amount <= balance);
        vm.assume(required <= balance);
        _seedWithdrawContext(sk, balance, required, balance);
        bool expected = balance - amount >= required;
        assertEq(module.withdrawalAllowed(sk, address(token), amount), expected);
    }
}
