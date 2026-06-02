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

interface IMatchingEngineGetter {
    function matchingEngine() external view returns (address);
}

/// @title SmokeOptionRfqV2FeesExecute
/// @notice V2G-P2 OPTION RFQ smoke executor. Safe-by-default: refuses
///         to broadcast unless `SMOKE_OPTION_RFQ_V2_FEES_EXECUTE_CONFIRM=true`,
///         and ALWAYS refuses mainnet. When confirmed, the script
///         derives the canonical Tier-2 taker + Tier-4 maker addresses
///         from `OPTION_SMOKE_BUYER_PRIVATE_KEY` /
///         `OPTION_SMOKE_SELLER_PRIVATE_KEY`, signs the EIP-712 RFQ
///         digest with each key, and calls
///         `OptionMatchingEngine.executeRfqTrade(t, buyerSig, sellerSig)`
///         from the executor (Foundry keystore — `--account`).
/// @dev
///   The V2G-P1 scaffold's digest + preflight logic is preserved
///   verbatim; the V2G-P2 patch only adds the signing + broadcast
///   block, plus address-assertion + executor-check.  The script
///   still does NOT touch FeesManagerV2 / MarginEngine /
///   OptionMatchingEngine state directly — every state change
///   flows through `executeRfqTrade(...)` and the protocol's
///   authorized paths.
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
    /// @notice V2G-P2 — `OPTION_SMOKE_BUYER_PRIVATE_KEY` not set or zero.
    error SmokeBuyerKeyNotSet();
    /// @notice V2G-P2 — `OPTION_SMOKE_SELLER_PRIVATE_KEY` not set or zero.
    error SmokeSellerKeyNotSet();
    /// @notice V2G-P2 — derived buyer address does not match the
    ///         {Inputs}.buyer slot derived from MAKER/TAKER + buyerIsMaker.
    error BuyerKeyAddressMismatch(address derived, address expected);
    /// @notice V2G-P2 — derived seller address does not match.
    error SellerKeyAddressMismatch(address derived, address expected);
    /// @notice V2G-P2 — the OME does not consider the broadcast signer
    ///         an authorized executor.
    error DeployerNotExecutor(address signer);
    /// @notice V2G-P2 — the OME does not point at the configured
    ///         MarginEngine.
    error OmeMarginEngineMismatch(address omeMarginEngine, address expected);
    /// @notice V2G-P2 — the MarginEngine does not have the OME as its
    ///         authorized matching engine.
    error MarginEngineMatchingEngineMismatch(address meMatching, address expectedOme);

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external {
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
        _validateWiring(inputs);

        _executeRfqSmoke(inputs);
    }

    /// @notice V2G-P2 broadcast leg. Split into its own function so the
    ///         locals don't share `run()`'s stack frame (avoids the
    ///         via-IR stack-too-deep on the trade struct + signature
    ///         tuple expansion).
    function _executeRfqSmoke(Inputs memory inputs) internal {
        // V2G-P2 — derive the maker/taker signer addresses from the
        // smoke private keys.  These keys are read from env (never
        // logged); only the derived addresses are surfaced.
        uint256 buyerPk = vm.envOr("OPTION_SMOKE_BUYER_PRIVATE_KEY", uint256(0));
        uint256 sellerPk = vm.envOr("OPTION_SMOKE_SELLER_PRIVATE_KEY", uint256(0));
        if (buyerPk == 0) revert SmokeBuyerKeyNotSet();
        if (sellerPk == 0) revert SmokeSellerKeyNotSet();

        _assertSignerMatch(inputs, buyerPk, sellerPk);

        OptionMatchingEngine.OptionRfqTrade memory t = _buildOptionRfqTrade(inputs);
        bytes32 digest = OptionMatchingEngine(inputs.optionMatchingEngine).hashRfqTrade(t);

        // Cross-check against the local digest reconstruction. If they
        // diverge that's a script bug — refuse to proceed.
        require(_rfqDigest(inputs) == digest, "rfq digest divergence");

        bytes memory buyerSig = _signDigest(buyerPk, digest);
        bytes memory sellerSig = _signDigest(sellerPk, digest);

        _logInputs(inputs);
        _logDigestPayload(inputs, digest);
        _logSignerSummary(vm.addr(buyerPk), vm.addr(sellerPk));

        // Single broadcast — the executor is whoever Foundry resolves via
        // `--account <keystore>` / `--sender` / `--unlocked`.  No env
        // private key is read for the broadcast leg.  The OME's
        // `onlyExecutor` gate already verified in {_validateWiring}.
        vm.startBroadcast();
        OptionMatchingEngine(inputs.optionMatchingEngine).executeRfqTrade(t, buyerSig, sellerSig);
        vm.stopBroadcast();

        _logPostBroadcast(t);
    }

    function _assertSignerMatch(Inputs memory inputs, uint256 buyerPk, uint256 sellerPk) internal view {
        address expectedBuyer = inputs.buyerIsMaker ? inputs.maker : inputs.taker;
        address expectedSeller = inputs.buyerIsMaker ? inputs.taker : inputs.maker;
        address derivedBuyer = vm.addr(buyerPk);
        address derivedSeller = vm.addr(sellerPk);
        if (derivedBuyer != expectedBuyer) revert BuyerKeyAddressMismatch(derivedBuyer, expectedBuyer);
        if (derivedSeller != expectedSeller) revert SellerKeyAddressMismatch(derivedSeller, expectedSeller);
    }

    function _buildOptionRfqTrade(Inputs memory inputs)
        internal
        view
        returns (OptionMatchingEngine.OptionRfqTrade memory t)
    {
        t.intentId = inputs.intentId;
        t.buyer = inputs.buyerIsMaker ? inputs.maker : inputs.taker;
        t.seller = inputs.buyerIsMaker ? inputs.taker : inputs.maker;
        t.optionId = inputs.optionId;
        t.underlying = inputs.underlying;
        t.settlementAsset = inputs.settlementAsset;
        t.expiry = inputs.expiry;
        t.strike1e8 = inputs.strike1e8;
        t.isCall = inputs.isCall;
        t.contractSize1e8 = inputs.contractSize1e8;
        t.quantity = inputs.quantity;
        t.premiumPerContract = inputs.premiumPerContract;
        t.buyerIsMaker = inputs.buyerIsMaker;
        t.buyerNonce = uint256(inputs.buyerNonce);
        t.sellerNonce = uint256(inputs.sellerNonce);
        t.deadline = block.timestamp + inputs.deadlineSeconds;
    }

    function _signDigest(uint256 pk, bytes32 digest) internal view returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    function _logPostBroadcast(OptionMatchingEngine.OptionRfqTrade memory t) internal pure {
        console2.log("V2G-P2 RFQ smoke broadcast complete.");
        console2.log(" intentId            ", uint256(t.intentId));
        console2.log(" buyer  (RFQ side)   ", t.buyer);
        console2.log(" seller (RFQ side)   ", t.seller);
        console2.log(" quantity            ", t.quantity);
        console2.log(" premiumPerContract  ", t.premiumPerContract);
        console2.log("Operator next steps:");
        console2.log(" 1. Capture the on-chain tx hash from forge output.");
        console2.log(" 2. Verify FeeChargedV2 + FeeRebatedV2 events with flow=RFQ.");
        console2.log(" 3. Verify rebateBudget decreased on FM-V2 by the expected rebate amount.");
        console2.log(" 4. Verify backend /admin/fees/onchain?tx_hash=<hash> echoes the V2 fee schedule.");
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

    /// @notice V2G-P2 — assert the on-chain wiring matches what the
    ///         broadcast assumes:
    ///          - OME.marginEngine() == configured MarginEngine
    ///          - MarginEngine.matchingEngine() == configured OME
    ///          - OME.isExecutor(<broadcast signer>) == true
    ///         The broadcast signer is read from env `DEPLOYER_ADDRESS`
    ///         (defaulting to the canonical V2 deployer EOA), which
    ///         matches the address Foundry will use under
    ///         `--account deopt-deployer --sender 0xc35F…3C27`.
    function _validateWiring(Inputs memory inputs) internal view {
        OptionMatchingEngine ome = OptionMatchingEngine(inputs.optionMatchingEngine);
        address omeMargin = address(ome.marginEngine());
        if (omeMargin != inputs.marginEngine) revert OmeMarginEngineMismatch(omeMargin, inputs.marginEngine);

        address meMatching = IMatchingEngineGetter(inputs.marginEngine).matchingEngine();
        if (meMatching != inputs.optionMatchingEngine) {
            revert MarginEngineMatchingEngineMismatch(meMatching, inputs.optionMatchingEngine);
        }

        address signer = vm.envOr("DEPLOYER_ADDRESS", address(0xc35F7A8A103A9A4464adfaa76B9B514093D23C27));
        if (!ome.isExecutor(signer)) revert DeployerNotExecutor(signer);
    }

    function _logSignerSummary(address derivedBuyer, address derivedSeller) internal pure {
        console2.log("V2G-P2 RFQ smoke signers:");
        console2.log("  buyer addr  (Tier2 taker) ", derivedBuyer);
        console2.log("  seller addr (Tier4 maker) ", derivedSeller);
        console2.log("  signatures composed from OPTION_SMOKE_*_PRIVATE_KEY env (never logged)");
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
