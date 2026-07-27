// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RiskModuleV2} from "../../../src/hybrid-v2/risk/RiskModuleV2.sol";
import {RiskModuleV2Harness} from "./harness/RiskModuleV2Harness.sol";
import {RiskModuleV2Handler} from "./handlers/RiskModuleV2Handler.sol";
import {RiskAwareVaultHarness} from "./harness/RiskAwareVaultHarness.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";

/// @title RiskModuleV2LiquidationFailSafeInvariants
/// @notice WP-07 boundedness + liquidation-safety patch — invariant coverage
///         for `RISK-LIQ-I1` + `RISK-LIQ-I2`.
///
/// Invariants:
///   RISK-LIQ-I1: missing / stale / unsupported / incomplete / reverting risk
///                input never produces affirmative liquidation eligibility.
///                We assert this by attempting every tracked subKey's
///                `liquidationStatus` under an arbitrary handler-generated
///                stale-toggle sequence and asserting: if the call reverts,
///                no affirmative status was returned; if it returns HEALTHY
///                / WARN, it is by definition non-affirmative; only
///                ELIGIBLE_FOR_LIQUIDATION requires a proof, and that proof
///                is: both hooks succeeded AND available < required.
///
///   RISK-LIQ-I2: affirmative eligibility only when required canonical
///                inputs are complete. Encoded as: `liquidationStatus`
///                returned `ELIGIBLE_FOR_LIQUIDATION` implies both
///                `_computeMarginRequirement` and `_computeAvailableMargin`
///                returned `ok=true` for this subKey — proven by the
///                contract's own control flow (any hook `ok=false` reverts
///                before the affirmative branch).
contract RiskModuleV2LiquidationFailSafeInvariants is Test {
    SubaccountRegistry internal registry;
    RiskAwareVaultHarness internal vault;
    OptionsPositionsLedger internal ledger;
    RiskModuleV2Harness internal module;
    MockERC20 internal token;
    RiskModuleV2Handler internal handler;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);

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

        handler = new RiskModuleV2Handler(module, vault, ledger, registry, token, governance, guardian, engineFill);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
        RISK-LIQ-I1 — indeterminate never authorizes seizure
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_LIQ_I1_indeterminateNeverAuthorizes() public view {
        // For every tracked subKey: if any hook is currently indeterminate
        // (providerStale OR subKeyStale), `liquidationStatus` MUST revert.
        // The frozen 3-value enum has no INDETERMINATE state; any returned
        // value would be a false-affirmative or false-safe.
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            bool stale = module.providerStale() || module.subKeyStale(sk);
            if (!stale) continue;
            try module.liquidationStatus(sk) returns (LiquidationStatus s) {
                s;
                revert("indeterminate input authorized a status");
            } catch {
                // expected
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
        RISK-LIQ-I2 — affirmative ELIGIBLE requires complete inputs
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_LIQ_I2_affirmativeRequiresCompleteInputs() public view {
        // For every tracked subKey: whenever `liquidationStatus` returned
        // `ELIGIBLE_FOR_LIQUIDATION`, both hooks must have succeeded (encoded
        // as: providerStale == false AND subKeyStale[sk] == false) AND the
        // ghost mirror must satisfy required > available.
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            bool stale = module.providerStale() || module.subKeyStale(sk);
            if (stale) continue; // covered by I1

            LiquidationStatus s;
            try module.liquidationStatus(sk) returns (LiquidationStatus retS) {
                s = retS;
            } catch {
                // With hooks non-stale, `liquidationStatus` MUST NOT revert.
                revert("liquidationStatus reverted with complete inputs");
            }
            if (s != LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION) continue;
            // ELIGIBLE requires required > available in the harness's ghost
            // arithmetic.
            uint256 req = handler.ghostRequired(sk);
            uint256 avail = handler.ghostAvailable(sk);
            assertGt(req, avail, "ELIGIBLE returned without required > available");
        }
    }

    /*//////////////////////////////////////////////////////////////
        Consumer-side try/catch pattern always authorizes correctly
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_LIQ_consumerTryCatchNeverAuthorizesOnRevert() public view {
        // The documented WP-08 consumer pattern (try/catch, treat any
        // revert as "no authority") NEVER authorizes on a revert.
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            bool authorized = false;
            try module.liquidationStatus(sk) returns (LiquidationStatus s) {
                authorized = (s == LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION);
            } catch {
                authorized = false;
            }
            // The invariant is: `authorized == true` ⇒ hooks were non-stale
            // (else I1 would have caught the revert path). Assert the
            // contrapositive: any stale-hook subKey MUST NOT be authorized.
            bool stale = module.providerStale() || module.subKeyStale(sk);
            if (stale) assertFalse(authorized, "consumer authorized despite stale hook");
        }
    }
}
