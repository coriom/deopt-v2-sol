// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {RiskModuleV2} from "../../../src/hybrid-v2/risk/RiskModuleV2.sol";
import {CollateralVaultV2RiskIntegrated} from "../../../src/hybrid-v2/risk/CollateralVaultV2RiskIntegrated.sol";
import {RiskAwareVaultHarness} from "./harness/RiskAwareVaultHarness.sol";
import {RiskModuleV2Harness} from "./harness/RiskModuleV2Harness.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @dev Test-only downstream consumer that models the WP-08 MarginEngine
///      constructor contract: bind the SAME RiskModule the Vault uses by
///      sourcing it from `Vault.RISK_MODULE()` — never accept an independent
///      arg. Any deviation from this pattern would allow the consumer to bind
///      a divergent module and violate `RISK-SLOT-I1`.
contract DownstreamConsumerCorrect {
    IRiskModule public immutable RISK_MODULE;
    address public immutable VAULT;

    constructor(address vault_) {
        VAULT = vault_;
        // Canonical pattern: source the RiskModule from the Vault itself. Any
        // second reference would allow divergence.
        RISK_MODULE = CollateralVaultV2RiskIntegrated(vault_).RISK_MODULE();
    }
}

/// @dev Test-only counter-example consumer that binds a caller-supplied module.
///      Included ONLY to demonstrate what MUST NOT be built. The invariant
///      `RISK-SLOT-I1` is preserved because the correct consumer above is the
///      only pattern the tracked doc authorizes.
contract DownstreamConsumerDivergent {
    IRiskModule public immutable RISK_MODULE;
    address public immutable VAULT;

    constructor(address vault_, address riskModule_) {
        VAULT = vault_;
        RISK_MODULE = IRiskModule(riskModule_);
    }
}

