// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {IOptionsPositionsLedger} from "../../../src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";

/// @title OptionsPositionsLedgerActiveSeriesBound
/// @notice `ONCHAIN-SUBACCOUNT-RISK-EXECUTION-BOUNDS-AND-COLLATERAL-UNIVERSE-V1`
///         — unit + fuzz for `MAX_ACTIVE_SERIES_PER_SUBACCOUNT = 32` cap.
contract OptionsPositionsLedgerActiveSeriesBound is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    OptionsPositionsLedger internal ledger;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);
    address internal engineSettle = address(0xE2);
    address internal engineLiquidate = address(0xE3);
    address internal ownerA = address(0xB1);
    address internal ownerB = address(0xB2);

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        ledger = new OptionsPositionsLedger(address(registry), address(vault));

        vm.prank(ownerA);
        registry.registerNext(); // Account 1
        vm.prank(ownerA);
        registry.registerNext(); // Account 2
        vm.prank(ownerB);
        registry.registerNext(); // Account 1

        vm.prank(governance);
        vault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.prank(governance);
        vault.setEngineCapability(engineSettle, Capabilities.CAP_SETTLE_OPTION, true);
        vm.prank(governance);
        vault.setEngineCapability(engineLiquidate, Capabilities.CAP_LIQUIDATE_OPTIONS, true);
    }

    function _sk(address o, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(o, id);
    }

    function _fill(bytes32 sk, uint256 series, uint8 side, uint128 q) internal {
        vm.prank(engineFill);
        ledger.applyFill(sk, series, side, q, 100e8);
    }

    function _openN(bytes32 sk, uint256 startSeries, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            _fill(sk, startSeries + i, 0, 10);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTANT + VIEW
    //////////////////////////////////////////////////////////////*/

    function test_constant_equals32() public view {
        assertEq(uint256(ledger.MAX_ACTIVE_SERIES_PER_SUBACCOUNT()), 32);
    }

    function test_view_maxActiveSeriesPerSubaccountReturns32() public view {
        assertEq(uint256(ledger.maxActiveSeriesPerSubaccount()), 32);
    }

    /*//////////////////////////////////////////////////////////////
                    FIRST + BOUNDARY ACTIVATIONS
    //////////////////////////////////////////////////////////////*/

    function test_firstActiveSeries() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, 1, 0, 10);
        assertEq(ledger.activeSeriesCount(sk), 1);
    }

    function test_thirtySecondActiveSeries() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        assertEq(ledger.activeSeriesCount(sk), 32);
    }

    function test_thirtyThirdActiveSeriesReverts() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionsPositionsLedger.ActiveSeriesLimitExceeded.selector, sk, uint32(32), uint32(32)
            )
        );
        _fill(sk, 33, 0, 10);
    }

    function test_thirtyThirdRevertLeavesCountUnchanged() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        try this._extFill(sk, 33, 0, 10) {
            revert("expected revert");
        } catch {}
        assertEq(ledger.activeSeriesCount(sk), 32);
    }

    function test_thirtyThirdRevertLeavesPositionUnchanged() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        try this._extFill(sk, 33, 0, 10) {
            revert("expected revert");
        } catch {}
        PositionTypes.OptionPosition memory p = ledger.positionOf(sk, 33);
        assertEq(p.longQuantity1e8, 0);
        assertEq(p.shortQuantity1e8, 0);
        assertEq(p.premiumBasis1e8, 0);
        assertEq(p.shortPremiumRecv1e8, 0);
    }

    /// @dev External wrapper so `try/catch` above works from the test.
    function _extFill(bytes32 sk, uint256 series, uint8 side, uint128 q) external {
        _fill(sk, series, side, q);
    }

    /*//////////////////////////////////////////////////////////////
                    MUTATIONS OF ALREADY-ACTIVE SERIES AT CAP
    //////////////////////////////////////////////////////////////*/

    function test_updatingAlreadyActiveAtCapSucceeds() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        // Adding more to series 5 is a mutation of an already active position;
        // does NOT consume another slot.
        _fill(sk, 5, 0, 100);
        assertEq(ledger.activeSeriesCount(sk), 32);
        assertEq(ledger.positionOf(sk, 5).longQuantity1e8, 110);
    }

    function test_shortSideOnExistingLongDoesNotConsumeSlot() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        // Series 5 already has a long. Adding a short to the same series
        // does NOT flip an inactive series active.
        _fill(sk, 5, 1, 3);
        assertEq(ledger.activeSeriesCount(sk), 32);
    }

    /*//////////////////////////////////////////////////////////////
              RISK-REDUCING PATHS AT CAP (RISK-BOUND-I2)
    //////////////////////////////////////////////////////////////*/

    function test_partialExerciseAtCapSucceeds() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        vm.prank(engineSettle);
        ledger.applyExercise(sk, 1, 3, 100e8);
        assertEq(ledger.positionOf(sk, 1).longQuantity1e8, 7);
        assertEq(ledger.activeSeriesCount(sk), 32);
    }

    function test_partialLiquidationReductionAtCapSucceeds() public {
        bytes32 sk = _sk(ownerA, 1);
        bytes32 liq = _sk(ownerB, 1);
        // Fill a short + 31 longs to reach 32.
        _fill(sk, 1, 1, 10);
        for (uint256 i = 2; i <= 32; i++) {
            _fill(sk, i, 0, 10);
        }
        assertEq(ledger.activeSeriesCount(sk), 32);
        vm.prank(engineLiquidate);
        ledger.applyLiquidation(sk, 1, 3, liq);
        assertEq(ledger.positionOf(sk, 1).shortQuantity1e8, 7);
        assertEq(ledger.activeSeriesCount(sk), 32);
    }

    function test_fullSettlementAtCapSucceeds() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        vm.prank(engineSettle);
        ledger.applySettlement(sk, 1, 100e8);
        // Long fill leaves basis > 0; settlement doesn't zero basis, so the
        // row remains counted (per WP-06 semantic). Count stays at 32.
        assertEq(ledger.activeSeriesCount(sk), 32);
        assertEq(ledger.positionOf(sk, 1).settlementState, ledger.STATE_FULL());
    }

    function test_fullyZeroingSeriesDecrementsCount() public {
        bytes32 sk = _sk(ownerA, 1);
        bytes32 liq = _sk(ownerB, 1);
        // Short-only fill with price=0 leaves recv=0 and shortQty>0.
        vm.prank(engineFill);
        ledger.applyFill(sk, 1, 1, 5, 0);
        assertEq(ledger.activeSeriesCount(sk), 1);
        // Use startPrank to survive an intervening view call.
        vm.startPrank(engineLiquidate);
        ledger.applyLiquidation(sk, 1, 5, liq);
        vm.stopPrank();
        // After full liquidation of a short with recv=0 → row all-zero → count 0.
        assertEq(ledger.activeSeriesCount(sk), 0);
    }

    function test_openingNewSeriesAfterFreeingCapacitySucceeds() public {
        bytes32 sk = _sk(ownerA, 1);
        bytes32 liq = _sk(ownerB, 1);
        // Fill series 1 with recv=0 so we can fully zero it later.
        vm.prank(engineFill);
        ledger.applyFill(sk, 1, 1, 5, 0);
        // Fill 31 more to reach 32.
        for (uint256 i = 2; i <= 32; i++) {
            _fill(sk, i, 0, 10);
        }
        assertEq(ledger.activeSeriesCount(sk), 32);
        // 33rd rejected.
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionsPositionsLedger.ActiveSeriesLimitExceeded.selector, sk, uint32(32), uint32(32)
            )
        );
        _fill(sk, 33, 0, 10);
        // Free one slot by liquidating series 1 to zero.
        vm.startPrank(engineLiquidate);
        ledger.applyLiquidation(sk, 1, 5, liq);
        vm.stopPrank();
        assertEq(ledger.activeSeriesCount(sk), 31);
        // Now series 33 can be opened.
        _fill(sk, 33, 0, 10);
        assertEq(ledger.activeSeriesCount(sk), 32);
    }

    /*//////////////////////////////////////////////////////////////
              SIBLING SUBACCOUNT / SIBLING OWNER ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_siblingSubaccountHasIndependentCapacity() public {
        bytes32 sk1 = _sk(ownerA, 1);
        bytes32 sk2 = _sk(ownerA, 2);
        _openN(sk1, 1, 32);
        // sk2 caps out independently.
        _openN(sk2, 1, 32);
        assertEq(ledger.activeSeriesCount(sk1), 32);
        assertEq(ledger.activeSeriesCount(sk2), 32);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionsPositionsLedger.ActiveSeriesLimitExceeded.selector, sk1, uint32(32), uint32(32)
            )
        );
        _fill(sk1, 33, 0, 10);
    }

    function test_siblingOwnerHasIndependentCapacity() public {
        bytes32 skA = _sk(ownerA, 1);
        bytes32 skB = _sk(ownerB, 1);
        _openN(skA, 1, 32);
        _openN(skB, 1, 32);
        assertEq(ledger.activeSeriesCount(skA), 32);
        assertEq(ledger.activeSeriesCount(skB), 32);
    }

    /*//////////////////////////////////////////////////////////////
              INACTIVE-SETTLEMENT DOES NOT DECREMENT COUNT
    //////////////////////////////////////////////////////////////*/

    function test_inactiveSettlementDoesNotDecrementCount() public {
        // This is the pre-existing WP-06 `wasActive` fix: settling a
        // never-touched series does not falsely decrement.
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, 5, 0, 10);
        assertEq(ledger.activeSeriesCount(sk), 1);
        // Settle an untouched series (7) — no-op economically, must not
        // decrement the counter for the ACTUAL active series (5).
        vm.prank(engineSettle);
        ledger.applySettlement(sk, 7, 100e8);
        assertEq(ledger.activeSeriesCount(sk), 1);
    }

    /*//////////////////////////////////////////////////////////////
              VERIFIER REJECTS INPUTS > 32 EARLY
    //////////////////////////////////////////////////////////////*/

    function test_verify_rejectsSuppliedArrayAbove32() public view {
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory arr = new uint256[](33);
        for (uint256 i = 0; i < 33; i++) {
            arr[i] = i + 1;
        }
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    /*//////////////////////////////////////////////////////////////
              COMPLETENESS-REJECTION AT CAP (regressions)
    //////////////////////////////////////////////////////////////*/

    function test_verify_duplicateAtCapRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        uint256[] memory arr = new uint256[](32);
        for (uint256 i = 0; i < 32; i++) {
            arr[i] = i + 1;
        }
        // Introduce a duplicate at position 5.
        arr[5] = arr[4];
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_omittedAtCapRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        uint256[] memory arr = new uint256[](31);
        for (uint256 i = 0; i < 31; i++) {
            arr[i] = i + 1;
        }
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_substitutedAtCapRejected() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        uint256[] memory arr = new uint256[](32);
        for (uint256 i = 0; i < 32; i++) {
            arr[i] = i + 1;
        }
        // Substitute an inactive series id at position 10.
        arr[10] = 999;
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_canonicalAtCapAccepted() public {
        bytes32 sk = _sk(ownerA, 1);
        _openN(sk, 1, 32);
        uint256[] memory arr = new uint256[](32);
        for (uint256 i = 0; i < 32; i++) {
            arr[i] = i + 1;
        }
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_zeroToNonZeroTransitionsBounded(uint8 seed) public {
        bytes32 sk = _sk(ownerA, 1);
        uint256 target = uint256(seed) % 50; // 0..49 attempts
        for (uint256 i = 0; i < target; i++) {
            uint256 sid = i + 1;
            if (ledger.activeSeriesCount(sk) >= 32) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        OptionsPositionsLedger.ActiveSeriesLimitExceeded.selector, sk, uint32(32), uint32(32)
                    )
                );
                vm.prank(engineFill);
                ledger.applyFill(sk, sid, 0, 10, 100e8);
            } else {
                vm.prank(engineFill);
                ledger.applyFill(sk, sid, 0, 10, 100e8);
            }
        }
        assertLe(uint256(ledger.activeSeriesCount(sk)), 32);
    }
}
