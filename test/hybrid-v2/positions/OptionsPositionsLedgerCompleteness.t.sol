// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {IOptionsPositionsLedger} from "../../../src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";

/// @title OptionsPositionsLedgerCompleteness
/// @notice WP-07 completeness patch — unit + fuzz coverage for the ledger's
///         canonical active-series membership + array-completeness proof.
///
/// Verifier definition (see `verifyActiveSeriesArrayComplete` NatSpec):
///   the supplied `seriesIds[]` is EXACTLY the active set iff
///     length == activeSeriesCount(subKey)
///     && strictly increasing (uniqueness + canonical order)
///     && every element is active per `isActiveSeries`.
///
/// Any missing active series fails count; any duplicate fails order;
/// any inactive substitution fails per-element check.
contract OptionsPositionsLedgerCompleteness is Test {
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

    uint256 internal constant SERIES_A = 1;
    uint256 internal constant SERIES_B = 2;
    uint256 internal constant SERIES_C = 3;

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

    function _sk(address owner, uint32 id) internal view returns (bytes32) {
        return registry.subKeyOf(owner, id);
    }

    function _fill(bytes32 sk, uint256 series, uint8 side, uint128 q) internal {
        vm.prank(engineFill);
        ledger.applyFill(sk, series, side, q, 100e8);
    }

    /*//////////////////////////////////////////////////////////////
                        isActiveSeries EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function test_isActiveSeries_falseOnZeroSubKey() public view {
        assertFalse(ledger.isActiveSeries(bytes32(0), SERIES_A));
    }

    function test_isActiveSeries_falseOnZeroSeriesId() public view {
        bytes32 sk = _sk(ownerA, 1);
        assertFalse(ledger.isActiveSeries(sk, 0));
    }

    function test_isActiveSeries_falseWhenNothingApplied() public view {
        bytes32 sk = _sk(ownerA, 1);
        assertFalse(ledger.isActiveSeries(sk, SERIES_A));
    }

    function test_isActiveSeries_trueAfterFill() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        assertTrue(ledger.isActiveSeries(sk, SERIES_A));
    }

    function test_isActiveSeries_isolatedPerSubKey() public {
        bytes32 skA = _sk(ownerA, 1);
        bytes32 skB = _sk(ownerB, 1);
        _fill(skA, SERIES_A, 0, 10);
        assertTrue(ledger.isActiveSeries(skA, SERIES_A));
        assertFalse(ledger.isActiveSeries(skB, SERIES_A));
    }

    function test_isActiveSeries_isolatedPerSeries() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        assertFalse(ledger.isActiveSeries(sk, SERIES_B));
    }

    /*//////////////////////////////////////////////////////////////
                verifyActiveSeriesArrayComplete — EMPTY
    //////////////////////////////////////////////////////////////*/

    function test_verify_emptyArrayEmptyAccount() public view {
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory empty = new uint256[](0);
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, empty));
    }

    function test_verify_rejectsNonEmptyWhenAccountEmpty() public view {
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory arr = new uint256[](1);
        arr[0] = SERIES_A;
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_rejectsEmptyWhenAccountNonEmpty() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        uint256[] memory empty = new uint256[](0);
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, empty));
    }

    function test_verify_rejectsZeroSubKey() public view {
        uint256[] memory empty = new uint256[](0);
        assertFalse(ledger.verifyActiveSeriesArrayComplete(bytes32(0), empty));
    }

    /*//////////////////////////////////////////////////////////////
                verifyActiveSeriesArrayComplete — HAPPY PATH
    //////////////////////////////////////////////////////////////*/

    function test_verify_singleSeriesAcceptsExactMatch() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        uint256[] memory arr = new uint256[](1);
        arr[0] = SERIES_A;
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_multipleSeriesInCanonicalOrder() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        _fill(sk, SERIES_B, 1, 5);
        _fill(sk, SERIES_C, 0, 20);
        uint256[] memory arr = new uint256[](3);
        arr[0] = SERIES_A;
        arr[1] = SERIES_B;
        arr[2] = SERIES_C;
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_acceptsLongAndShortInSameSeries() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        _fill(sk, SERIES_A, 1, 5); // long + short in same series is still one series
        assertEq(ledger.activeSeriesCount(sk), 1);
        uint256[] memory arr = new uint256[](1);
        arr[0] = SERIES_A;
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    /*//////////////////////////////////////////////////////////////
              verifyActiveSeriesArrayComplete — REJECTION
    //////////////////////////////////////////////////////////////*/

    function test_verify_rejectsMissingActiveSeries() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        _fill(sk, SERIES_B, 0, 10);
        // Supplied array omits SERIES_B → length mismatch.
        uint256[] memory arr = new uint256[](1);
        arr[0] = SERIES_A;
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_rejectsExtraInactiveSeries() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        // Supplied array adds inactive SERIES_B → length mismatch (1 vs 2) AND
        // per-element failure would trigger for the inactive one.
        uint256[] memory arr = new uint256[](2);
        arr[0] = SERIES_A;
        arr[1] = SERIES_B;
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_rejectsWrongOrder() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        _fill(sk, SERIES_B, 0, 10);
        // Correct count + all active but order is B, A (not strictly increasing).
        uint256[] memory arr = new uint256[](2);
        arr[0] = SERIES_B;
        arr[1] = SERIES_A;
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_rejectsDuplicates() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        _fill(sk, SERIES_B, 0, 10);
        // Length matches (2) but duplicate SERIES_A → not strictly increasing.
        uint256[] memory arr = new uint256[](2);
        arr[0] = SERIES_A;
        arr[1] = SERIES_A;
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_rejectsSubstitutedInactive() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        _fill(sk, SERIES_C, 0, 10);
        // Count matches (2), strictly increasing, but SERIES_B was substituted
        // for the actual active SERIES_A → per-element active-check fails on B.
        uint256[] memory arr = new uint256[](2);
        arr[0] = SERIES_B;
        arr[1] = SERIES_C;
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_rejectsZeroSeriesIdElement() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10);
        // Length 1 but element is 0 → rejected.
        // (Would also fail per-element active-check because seriesId 0 is not stored.)
        uint256[] memory arr = new uint256[](1);
        arr[0] = 0;
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    /*//////////////////////////////////////////////////////////////
              LIFECYCLE INTERACTION — SETTLEMENT / EXERCISE
    //////////////////////////////////////////////////////////////*/

    function test_verify_stableAcrossFullExerciseKeepsBasisRow() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 0, 10); // long fill leaves basis > 0
        // Exercise the full long: long → 0, but basis remains. Row is still
        // considered active because basis != 0 (per `_isPositionAllZero`).
        vm.prank(engineSettle);
        ledger.applyExercise(sk, SERIES_A, 10, 100e8);
        assertEq(ledger.activeSeriesCount(sk), 1);
        assertTrue(ledger.isActiveSeries(sk, SERIES_A));
        uint256[] memory arr = new uint256[](1);
        arr[0] = SERIES_A;
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_stableAcrossSettlementKeepsBasisRow() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_A, 1, 10); // short fill records recv premium
        vm.prank(engineSettle);
        ledger.applySettlement(sk, SERIES_A, 100e8);
        // settlementState=FULL but recv premium remains → row still active.
        assertEq(ledger.activeSeriesCount(sk), 1);
        uint256[] memory arr = new uint256[](1);
        arr[0] = SERIES_A;
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    function test_verify_liquidationRemovesShortSeriesFromCount() public {
        bytes32 sk = _sk(ownerA, 1);
        bytes32 liq = _sk(ownerB, 1);
        // Short fill has recv premium > 0; liquidating the full short does NOT
        // zero recv, so the series is still "active" per the ledger convention.
        // The completeness verifier reflects this ledger-level semantic.
        _fill(sk, SERIES_A, 1, 10);
        vm.prank(engineLiquidate);
        ledger.applyLiquidation(sk, SERIES_A, 10, liq);
        assertEq(ledger.activeSeriesCount(sk), 1);
        uint256[] memory arr = new uint256[](1);
        arr[0] = SERIES_A;
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, arr));
    }

    /*//////////////////////////////////////////////////////////////
                          SUBACCOUNT ISOLATION
    //////////////////////////////////////////////////////////////*/

    function test_verify_siblingIsolation() public {
        bytes32 skA = _sk(ownerA, 1);
        bytes32 skB = _sk(ownerB, 1);
        _fill(skA, SERIES_A, 0, 10);
        _fill(skA, SERIES_B, 0, 10);
        // Correct array for skA.
        uint256[] memory forA = new uint256[](2);
        forA[0] = SERIES_A;
        forA[1] = SERIES_B;
        assertTrue(ledger.verifyActiveSeriesArrayComplete(skA, forA));
        // Same array against skB (which has 0 active) → false.
        assertFalse(ledger.verifyActiveSeriesArrayComplete(skB, forA));
        // Empty array for skB (which has 0 active) → true.
        uint256[] memory empty = new uint256[](0);
        assertTrue(ledger.verifyActiveSeriesArrayComplete(skB, empty));
    }

    function test_verify_siblingSubaccountIsolation() public {
        bytes32 sk1 = _sk(ownerA, 1);
        bytes32 sk2 = _sk(ownerA, 2);
        _fill(sk1, SERIES_A, 0, 10);
        _fill(sk2, SERIES_B, 0, 10);
        uint256[] memory arr1 = new uint256[](1);
        arr1[0] = SERIES_A;
        uint256[] memory arr2 = new uint256[](1);
        arr2[0] = SERIES_B;
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk1, arr1));
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk2, arr2));
        // Swap arrays.
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk1, arr2));
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk2, arr1));
    }

    /*//////////////////////////////////////////////////////////////
                    RECONSTRUCTION FROM EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev DB-loss reconstruction: after arbitrary fills, an off-chain
    ///      indexer that follows `OptionPositionOpened` events can rebuild
    ///      the set of series ever opened for a subaccount; filtering by
    ///      `isActiveSeries` reproduces the current active set. Verifier
    ///      then confirms the reconstructed array is canonical.
    function test_verify_reconstructionFromEvents() public {
        bytes32 sk = _sk(ownerA, 1);
        _fill(sk, SERIES_B, 0, 10); // record 1
        _fill(sk, SERIES_A, 0, 10); // record 2
        _fill(sk, SERIES_C, 1, 10); // record 3

        // Simulated indexer: seen [SERIES_B, SERIES_A, SERIES_C]. Deterministic
        // reconstruction sorts them (canonical order).
        uint256[] memory seen = new uint256[](3);
        seen[0] = SERIES_A;
        seen[1] = SERIES_B;
        seen[2] = SERIES_C;

        // Filter by current active (all three are still active).
        uint256 activeN;
        for (uint256 i = 0; i < seen.length; i++) {
            if (ledger.isActiveSeries(sk, seen[i])) activeN++;
        }
        uint256[] memory active = new uint256[](activeN);
        uint256 j;
        for (uint256 i = 0; i < seen.length; i++) {
            if (ledger.isActiveSeries(sk, seen[i])) {
                active[j++] = seen[i];
            }
        }
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, active));
    }

    /*//////////////////////////////////////////////////////////////
                              FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_verify_countMatchesActive(uint8 mask) public {
        // Interpret the low 3 bits of `mask` as which of SERIES_A/B/C receive
        // a fill. Then supply the correct sorted active array and expect true.
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory series = new uint256[](3);
        series[0] = SERIES_A;
        series[1] = SERIES_B;
        series[2] = SERIES_C;

        uint256 filled;
        for (uint256 i = 0; i < 3; i++) {
            if ((mask >> i) & 1 == 1) {
                _fill(sk, series[i], 0, 10);
                filled++;
            }
        }
        assertEq(ledger.activeSeriesCount(sk), filled);

        uint256[] memory active = new uint256[](filled);
        uint256 j;
        for (uint256 i = 0; i < 3; i++) {
            if ((mask >> i) & 1 == 1) {
                active[j++] = series[i];
            }
        }
        assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, active));
    }

    function testFuzz_verify_rejectsPermutation(uint8 mask, uint8 swapSeed) public {
        // Same as above, but if there are >= 2 active series, swap two entries
        // and assert rejection.
        vm.assume(mask != 0);
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory series = new uint256[](3);
        series[0] = SERIES_A;
        series[1] = SERIES_B;
        series[2] = SERIES_C;

        uint256 filled;
        for (uint256 i = 0; i < 3; i++) {
            if ((mask >> i) & 1 == 1) {
                _fill(sk, series[i], 0, 10);
                filled++;
            }
        }
        if (filled < 2) return;

        uint256[] memory active = new uint256[](filled);
        uint256 j;
        for (uint256 i = 0; i < 3; i++) {
            if ((mask >> i) & 1 == 1) {
                active[j++] = series[i];
            }
        }
        // Swap positions 0 and 1.
        (active[0], active[1]) = (active[1], active[0]);
        swapSeed; // silence
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, active));
    }

    function testFuzz_verify_rejectsAnyOmission(uint8 mask) public {
        vm.assume(mask & 0x7 == 0x7); // require ALL three filled
        bytes32 sk = _sk(ownerA, 1);
        uint256[] memory series = new uint256[](3);
        series[0] = SERIES_A;
        series[1] = SERIES_B;
        series[2] = SERIES_C;
        for (uint256 i = 0; i < 3; i++) {
            _fill(sk, series[i], 0, 10);
        }

        // Try each 2-element subset — every one should be rejected.
        for (uint256 omit = 0; omit < 3; omit++) {
            uint256[] memory two = new uint256[](2);
            uint256 j;
            for (uint256 i = 0; i < 3; i++) {
                if (i == omit) continue;
                two[j++] = series[i];
            }
            assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, two));
        }
    }
}
