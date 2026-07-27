// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RiskModuleV2Handler} from "./handlers/RiskModuleV2Handler.sol";
import {RiskModuleV2Harness} from "./harness/RiskModuleV2Harness.sol";
import {RiskAwareVaultHarness} from "./harness/RiskAwareVaultHarness.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title RiskModuleV2Invariants
/// @notice RISK-I1..RISK-I16 invariant suite for the WP-07 RiskModule.
///
/// Budget: 64 runs × 64 depth (~4096 handler calls per invariant).
contract RiskModuleV2Invariants is Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    OptionsPositionsLedger internal ledger;
    RiskModuleV2Harness internal module;
    MockERC20 internal token;
    RiskModuleV2Handler internal handler;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);

    // Snapshot of Vault + Registry state that RiskModule mutations MUST NOT alter.
    uint256 internal baselineCap;

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        uint256 currentNonce = vm.getNonce(address(this));
        address predictedModule = vm.computeCreateAddress(address(this), currentNonce);
        address predictedVault = vm.computeCreateAddress(address(this), currentNonce + 1);
        address predictedLedger = vm.computeCreateAddress(address(this), currentNonce + 2);

        module = new RiskModuleV2Harness(address(registry), predictedVault, predictedLedger, 1);
        vault = new RiskAwareVaultHarness(address(registry), governance, guardian, predictedModule);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        token = new MockERC20("Mock", "MCK", 18);

        vm.prank(governance);
        vault.addSupportedToken(address(token));
        module.setTokenPrice1e8(address(token), 1e8);

        vm.prank(governance);
        vault.setEngineCapability(engineFill, Capabilities.CAP_LOCK_COLLATERAL, true);

        baselineCap = vault.engineCapabilityBits(engineFill);

        handler = new RiskModuleV2Handler(module, vault, ledger, registry, token, governance, guardian, engineFill);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                RISK-I1: no canonical state ownership
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I1_moduleOwnsNoCanonicalState() public view {
        // The Vault + Registry + Ledger references stay constant regardless of
        // handler activity. Vault capability bits for engineFill remain at
        // baseline (module has no path to mutate them).
        assertEq(vault.engineCapabilityBits(engineFill), baselineCap);
        assertEq(address(module.REGISTRY()), address(registry));
        assertEq(address(module.VAULT()), address(vault));
        assertEq(address(module.OPTIONS_LEDGER()), address(ledger));
    }

    /*//////////////////////////////////////////////////////////////
              RISK-I2 + I3: collateral / position isolation
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I2_I3_subaccountIsolationHolds() public view {
        // Verify that Vault balances the handler credited on each subKey stay
        // per-subKey (handler mirror should match Vault reading).
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            assertEq(vault.balanceOf(sk, address(token)), handler.ghostVaultBalance(sk), "vault balance ghost drift");
            assertEq(vault.lockedOf(sk, address(token)), handler.ghostVaultLocked(sk), "vault locked ghost drift");
        }
    }

    /*//////////////////////////////////////////////////////////////
        RISK-I4 + I5: incomplete / stale inputs fail closed
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I4_I5_stateReflectsProviderStale() public view {
        // When the provider is globally stale, every module view that is
        // fail-closed on the safety-negative side returns the safety-negative
        // decision.
        if (!module.providerStale()) return;
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            assertFalse(module.marginHealthy(sk));
            assertFalse(module.withdrawalAllowed(sk, address(token), 1));
            assertFalse(module.transferAllowed(sk, address(token), 1));
            assertTrue(module.liquidationStatus(sk) == LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION);
        }
    }

    /*//////////////////////////////////////////////////////////////
                RISK-I6: non-negative margin
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I6_nonNegative() public view {
        // uint256 values cannot be negative; assert as a witness that no
        // mysterious wrap-around happened. Also cross-check ghost mirror.
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            assertLe(module.requiredMarginOf(sk), type(uint256).max);
            assertEq(module.requiredMarginOf(sk), handler.ghostRequired(sk));
            assertEq(module.availableMarginOf(sk), handler.ghostAvailable(sk));
        }
    }

    /*//////////////////////////////////////////////////////////////
              RISK-I7 + I8: withdrawal safety semantics
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I7_I8_withdrawalReflectsRule() public view {
        if (module.providerStale()) return;
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            uint256 required = handler.ghostRequired(sk);
            uint256 available = handler.ghostAvailable(sk);
            uint256 tokenAvail = vault.availableOf(sk, address(token));
            // Pick a bounded amount to check the semantic.
            uint256 amount = 1;
            if (tokenAvail == 0) {
                assertFalse(module.withdrawalAllowed(sk, address(token), amount));
                continue;
            }
            if (amount > tokenAvail) {
                assertFalse(module.withdrawalAllowed(sk, address(token), amount));
                continue;
            }
            uint256 delta = (amount * 1e8) / 1e8; // = amount (price = 1e8)
            bool expected = delta <= available && (available - delta) >= required;
            assertEq(module.withdrawalAllowed(sk, address(token), amount), expected);
        }
    }

    /*//////////////////////////////////////////////////////////////
              RISK-I9 + I10: internal-transfer safety
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_I9_I10_transferMirrorsWithdrawal() public view {
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            assertEq(module.withdrawalAllowed(sk, address(token), 1), module.transferAllowed(sk, address(token), 1));
        }
    }

    /*//////////////////////////////////////////////////////////////
              RISK-I11: module compatibility mismatch fails closed
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 32
    function invariant_I11_compatibilityStable() public view {
        // Module compatibility check is a pure function of immutable state.
        assertTrue(module.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION));
        assertFalse(module.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION + 1));
    }

    /*//////////////////////////////////////////////////////////////
          RISK-I12: replacement never mutates canonical state
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 32
    function invariant_I12_registryVaultLedgerImmutable() public view {
        // Registry + Vault + Ledger reference never changes on the module.
        assertEq(address(module.REGISTRY()), address(registry));
        assertEq(address(module.VAULT()), address(vault));
        assertEq(address(module.OPTIONS_LEDGER()), address(ledger));
    }

    /*//////////////////////////////////////////////////////////////
          RISK-I13: cross-series offsets only when approved
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 32
    function invariant_I13_noHiddenCrossSeriesOffsets() public view {
        // The abstract module exposes no offset mechanism. The harness sums
        // required directly (no netting).
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            assertEq(module.requiredMarginOf(sk), handler.ghostRequired(sk));
        }
    }

    /*//////////////////////////////////////////////////////////////
          RISK-I14: finalized position treatment (deferred)
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 32
    function invariant_I14_lifecyclePreserved() public view {
        // WP-06 owns lifecycle transitions. The RiskModule harness does not
        // alter ledger state; ledger positions accessible to the module remain
        // as set. Trivial witness.
        assertEq(address(module.OPTIONS_LEDGER()), address(ledger));
    }

    /*//////////////////////////////////////////////////////////////
          RISK-I15: deterministic under identical inputs
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 32
    function invariant_I15_deterministic() public view {
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            // Two calls with identical state return identical results.
            bool a = module.marginHealthy(sk);
            bool b = module.marginHealthy(sk);
            assertEq(a, b);
        }
    }

    /*//////////////////////////////////////////////////////////////
          RISK-I16: perps never contribute to Options V1 module
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 32
    function invariant_I16_perpsDisabled() public view {
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            (, bool perpsEnabled) = module.productsEnabled(sk);
            assertFalse(perpsEnabled);
        }
    }
}
