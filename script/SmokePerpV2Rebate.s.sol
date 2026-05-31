// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../src/fees/IFeesManagerV2.sol";

interface IUseFeesManagerV2 {
    function feesManagerV2() external view returns (address);
    function useFeesManagerV2() external view returns (bool);
}

/// @title SmokePerpV2Rebate
/// @notice V2G-B PERP rebate smoke **preflight** checker. This script
///         is intentionally read-only: it verifies that the chain is
///         configured for a PERP rebate smoke (Merkle root set,
///         budget funded, maker tier claimed at a negative-ppm tier,
///         NEW PerpEngine wired to FeesManagerV2, OLD untouched) and
///         then **prints exactly what the operator must do** to drive
///         the trade. The actual trade is signed and broadcast by the
///         backend executor (see V2D-V / V2E-G patterns), not by this
///         script.
/// @dev
///  Required env:
///    - `FEES_MANAGER_V2_ADDRESS`
///    - `PERP_ENGINE` (NEW; must NOT equal `OLD_PERP_ENGINE`)
///    - `REBATE_TOKEN`
///    - `MAKER_ACCOUNT` (the Tier 4 / Tier 3 / Tier 2 rebate
///                       candidate from the V2G-B artifact)
///    - `TAKER_ACCOUNT`
///
///  Optional env:
///    - `OLD_PERP_ENGINE` (defaults to the V2F-LM stranded address).
///    - `MIN_REBATE_BUDGET` (defaults to 0; bumps the alert when the
///       on-contract `rebateBudget(REBATE_TOKEN)` is below this).
contract SmokePerpV2Rebate is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address feesManager;
        address perpEngine;
        address oldPerpEngine;
        address rebateToken;
        address maker;
        address taker;
        uint256 minBudget;
    }

    struct Snapshot {
        bool perpUsesFeesManagerV2;
        address perpFeesManagerV2;
        bool oldUsesFeesManagerV2;
        bool isFeeConsumerNew;
        bool isFeeConsumerOld;
        uint256 rebateBudget;
        bytes32 merkleRoot;
        uint8 makerTier;
        uint8 takerTier;
        int32 makerPpmAtTier;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error FeesManagerUnset();
    error PerpEngineUnset();
    error PerpEngineEqualsOld(address engine);
    error PerpEngineDoesNotUseFeesManagerV2();
    error PerpEngineFeesManagerMismatch(address onPerp, address configured);
    error PerpEngineNotFeeConsumer();
    error OldPerpEngineStillFeeConsumer();
    error MerkleRootUnset();
    error MakerHasNoNegativeRebateTier(uint8 tier, int32 ppm);
    error RebateBudgetBelowMinimum(uint256 budget, uint256 minBudget);

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory snap = _snapshot(inputs);
        _logInputs(inputs);
        _logSnapshot(snap);

        _validatePreflight(inputs, snap);

        console2.log("V2G-B PERP smoke preflight PASSED. Next step:");
        console2.log(" 1. Sign and broadcast a tiny PERP trade via the backend executor");
        console2.log("    with MAKER_ACCOUNT as the resting maker and TAKER_ACCOUNT crossing.");
        console2.log(" 2. Expected events on the tx:");
        console2.log("      FeeChargedV2(taker, productKind=PERP, flowKind=ORDERBOOK)");
        console2.log("      FeeRebatedV2(maker, productKind=PERP, flowKind=ORDERBOOK)");
        console2.log("      RebateBudgetSpent(REBATE_TOKEN, rebateAmount)");
        console2.log(" 3. Verify via backend: GET /admin/fees/onchain?tx_hash=<tx>");
        console2.log(" 4. Scrape /metrics and confirm deopt_perp_fee_charged_v2_total{consumer=\"new\"}");
        console2.log("    and deopt_perp_fee_rebated_v2_total{consumer=\"new\"} both advanced by 1.");
        console2.log(" 5. This script does NOT broadcast the trade.");
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        inputs.feesManager = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.perpEngine = _envAddressOrZero("PERP_ENGINE");
        inputs.oldPerpEngine = vm.envOr("OLD_PERP_ENGINE", address(0xB36395b67D0798ADA981731c9Fa5239F4362b53B));
        inputs.rebateToken = _envAddressOrZero("REBATE_TOKEN");
        inputs.maker = _envAddressOrZero("MAKER_ACCOUNT");
        inputs.taker = _envAddressOrZero("TAKER_ACCOUNT");
        inputs.minBudget = vm.envOr("MIN_REBATE_BUDGET", uint256(0));
    }

    function _validateInputs(Inputs memory inputs) internal pure {
        if (inputs.feesManager == address(0)) revert FeesManagerUnset();
        if (inputs.perpEngine == address(0)) revert PerpEngineUnset();
        if (inputs.perpEngine == inputs.oldPerpEngine) revert PerpEngineEqualsOld(inputs.perpEngine);
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        FeesManagerV2 fm = FeesManagerV2(inputs.feesManager);
        IUseFeesManagerV2 perp = IUseFeesManagerV2(inputs.perpEngine);

        try perp.useFeesManagerV2() returns (bool ok) {
            snap.perpUsesFeesManagerV2 = ok;
        } catch {}
        try perp.feesManagerV2() returns (address fmAddr) {
            snap.perpFeesManagerV2 = fmAddr;
        } catch {}
        if (inputs.oldPerpEngine.code.length > 0) {
            try IUseFeesManagerV2(inputs.oldPerpEngine).useFeesManagerV2() returns (bool ok) {
                snap.oldUsesFeesManagerV2 = ok;
            } catch {}
        }
        snap.isFeeConsumerNew = fm.isFeeConsumer(inputs.perpEngine);
        snap.isFeeConsumerOld = fm.isFeeConsumer(inputs.oldPerpEngine);
        snap.rebateBudget = fm.rebateBudget(inputs.rebateToken);
        snap.merkleRoot = fm.merkleRoot();
        snap.makerTier = fm.currentTier(inputs.maker);
        snap.takerTier = fm.currentTier(inputs.taker);
        snap.makerPpmAtTier = fm.getFeeProfile(snap.makerTier, IFeesManagerV2.ProductKind.PERP).makerPpm;
    }

    function _validatePreflight(Inputs memory inputs, Snapshot memory snap) internal view {
        if (!snap.perpUsesFeesManagerV2) revert PerpEngineDoesNotUseFeesManagerV2();
        if (snap.perpFeesManagerV2 != inputs.feesManager) {
            revert PerpEngineFeesManagerMismatch(snap.perpFeesManagerV2, inputs.feesManager);
        }
        if (!snap.isFeeConsumerNew) revert PerpEngineNotFeeConsumer();
        if (snap.isFeeConsumerOld) revert OldPerpEngineStillFeeConsumer();
        if (snap.merkleRoot == bytes32(0)) revert MerkleRootUnset();
        if (snap.makerPpmAtTier >= 0) {
            revert MakerHasNoNegativeRebateTier(snap.makerTier, snap.makerPpmAtTier);
        }
        if (snap.rebateBudget < inputs.minBudget) {
            revert RebateBudgetBelowMinimum(snap.rebateBudget, inputs.minBudget);
        }
    }

    function _logInputs(Inputs memory inputs) internal pure {
        console2.log("V2G-B PERP rebate smoke preflight");
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        console2.log("PERP_ENGINE (NEW)", inputs.perpEngine);
        console2.log("OLD_PERP_ENGINE (must be stranded)", inputs.oldPerpEngine);
        console2.log("REBATE_TOKEN", inputs.rebateToken);
        console2.log("MAKER_ACCOUNT", inputs.maker);
        console2.log("TAKER_ACCOUNT", inputs.taker);
        console2.log("MIN_REBATE_BUDGET", inputs.minBudget);
    }

    function _logSnapshot(Snapshot memory snap) internal pure {
        console2.log("State snapshot:");
        console2.log(" PerpEngine.useFeesManagerV2()", snap.perpUsesFeesManagerV2);
        console2.log(" PerpEngine.feesManagerV2()", snap.perpFeesManagerV2);
        console2.log(" OldPerpEngine.useFeesManagerV2()", snap.oldUsesFeesManagerV2);
        console2.log(" FeesManagerV2.isFeeConsumer(NEW)", snap.isFeeConsumerNew);
        console2.log(" FeesManagerV2.isFeeConsumer(OLD)", snap.isFeeConsumerOld);
        console2.log(" FeesManagerV2.rebateBudget(token)", snap.rebateBudget);
        console2.log(" FeesManagerV2.merkleRoot()");
        console2.logBytes32(snap.merkleRoot);
        console2.log(" FeesManagerV2.currentTier(MAKER)", snap.makerTier);
        console2.log(" FeesManagerV2.currentTier(TAKER)", snap.takerTier);
        console2.log(" PERP makerPpm at MAKER tier (negative = rebate)");
        console2.logInt(snap.makerPpmAtTier);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
