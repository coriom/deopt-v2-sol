// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../src/fees/IFeesManagerV2.sol";

interface IUseFeesManagerV2 {
    function feesManagerV2() external view returns (address);
    function useFeesManagerV2() external view returns (bool);
}

/// @title SmokeOptionRfqV2Fees
/// @notice V2G-P1 OPTION **RFQ** fees preflight checker. Mirrors the
///         V2G-B {SmokeOptionV2Rebate} script but targets the
///         `FlowKind.RFQ` discount path that V2G-O exposed via
///         `OptionMatchingEngine.executeRfqTrade`. **Read-only.** No
///         broadcast. The actual RFQ trade is driven by the operator
///         signing CLI after this preflight passes.
/// @dev
///   Required env:
///     - `FEES_MANAGER_V2_ADDRESS`
///     - `MARGIN_ENGINE`
///     - `OPTION_MATCHING_ENGINE`
///     - `MAKER_ACCOUNT`
///     - `TAKER_ACCOUNT`
///     - `SETTLEMENT_ASSET`
///
///   Optional env (defaults to a canonical V2G-N reference trade):
///     - `RFQ_PREMIUM_NATIVE`        (default 100_000)  — basis amount used by quoteFees
///     - `EXPECTED_MAKER_FEE_NATIVE` (no default)        — if set, asserts equality with the maker quote
///     - `EXPECTED_TAKER_FEE_NATIVE` (no default)        — if set, asserts equality with the taker quote
///     - `EXPECTED_FLOW_KIND_RFQ`    (default true)      — asserts both quotes carry flow == RFQ
///
///   Hard rules enforced at runtime:
///     - this script is `view` end-to-end; cannot send transactions;
///     - aborts if FeesManagerV2 is not wired to MarginEngine,
///       MarginEngine does not declare V2 fee usage, or the
///       OptionMatchingEngine target lacks code;
///     - when the expected-fee env vars are set, mismatch reverts
///       with a labelled custom error so operators see the diff.
contract SmokeOptionRfqV2Fees is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct Inputs {
        address feesManager;
        address marginEngine;
        address optionMatchingEngine;
        address maker;
        address taker;
        address settlementAsset;
        uint256 premiumNative;
        bool expectFlowRfq;
        uint256 expectedMakerFee;
        bool expectedMakerFeeSet;
        uint256 expectedTakerFee;
        bool expectedTakerFeeSet;
    }

    struct Snapshot {
        bool marginUsesFeesManagerV2;
        address marginFeesManagerV2;
        bool isFeeConsumerMargin;
        uint256 optionMatchingEngineCodeSize;
        uint256 marginEngineCodeSize;
        uint8 makerTier;
        uint8 takerTier;
        int32 orderbookMakerPpmAtMakerTier;
        int32 orderbookTakerPpmAtTakerTier;
        uint32 rfqMakerDiscountPpmAtMakerTier;
        uint32 rfqTakerDiscountPpmAtTakerTier;
        IFeesManagerV2.FeeQuote rfqMakerQuote;
        IFeesManagerV2.FeeQuote rfqTakerQuote;
        IFeesManagerV2.FeeQuote orderbookMakerQuote;
        IFeesManagerV2.FeeQuote orderbookTakerQuote;
        uint256 rebateBudget;
        uint256 rebateBudgetDeltaIfMakerRebates;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error FeesManagerUnset();
    error MarginEngineUnset();
    error OptionMatchingEngineUnset();
    error MakerAccountUnset();
    error TakerAccountUnset();
    error SettlementAssetUnset();
    error MarginEngineDoesNotUseFeesManagerV2();
    error MarginEngineFeesManagerMismatch(address onMargin, address configured);
    error MarginEngineNotFeeConsumer();
    error MarginEngineHasNoCode(address target);
    error OptionMatchingEngineHasNoCode(address target);
    error RfqMakerQuoteFlowKindMismatch(IFeesManagerV2.FlowKind got);
    error RfqTakerQuoteFlowKindMismatch(IFeesManagerV2.FlowKind got);
    error RfqMakerFeeMismatch(uint256 expected, uint256 actual);
    error RfqTakerFeeMismatch(uint256 expected, uint256 actual);
    error RebateBudgetTooLowForMakerRebate(uint256 budget, uint256 required);

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external view {
        Inputs memory inputs = _readInputs();
        _validateInputs(inputs);

        Snapshot memory snap = _snapshot(inputs);

        _logInputs(inputs);
        _logSnapshot(snap);

        _validatePreflight(inputs, snap);

        console2.log("V2G-P1 OPTION RFQ smoke preflight PASSED. Operator next step:");
        console2.log(" 1. Build the RFQ packet via the backend operator module");
        console2.log("    (deopt-v2-backend/src/options/rfq_operator_packet.rs).");
        console2.log(" 2. Sign the OptionRfqTrade EIP-712 digest with maker + taker keys.");
        console2.log(" 3. Broadcast executeRfqTrade(...) via the gated executor.");
        console2.log(" 4. Expected events on the tx:");
        console2.log("      FeeChargedV2(taker, productKind=OPTION, flowKind=RFQ)");
        console2.log("      If maker is rebate-tier: FeeRebatedV2(maker, productKind=OPTION, flowKind=RFQ)");
        console2.log(" 5. Verify via backend: GET /admin/fees/onchain?tx_hash=<tx>");
        console2.log(" 6. This script does NOT broadcast the trade.");
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (Inputs memory inputs) {
        inputs.feesManager = _envAddressOrZero("FEES_MANAGER_V2_ADDRESS");
        inputs.marginEngine = _envAddressOrZero("MARGIN_ENGINE");
        inputs.optionMatchingEngine = _envAddressOrZero("OPTION_MATCHING_ENGINE");
        inputs.maker = _envAddressOrZero("MAKER_ACCOUNT");
        inputs.taker = _envAddressOrZero("TAKER_ACCOUNT");
        inputs.settlementAsset = _envAddressOrZero("SETTLEMENT_ASSET");
        inputs.premiumNative = vm.envOr("RFQ_PREMIUM_NATIVE", uint256(100_000));
        inputs.expectFlowRfq = vm.envOr("EXPECTED_FLOW_KIND_RFQ", true);
        (inputs.expectedMakerFee, inputs.expectedMakerFeeSet) = _envUintOptional("EXPECTED_MAKER_FEE_NATIVE");
        (inputs.expectedTakerFee, inputs.expectedTakerFeeSet) = _envUintOptional("EXPECTED_TAKER_FEE_NATIVE");
    }

    function _validateInputs(Inputs memory inputs) internal pure {
        if (inputs.feesManager == address(0)) revert FeesManagerUnset();
        if (inputs.marginEngine == address(0)) revert MarginEngineUnset();
        if (inputs.optionMatchingEngine == address(0)) revert OptionMatchingEngineUnset();
        if (inputs.maker == address(0)) revert MakerAccountUnset();
        if (inputs.taker == address(0)) revert TakerAccountUnset();
        if (inputs.settlementAsset == address(0)) revert SettlementAssetUnset();
    }

    function _snapshot(Inputs memory inputs) internal view returns (Snapshot memory snap) {
        FeesManagerV2 fm = FeesManagerV2(inputs.feesManager);

        snap.marginEngineCodeSize = inputs.marginEngine.code.length;
        snap.optionMatchingEngineCodeSize = inputs.optionMatchingEngine.code.length;

        try IUseFeesManagerV2(inputs.marginEngine).useFeesManagerV2() returns (bool ok) {
            snap.marginUsesFeesManagerV2 = ok;
        } catch {}
        try IUseFeesManagerV2(inputs.marginEngine).feesManagerV2() returns (address fmAddr) {
            snap.marginFeesManagerV2 = fmAddr;
        } catch {}

        snap.isFeeConsumerMargin = fm.isFeeConsumer(inputs.marginEngine);
        snap.rebateBudget = fm.rebateBudget(inputs.settlementAsset);

        snap.makerTier = fm.currentTier(inputs.maker);
        snap.takerTier = fm.currentTier(inputs.taker);

        IFeesManagerV2.ProductFeeProfilePpm memory makerProfile =
            fm.getFeeProfile(snap.makerTier, IFeesManagerV2.ProductKind.OPTION);
        IFeesManagerV2.ProductFeeProfilePpm memory takerProfile =
            fm.getFeeProfile(snap.takerTier, IFeesManagerV2.ProductKind.OPTION);
        snap.orderbookMakerPpmAtMakerTier = makerProfile.makerPpm;
        snap.orderbookTakerPpmAtTakerTier = takerProfile.takerPpm;

        IFeesManagerV2.RfqDiscountProfile memory makerRfq =
            fm.getRfqDiscountProfile(snap.makerTier, IFeesManagerV2.ProductKind.OPTION);
        IFeesManagerV2.RfqDiscountProfile memory takerRfq =
            fm.getRfqDiscountProfile(snap.takerTier, IFeesManagerV2.ProductKind.OPTION);
        snap.rfqMakerDiscountPpmAtMakerTier = makerRfq.makerDiscountPpm;
        snap.rfqTakerDiscountPpmAtTakerTier = takerRfq.takerDiscountPpm;

        snap.rfqMakerQuote = fm.quoteFees(
            inputs.maker,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.RFQ,
            true,
            inputs.settlementAsset,
            inputs.premiumNative
        );
        snap.rfqTakerQuote = fm.quoteFees(
            inputs.taker,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.RFQ,
            false,
            inputs.settlementAsset,
            inputs.premiumNative
        );
        snap.orderbookMakerQuote = fm.quoteFees(
            inputs.maker,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            true,
            inputs.settlementAsset,
            inputs.premiumNative
        );
        snap.orderbookTakerQuote = fm.quoteFees(
            inputs.taker,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            false,
            inputs.settlementAsset,
            inputs.premiumNative
        );

        if (snap.rfqMakerQuote.isRebate) {
            snap.rebateBudgetDeltaIfMakerRebates = snap.rfqMakerQuote.feeAmount;
        }
    }

    function _validatePreflight(Inputs memory inputs, Snapshot memory snap) internal pure {
        if (snap.marginEngineCodeSize == 0) revert MarginEngineHasNoCode(inputs.marginEngine);
        if (snap.optionMatchingEngineCodeSize == 0) {
            revert OptionMatchingEngineHasNoCode(inputs.optionMatchingEngine);
        }
        if (!snap.marginUsesFeesManagerV2) revert MarginEngineDoesNotUseFeesManagerV2();
        if (snap.marginFeesManagerV2 != inputs.feesManager) {
            revert MarginEngineFeesManagerMismatch(snap.marginFeesManagerV2, inputs.feesManager);
        }
        if (!snap.isFeeConsumerMargin) revert MarginEngineNotFeeConsumer();

        if (inputs.expectFlowRfq) {
            if (snap.rfqMakerQuote.flow != IFeesManagerV2.FlowKind.RFQ) {
                revert RfqMakerQuoteFlowKindMismatch(snap.rfqMakerQuote.flow);
            }
            if (snap.rfqTakerQuote.flow != IFeesManagerV2.FlowKind.RFQ) {
                revert RfqTakerQuoteFlowKindMismatch(snap.rfqTakerQuote.flow);
            }
        }
        if (inputs.expectedMakerFeeSet && snap.rfqMakerQuote.feeAmount != inputs.expectedMakerFee) {
            revert RfqMakerFeeMismatch(inputs.expectedMakerFee, snap.rfqMakerQuote.feeAmount);
        }
        if (inputs.expectedTakerFeeSet && snap.rfqTakerQuote.feeAmount != inputs.expectedTakerFee) {
            revert RfqTakerFeeMismatch(inputs.expectedTakerFee, snap.rfqTakerQuote.feeAmount);
        }

        if (snap.rfqMakerQuote.isRebate && snap.rebateBudget < snap.rfqMakerQuote.feeAmount) {
            revert RebateBudgetTooLowForMakerRebate(snap.rebateBudget, snap.rfqMakerQuote.feeAmount);
        }
    }

    function _logInputs(Inputs memory inputs) internal pure {
        console2.log("V2G-P1 OPTION RFQ fees preflight");
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        console2.log("MARGIN_ENGINE", inputs.marginEngine);
        console2.log("OPTION_MATCHING_ENGINE", inputs.optionMatchingEngine);
        console2.log("MAKER_ACCOUNT", inputs.maker);
        console2.log("TAKER_ACCOUNT", inputs.taker);
        console2.log("SETTLEMENT_ASSET", inputs.settlementAsset);
        console2.log("RFQ_PREMIUM_NATIVE", inputs.premiumNative);
        console2.log("EXPECTED_FLOW_KIND_RFQ", inputs.expectFlowRfq);
        if (inputs.expectedMakerFeeSet) console2.log("EXPECTED_MAKER_FEE_NATIVE", inputs.expectedMakerFee);
        if (inputs.expectedTakerFeeSet) console2.log("EXPECTED_TAKER_FEE_NATIVE", inputs.expectedTakerFee);
    }

    function _logSnapshot(Snapshot memory snap) internal pure {
        console2.log("State snapshot:");
        console2.log(" MarginEngine.useFeesManagerV2()", snap.marginUsesFeesManagerV2);
        console2.log(" MarginEngine.feesManagerV2()", snap.marginFeesManagerV2);
        console2.log(" FeesManagerV2.isFeeConsumer(MarginEngine)", snap.isFeeConsumerMargin);
        console2.log(" MarginEngine code size", snap.marginEngineCodeSize);
        console2.log(" OptionMatchingEngine code size", snap.optionMatchingEngineCodeSize);
        console2.log(" maker tier", snap.makerTier);
        console2.log(" taker tier", snap.takerTier);
        console2.log(" OPTION ORDERBOOK makerPpm at maker tier");
        console2.logInt(snap.orderbookMakerPpmAtMakerTier);
        console2.log(" OPTION ORDERBOOK takerPpm at taker tier");
        console2.logInt(snap.orderbookTakerPpmAtTakerTier);
        console2.log(" OPTION RFQ maker discount ppm at maker tier", snap.rfqMakerDiscountPpmAtMakerTier);
        console2.log(" OPTION RFQ taker discount ppm at taker tier", snap.rfqTakerDiscountPpmAtTakerTier);
        console2.log(" RFQ maker quote feeAmount", snap.rfqMakerQuote.feeAmount);
        console2.log(" RFQ maker quote isRebate", snap.rfqMakerQuote.isRebate);
        console2.log(" RFQ maker quote appliedPpm");
        console2.logInt(snap.rfqMakerQuote.appliedPpm);
        console2.log(" RFQ taker quote feeAmount", snap.rfqTakerQuote.feeAmount);
        console2.log(" RFQ taker quote isRebate", snap.rfqTakerQuote.isRebate);
        console2.log(" RFQ taker quote appliedPpm");
        console2.logInt(snap.rfqTakerQuote.appliedPpm);
        console2.log(" ORDERBOOK maker quote feeAmount (reference)", snap.orderbookMakerQuote.feeAmount);
        console2.log(" ORDERBOOK taker quote feeAmount (reference)", snap.orderbookTakerQuote.feeAmount);
        console2.log(" rebateBudget(settlementAsset)", snap.rebateBudget);
        console2.log(" rebateBudgetDeltaIfMakerRebates", snap.rebateBudgetDeltaIfMakerRebates);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }

    function _envUintOptional(string memory name) internal view returns (uint256, bool) {
        if (!vm.envExists(name)) return (0, false);
        return (vm.envUint(name), true);
    }
}
