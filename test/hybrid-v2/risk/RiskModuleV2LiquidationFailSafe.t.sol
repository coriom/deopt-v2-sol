// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RiskModuleV2} from "../../../src/hybrid-v2/risk/RiskModuleV2.sol";
import {RiskModuleV2Harness} from "./harness/RiskModuleV2Harness.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {MockERC20} from "../vault/mocks/MockERC20.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

/// @title RiskModuleV2LiquidationFailSafe
/// @notice WP-07 boundedness + liquidation-safety patch — proves that
///         `liquidationStatus` cannot authorize seizure under indeterminate
///         risk inputs.
///
/// Prior (unsafe) behavior: `liquidationStatus` silently returned
///   `ELIGIBLE_FOR_LIQUIDATION` whenever any hook failed (stale provider,
///   unknown subKey, zero subKey). A consumer that trusted the enum would
///   have interpreted the affirmative value as authorization to seize
///   collateral. Spec 06 explicitly forbids this: "Liquidation triggers
///   MUST NOT trigger if `liquidationStatus` cannot be computed."
///
/// Current (fail-safe) behavior: any indeterminate state reverts. The
/// frozen 3-value enum has no INDETERMINATE state, so revert is the only
/// safe ABI-preserving surface. Consumers MUST wrap the call in try/catch.
///
/// Coverage:
///   - RISK-LIQ-I1: missing / stale / unsupported / reverting risk input
///     never produces affirmative liquidation eligibility.
///   - RISK-LIQ-I2: affirmative eligibility only when required canonical
///     inputs are complete (positive direction).
contract RiskModuleV2LiquidationFailSafe is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    OptionsPositionsLedger internal ledger;
    RiskModuleV2Harness internal module;
    MockERC20 internal token;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);
    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        uint256 currentNonce = vm.getNonce(address(this));
        address predictedModule = vm.computeCreateAddress(address(this), currentNonce);
        address predictedVault = vm.computeCreateAddress(address(this), currentNonce + 1);
        address predictedLedger = vm.computeCreateAddress(address(this), currentNonce + 2);
        module = new RiskModuleV2Harness(address(registry), predictedVault, predictedLedger, 1);
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        ledger = new OptionsPositionsLedger(address(registry), predictedVault);
        require(address(module) == predictedModule, "module addr mismatch");
        require(address(vault) == predictedVault, "vault addr mismatch");
        require(address(ledger) == predictedLedger, "ledger addr mismatch");

        token = new MockERC20("Mock", "MCK", 18);
        vm.prank(governance);
        vault.addSupportedToken(address(token));
        vm.prank(governance);
        vault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        module.setTokenPrice1e8(address(token), 1e8);

        vm.prank(ownerA);
        registry.registerNext();
        vm.prank(ownerB);
        registry.registerNext();
    }

    function _sk(address o, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(o, id);
    }

    /*//////////////////////////////////////////////////////////////
              RISK-LIQ-I1 — indeterminate NEVER authorizes
    //////////////////////////////////////////////////////////////*/

    function test_revertsOnZeroSubKey() public {
        vm.expectRevert(RiskModuleV2.SubKeyRequired.selector);
        module.liquidationStatus(bytes32(0));
    }

    function test_revertsOnUnknownSubaccount() public {
        bytes32 fake = registry.subKeyOf(address(0xDEADBEEF), 99);
        vm.expectRevert(abi.encodeWithSelector(RiskModuleV2.UnknownSubaccount.selector, fake));
        module.liquidationStatus(fake);
    }

    function test_revertsOnGlobalStaleProvider() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 100e18);
        module.setProviderStale(true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(sk);
    }

    function test_revertsOnPerSubKeyStale() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 100e18);
        module.setSubKeyStale(sk, true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(sk);
    }

    function test_revertsWhenRequirementHookFails() public {
        // Setup: the RiskModuleV2Harness returns ok=false on either compute
        // hook if `providerStale || subKeyStale[sk]`. There's no separate
        // knob for "requirement-only fails" vs "available-only fails", so
        // this test exercises the combined path via `providerStale`. The
        // symmetric per-hook test would require a second harness variant;
        // documented as follow-up if needed.
        bytes32 sk = _sk(ownerA, 1);
        module.setProviderStale(true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(sk);
    }

    function test_healthyAccountReturnsHealthy() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 200e18);
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.HEALTHY));
    }

    function test_equalAvailableAndRequiredReturnsHealthy() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 100e18);
        // available >= required → HEALTHY (spec 06 comparison rule).
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.HEALTHY));
    }

    function test_shortfallReturnsEligible() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 99e18);
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION));
    }

    function test_zeroRequirementReturnsHealthy() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 0);
        module.setAvailableMargin(sk, 0);
        // 0 available >= 0 required → HEALTHY.
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.HEALTHY));
    }

    /*//////////////////////////////////////////////////////////////
                    Sibling / owner isolation
    //////////////////////////////////////////////////////////////*/

    function test_siblingSubKeyDoesNotAffectStatus() public {
        // Setting per-subKey stale on skB must not affect skA's status.
        bytes32 skA = _sk(ownerA, 1);
        bytes32 skB = _sk(ownerB, 1);
        module.setRequiredMargin(skA, 100e18);
        module.setAvailableMargin(skA, 200e18);
        module.setSubKeyStale(skB, true);

        assertEq(uint8(module.liquidationStatus(skA)), uint8(LiquidationStatus.HEALTHY));
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(skB);
    }

    /*//////////////////////////////////////////////////////////////
              RISK-LIQ-I1 — read-only + no state mutation
    //////////////////////////////////////////////////////////////*/

    function test_classificationDoesNotMutateCanonicalState() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 200e18);
        // Snapshot canonical state.
        address ownerBefore = registry.ownerOf(sk);
        uint32 idBefore = registry.subaccountIdOf(sk);
        uint256 vaultBalBefore = vault.balanceOf(sk, address(token));
        uint32 activeCountBefore = ledger.activeSeriesCount(sk);

        // Classification call.
        module.liquidationStatus(sk);

        assertEq(registry.ownerOf(sk), ownerBefore);
        assertEq(registry.subaccountIdOf(sk), idBefore);
        assertEq(vault.balanceOf(sk, address(token)), vaultBalBefore);
        assertEq(ledger.activeSeriesCount(sk), activeCountBefore);
    }

    function test_classificationRevertDoesNotMutateCanonicalState() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 100e18);
        module.setAvailableMargin(sk, 200e18);
        module.setProviderStale(true);

        address ownerBefore = registry.ownerOf(sk);
        uint256 vaultBalBefore = vault.balanceOf(sk, address(token));

        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(sk);

        assertEq(registry.ownerOf(sk), ownerBefore);
        assertEq(vault.balanceOf(sk, address(token)), vaultBalBefore);
    }

    /*//////////////////////////////////////////////////////////////
              RISK-LIQ-I2 — affirmative only when complete
    //////////////////////////////////////////////////////////////*/

    function test_affirmativeEligibleRequiresBothHooksSucceeded() public {
        // Positive direction: only when BOTH hooks succeed AND
        // available < required does the module return ELIGIBLE_FOR_LIQUIDATION.
        bytes32 sk = _sk(ownerA, 1);
        module.setRequiredMargin(sk, 200e18);
        module.setAvailableMargin(sk, 100e18);
        assertEq(uint8(module.liquidationStatus(sk)), uint8(LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION));

        // Now stale one hook — status changes from ELIGIBLE to REVERT.
        module.setSubKeyStale(sk, true);
        vm.expectRevert(IRiskModule.RiskModuleUnavailable.selector);
        module.liquidationStatus(sk);
    }

    /*//////////////////////////////////////////////////////////////
              try/catch pattern documented for WP-08 consumers
    //////////////////////////////////////////////////////////////*/

    /// @notice Documents the required consumer pattern: any downstream
    ///         liquidation execution MUST catch the revert and treat it as
    ///         "no authority". WP-08 tests will re-assert this against the
    ///         real MarginEngine.
    function test_documentsConsumerTryCatchPattern() public {
        bytes32 sk = _sk(ownerA, 1);
        module.setProviderStale(true);
        // A "consumer" here is a caller that reads liquidationStatus and
        // rejects on any revert. Encoded inline as the try/catch idiom.
        LiquidationStatus status = LiquidationStatus.HEALTHY;
        bool authorized = false;
        try module.liquidationStatus(sk) returns (LiquidationStatus s) {
            status = s;
            authorized = (s == LiquidationStatus.ELIGIBLE_FOR_LIQUIDATION);
        } catch {
            // No authorization on revert.
            authorized = false;
        }
        assertFalse(authorized, "revert MUST NOT authorize liquidation");
    }
}