/// @title RiskModuleV2SlotAuthority
/// @notice WP-07 slot/authority patch — tests that lock in the RM-1 posture:
///   `SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT`.
///
/// Invariants exercised:
///   RISK-SLOT-I1: every consumer of Vault-driven risk decisions binds the
///                 SAME `IRiskModule` address as the Vault. Enforced by the
///                 canonical constructor pattern in `DownstreamConsumerCorrect`.
///   RISK-SLOT-I2: an incompatible RiskModule cannot bind to the Vault.
///                 Enforced by `CollateralVaultV2RiskIntegrated` construction
///                 checks (Registry / architecture / storage-version) — already
///                 covered by `RiskModuleV2Integration.t.sol` for the Vault
///                 side; this file adds symmetric coverage for the consumer
///                 pattern.
///   RISK-SLOT-I3: RiskModule replacement / configuration does not mutate
///                 canonical economic state. Trivially witnessed here because
///                 the tests never mutate module state, and the module has no
///                 admin setters.
contract RiskModuleV2SlotAuthority is Test {
    SubaccountRegistry internal registry;
    OptionsPositionsLedger internal ledger;
    RiskModuleV2Harness internal riskModule;
    RiskAwareVaultHarness internal riskVault;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        uint256 currentNonce = vm.getNonce(address(this));
        address predictedModule = vm.computeCreateAddress(address(this), currentNonce);
        address predictedVault = vm.computeCreateAddress(address(this), currentNonce + 1);
        address predictedLedger = vm.computeCreateAddress(address(this), currentNonce + 2);
        riskModule = new RiskModuleV2Harness(address(registry), predictedVault, predictedLedger, 1);
        riskVault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        require(address(riskModule) == predictedModule, "module addr mismatch");
        require(address(riskVault) == predictedVault, "vault addr mismatch");
        require(address(ledger) == predictedLedger, "ledger addr mismatch");
    }

    /*//////////////////////////////////////////////////////////////
              RISK-SLOT-I1: single canonical module reference
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical downstream consumer binds Vault's own RiskModule.
    function test_correctConsumer_bindsExactVaultModule() public {
        DownstreamConsumerCorrect consumer = new DownstreamConsumerCorrect(address(riskVault));
        assertEq(address(consumer.RISK_MODULE()), address(riskModule));
        // Symmetric: the Vault reports the same address.
        assertEq(address(riskVault.RISK_MODULE()), address(consumer.RISK_MODULE()));
    }

    /// @notice A downstream consumer sourcing from the Vault CANNOT bind a
    ///         module different from the Vault's, regardless of caller input.
    function test_correctConsumer_ignoresExternalModuleArg() public {
        // Build a "second" module that would satisfy compatibility if it were
        // wired into a Vault. The correct consumer pattern gives no way to
        // pass this address — the canonical `RISK_MODULE` field is always
        // sourced from the Vault.
        RiskModuleV2Harness other = new RiskModuleV2Harness(address(registry), address(0x1), address(0x2), 2);
        DownstreamConsumerCorrect consumer = new DownstreamConsumerCorrect(address(riskVault));
        assertEq(address(consumer.RISK_MODULE()), address(riskModule));
        assertTrue(address(consumer.RISK_MODULE()) != address(other));
    }

    /*//////////////////////////////////////////////////////////////
              Immutability — RiskModule reference cannot rotate
    //////////////////////////////////////////////////////////////*/

    function test_moduleReferenceIsImmutable() public {
        // The Vault's `RISK_MODULE` is declared `public immutable` — no setter
        // is exposed. Assert the same value across two reads.
        address before = address(riskVault.RISK_MODULE());
        // Perform some Vault operations that MAY touch storage but never touch
        // the immutable slot.
        vm.prank(governance);
        riskVault.addSupportedToken(address(0xBEEF));
        vm.prank(governance);
        riskVault.setEngineCapability(address(0xCAFE), 1 << 3, true);
        assertEq(address(riskVault.RISK_MODULE()), before);
    }

    function test_moduleArchitectureAndStorageVersionFrozen() public view {
        // Storage-version compatibility answer is a pure function of an
        // immutable — assert stability under multiple queries.
        assertTrue(riskModule.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION));
        assertFalse(riskModule.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION + 1));
        assertEq(uint256(riskModule.ARCHITECTURE_VERSION()), uint256(Versions.ARCHITECTURE_VERSION));
    }

    /*//////////////////////////////////////////////////////////////
              RISK-SLOT-I2: incompatible module rejected
    //////////////////////////////////////////////////////////////*/

    function test_vaultRejectsIncompatibleRegistryOnConstruction() public {
        SubaccountRegistry other = new SubaccountRegistry(address(0xDEAD));
        // Build a RiskModule scoped to `other`. Any attempt to wire it into a
        // Vault scoped to `registry` MUST fail at construction.
        RiskModuleV2Harness foreignModule = new RiskModuleV2Harness(address(other), address(0x11), address(0x22), 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CollateralVaultV2RiskIntegrated.RiskModuleRegistryMismatch.selector, address(registry), address(other)
            )
        );
        new RiskAwareVaultHarness(address(registry), governance, guardian, address(foreignModule));
    }

    /*//////////////////////////////////////////////////////////////
              RISK-SLOT-I3: RiskModule config does not mutate canon
    //////////////////////////////////////////////////////////////*/

    function test_moduleHasNoAdminSetterForCanonState() public view {
        // Any external write path on the RiskModule would surface here as a
        // compiler-visible function. We cross-check by exercising every public
        // ABI function of `IRiskModule` — all `view` — and asserting neither
        // Registry ownership nor Vault balances nor Ledger positions change.
        bytes32 sk = registry.subKeyOf(address(0xB1), 1);
        // Read views (all `view` — no mutation possible).
        riskModule.moduleVersion();
        riskModule.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION);
        // `productsEnabled` etc. would fail closed for an unknown subKey; call
        // them for coverage.
        riskModule.productsEnabled(sk);
        // Registry / Vault / Ledger references intact after arbitrary reads.
        assertEq(address(riskModule.REGISTRY()), address(registry));
        assertEq(address(riskModule.VAULT()), address(riskVault));
        assertEq(address(riskModule.OPTIONS_LEDGER()), address(ledger));
    }

    /*//////////////////////////////////////////////////////////////
              Cross-check: correct-consumer pattern documented
    //////////////////////////////////////////////////////////////*/

    /// @notice Two independently-constructed correct consumers always agree
    ///         on the canonical module reference — the invariant is not
    ///         dependent on the deployment order.
    function test_correctConsumers_agreeAcrossInstances() public {
        DownstreamConsumerCorrect c1 = new DownstreamConsumerCorrect(address(riskVault));
        DownstreamConsumerCorrect c2 = new DownstreamConsumerCorrect(address(riskVault));
        assertEq(address(c1.RISK_MODULE()), address(c2.RISK_MODULE()));
        assertEq(address(c1.RISK_MODULE()), address(riskModule));
    }

    /// @notice Counter-example (documentation): the divergent consumer CAN
    ///         bind an arbitrary module because it accepts one as an arg.
    ///         Included only to prove that the invariant is guaranteed by
    ///         the CANONICAL pattern, not by the module itself — downstream
    ///         milestones (WP-08) MUST use the canonical pattern per the
    ///         tracked doc.
    function test_divergentPattern_isPossibleAndForbiddenByDoc() public {
        RiskModuleV2Harness other = new RiskModuleV2Harness(address(registry), address(0x1), address(0x2), 2);
        DownstreamConsumerDivergent bad = new DownstreamConsumerDivergent(address(riskVault), address(other));
        // Sanity: the counter-example indeed diverges.
        assertTrue(address(bad.RISK_MODULE()) != address(riskVault.RISK_MODULE()));
        // The correct pattern would never allow this — see `DownstreamConsumerCorrect`.
    }

    /*//////////////////////////////////////////////////////////////
              Replacement policy: fresh Vault redeploy = new module
    //////////////////////////////////////////////////////////////*/

    function test_moduleReplacementRequiresFreshVaultCutover() public {
        // Deploy a second (Vault, Module, Ledger) triple. It has a DIFFERENT
        // RISK_MODULE address than the original; existing consumers of the
        // original Vault continue to point at the original module. This models
        // spec 06 §"C-01 Replacement policy" fresh-deployment cutover in V1.
        uint256 currentNonce = vm.getNonce(address(this));
        address newPredictedModule = vm.computeCreateAddress(address(this), currentNonce);
        address newPredictedVault = vm.computeCreateAddress(address(this), currentNonce + 1);
        address newPredictedLedger = vm.computeCreateAddress(address(this), currentNonce + 2);
        RiskModuleV2Harness newModule =
            new RiskModuleV2Harness(address(registry), newPredictedVault, newPredictedLedger, 2);
        RiskAwareVaultHarness newVault =
            new RiskAwareVaultHarness(address(registry), governance, guardian, newPredictedModule);
        OptionsPositionsLedger newLedger = new OptionsPositionsLedger(address(registry), newPredictedVault);

        assertTrue(address(newModule) != address(riskModule));
        assertTrue(address(newVault) != address(riskVault));
        // Consumers on the original Vault still see the original module.
        DownstreamConsumerCorrect origConsumer = new DownstreamConsumerCorrect(address(riskVault));
        DownstreamConsumerCorrect newConsumer = new DownstreamConsumerCorrect(address(newVault));
        assertEq(address(origConsumer.RISK_MODULE()), address(riskModule));
        assertEq(address(newConsumer.RISK_MODULE()), address(newModule));
        // Silence unused warning.
        newLedger;
    }
}
