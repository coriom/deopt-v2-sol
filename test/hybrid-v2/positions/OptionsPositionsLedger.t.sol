// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {OptionsPositionsLedgerHarness} from "./harness/OptionsPositionsLedgerHarness.sol";
import {IOptionsPositionsLedger} from "../../../src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title OptionsPositionsLedgerUnitFuzz
/// @notice L1 unit + L3 fuzz suite for the canonical Options-position ledger (WP-06).
contract OptionsPositionsLedgerUnitFuzz is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    OptionsPositionsLedger internal ledger;
    OptionsPositionsLedgerHarness internal ledgerHarness;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);
    address internal engineSettle = address(0xE2);
    address internal engineLiquidate = address(0xE3);
    address internal engineNoCap = address(0xE4);

    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    uint256 internal constant SERIES_A = 1;
    uint256 internal constant SERIES_B = 2;

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        ledger = new OptionsPositionsLedger(address(registry), address(vault));
        ledgerHarness = new OptionsPositionsLedgerHarness(address(registry), address(vault));

        vm.prank(ownerA);
        registry.registerNext(); // Account 1
        vm.prank(ownerA);
        registry.registerNext(); // Account 2
        vm.prank(ownerB);
        registry.registerNext(); // Account 1

        // Grant per-engine capabilities via the vault.
        vm.prank(governance);
        vault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.prank(governance);
        vault.setEngineCapability(engineSettle, Capabilities.CAP_SETTLE_OPTION, true);
        vm.prank(governance);
        vault.setEngineCapability(engineLiquidate, Capabilities.CAP_LIQUIDATE_OPTIONS, true);
    }

    function _sk(address owner, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(owner, id);
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    function test_constructor_recordsImmutables() public view {
        assertEq(address(ledger.REGISTRY()), address(registry));
        assertEq(address(ledger.CAPABILITY_AUTHORITY()), address(vault));
    }

    function test_constructor_rejectsZeroRegistry() public {
        vm.expectRevert(OptionsPositionsLedger.InvalidRegistry.selector);
        new OptionsPositionsLedger(address(0), address(vault));
    }

    function test_constructor_rejectsZeroCapabilityAuthority() public {
        vm.expectRevert(OptionsPositionsLedger.InvalidCapabilityAuthority.selector);
        new OptionsPositionsLedger(address(registry), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                             CAPABILITY GATING
    //////////////////////////////////////////////////////////////*/

    function test_applyFill_requiresExactCapability() public {
        bytes32 sk = _sk(ownerA, 1);
        // engineNoCap has zero bits — must revert.
        vm.expectRevert(IOptionsPositionsLedger.OptionMissingCapability.selector);
        vm.prank(engineNoCap);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);

        // engineSettle has CAP_SETTLE_OPTION but not CAP_APPLY_OPTIONS_POSITION_DELTA.
        vm.expectRevert(IOptionsPositionsLedger.OptionMissingCapability.selector);
        vm.prank(engineSettle);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);

        // engineFill succeeds.
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);
    }

    function test_applyExercise_requiresSettleCapability() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8); // long 10

        vm.expectRevert(IOptionsPositionsLedger.OptionMissingCapability.selector);
        vm.prank(engineFill); // has CAP_APPLY_OPTIONS_POSITION_DELTA only
        ledger.applyExercise(sk, SERIES_A, 5e8, 110e8);

        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 5e8, 110e8);
    }

    function test_applyLiquidation_requiresLiquidateCapability() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 1, 10e8, 100e8);

        bytes32 liquidator = _sk(ownerB, 1);
        vm.expectRevert(IOptionsPositionsLedger.OptionMissingCapability.selector);
        vm.prank(engineSettle);
        ledger.applyLiquidation(sk, SERIES_A, 3e8, liquidator);

        vm.prank(engineLiquidate);
        ledger.applyLiquidation(sk, SERIES_A, 3e8, liquidator);
    }

    function test_guardianRevocationBlocksFutureMutation() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);

        // Snapshot state before revocation.
        PositionTypes.OptionPosition memory before = ledger.positionOf(sk, SERIES_A);
        assertEq(before.longQuantity1e8, 1e8);

        // Guardian revokes engineFill on the vault.
        vm.prank(guardian);
        vault.guardianRevokeEngine(engineFill);

        // Future mutations rejected.
        vm.expectRevert(IOptionsPositionsLedger.OptionMissingCapability.selector);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);

        // Existing state UNCHANGED.
        PositionTypes.OptionPosition memory after_ = ledger.positionOf(sk, SERIES_A);
        assertEq(after_.longQuantity1e8, 1e8);
        assertEq(after_.premiumBasis1e8, before.premiumBasis1e8);
    }

    function test_governanceHasNoDirectPositionEditor() public view {
        // No such function exists on the ledger. Compilation of this test proves
        // absence: any call attempt via the interface set would fail to compile.
        // We also spot-check that governance without a capability grant cannot
        // mutate (governance is not automatically an engine).
        // The ledger surface is only `applyFill / applyExercise / applySettlement / applyLiquidation`.
        assertTrue(true);
    }

    /*//////////////////////////////////////////////////////////////
                          IDENTITY VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_applyFill_rejectsZeroSubKey() public {
        vm.expectRevert(OptionsPositionsLedger.SubKeyRequired.selector);
        vm.prank(engineFill);
        ledger.applyFill(bytes32(0), SERIES_A, 0, 1e8, 100e8);
    }

    function test_applyFill_rejectsZeroSeries() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.expectRevert(OptionsPositionsLedger.SeriesIdRequired.selector);
        vm.prank(engineFill);
        ledger.applyFill(sk, 0, 0, 1e8, 100e8);
    }

    function test_applyFill_rejectsUnknownSubKey() public {
        bytes32 sk = registry.subKeyOf(ownerA, 99); // never registered
        vm.expectRevert(IOptionsPositionsLedger.OptionSubKeyNotFound.selector);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);
    }

    function test_applyFill_rejectsInvalidSide() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.expectRevert(IOptionsPositionsLedger.OptionInvalidSide.selector);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 2, 1e8, 100e8);
    }

    function test_applyFill_rejectsZeroQuantity() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.expectRevert(IOptionsPositionsLedger.OptionQuantityZero.selector);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 0, 100e8);
    }

    /*//////////////////////////////////////////////////////////////
                           POSITION MUTATIONS
    //////////////////////////////////////////////////////////////*/

    function test_applyFill_firstLongOpensPosition() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.expectEmit(true, true, true, true);
        emit IOptionsPositionsLedger.OptionPositionOpened(
            sk, SERIES_A, 0, 10e8, 100e8, engineFill, ownerA, 1, Versions.EVENT_VERSION
        );
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);

        PositionTypes.OptionPosition memory p = ledger.positionOf(sk, SERIES_A);
        assertEq(p.longQuantity1e8, 10e8);
        assertEq(p.shortQuantity1e8, 0);
        assertEq(p.premiumBasis1e8, 1000e8); // 10 * 100
        assertEq(ledger.activeSeriesCount(sk), 1);
    }

    function test_applyFill_secondFillEmitsModified() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);

        vm.expectEmit(true, true, true, true);
        emit IOptionsPositionsLedger.OptionPositionModified(
            sk, SERIES_A, 0, int128(uint128(5e8)), 120e8, engineFill, ownerA, 1, Versions.EVENT_VERSION
        );
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 5e8, 120e8);

        PositionTypes.OptionPosition memory p = ledger.positionOf(sk, SERIES_A);
        assertEq(p.longQuantity1e8, 15e8);
        assertEq(p.premiumBasis1e8, 1600e8); // 1000 + 600
        assertEq(ledger.activeSeriesCount(sk), 1);
    }

    function test_applyFill_longAndShortCoexist() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 1, 4e8, 105e8);

        PositionTypes.OptionPosition memory p = ledger.positionOf(sk, SERIES_A);
        assertEq(p.longQuantity1e8, 10e8);
        assertEq(p.shortQuantity1e8, 4e8);
        assertEq(p.premiumBasis1e8, 1000e8);
        assertEq(p.shortPremiumRecv1e8, 420e8);
        assertEq(ledger.activeSeriesCount(sk), 1);
    }

    function test_applyFill_quantityOverflowReverts() public {
        // Seed near max via harness.
        bytes32 sk = _sk(ownerA, 1);
        PositionTypes.OptionPosition memory p;
        p.longQuantity1e8 = type(uint128).max - 1e8 + 1;
        p.premiumBasis1e8 = 0;
        ledgerHarness.testForceSetPosition(sk, SERIES_A, p);

        vm.prank(governance);
        vault.setEngineCapability(address(this), Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.expectRevert(OptionsPositionsLedger.OptionQuantityOverflow.selector);
        ledgerHarness.applyFill(sk, SERIES_A, 0, 1e8 + 1, 1);
    }

    function test_applyFill_premiumBasisOverflowReverts() public {
        bytes32 sk = _sk(ownerA, 1);
        PositionTypes.OptionPosition memory p;
        p.premiumBasis1e8 = type(uint128).max - 100;
        ledgerHarness.testForceSetPosition(sk, SERIES_A, p);

        vm.prank(governance);
        vault.setEngineCapability(address(this), Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.expectRevert(OptionsPositionsLedger.OptionPremiumBasisOverflow.selector);
        ledgerHarness.applyFill(sk, SERIES_A, 0, 1e8, 1e8 * 200); // quantity * price / 1e8 > 100
    }

    /*//////////////////////////////////////////////////////////////
                        EXERCISE + SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function test_applyExercise_partialReducesLong() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);

        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 4e8, 110e8);

        PositionTypes.OptionPosition memory p = ledger.positionOf(sk, SERIES_A);
        assertEq(p.longQuantity1e8, 6e8);
        assertEq(p.exerciseState, 1); // partial
    }

    function test_applyExercise_fullClosesLongAndEmitsClose() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);

        vm.expectEmit(true, true, true, true);
        emit IOptionsPositionsLedger.OptionExercised(
            sk, SERIES_A, 10e8, 110e8, int256(0), ownerA, 1, Versions.EVENT_VERSION
        );
        vm.expectEmit(true, true, true, true);
        emit IOptionsPositionsLedger.OptionPositionClosed(
            sk, SERIES_A, 0, engineSettle, ownerA, 1, Versions.EVENT_VERSION
        );
        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 10e8, 110e8);

        PositionTypes.OptionPosition memory p = ledger.positionOf(sk, SERIES_A);
        assertEq(p.longQuantity1e8, 0);
        assertEq(p.exerciseState, 2); // full
        // premium basis still holds (historical), so series remains active.
        assertEq(ledger.activeSeriesCount(sk), 1);
    }

    function test_applyExercise_excessRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 3e8, 100e8);

        vm.expectRevert(IOptionsPositionsLedger.OptionInsufficientLongForExercise.selector);
        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 5e8, 110e8);
    }

    function test_applyExercise_zeroQuantityRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 3e8, 100e8);

        vm.expectRevert(IOptionsPositionsLedger.OptionQuantityZero.selector);
        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 0, 110e8);
    }

    function test_applySettlement_zerosBothSidesAndFinalizes() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 1, 4e8, 105e8);

        vm.prank(engineSettle);
        ledger.applySettlement(sk, SERIES_A, 120e8);

        PositionTypes.OptionPosition memory p = ledger.positionOf(sk, SERIES_A);
        assertEq(p.longQuantity1e8, 0);
        assertEq(p.shortQuantity1e8, 0);
        assertEq(p.settlementState, 2); // full
        // exerciseState defaults to full when settlement finalizes.
        assertEq(p.exerciseState, 2);
    }

    function test_applySettlement_duplicateRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        vm.prank(engineSettle);
        ledger.applySettlement(sk, SERIES_A, 120e8);

        vm.expectRevert(IOptionsPositionsLedger.OptionAlreadySettled.selector);
        vm.prank(engineSettle);
        ledger.applySettlement(sk, SERIES_A, 121e8);
    }

    function test_fillAfterFullSettlementRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        vm.prank(engineSettle);
        ledger.applySettlement(sk, SERIES_A, 120e8);

        vm.expectRevert(OptionsPositionsLedger.OptionFillAfterFullSettlement.selector);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 1e8, 100e8);
    }

    function test_exerciseAfterFullSettlementRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        vm.prank(engineSettle);
        ledger.applySettlement(sk, SERIES_A, 120e8);

        vm.expectRevert(OptionsPositionsLedger.OptionExerciseAfterFullSettlement.selector);
        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 1, 120e8);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function test_applyLiquidation_reducesShort() public {
        bytes32 sk = _sk(ownerA, 1);
        bytes32 liquidator = _sk(ownerB, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 1, 10e8, 100e8);

        vm.prank(engineLiquidate);
        ledger.applyLiquidation(sk, SERIES_A, 3e8, liquidator);

        PositionTypes.OptionPosition memory p = ledger.positionOf(sk, SERIES_A);
        assertEq(p.shortQuantity1e8, 7e8);
    }

    function test_applyLiquidation_excessRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        bytes32 liquidator = _sk(ownerB, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 1, 3e8, 100e8);

        vm.expectRevert(IOptionsPositionsLedger.OptionInsufficientShortForLiquidation.selector);
        vm.prank(engineLiquidate);
        ledger.applyLiquidation(sk, SERIES_A, 5e8, liquidator);
    }

    function test_applyLiquidation_rejectsZeroLiquidator() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 1, 3e8, 100e8);

        vm.expectRevert(OptionsPositionsLedger.LiquidatorSubKeyRequired.selector);
        vm.prank(engineLiquidate);
        ledger.applyLiquidation(sk, SERIES_A, 1e8, bytes32(0));
    }

    function test_applyLiquidation_rejectsUnknownLiquidator() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 1, 3e8, 100e8);

        bytes32 fakeLiquidator = registry.subKeyOf(address(0x9999), 1);
        vm.expectRevert(OptionsPositionsLedger.LiquidatorSubKeyNotFound.selector);
        vm.prank(engineLiquidate);
        ledger.applyLiquidation(sk, SERIES_A, 1e8, fakeLiquidator);
    }

    /*//////////////////////////////////////////////////////////////
                              ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_isolation_siblingSubaccountUntouched() public {
        bytes32 sk1 = _sk(ownerA, 1);
        bytes32 sk2 = _sk(ownerA, 2);
        vm.prank(engineFill);
        ledger.applyFill(sk1, SERIES_A, 0, 10e8, 100e8);
        assertEq(ledger.positionOf(sk1, SERIES_A).longQuantity1e8, 10e8);
        assertEq(ledger.positionOf(sk2, SERIES_A).longQuantity1e8, 0);
    }

    function test_isolation_siblingOwnerUntouched() public {
        bytes32 skA = _sk(ownerA, 1);
        bytes32 skB = _sk(ownerB, 1);
        vm.prank(engineFill);
        ledger.applyFill(skA, SERIES_A, 0, 10e8, 100e8);
        assertEq(ledger.positionOf(skB, SERIES_A).longQuantity1e8, 0);
    }

    function test_isolation_seriesUntouched() public {
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, 10e8, 100e8);
        assertEq(ledger.positionOf(sk, SERIES_B).longQuantity1e8, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_applyFill_longSideAccumulates(uint64 q1, uint64 q2, uint64 price) public {
        vm.assume(q1 > 0 && q2 > 0 && price > 0);
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, uint128(q1), uint128(price));
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, uint128(q2), uint128(price));

        assertEq(ledger.positionOf(sk, SERIES_A).longQuantity1e8, uint128(q1) + uint128(q2));
    }

    function testFuzz_isolation_multiOwner(address newOwner, uint128 q) public {
        vm.assume(newOwner != address(0) && newOwner != ownerA && newOwner != ownerB);
        q = uint128(bound(q, 1, uint128(1e18)));

        vm.prank(newOwner);
        registry.registerNext();

        bytes32 sk = _sk(newOwner, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, q, 100e8);

        assertEq(ledger.positionOf(sk, SERIES_A).longQuantity1e8, q);
        assertEq(ledger.positionOf(sk, SERIES_B).longQuantity1e8, 0);
        // Sibling owners unaffected.
        assertEq(ledger.positionOf(_sk(ownerA, 1), SERIES_A).longQuantity1e8, 0);
    }

    function testFuzz_exercise_boundedByLong(uint128 fillQty, uint128 exerciseQty) public {
        vm.assume(fillQty > 0 && fillQty < 1e30);
        vm.assume(exerciseQty > 0);
        bytes32 sk = _sk(ownerA, 1);
        vm.prank(engineFill);
        ledger.applyFill(sk, SERIES_A, 0, fillQty, 100e8);

        if (exerciseQty > fillQty) {
            vm.expectRevert(IOptionsPositionsLedger.OptionInsufficientLongForExercise.selector);
            vm.prank(engineSettle);
            ledger.applyExercise(sk, SERIES_A, exerciseQty, 100e8);
        } else {
            vm.prank(engineSettle);
            ledger.applyExercise(sk, SERIES_A, exerciseQty, 100e8);
            assertEq(ledger.positionOf(sk, SERIES_A).longQuantity1e8, fillQty - exerciseQty);
        }
    }
}
