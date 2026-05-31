// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../src/fees/IFeesManagerV2.sol";

interface IUseFeesManagerV2 {
    function feesManagerV2() external view returns (address);
    function useFeesManagerV2() external view returns (bool);
}

/// @title SmokeOptionV2Rebate
/// @notice V2G-B OPTION rebate smoke **preflight** checker. Mirrors
///         `SmokePerpV2Rebate` for the OPTION product. Read-only;
///         the actual trade is driven by the backend executor (V2E-G
///         pattern), not by this script.
/// @dev
///  Required env:
///    - `FEES_MANAGER_V2_ADDRESS`
///    - `MARGIN_ENGINE` (NEW MarginEngine V2)
///    - `REBATE_TOKEN`
///    - `MAKER_ACCOUNT`
///    - `TAKER_ACCOUNT`
///
///  Optional env:
///    - `MIN_REBATE_BUDGET` (defaults to 0).
contract SmokeOptionV2Rebate is Script {
    struct Inputs {
        address feesManager;
        address marginEngine;
        address rebateToken;
        address maker;
        address taker;
        uint256 minBudget;
    }

    struct Snapshot {
        bool marginUsesFeesManagerV2;
        address marginFeesManagerV2;
        bool isFeeConsumerMargin;
        uint256 rebateBudget;
        bytes32 merkleRoot;
        uint8 makerTier;
        uint8 takerTier;
        int32 makerPpmAtTier;
    }

    error FeesManagerUnset();
    error MarginEngineUnset();
    error MarginEngineDoesNotUseFeesManagerV2();
    error MarginEngineFeesManagerMismatch(address onMargin, address configured);
    error MarginEngineNotFeeConsumer();
    error MerkleRootUnset();
    error MakerHasNoNegativeRebateTier(uint8 tier, int32 ppm);
    error RebateBudgetBelowMinimum(uint256 budget, uint256 minBudget);

    function run() external view {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory snap = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot(snap);

        _validatePreflight(inputs, snap);

        console2.log("V2G-B OPTION smoke preflight PASSED. Next step:");
        console2.log(" 1. Sign and broadcast a tiny OPTION trade via the backend executor");
        console2.log("    with MAKER_ACCOUNT as the resting maker and TAKER_ACCOUNT crossing.");
        console2.log(" 2. Expected events on the tx:");
        console2.log("      FeeChargedV2(taker, productKind=OPTION, flowKind=ORDERBOOK)");
        console2.log("      FeeRebatedV2(maker, productKind=OPTION, flowKind=ORDERBOOK)");
        console2.log("      RebateBudgetSpent(REBATE_TOKEN, rebateAmount)");
        console2.log(" 3. Verify via backend: GET /admin/fees/onchain?tx_hash=<tx>");
        console2.log(" 4. This script does NOT broadcast the trade.");
    }

    function _readInputs() internal view returns (Inputs memory inputs) {
        inputs.feesManager = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.marginEngine = _envAddressOrZero("MARGIN_ENGINE");
        inputs.rebateToken = _envAddressOrZero("REBATE_TOKEN");
        inputs.maker = _envAddressOrZero("MAKER_ACCOUNT");
        inputs.taker = _envAddressOrZero("TAKER_ACCOUNT");
        inputs.minBudget = vm.envOr("MIN_REBATE_BUDGET", uint256(0));
    }

    function _validateInputs(Inputs memory inputs) internal pure {
        if (inputs.feesManager == address(0)) revert FeesManagerUnset();
        if (inputs.marginEngine == address(0)) revert MarginEngineUnset();
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        FeesManagerV2 fm = FeesManagerV2(inputs.feesManager);
        try IUseFeesManagerV2(inputs.marginEngine).useFeesManagerV2() returns (bool ok) {
            snap.marginUsesFeesManagerV2 = ok;
        } catch {}
        try IUseFeesManagerV2(inputs.marginEngine).feesManagerV2() returns (address fmAddr) {
            snap.marginFeesManagerV2 = fmAddr;
        } catch {}
        snap.isFeeConsumerMargin = fm.isFeeConsumer(inputs.marginEngine);
        snap.rebateBudget = fm.rebateBudget(inputs.rebateToken);
        snap.merkleRoot = fm.merkleRoot();
        snap.makerTier = fm.currentTier(inputs.maker);
        snap.takerTier = fm.currentTier(inputs.taker);
        snap.makerPpmAtTier = fm.getFeeProfile(snap.makerTier, IFeesManagerV2.ProductKind.OPTION).makerPpm;
    }

    function _validatePreflight(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (!snap.marginUsesFeesManagerV2) revert MarginEngineDoesNotUseFeesManagerV2();
        if (snap.marginFeesManagerV2 != inputs.feesManager) {
            revert MarginEngineFeesManagerMismatch(snap.marginFeesManagerV2, inputs.feesManager);
        }
        if (!snap.isFeeConsumerMargin) revert MarginEngineNotFeeConsumer();
        if (snap.merkleRoot == bytes32(0)) revert MerkleRootUnset();
        if (snap.makerPpmAtTier >= 0) {
            revert MakerHasNoNegativeRebateTier(snap.makerTier, snap.makerPpmAtTier);
        }
        if (snap.rebateBudget < inputs.minBudget) {
            revert RebateBudgetBelowMinimum(snap.rebateBudget, inputs.minBudget);
        }
    }

    function _logInputs(Inputs memory inputs) internal pure {
        console2.log("V2G-B OPTION rebate smoke preflight");
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        console2.log("MARGIN_ENGINE", inputs.marginEngine);
        console2.log("REBATE_TOKEN", inputs.rebateToken);
        console2.log("MAKER_ACCOUNT", inputs.maker);
        console2.log("TAKER_ACCOUNT", inputs.taker);
        console2.log("MIN_REBATE_BUDGET", inputs.minBudget);
    }

    function _logSnapshot(Snapshot memory snap) internal pure {
        console2.log("State snapshot:");
        console2.log(" MarginEngine.useFeesManagerV2()", snap.marginUsesFeesManagerV2);
        console2.log(" MarginEngine.feesManagerV2()", snap.marginFeesManagerV2);
        console2.log(" FeesManagerV2.isFeeConsumer(MarginEngine)", snap.isFeeConsumerMargin);
        console2.log(" FeesManagerV2.rebateBudget(token)", snap.rebateBudget);
        console2.log(" FeesManagerV2.merkleRoot()");
        console2.logBytes32(snap.merkleRoot);
        console2.log(" FeesManagerV2.currentTier(MAKER)", snap.makerTier);
        console2.log(" FeesManagerV2.currentTier(TAKER)", snap.takerTier);
        console2.log(" OPTION makerPpm at MAKER tier (negative = rebate)");
        console2.logInt(snap.makerPpmAtTier);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
