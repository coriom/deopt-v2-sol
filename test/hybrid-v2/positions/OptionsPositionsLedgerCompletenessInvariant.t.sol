// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {OptionsPositionsLedgerHandler} from "./handlers/OptionsPositionsLedgerHandler.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";

/// @title OptionsPositionsLedgerCompletenessInvariants
/// @notice WP-07 completeness patch — invariant suite for the ledger's
///         active-set membership + verifier proof.
///
/// Invariants:
///   RISK-COMP-I1: any array shorter than `activeSeriesCount(subKey)` is
///                 rejected by `verifyActiveSeriesArrayComplete` — no
///                 affirmative completeness under omission.
///   RISK-COMP-I2: `activeSeriesCount(subKey)` equals the number of series
///                 in the handler's known pool that report `isActiveSeries==true`.
///   RISK-COMP-I3+I4: covered by RISK-COMP-I2 via the handler's fuzz path —
///                   every fill / exercise / settle / liquidate transition
///                   maintains the count equality.
///   RISK-COMP-I5: sibling-subaccount isolation — the verifier for one
///                 subKey rejects an array reflecting another's active set
///                 whenever the counts differ.
contract OptionsPositionsLedgerCompletenessInvariants is Test {
    SubaccountRegistry internal registry;
    CollateralVaultV2Harness internal vault;
    OptionsPositionsLedger internal ledger;
    OptionsPositionsLedgerHandler internal handler;

    address internal governance = address(0xA1);
    address internal guardian = address(0xA2);
    address internal engineFill = address(0xE1);
    address internal engineSettle = address(0xE2);
    address internal engineLiquidate = address(0xE3);
    address internal attacker = address(0xE9);

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        vault = new CollateralVaultV2Harness(address(registry), governance, guardian);
        ledger = new OptionsPositionsLedger(address(registry), address(vault));

        vm.prank(governance);
        vault.setEngineCapability(engineFill, Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA, true);
        vm.prank(governance);
        vault.setEngineCapability(engineSettle, Capabilities.CAP_SETTLE_OPTION, true);
        vm.prank(governance);
        vault.setEngineCapability(engineLiquidate, Capabilities.CAP_LIQUIDATE_OPTIONS, true);

        handler = new OptionsPositionsLedgerHandler(
            ledger, registry, vault, governance, engineFill, engineSettle, engineLiquidate, attacker
        );
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                RISK-COMP-I2 — count matches per-series membership
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_COMP_I2_countMatchesMembership() public view {
        uint256 n = handler.trackedSubKeysLength();
        uint256 poolN = handler.seriesPoolLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            uint256 counted;
            for (uint256 j = 0; j < poolN; j++) {
                if (ledger.isActiveSeries(sk, handler.seriesPool(j))) counted++;
            }
            assertEq(ledger.activeSeriesCount(sk), counted, "activeSeriesCount != sum isActiveSeries");
        }
    }

    /*//////////////////////////////////////////////////////////////
                RISK-COMP-I1 — omission never verifies
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_COMP_I1_omissionRejected() public view {
        uint256 n = handler.trackedSubKeysLength();
        uint256 poolN = handler.seriesPoolLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            uint32 count = ledger.activeSeriesCount(sk);
            if (count == 0) continue;
            // Construct the sorted active set (pool ids 1..poolN are already
            // monotonic + distinct).
            uint256[] memory active = new uint256[](count);
            uint256 j;
            for (uint256 k = 0; k < poolN && j < count; k++) {
                uint256 sid = handler.seriesPool(k);
                if (ledger.isActiveSeries(sk, sid)) active[j++] = sid;
            }
            // Any strict subset (drop the last entry) MUST be rejected.
            uint256[] memory shortArr = new uint256[](count - 1);
            for (uint256 k = 0; k < count - 1; k++) {
                shortArr[k] = active[k];
            }
            assertFalse(ledger.verifyActiveSeriesArrayComplete(sk, shortArr), "omission accepted");
        }
    }

    /*//////////////////////////////////////////////////////////////
                RISK-COMP-I5 — verifier respects sibling isolation
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_COMP_I5_siblingIsolation() public view {
        uint256 n = handler.trackedSubKeysLength();
        if (n < 2) return;
        // For any two tracked subKeys, if their active-series counts differ,
        // the smaller subKey's canonical array must NOT verify for the larger,
        // and vice versa. (When counts happen to coincide, this is a weaker
        // test — the verifier could still reject because per-element active
        // check fails on the wrong subKey — but we do not rely on that.)
        bytes32 sk0 = handler.trackedSubKeys(0);
        bytes32 sk1 = handler.trackedSubKeys(1);
        uint32 c0 = ledger.activeSeriesCount(sk0);
        uint32 c1 = ledger.activeSeriesCount(sk1);
        if (c0 == c1) return;

        // Build sk0's canonical array.
        uint256 poolN = handler.seriesPoolLength();
        uint256[] memory arr0 = new uint256[](c0);
        uint256 j;
        for (uint256 k = 0; k < poolN && j < c0; k++) {
            uint256 sid = handler.seriesPool(k);
            if (ledger.isActiveSeries(sk0, sid)) arr0[j++] = sid;
        }
        // sk0's array applied to sk1 → false (length mismatch, since c0 != c1).
        assertFalse(ledger.verifyActiveSeriesArrayComplete(sk1, arr0), "sibling accepted foreign active array");
    }

    /*//////////////////////////////////////////////////////////////
              RISK-COMP-I2 corollary — canonical array verifies
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_COMP_I2_canonicalArrayVerifies() public view {
        uint256 n = handler.trackedSubKeysLength();
        uint256 poolN = handler.seriesPoolLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            uint32 count = ledger.activeSeriesCount(sk);
            uint256[] memory active = new uint256[](count);
            uint256 j;
            for (uint256 k = 0; k < poolN && j < count; k++) {
                uint256 sid = handler.seriesPool(k);
                if (ledger.isActiveSeries(sk, sid)) active[j++] = sid;
            }
            assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, active), "canonical array rejected");
        }
    }
}
