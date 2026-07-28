// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {OptionsPositionsLedger} from "../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {OptionsPositionsLedgerHandler} from "./handlers/OptionsPositionsLedgerHandler.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../vault/harness/CollateralVaultV2Harness.sol";
import {Capabilities} from "../../../src/hybrid-v2/libraries/Capabilities.sol";
import {PositionTypes} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";

/// @title OptionsPositionsLedgerActiveSeriesBoundInvariants
/// @notice `ONCHAIN-SUBACCOUNT-RISK-EXECUTION-BOUNDS-AND-COLLATERAL-UNIVERSE-V1`
///         — invariants over the frozen `MAX_ACTIVE_SERIES_PER_SUBACCOUNT = 32` cap.
///
/// Invariants:
///   RISK-BOUND-I1: `activeSeriesCount(subKey)` never exceeds 32.
///   RISK-BOUND-I3: a rejected 33rd-series activation produces no partial
///                  position or count mutation (property of atomic revert;
///                  witnessed via I1 remaining stable after every handler call
///                  including deliberate over-cap attempts).
contract OptionsPositionsLedgerActiveSeriesBoundInvariants is Test {
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
              RISK-BOUND-I1 — count never exceeds 32
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_BOUND_I1_countNeverExceeds32() public view {
        uint256 n = handler.trackedSubKeysLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 sk = handler.trackedSubKeys(i);
            assertLe(uint256(ledger.activeSeriesCount(sk)), 32);
        }
    }

    /*//////////////////////////////////////////////////////////////
              RISK-BOUND-I3 — atomic revert on cap breach
    //////////////////////////////////////////////////////////////*/

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_BOUND_I3_verifierMatchesCount() public view {
        // Consistency witness: every canonical portfolio at or below 32 is
        // verifiable via the reconstruction pattern. A rejected 33rd
        // activation would leave the mutation partial only if the counter
        // OR the underlying position row went out of sync; the completeness
        // verifier surfaces any such divergence.
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
            assertTrue(ledger.verifyActiveSeriesArrayComplete(sk, active), "canonical reconstruction rejected");
        }
    }
}
