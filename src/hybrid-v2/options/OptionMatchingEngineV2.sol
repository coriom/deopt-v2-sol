// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ReplayAndEpochController} from "../security/ReplayAndEpochController.sol";
import {IntentHash} from "../libraries/IntentHash.sol";
import {Versions} from "../libraries/Versions.sol";

import {IOptionMatchingEngine} from "../interfaces/IOptionMatchingEngine.sol";
import {IOptionExecutionFeeHook} from "../interfaces/IOptionExecutionFeeHook.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {IOptionsPositionsLedger} from "../interfaces/IOptionsPositionsLedger.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {IOptionsRiskProvider} from "../interfaces/IOptionsRiskProvider.sol";

import {CollateralVaultV2RiskIntegrated} from "../risk/CollateralVaultV2RiskIntegrated.sol";
import {MarginEngineV2} from "../margin/MarginEngineV2.sol";
import {OptionOrderTypes} from "./OptionOrderTypes.sol";

/// @title OptionMatchingEngineV2
/// @notice WP-08B — Concrete Options execution engine. Atomically composes
///         Registry identity, EIP-712 signature envelopes, WP-05 replay
///         protection, canonical Options position mutation, Vault-scoped
///         Options premium transfer, engine-owned margin reservation, and
///         post-state MarginEngine health checks.
/// @dev
///  Non-goals (frozen for this milestone):
///   - No on-chain order book. No global order iteration. No unbounded
///     batching. One matched pair per external call.
///   - No RFQ. No multi-leg execution. No cross-product execution.
///   - No settlement / exercise / liquidation execution.
///   - No fee/rebate DIRECT Vault mutation — fees are validated + emitted
///     through the mandatory `IOptionExecutionFeeHook`. Concrete fee
///     integration (Vault-side `applyFeeDebit` + `applyRebateCredit`) lands
///     with the future FeesManager V2 milestone.
///   - No on-chain filled-quantity accumulator: PF-2 semantics — each
///     signed intent is a SINGLE EXACT FILL of `quantity1e8`. Nonce
///     consumed per intent.
///
///  Frozen semantics:
///   - Buyer = SIDE_LONG, seller = SIDE_SHORT. Every matched pair MUST have
///     opposite sides.
///   - Buyer and seller MAY belong to different owners.
///   - Identical subKey self-trade is REJECTED (single subKey cannot be
///     both sides).
///   - Sibling-subaccount trade (same-owner, distinct subaccounts) is
///     REJECTED in V1. Cross-owner trade REQUIRED for real market activity.
///   - Roles are exchanged: one side signs `role = MAKER`, the other signs
///     `role = TAKER`. Post-only orders MUST sign `role = MAKER`.
///   - Both counterparties MUST sign the same `pricePerContract1e8` and
///     `quantity1e8`. The engine does NOT compute an "execution premium"
///     from independent limits — the signed price IS the execution price.
///   - Both signed `limitPricePerContract1e8` values MUST accept the
///     signed price (buyer: price ≤ limit; seller: price ≥ limit).
///
///  Atomicity (Part P):
///   Order inside `executeMatch`:
///     1. `nonReentrant`.
///     2. Not paused.
///     3. Envelope binding + payload-hash validation for both sides.
///     4. EOA + ERC-1271 signature verification via OZ SignatureChecker.
///     5. Deadline + epoch freshness for both sides.
///     6. Order compatibility (series, premium token, side, price,
///        quantity, TIF, role, self-trade check).
///     7. Series metadata resolution (via `IOptionsRiskProvider`) — active,
///        not expired, contractSize1e8 == 1e8, settlementAsset == QUOTE_TOKEN.
///     8. Fee hook quote for both sides (V1: rebate MUST be zero).
///     9. Nonce consumption + intent consumption for both sides.
///    10. Ledger `applyFill` for buyer (long).
///    11. Ledger `applyFill` for seller (short).
///    12. Vault `applyOptionPremiumTransfer(buyerSubKey, sellerSubKey,
///        premiumToken, totalPremium)` — atomic entitlement swap. Buyer's
///        AVAILABLE balance is decremented (never locked collateral).
///    13. Compute seller-side IM in native premium-token units via
///        MarginEngine's witness view; adjust `Vault.applyLock` on the
///        seller's engine reservation by the DELTA between target and
///        current per-engine reservation.
///    14. Buyer-side IM (long-only in V1 contributes 0 to portfolio margin,
///        so the buyer's target reservation is 0 — but the code still
///        walks the buyer's witness for the health check).
///    15. MarginEngine `isHealthy` for BOTH sides on POST-STATE witness.
///    16. Emit `OptionOrderPairExecuted`.
///   Any downstream revert unwinds the entire transaction (Solidity
///   atomicity). No partial mutation can survive.
///
///  Reservation policy (Part K verdict
///  `OPTION_MARGIN_RESERVATION_SERIES_SETTLEMENT_TOKEN`):
///   - Reservations are held in the series' `settlementAsset`, which for
///     V1 MUST equal the RiskModule's frozen `QUOTE_TOKEN`.
///   - Target reservation = IM in 1e18 quote units → scaled DOWN to native
///     token units by `10^(18 - quoteDecimals)`. Rounded UP so the
///     reservation is at LEAST the required IM.
///   - Only the SELLER-side reservation is meaningful in V1 (long
///     positions have zero portfolio-margin contribution).
///   - The engine adjusts its OWN reservation via `applyLock` (deltas) or
///     `applyUnlock` (deltas). It never touches another engine's slot.
contract OptionMatchingEngineV2 is IOptionMatchingEngine, ReplayAndEpochController, ReentrancyGuard {
    /// @notice Canonical Vault. Same object every consumer of the same
    ///         deployment sees. Immutable at construction.
    ICollateralVault public immutable VAULT;

    /// @notice Canonical `IRiskModule` sourced directly from the Vault's
    ///         `RISK_MODULE()` at construction. Enforces RM-1
    ///         (`SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT`).
    IRiskModule public immutable RISK_MODULE;
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical Options positions ledger sourced from the
    ///         MarginEngine's binding.
    IOptionsPositionsLedger public immutable OPTIONS_LEDGER;

    /// @notice Canonical MarginEngine binding. Used ONLY for read-only
    ///         `isHealthy` + `initialMargin1e18` witness-checked views.
    IMarginEngine public immutable MARGIN_ENGINE;

    /// @notice Concrete risk provider sourced from the RiskModule. Provides
    ///         series metadata for pre-execution validation.
    IOptionsRiskProvider public immutable RISK_PROVIDER;

    /// @notice Single deployment-scoped quote / settlement numeraire token,
    ///         sourced from the RiskModule.
    address public immutable QUOTE_TOKEN;

    /// @notice Cached decimals of `QUOTE_TOKEN` sourced from the RiskModule.
    uint8 public immutable QUOTE_DECIMALS;

    /// @notice Mandatory fee hook (V1 = FEES-2 abstract boundary). Concrete
    ///         zero-fee production defaults are NOT permitted; this address
    ///         is constructor-immutable.
    IOptionExecutionFeeHook public immutable FEE_HOOK;

    /// @notice Engine version tag for governance + tooling.
    uint16 public immutable ENGINE_VERSION;

    /// @notice EIP-712 domain name — mirrored on ReplayAndEpochController.
    string internal constant EIP712_NAME = "DeOptV2-OptionMatchingEngine";

    /// @notice EIP-712 domain version — mirrored on ReplayAndEpochController.
    string internal constant EIP712_VERSION = "1";

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Guardian-only pause flag (D-C-04 shape). No governance path
    ///         may fabricate a trade — this flag is a REJECTION shortcut
    ///         only. It cannot mutate any economic state.
    bool public executionPaused;

    /// @notice Guardian address — capability-gated ONLY for pause.
    address public immutable GUARDIAN;

    /// @notice Governance address — capability-gated ONLY for guardian rotation.
    address public immutable GOVERNANCE;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param vault_        Canonical Vault. Constructor derives the
    ///                      RiskModule from this via `VaultRiskModuleConsumer`.
    /// @param marginEngine_ Concrete `MarginEngineV2` deployment. MUST bind
    ///                      the same Vault + RiskModule.
    /// @param feeHook_      Concrete `IOptionExecutionFeeHook` deployment.
    ///                      Zero-fee test hooks are acceptable in tests;
    ///                      production hook is FeesManager V2 adapter.
    /// @param guardian_     Guardian address permitted to set `executionPaused`.
    /// @param governance_   Governance address permitted to rotate the
    ///                      guardian only.
    /// @param engineVersion_ Engine version tag (non-zero).
    constructor(
        address vault_,
        address marginEngine_,
        address feeHook_,
        address guardian_,
        address governance_,
        uint16 engineVersion_
    ) ReplayAndEpochController(_readRegistry(vault_), EIP712_NAME, EIP712_VERSION) {
        if (marginEngine_ == address(0) || feeHook_ == address(0)) revert InvalidDependency();
        if (guardian_ == address(0) || governance_ == address(0)) revert InvalidDependency();
        if (engineVersion_ == 0) revert InvalidDependency();

        // Read RISK_MODULE from the Vault directly (RM-1 posture — same
        // pattern as `VaultRiskModuleConsumer`, inlined here because that
        // abstract collides with `ReplayAndEpochController.ARCHITECTURE_VERSION`).
        IRiskModule module = CollateralVaultV2RiskIntegrated(vault_).RISK_MODULE();
        if (address(module) == address(0)) revert InvalidDependency();

        MarginEngineV2 marginEngine = MarginEngineV2(marginEngine_);
        if (marginEngine.vault() != vault_) revert DependencyMismatch();
        if (marginEngine.riskModule() != address(module)) revert DependencyMismatch();

        IOptionsPositionsLedger ledger = marginEngine.OPTIONS_LEDGER();
        if (address(ledger) == address(0)) revert InvalidDependency();

        IOptionsRiskProvider provider = marginEngine.RISK_PROVIDER();
        if (address(provider) == address(0)) revert InvalidDependency();

        VAULT = ICollateralVault(vault_);
        RISK_MODULE = module;
        OPTIONS_LEDGER = ledger;
        MARGIN_ENGINE = IMarginEngine(marginEngine_);
        RISK_PROVIDER = provider;
        QUOTE_TOKEN = marginEngine.QUOTE_TOKEN();
        QUOTE_DECIMALS = marginEngine.QUOTE_DECIMALS();
        FEE_HOOK = IOptionExecutionFeeHook(feeHook_);
        GUARDIAN = guardian_;
        GOVERNANCE = governance_;
        ENGINE_VERSION = engineVersion_;
    }

    /// @dev Extract the Registry address from the Vault BEFORE the constructor
    ///      body runs so it can be passed to the `ReplayAndEpochController`
    ///      base initializer.
    function _readRegistry(address vault_) internal view returns (address) {
        if (vault_ == address(0)) revert InvalidDependency();
        return address(ICollateralVaultWithRegistry(vault_).REGISTRY());
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP-712 typed-data digest for a signed envelope. Public so
    ///         off-chain wallets and test harnesses can compute the exact
    ///         digest to sign without duplicating the domain separator.
    function hashSignedActionEnvelopeDigest(IntentHash.SignedActionEnvelope calldata envelope)
        external
        view
        returns (bytes32)
    {
        return _hashSignedActionEnvelopeDigest(envelope);
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Guardian-only immediate pause. Does NOT mutate any economic
    ///         state, only refuses new executions.
    function pauseExecution() external {
        if (msg.sender != GUARDIAN) revert InvalidDependency();
        executionPaused = true;
    }

    /// @notice Governance-only unpause (D-C-04 asymmetry: pause = guardian
    ///         OR governance immediate; unpause = governance only).
    function unpauseExecution() external {
        if (msg.sender != GOVERNANCE) revert InvalidDependency();
        executionPaused = false;
    }

    /// @dev Scratchpad packing every value derived during `executeMatch`
    ///      that would otherwise blow the stack. Held in memory so the
    ///      compiler can keep a small pointer on the stack and reach the
    ///      fields via SSA loads.
    struct ExecutionScratch {
        bytes32 buyerOrderHash;
        bytes32 sellerOrderHash;
        bytes32 buyerIntent;
        bytes32 sellerIntent;
        uint128 buyerFee;
        uint128 sellerFee;
        uint256 totalPremiumNative;
        bytes32 executionId;
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION ENTRYPOINT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOptionMatchingEngine
    function executeMatch(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        bytes calldata buyerSignature,
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        bytes calldata sellerSignature,
        OptionOrderTypes.OptionOrder calldata sellerOrder,
        uint256[] calldata buyerActiveSeriesIds,
        uint256[] calldata sellerActiveSeriesIds
    ) external nonReentrant returns (bytes32 executionId) {
        if (executionPaused) revert ExecutionPaused();
        ExecutionScratch memory s;

        _validateEnvelopes(buyerEnvelope, buyerOrder, sellerEnvelope, sellerOrder, s);
        _validateSignatures(buyerEnvelope, buyerSignature, sellerEnvelope, sellerSignature);

        _requireCompatibleOrders(buyerOrder, sellerOrder, buyerEnvelope.subKey, sellerEnvelope.subKey);
        _requireSeriesTradeable(buyerOrder.seriesId, buyerOrder.premiumToken);

        (s.buyerFee, s.sellerFee) = _quoteBothFees(buyerEnvelope.subKey, sellerEnvelope.subKey, buyerOrder);

        _consumeAllReplayState(buyerEnvelope, sellerEnvelope, s);

        _applyLedgerFills(buyerEnvelope.subKey, sellerEnvelope.subKey, buyerOrder);
        s.totalPremiumNative = _computeTotalPremiumNative(buyerOrder.quantity1e8, buyerOrder.pricePerContract1e8);
        if (s.totalPremiumNative > 0) {
            ICollateralVault(address(VAULT))
                .applyOptionPremiumTransfer(
                    buyerEnvelope.subKey, sellerEnvelope.subKey, buyerOrder.premiumToken, s.totalPremiumNative
                );
        }

        _syncSellerReservation(sellerEnvelope.subKey, sellerActiveSeriesIds, buyerOrder.premiumToken);

        if (!MARGIN_ENGINE.isHealthy(buyerEnvelope.subKey, buyerActiveSeriesIds)) {
            revert UnsafePostTradeMargin(buyerEnvelope.subKey);
        }
        if (!MARGIN_ENGINE.isHealthy(sellerEnvelope.subKey, sellerActiveSeriesIds)) {
            revert UnsafePostTradeMargin(sellerEnvelope.subKey);
        }

        s.executionId = keccak256(abi.encode(s.buyerIntent, s.sellerIntent, block.number, block.timestamp));
        _emitExecution(buyerEnvelope, sellerEnvelope, buyerOrder, sellerOrder, s);
        executionId = s.executionId;
    }

    /*//////////////////////////////////////////////////////////////
                    EXECUTION SUB-STEPS (STACK-FRIENDLY)
    //////////////////////////////////////////////////////////////*/

    function _validateEnvelopes(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        OptionOrderTypes.OptionOrder calldata sellerOrder,
        ExecutionScratch memory s
    ) internal view {
        _requireEnvelopeBindingValid(buyerEnvelope);
        _requireEnvelopeBindingValid(sellerEnvelope);
        s.buyerOrderHash = OptionOrderTypes.hashOrder(buyerOrder);
        s.sellerOrderHash = OptionOrderTypes.hashOrder(sellerOrder);
        if (s.buyerOrderHash != buyerEnvelope.payloadHash) {
            revert OrderPayloadHashMismatch(buyerEnvelope.payloadHash, s.buyerOrderHash);
        }
        if (s.sellerOrderHash != sellerEnvelope.payloadHash) {
            revert OrderPayloadHashMismatch(sellerEnvelope.payloadHash, s.sellerOrderHash);
        }
        if (buyerEnvelope.action != OptionOrderTypes.ACTION_OPTION_ORDER) revert InvalidDependency();
        if (sellerEnvelope.action != OptionOrderTypes.ACTION_OPTION_ORDER) revert InvalidDependency();
        _requireDeadlineNotExpired(buyerEnvelope.deadline);
        _requireDeadlineNotExpired(sellerEnvelope.deadline);
        _requireEpochsFresh(
            buyerEnvelope.owner,
            buyerEnvelope.subKey,
            buyerEnvelope.ownerRecoveryEpoch,
            buyerEnvelope.subaccountRecoveryEpoch
        );
        _requireEpochsFresh(
            sellerEnvelope.owner,
            sellerEnvelope.subKey,
            sellerEnvelope.ownerRecoveryEpoch,
            sellerEnvelope.subaccountRecoveryEpoch
        );
    }

    function _validateSignatures(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        bytes calldata buyerSignature,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        bytes calldata sellerSignature
    ) internal view {
        _requireSignerAuthorized(buyerEnvelope, buyerSignature);
        _requireSignerAuthorized(sellerEnvelope, sellerSignature);
    }

    function _consumeAllReplayState(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        ExecutionScratch memory s
    ) internal {
        _consumeNonce(buyerEnvelope.signer, buyerEnvelope.nonce);
        _consumeNonce(sellerEnvelope.signer, sellerEnvelope.nonce);
        s.buyerIntent = _hashSignedActionEnvelopeDigest(buyerEnvelope);
        s.sellerIntent = _hashSignedActionEnvelopeDigest(sellerEnvelope);
        _consumeIntent(s.buyerIntent, buyerEnvelope.signer, OptionOrderTypes.ACTION_OPTION_ORDER);
        _consumeIntent(s.sellerIntent, sellerEnvelope.signer, OptionOrderTypes.ACTION_OPTION_ORDER);
    }

    function _applyLedgerFills(
        bytes32 buyerSubKey,
        bytes32 sellerSubKey,
        OptionOrderTypes.OptionOrder calldata buyerOrder
    ) internal {
        OPTIONS_LEDGER.applyFill(
            buyerSubKey,
            buyerOrder.seriesId,
            OptionOrderTypes.SIDE_LONG,
            buyerOrder.quantity1e8,
            buyerOrder.pricePerContract1e8
        );
        OPTIONS_LEDGER.applyFill(
            sellerSubKey,
            buyerOrder.seriesId,
            OptionOrderTypes.SIDE_SHORT,
            buyerOrder.quantity1e8,
            buyerOrder.pricePerContract1e8
        );
    }

    function _emitExecution(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        OptionOrderTypes.OptionOrder calldata sellerOrder,
        ExecutionScratch memory s
    ) internal {
        emit OptionOrderPairExecuted(
            s.executionId,
            s.buyerOrderHash,
            s.sellerOrderHash,
            buyerOrder.seriesId,
            buyerEnvelope.subKey,
            sellerEnvelope.subKey,
            buyerEnvelope.owner,
            sellerEnvelope.owner,
            buyerEnvelope.subaccountId,
            sellerEnvelope.subaccountId,
            buyerOrder.quantity1e8,
            buyerOrder.pricePerContract1e8,
            s.totalPremiumNative,
            buyerOrder.premiumToken,
            buyerOrder.role,
            sellerOrder.role,
            s.buyerFee,
            s.sellerFee,
            msg.sender,
            Versions.EVENT_VERSION
        );
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Verify signature validity via OZ SignatureChecker (EOA + ERC-1271).
    ///      The signer MUST equal the envelope owner in V1 (no session keys).
    function _requireSignerAuthorized(IntentHash.SignedActionEnvelope calldata envelope, bytes calldata signature)
        internal
        view
    {
        // V1 policy: signer field MUST equal owner. Delegation deferred.
        if (envelope.signer != envelope.owner) {
            revert InvalidSigner(envelope.subKey, envelope.signer, envelope.owner);
        }
        bytes32 digest = _hashSignedActionEnvelopeDigest(envelope);
        if (!SignatureChecker.isValidSignatureNow(envelope.owner, digest, signature)) {
            revert InvalidSigner(envelope.subKey, envelope.signer, envelope.owner);
        }
    }

    function _requireCompatibleOrders(
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        OptionOrderTypes.OptionOrder calldata sellerOrder,
        bytes32 buyerSubKey,
        bytes32 sellerSubKey
    ) internal pure {
        if (buyerOrder.quantity1e8 == 0) revert QuantityZero();
        if (buyerOrder.quantity1e8 != sellerOrder.quantity1e8) {
            revert QuantityDisagreement(buyerOrder.quantity1e8, sellerOrder.quantity1e8);
        }
        if (buyerOrder.seriesId == 0) revert InvalidSeries(0);
        if (buyerOrder.seriesId != sellerOrder.seriesId) {
            revert SeriesMismatch(buyerOrder.seriesId, sellerOrder.seriesId);
        }
        if (buyerOrder.premiumToken != sellerOrder.premiumToken) {
            revert PremiumTokenMismatch(buyerOrder.premiumToken, sellerOrder.premiumToken);
        }
        if (buyerOrder.side != OptionOrderTypes.SIDE_LONG || sellerOrder.side != OptionOrderTypes.SIDE_SHORT) {
            revert SameSideMatch(buyerOrder.side, sellerOrder.side);
        }
        if (buyerSubKey == sellerSubKey) revert SelfTrade(buyerSubKey);
        // Roles must be maker+taker (one and the other).
        if (!((buyerOrder.role == OptionOrderTypes.ROLE_MAKER && sellerOrder.role == OptionOrderTypes.ROLE_TAKER)
                    || (buyerOrder.role == OptionOrderTypes.ROLE_TAKER
                        && sellerOrder.role == OptionOrderTypes.ROLE_MAKER))) {
            revert InvalidMakerTakerAssignment(buyerOrder.role, sellerOrder.role);
        }
        // Post-only enforcement: a POST_ONLY-tagged order MUST be in MAKER role.
        if (buyerOrder.timeInForce == OptionOrderTypes.TIF_POST_ONLY && buyerOrder.role != OptionOrderTypes.ROLE_MAKER)
        {
            revert PostOnlyRoleViolation(buyerSubKey);
        }
        if (
            sellerOrder.timeInForce == OptionOrderTypes.TIF_POST_ONLY && sellerOrder.role != OptionOrderTypes.ROLE_MAKER
        ) {
            revert PostOnlyRoleViolation(sellerSubKey);
        }
        // TIF combination check: POST_ONLY + IOC/FOK is forbidden — a taker
        // TIF cannot pair with a POST_ONLY maker whose TIF requires it to be
        // resting.
        if (
            buyerOrder.timeInForce == OptionOrderTypes.TIF_POST_ONLY
                && sellerOrder.timeInForce == OptionOrderTypes.TIF_POST_ONLY
        ) {
            revert InvalidTifCombination(buyerOrder.timeInForce, sellerOrder.timeInForce);
        }
        // Both counterparties MUST agree on the SIGNED execution price.
        if (buyerOrder.pricePerContract1e8 != sellerOrder.pricePerContract1e8) {
            revert PremiumDisagreement(buyerOrder.pricePerContract1e8, sellerOrder.pricePerContract1e8);
        }
        // Buyer's limit is a MAX (buyer signs a maximum they'll pay).
        if (buyerOrder.pricePerContract1e8 > buyerOrder.limitPricePerContract1e8) {
            revert PremiumOutsideLimit(
                buyerOrder.pricePerContract1e8, buyerOrder.limitPricePerContract1e8, OptionOrderTypes.SIDE_LONG
            );
        }
        // Seller's limit is a MIN (seller signs a minimum they'll accept).
        if (sellerOrder.pricePerContract1e8 < sellerOrder.limitPricePerContract1e8) {
            revert PremiumOutsideLimit(
                sellerOrder.pricePerContract1e8, sellerOrder.limitPricePerContract1e8, OptionOrderTypes.SIDE_SHORT
            );
        }
    }

    function _requireSeriesTradeable(uint256 seriesId, address premiumToken) internal view {
        IOptionsRiskProvider.SeriesRiskView memory s = RISK_PROVIDER.seriesRiskView(seriesId);
        if (!s.exists) revert InvalidSeries(seriesId);
        if (!s.isActive) revert InvalidSeries(seriesId);
        if (s.settlementAsset != premiumToken) revert InvalidSeries(seriesId);
        if (s.settlementAsset != QUOTE_TOKEN) revert InvalidSeries(seriesId);
        if (s.contractSize1e8 != 1e8) revert InvalidSeries(seriesId);
        if (s.strike1e8 == 0) revert InvalidSeries(seriesId);
        if (s.expiry <= block.timestamp) revert InvalidSeries(seriesId);
    }

    function _quoteBothFees(bytes32 buyerSubKey, bytes32 sellerSubKey, OptionOrderTypes.OptionOrder calldata buyerOrder)
        internal
        view
        returns (uint128 buyerFee, uint128 sellerFee)
    {
        uint128 buyerRebate;
        uint128 sellerRebate;
        bool okBuyer;
        bool okSeller;
        (buyerFee, buyerRebate, okBuyer) = FEE_HOOK.quoteExecutionFee(
            buyerSubKey,
            buyerOrder.premiumToken,
            buyerOrder.quantity1e8,
            buyerOrder.pricePerContract1e8,
            OptionOrderTypes.ROLE_TAKER
        );
        (sellerFee, sellerRebate, okSeller) = FEE_HOOK.quoteExecutionFee(
            sellerSubKey,
            buyerOrder.premiumToken,
            buyerOrder.quantity1e8,
            buyerOrder.pricePerContract1e8,
            OptionOrderTypes.ROLE_MAKER
        );
        if (!okBuyer || buyerRebate != 0) revert FeeHookRejected(buyerSubKey);
        if (!okSeller || sellerRebate != 0) revert FeeHookRejected(sellerSubKey);
    }

    /// @dev `totalPremium_native = quantity1e8 * pricePerContract1e8 / 1e8`
    ///      then scale from 1e8 to `10^quoteDecimals` — the RiskModule's
    ///      QUOTE_TOKEN native scale. Round UP against the buyer.
    function _computeTotalPremiumNative(uint128 quantity1e8, uint128 pricePerContract1e8)
        internal
        view
        returns (uint256 amount)
    {
        if (quantity1e8 == 0 || pricePerContract1e8 == 0) return 0;
        // In 1e8 quote units: totalPremium_1e8 = qty * price / 1e8.
        uint256 totalPremium1e8 = (uint256(quantity1e8) * uint256(pricePerContract1e8)) / 1e8;
        // Native units for a 6-dec QUOTE_TOKEN: divide by 10^(8-6) = 100.
        // For an 8-dec QUOTE_TOKEN: divide by 1.
        // For an 18-dec QUOTE_TOKEN: MULTIPLY by 10^10 (see note below).
        if (QUOTE_DECIMALS <= 8) {
            uint256 divisor = 10 ** (8 - uint256(QUOTE_DECIMALS));
            // Round UP against the buyer.
            amount = (totalPremium1e8 + divisor - 1) / divisor;
        } else {
            uint256 mult = 10 ** (uint256(QUOTE_DECIMALS) - 8);
            amount = totalPremium1e8 * mult;
        }
    }

    /// @dev Adjust the seller-side engine reservation to the current post-state
    ///      target IM. Uses the MarginEngine's witness-taking view for the
    ///      1e18 aggregate then scales to native premium-token units.
    function _syncSellerReservation(
        bytes32 sellerSubKey,
        uint256[] calldata sellerActiveSeriesIds,
        address premiumToken
    ) internal {
        uint256 imTarget1e18 = MARGIN_ENGINE.initialMargin1e18(sellerSubKey, sellerActiveSeriesIds);
        uint256 targetNative = _scale1e18ToNative(imTarget1e18);
        uint256 currentEngineLocked = VAULT.lockedByEngineOf(sellerSubKey, premiumToken, address(this));
        if (targetNative > currentEngineLocked) {
            uint256 delta = targetNative - currentEngineLocked;
            ICollateralVault(address(VAULT)).applyLock(sellerSubKey, premiumToken, delta);
        } else if (targetNative < currentEngineLocked) {
            uint256 delta = currentEngineLocked - targetNative;
            ICollateralVault(address(VAULT)).applyUnlock(sellerSubKey, premiumToken, delta);
        }
    }

    /// @dev Scale a 1e18 quote-value into native `QUOTE_TOKEN` units. Rounds
    ///      UP against the trader for reservation target.
    ///      `value1e18 = value1e8 * 1e10` (see `OptionsRiskMath.scale1e8To1e18`).
    ///      Native = value1e18 * 10^QUOTE_DECIMALS / 1e18.
    function _scale1e18ToNative(uint256 value1e18) internal view returns (uint256 native) {
        if (value1e18 == 0) return 0;
        if (QUOTE_DECIMALS >= 18) {
            uint256 mult = 10 ** (uint256(QUOTE_DECIMALS) - 18);
            native = value1e18 * mult;
        } else {
            uint256 divisor = 10 ** (18 - uint256(QUOTE_DECIMALS));
            // Round UP so the reservation is at LEAST the required IM.
            native = (value1e18 + divisor - 1) / divisor;
        }
    }
}

/// @dev Compile-time helper interface used ONLY by the constructor's
///      `_readRegistry`. Reading `ICollateralVault.REGISTRY()` before the
///      base constructor runs cannot use the immutable in `VaultRiskModuleConsumer`,
///      so we cast the raw vault address.
interface ICollateralVaultWithRegistry {
    function REGISTRY() external view returns (address);
}
