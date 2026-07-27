// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {VaultRiskModuleConsumer} from "../../../src/hybrid-v2/risk/VaultRiskModuleConsumer.sol";
import {CollateralVaultV2RiskIntegrated} from "../../../src/hybrid-v2/risk/CollateralVaultV2RiskIntegrated.sol";
import {RiskAwareVaultHarness} from "./harness/RiskAwareVaultHarness.sol";
import {RiskModuleV2Harness} from "./harness/RiskModuleV2Harness.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @dev A concrete consumer that binds the Vault-side RiskModule via the
///      canonical `VaultRiskModuleConsumer` abstract. Models the exact
///      constructor shape a future WP-08 MarginEngineV2 MUST follow.
contract ConsumerConcrete is VaultRiskModuleConsumer {
    constructor(address vault_) VaultRiskModuleConsumer(vault_) {}
}

/// @dev A pretend RiskModule that returns a mismatched architecture version.
///      Used to prove the consumer's defence-in-depth compat check triggers
///      even if a future Vault variant relaxed its own check.
contract StubRiskModuleWrongArch is IRiskModule {
    function marginRequirement(bytes32) external pure returns (uint256) {
        return 0;
    }

    function availableMargin(bytes32) external pure returns (uint256) {
        return 0;
    }

    function marginHealthy(bytes32) external pure returns (bool) {
        return true;
    }

    function marginRatio(bytes32) external pure returns (uint256) {
        return type(uint256).max;
    }

    function withdrawalAllowed(bytes32, address, uint256) external pure returns (bool) {
        return true;
    }

    function transferAllowed(bytes32, address, uint256) external pure returns (bool) {
        return true;
    }

    function liquidationStatus(bytes32) external pure returns (LiquidationStatus) {
        return LiquidationStatus.HEALTHY;
    }

    function productsEnabled(bytes32) external pure returns (bool, bool) {
        return (true, false);
    }

    function moduleVersion() external pure returns (uint16) {
        return 42;
    }

    function supportsCanonicalStorageVersion(uint16 v) external pure returns (bool) {
        return v == Versions.STORAGE_VERSION;
    }

    // Non-standard: report a DIFFERENT architecture version to force mismatch.
    function ARCHITECTURE_VERSION() external pure returns (uint256) {
        return Versions.ARCHITECTURE_VERSION + 100;
    }
}

/// @dev A pretend RiskModule that reports the correct architecture but
///      refuses the canonical storage version.
contract StubRiskModuleWrongStorage is IRiskModule {
    function marginRequirement(bytes32) external pure returns (uint256) {
        return 0;
    }

    function availableMargin(bytes32) external pure returns (uint256) {
        return 0;
    }

    function marginHealthy(bytes32) external pure returns (bool) {
        return true;
    }

    function marginRatio(bytes32) external pure returns (uint256) {
        return type(uint256).max;
    }

    function withdrawalAllowed(bytes32, address, uint256) external pure returns (bool) {
        return true;
    }

    function transferAllowed(bytes32, address, uint256) external pure returns (bool) {
        return true;
    }

    function liquidationStatus(bytes32) external pure returns (LiquidationStatus) {
        return LiquidationStatus.HEALTHY;
    }

    function productsEnabled(bytes32) external pure returns (bool, bool) {
        return (true, false);
    }

    function moduleVersion() external pure returns (uint16) {
        return 42;
    }

    function supportsCanonicalStorageVersion(uint16) external pure returns (bool) {
        return false;
    }

    function ARCHITECTURE_VERSION() external pure returns (uint256) {
        return Versions.ARCHITECTURE_VERSION;
    }
}

