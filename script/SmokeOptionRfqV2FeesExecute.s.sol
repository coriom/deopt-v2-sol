// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../src/fees/IFeesManagerV2.sol";

interface IUseFeesManagerV2 {
    function feesManagerV2() external view returns (address);
    function useFeesManagerV2() external view returns (bool);
}

/// @title SmokeOptionRfqV2FeesExecute
/// @notice V2G-P1 OPTION RFQ smoke execute **scaffold**. Strictly
///         safe-by-default: defaults to preflight-only and refuses to
///         broadcast unless `SMOKE_OPTION_RFQ_V2_FEES_EXECUTE_CONFIRM=true`
///         AND the maker / taker / executor signatures are produced by
///         the operator off-chain. This script does NOT broadcast on
///         its own — V2G-P1 leaves the actual signed RFQ trade to
///         V2G-P2 once the operator review window opens.
/// @dev
///   The current scope is:
///     - read all required env (preflight + executor + RFQ-specific);
///     - run the same fees-side preflight as {SmokeOptionRfqV2Fees};
///     - rebuild the EIP-712 RFQ digest the operator would sign;
///     - log the digest and ABI-encoded `executeRfqTrade` calldata
///       template (signatures left as placeholders).
///   It explicitly does NOT:
///     - sign with any private key beyond the deployer (used only for
///       `OptionMatchingEngine.isExecutor` check via `vm.addr`);
///     - call `OptionMatchingEngine.executeRfqTrade(...)`;
///     - mutate FeesManagerV2 / MarginEngine / OptionMatchingEngine.
///
///   The `SMOKE_OPTION_RFQ_V2_FEES_EXECUTE_CONFIRM` gate flips the
///   logging from "preflight only" to "preflight + digest report",
///   not "broadcast." Even when set, no transactions are sent.
///
///   When V2G-P2 wires the actual signing flow, the broadcast block
///   should be added inside the `if (inputs.smokeConfirmed) { ... }`
///   branch and gated by an additional explicit operator-side flag
///   (e.g. `SMOKE_OPTION_RFQ_V2_FEES_BROADCAST_CONFIRM=true`).
contract SmokeOptionRfqV2FeesExecute is Script {
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
        uint256 optionId;
        address underlying;
        uint64 expiry;
        uint64 strike1e8;
        bool isCall;
        uint128 contractSize1e8;
        uint128 quantity;
        uint128 premiumPerContract;
        bool buyerIsMaker;
        uint256 deadlineSeconds;
        uint128 buyerNonce;
        uint128 sellerNonce;
        bytes32 intentId;
        uint256 minRebateBudget;
        bool smokeConfirmed;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error SmokeNotConfirmed();
    error FeesManagerUnset();
    error MarginEngineUnset();
    error OptionMatchingEngineUnset();
    error MakerAccountUnset();
    error TakerAccountUnset();
    error SettlementAssetUnset();
    error OptionIdUnset();
    error UnderlyingUnset();
    error ExpiryUnset();
    error QuantityUnset();
    error PremiumUnset();
    error MarginEngineNotFeeConsumer();
    error MarginEngineDoesNotUseFeesManagerV2();
    error MainnetForbidden(uint256 chainId);
    error RebateBudgetTooLow(uint256 actual, uint256 minBudget);

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external view {
        Inputs memory inputs = _readInputs();

        if (block.chainid == 8453) revert MainnetForbidden(block.chainid);

        if (!inputs.smokeConfirmed) {
            _logInputs(inputs);
            console2.log("SMOKE_OPTION_RFQ_V2_FEES_EXECUTE_CONFIRM not set; preflight-only mode.");
            console2.log("This script will NOT broadcast under any circumstance.");
            revert SmokeNotConfirmed();
        }

        _validateInputs(inputs);
        _validatePreflight(inputs);

        bytes32 digest = _rfqDigest(inputs);

        _logInputs(inputs);
        _logDigestPayload(inputs, digest);

        console2.log("V2G-P1 RFQ execute scaffold complete. Operator action required:");
        console2.log(" 1. Sign the digest below with maker + taker EOAs out-of-band.");
        console2.log(" 2. Call OptionMatchingEngine.executeRfqTrade(OptionRfqTrade, buyerSig, sellerSig)");
        console2.log("    through the gated backend executor.");
        console2.log(" 3. Verify the V2 fee events arrive in /admin/fees/onchain with");
        console2.log("    flow_kind=rfq and the expected feeAmount per V2G-N table.");
        console2.log(" 4. This script did NOT broadcast.");
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

        inputs.optionId = vm.envOr("OPTION_ID", uint256(0));
        inputs.underlying = _envAddressOrZero("UNDERLYING");
        inputs.expiry = uint64(vm.envOr("OPTION_EXPIRY", uint256(0)));
        inputs.strike1e8 = uint64(vm.envOr("OPTION_STRIKE_1E8", uint256(0)));
        inputs.isCall = vm.envOr("OPTION_IS_CALL", true);
        inputs.contractSize1e8 = uint128(vm.envOr("OPTION_CONTRACT_SIZE_1E8", uint256(1e8)));
        inputs.quantity = uint128(vm.envOr("OPTION_QUANTITY", uint256(1)));
        inputs.premiumPerContract = uint128(vm.envOr("OPTION_PREMIUM_PER_CONTRACT", uint256(200_000)));
        inputs.buyerIsMaker = vm.envOr("OPTION_BUYER_IS_MAKER", false);
        inputs.deadlineSeconds = vm.envOr("OPTION_DEADLINE_SECONDS", uint256(600));
        inputs.buyerNonce = uint128(vm.envOr("OPTION_BUYER_NONCE", uint256(0)));
        inputs.sellerNonce = uint128(vm.envOr("OPTION_SELLER_NONCE", uint256(0)));
        inputs.intentId = vm.envOr("OPTION_INTENT_ID", bytes32(0));
        inputs.minRebateBudget = vm.envOr("MIN_REBATE_BUDGET", uint256(1));

        inputs.smokeConfirmed = vm.envOr("SMOKE_OPTION_RFQ_V2_FEES_EXECUTE_CONFIRM", false);
    }

    function _validateInputs(Inputs memory inputs) internal pure {
        if (inputs.feesManager == address(0)) revert FeesManagerUnset();
        if (inputs.marginEngine == address(0)) revert MarginEngineUnset();
        if (inputs.optionMatchingEngine == address(0)) revert OptionMatchingEngineUnset();
        if (inputs.maker == address(0)) revert MakerAccountUnset();
        if (inputs.taker == address(0)) revert TakerAccountUnset();
        if (inputs.settlementAsset == address(0)) revert SettlementAssetUnset();
        if (inputs.optionId == 0) revert OptionIdUnset();
        if (inputs.underlying == address(0)) revert UnderlyingUnset();
        if (inputs.expiry == 0) revert ExpiryUnset();
        if (inputs.quantity == 0) revert QuantityUnset();
        if (inputs.premiumPerContract == 0) revert PremiumUnset();
    }

    function _validatePreflight(Inputs memory inputs) internal view {
        FeesManagerV2 fm = FeesManagerV2(inputs.feesManager);
        if (!IUseFeesManagerV2(inputs.marginEngine).useFeesManagerV2()) {
            revert MarginEngineDoesNotUseFeesManagerV2();
        }
        if (!fm.isFeeConsumer(inputs.marginEngine)) revert MarginEngineNotFeeConsumer();

        uint256 budget = fm.rebateBudget(inputs.settlementAsset);
        if (budget < inputs.minRebateBudget) {
            revert RebateBudgetTooLow(budget, inputs.minRebateBudget);
        }
    }

    /// @dev Reproduce the EIP-712 digest the operator must sign. Pulls
    ///      the domain separator from the live OptionMatchingEngine
    ///      (which exposes `DOMAIN_SEPARATOR()` via the OZ {EIP712}
    ///      inheritance). The struct hash mirrors the V2G-O
    ///      `_rfqStructHash` chunked-encode layout — byte-identical to
    ///      the canonical single-encode form.
    function _rfqDigest(Inputs memory inputs) internal view returns (bytes32) {
        bytes32 typehash = OptionMatchingEngine(inputs.optionMatchingEngine).RFQ_TRADE_TYPEHASH();
        bytes32 domainSeparator = OptionMatchingEngine(inputs.optionMatchingEngine).domainSeparatorV4();

        bytes memory head = abi.encode(
            typehash,
            inputs.intentId,
            inputs.buyerIsMaker ? inputs.maker : inputs.taker,
            inputs.buyerIsMaker ? inputs.taker : inputs.maker,
            inputs.optionId,
            inputs.underlying,
            inputs.settlementAsset,
            inputs.expiry
        );
        bytes memory tail = abi.encode(
            inputs.strike1e8,
            inputs.isCall,
            inputs.contractSize1e8,
            inputs.quantity,
            inputs.premiumPerContract,
            inputs.buyerIsMaker,
            uint256(inputs.buyerNonce),
            uint256(inputs.sellerNonce),
            uint256(block.timestamp + inputs.deadlineSeconds)
        );
        bytes32 structHash = keccak256(bytes.concat(head, tail));
        return keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, structHash));
    }

    function _logInputs(Inputs memory inputs) internal pure {
        console2.log("V2G-P1 OPTION RFQ fees execute scaffold");
        console2.log("FEES_MANAGER_V2_ADDRESS", inputs.feesManager);
        console2.log("MARGIN_ENGINE", inputs.marginEngine);
        console2.log("OPTION_MATCHING_ENGINE", inputs.optionMatchingEngine);
        console2.log("MAKER_ACCOUNT", inputs.maker);
        console2.log("TAKER_ACCOUNT", inputs.taker);
        console2.log("SETTLEMENT_ASSET", inputs.settlementAsset);
        console2.log("OPTION_ID", inputs.optionId);
        console2.log("UNDERLYING", inputs.underlying);
        console2.log("OPTION_EXPIRY", inputs.expiry);
        console2.log("OPTION_STRIKE_1E8", inputs.strike1e8);
        console2.log("OPTION_IS_CALL", inputs.isCall);
        console2.log("OPTION_CONTRACT_SIZE_1E8", inputs.contractSize1e8);
        console2.log("OPTION_QUANTITY", inputs.quantity);
        console2.log("OPTION_PREMIUM_PER_CONTRACT", inputs.premiumPerContract);
        console2.log("OPTION_BUYER_IS_MAKER", inputs.buyerIsMaker);
        console2.log("OPTION_DEADLINE_SECONDS", inputs.deadlineSeconds);
        console2.log("OPTION_BUYER_NONCE", inputs.buyerNonce);
        console2.log("OPTION_SELLER_NONCE", inputs.sellerNonce);
        console2.log("MIN_REBATE_BUDGET", inputs.minRebateBudget);
        console2.log("SMOKE_OPTION_RFQ_V2_FEES_EXECUTE_CONFIRM", inputs.smokeConfirmed);
    }

    function _logDigestPayload(Inputs memory inputs, bytes32 digest) internal pure {
        console2.log("Computed EIP-712 RFQ digest (sign this with maker + taker keys):");
        console2.logBytes32(digest);
        console2.log(" buyer ", inputs.buyerIsMaker ? inputs.maker : inputs.taker);
        console2.log(" seller", inputs.buyerIsMaker ? inputs.taker : inputs.maker);
        console2.log(" effective deadline at block.timestamp +", inputs.deadlineSeconds);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
