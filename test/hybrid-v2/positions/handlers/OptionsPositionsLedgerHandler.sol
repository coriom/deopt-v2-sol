// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {OptionsPositionsLedger} from "../../../../src/hybrid-v2/positions/OptionsPositionsLedger.sol";
import {SubaccountRegistry} from "../../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {CollateralVaultV2Harness} from "../../vault/harness/CollateralVaultV2Harness.sol";
import {PositionTypes} from "../../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {Capabilities} from "../../../../src/hybrid-v2/libraries/Capabilities.sol";

/// @title OptionsPositionsLedgerHandler
/// @notice Bounded fuzz-driven handler + ghost mirror for the WP-06 ledger invariants.
contract OptionsPositionsLedgerHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    OptionsPositionsLedger public immutable ledger;
    SubaccountRegistry public immutable registry;
    CollateralVaultV2Harness public immutable vault;

    address public immutable governance;
    address public immutable engineFill;
    address public immutable engineSettle;
    address public immutable engineLiquidate;
    address public immutable attackerEngine;

    address[] public owners;
    bytes32[] public trackedSubKeys;
    mapping(bytes32 => address) public subKeyOwner;
    mapping(bytes32 => uint32) public subKeyId;

    // Ghost mirrors keyed by (subKey, seriesId).
    mapping(bytes32 => mapping(uint256 => uint128)) public ghostLong;
    mapping(bytes32 => mapping(uint256 => uint128)) public ghostShort;
    mapping(bytes32 => mapping(uint256 => uint8)) public ghostExerciseState;
    mapping(bytes32 => mapping(uint256 => uint8)) public ghostSettlementState;

    uint256[] public seriesPool;

    // Sum of buyer/seller quantities for OPT-POS-I7 (per series, gross accumulators
    // — bounded by fuzz budget, uint128).
    mapping(uint256 => uint256) public ghostTotalLongOpen;
    mapping(uint256 => uint256) public ghostTotalShortOpen;

    uint256 public callCount;

    constructor(
        OptionsPositionsLedger ledger_,
        SubaccountRegistry registry_,
        CollateralVaultV2Harness vault_,
        address governance_,
        address engineFill_,
        address engineSettle_,
        address engineLiquidate_,
        address attackerEngine_
    ) {
        ledger = ledger_;
        registry = registry_;
        vault = vault_;
        governance = governance_;
        engineFill = engineFill_;
        engineSettle = engineSettle_;
        engineLiquidate = engineLiquidate_;
        attackerEngine = attackerEngine_;

        for (uint160 i = 1; i <= 4; i++) {
            owners.push(address(uint160(0x60000 + i)));
        }
        seriesPool.push(1);
        seriesPool.push(2);
        seriesPool.push(3);
    }

    function ownerRegister(uint256 seed) external {
        callCount++;
        address owner = owners[seed % owners.length];
        uint32 nextId = registry.nextIdFor(owner);
        if (nextId >= 3) return;
        vm.prank(owner);
        registry.registerNext();
        bytes32 sk = registry.subKeyOf(owner, nextId);
        trackedSubKeys.push(sk);
        subKeyOwner[sk] = owner;
        subKeyId[sk] = nextId;
    }

    function fillLong(uint256 seed, uint64 quantity, uint64 price) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 series = seriesPool[seed % seriesPool.length];
        uint128 q = uint128(bound(quantity, 1, 1e15));
        uint128 p = uint128(bound(price, 1, 1e15));
        // Skip if series has been fully settled per ghost.
        if (ghostSettlementState[sk][series] == 2) return;
        // Skip if would overflow uint128.
        if (uint256(ghostLong[sk][series]) + uint256(q) > type(uint128).max) return;
        vm.prank(engineFill);
        ledger.applyFill(sk, series, 0, q, p);
        // Mirror the contract's re-open reset of exerciseState when the long
        // side was previously fully exercised.
        if (ghostLong[sk][series] == 0 && ghostExerciseState[sk][series] == 2) {
            ghostExerciseState[sk][series] = 0;
        }
        ghostLong[sk][series] += q;
        ghostTotalLongOpen[series] += q;
    }

    function fillShort(uint256 seed, uint64 quantity, uint64 price) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 series = seriesPool[seed % seriesPool.length];
        uint128 q = uint128(bound(quantity, 1, 1e15));
        uint128 p = uint128(bound(price, 1, 1e15));
        if (ghostSettlementState[sk][series] == 2) return;
        if (uint256(ghostShort[sk][series]) + uint256(q) > type(uint128).max) return;
        vm.prank(engineFill);
        ledger.applyFill(sk, series, 1, q, p);
        ghostShort[sk][series] += q;
        ghostTotalShortOpen[series] += q;
    }

    function exercisePartial(uint256 seed, uint64 quantity) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 series = seriesPool[seed % seriesPool.length];
        uint128 have = ghostLong[sk][series];
        if (have == 0) return;
        if (ghostSettlementState[sk][series] == 2) return;
        uint128 q = uint128(bound(quantity, 1, have));
        vm.prank(engineSettle);
        ledger.applyExercise(sk, series, q, 100e8);
        ghostLong[sk][series] -= q;
        ghostExerciseState[sk][series] = ghostLong[sk][series] == 0 ? 2 : 1;
    }

    function liquidatePartial(uint256 seed, uint64 quantity) external {
        callCount++;
        if (trackedSubKeys.length < 2) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        bytes32 liquidator = trackedSubKeys[(seed + 1) % trackedSubKeys.length];
        if (sk == liquidator) return;
        uint256 series = seriesPool[seed % seriesPool.length];
        uint128 have = ghostShort[sk][series];
        if (have == 0) return;
        if (ghostSettlementState[sk][series] == 2) return;
        uint128 q = uint128(bound(quantity, 1, have));
        vm.prank(engineLiquidate);
        ledger.applyLiquidation(sk, series, q, liquidator);
        ghostShort[sk][series] -= q;
    }

    function settle(uint256 seed) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 series = seriesPool[seed % seriesPool.length];
        if (ghostSettlementState[sk][series] == 2) return;
        uint128 hadLongGhost = ghostLong[sk][series];
        vm.prank(engineSettle);
        ledger.applySettlement(sk, series, 100e8);
        ghostLong[sk][series] = 0;
        ghostShort[sk][series] = 0;
        ghostSettlementState[sk][series] = 2;
        // Contract only escalates exerciseState to FULL when a long side was zeroed
        // by settlement. Positions that never had long remain at their original
        // exerciseState value.
        if (hadLongGhost > 0 && ghostExerciseState[sk][series] != 2) {
            ghostExerciseState[sk][series] = 2;
        }
    }

    function attackerAttemptFill(uint256 seed) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 series = seriesPool[seed % seriesPool.length];
        vm.prank(attackerEngine);
        try ledger.applyFill(sk, series, 0, 1e8, 100e8) {
            revert("unauthorized attacker mutated ledger");
        } catch {}
    }

    function attackerAttemptSettle(uint256 seed) external {
        callCount++;
        if (trackedSubKeys.length == 0) return;
        bytes32 sk = trackedSubKeys[seed % trackedSubKeys.length];
        uint256 series = seriesPool[seed % seriesPool.length];
        vm.prank(attackerEngine);
        try ledger.applySettlement(sk, series, 100e8) {
            revert("unauthorized attacker settled");
        } catch {}
    }

    // ----- accessors -----
    function ownersLength() external view returns (uint256) {
        return owners.length;
    }

    function trackedSubKeysLength() external view returns (uint256) {
        return trackedSubKeys.length;
    }

    function seriesPoolLength() external view returns (uint256) {
        return seriesPool.length;
    }
}