/// @title VaultRiskModuleConsumerTest
/// @notice WP-07 boundedness + liquidation-safety patch — proves the
///         production RM-1 consumer boundary CANNOT bind a divergent
///         RiskModule and correctly rejects incompatible modules.
///
/// Enforces `SINGLE_RISKMODULE_CONSUMER_BOUNDARY_ENFORCED` (Part J).
contract VaultRiskModuleConsumerTest is Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    RiskModuleV2Harness internal module;
    OptionsPositionsLedger internal ledger;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        uint256 currentNonce = vm.getNonce(address(this));
        address predictedModule = vm.computeCreateAddress(address(this), currentNonce);
        address predictedVault = vm.computeCreateAddress(address(this), currentNonce + 1);
        address predictedLedger = vm.computeCreateAddress(address(this), currentNonce + 2);
        module = new RiskModuleV2Harness(address(registry), predictedVault, predictedLedger, 1);
        vault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        require(address(module) == predictedModule, "module addr mismatch");
        require(address(vault) == predictedVault, "vault addr mismatch");
        require(address(ledger) == predictedLedger, "ledger addr mismatch");
    }

    /*//////////////////////////////////////////////////////////////
              Happy path: consumer binds Vault's module
    //////////////////////////////////////////////////////////////*/

    function test_consumerBindsExactVaultModule() public {
        ConsumerConcrete c = new ConsumerConcrete(address(vault));
        assertEq(address(c.VAULT()), address(vault));
        assertEq(address(c.RISK_MODULE()), address(module));
    }

    function test_twoConsumersOnSameVaultAgree() public {
        ConsumerConcrete a = new ConsumerConcrete(address(vault));
        ConsumerConcrete b = new ConsumerConcrete(address(vault));
        assertEq(address(a.RISK_MODULE()), address(b.RISK_MODULE()));
        assertEq(address(a.VAULT()), address(b.VAULT()));
    }

    function test_versionImmutablesPinned() public {
        ConsumerConcrete c = new ConsumerConcrete(address(vault));
        assertEq(uint256(c.ARCHITECTURE_VERSION()), uint256(Versions.ARCHITECTURE_VERSION));
        assertEq(uint256(c.SUPPORTED_STORAGE_VERSION()), uint256(Versions.STORAGE_VERSION));
    }

    /*//////////////////////////////////////////////////////////////
              Rejection: zero vault
    //////////////////////////////////////////////////////////////*/

    function test_rejectsZeroVault() public {
        vm.expectRevert(VaultRiskModuleConsumer.InvalidVault.selector);
        new ConsumerConcrete(address(0));
    }

    /*//////////////////////////////////////////////////////////////
              Rejection: architecture mismatch (defence in depth)
    //////////////////////////////////////////////////////////////*/

    function test_rejectsArchitectureMismatch() public {
        // Deploy a stub-module Vault variant. We can't easily wire a real
        // RiskAwareVault to a stub module (the Vault's own constructor
        // checks would fail first). To exercise the CONSUMER-side check we
        // deploy a mock Vault that simply returns a stub `RISK_MODULE()`.
        MockVaultReturningStub badVault = new MockVaultReturningStub(address(new StubRiskModuleWrongArch()));
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultRiskModuleConsumer.RiskModuleArchitectureMismatch.selector,
                Versions.ARCHITECTURE_VERSION,
                Versions.ARCHITECTURE_VERSION + 100
            )
        );
        new ConsumerConcrete(address(badVault));
    }

    /*//////////////////////////////////////////////////////////////
              Rejection: storage version unsupported (defence in depth)
    //////////////////////////////////////////////////////////////*/

    function test_rejectsStorageVersionUnsupported() public {
        MockVaultReturningStub badVault = new MockVaultReturningStub(address(new StubRiskModuleWrongStorage()));
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultRiskModuleConsumer.RiskModuleStorageVersionUnsupported.selector, Versions.STORAGE_VERSION
            )
        );
        new ConsumerConcrete(address(badVault));
    }

    /*//////////////////////////////////////////////////////////////
              Rejection: Vault reports zero RiskModule
    //////////////////////////////////////////////////////////////*/

    function test_rejectsVaultWithZeroRiskModule() public {
        MockVaultReturningStub badVault = new MockVaultReturningStub(address(0));
        vm.expectRevert(VaultRiskModuleConsumer.RiskModuleNotBoundOnVault.selector);
        new ConsumerConcrete(address(badVault));
    }

    /*//////////////////////////////////////////////////////////////
              Replacement: fresh consumer redeploy = fresh cutover
    //////////////////////////////////////////////////////////////*/

    function test_replacementRequiresFreshConsumerRedeploy() public {
        ConsumerConcrete origConsumer = new ConsumerConcrete(address(vault));
        assertEq(address(origConsumer.RISK_MODULE()), address(module));

        // Deploy a fresh (Vault, Module) triple.
        uint256 currentNonce = vm.getNonce(address(this));
        address predictedNewModule = vm.computeCreateAddress(address(this), currentNonce);
        address predictedNewVault = vm.computeCreateAddress(address(this), currentNonce + 1);
        address predictedNewLedger = vm.computeCreateAddress(address(this), currentNonce + 2);
        RiskModuleV2Harness newModule =
            new RiskModuleV2Harness(address(registry), predictedNewVault, predictedNewLedger, 2);
        RiskAwareVaultHarness newVault =
            new RiskAwareVaultHarness(address(registry), governance, guardian, predictedNewModule);
        OptionsPositionsLedger newLedger = new OptionsPositionsLedger(address(registry), predictedNewVault);
        newLedger; // silence

        ConsumerConcrete newConsumer = new ConsumerConcrete(address(newVault));
        // Different consumer instance → different (Vault, Module) reference.
        assertTrue(address(newConsumer.RISK_MODULE()) != address(module));
        assertEq(address(newConsumer.RISK_MODULE()), address(newModule));
        // Original consumer is unaffected — immutable.
        assertEq(address(origConsumer.RISK_MODULE()), address(module));
        assertEq(address(origConsumer.VAULT()), address(vault));
    }

    /*//////////////////////////////////////////////////////////////
              Compile-time proof: no independent module arg
    //////////////////////////////////////////////////////////////*/

    /// @notice The `VaultRiskModuleConsumer` abstract's constructor accepts
    ///         ONLY `address vault_`. There is no `(vault, riskModule)`
    ///         overload. Any inheritor that tried to bind a second module
    ///         would need to shadow / re-declare `RISK_MODULE` — visibly.
    ///         This test documents the property; the type system enforces it.
    function test_documentsAbsenceOfIndependentModuleArg() public {
        // Reference constructor shape.
        ConsumerConcrete c = new ConsumerConcrete(address(vault));
        assertEq(address(c.VAULT()), address(vault));
        assertEq(address(c.RISK_MODULE()), address(module));
        // If a future WP-08 tried `constructor(address vault, address riskModule)`,
        // it would either not inherit `VaultRiskModuleConsumer` (visible ABI
        // deviation) or would fail to compile because the parent constructor
        // takes ONE argument.
    }
}

/// @dev Minimal Vault stub that returns an arbitrary `RISK_MODULE()`. Used to
///      exercise the consumer's defence-in-depth compat checks without
///      needing to bypass the real Vault's own construction gates.
contract MockVaultReturningStub {
    address public immutable STUBBED_MODULE;

    constructor(address stubbed) {
        STUBBED_MODULE = stubbed;
    }

    function RISK_MODULE() external view returns (IRiskModule) {
        return IRiskModule(STUBBED_MODULE);
    }
}
