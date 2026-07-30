// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ReplayAndEpochController} from "../security/ReplayAndEpochController.sol";
import {IntentHash} from "../libraries/IntentHash.sol";
import {SubKey} from "../libraries/SubKey.sol";
import {Versions} from "../libraries/Versions.sol";

import {IOptionMatchingEngine} from "../interfaces/IOptionMatchingEngine.sol";
import {IOptionExecutionFeeHook} from "../interfaces/IOptionExecutionFeeHook.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {IOptionsPositionsLedger} from "../interfaces/IOptionsPositionsLedger.sol";
import {IMarginEngine} from "../interfaces/IMarginEngine.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {IOptionsRiskProvider} from "../interfaces/IOptionsRiskProvider.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";

import {CollateralVaultV2RiskIntegrated} from "../risk/CollateralVaultV2RiskIntegrated.sol";
import {MarginEngineV2} from "../margin/MarginEngineV2.sol";
import {OptionOrderTypes} from "./OptionOrderTypes.sol";

/// @title OptionMatchingEngineV2
/// @notice WP-08B (concrete Options execution engine) as amended by
///         `ONCHAIN-SUBACCOUNT-OPTION-ORDER-LIFECYCLE-AND-NONCE-V2-PATCH`.
///         Atomically composes Registry identity, EIP-712 signature
///         envelopes, canonical on-chain order lifecycle
///         (filled-quantity + individual cancel + per-subaccount bulk
///         cancel), canonical Options position mutation, Vault-scoped
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
///
///  Order lifecycle (post-patch — supersedes PF-2 exact-fill):
///   - `orderId = _hashSignedActionEnvelopeDigest(envelope)` — the frozen
///     EIP-712 typed-data digest of the outer envelope. Unique per
///     (owner, subKey, engine, action, architectureVersion, nonce,
///     deadline, ownerRecoveryEpoch, subaccountRecoveryEpoch, payloadHash)
///     with `payloadHash` further binding all `OptionOrder` fields
///     including the signer-chosen `salt`.
///   - `_filledQuantity1e8[orderId]` is monotone non-decreasing. Sum of
///     any past `OptionOrderFilled` events for `orderId` equals the
///     current stored value.
///   - `_cancelledOrder[orderId]` transitions false → true exactly once.
///     Cannot be re-armed. IOC termination, individual cancellation, and
///     bulk cancellation are three sources of this transition.
///   - `_minValidOrderNonce[subKey]` is monotone non-decreasing per subKey.
///     Every envelope submitted for `subKey` with `envelope.nonce < min`
///     reverts `OrderNonceStale`.
///   - The engine does NOT call the base `_consumeNonce` primitive —
///     sequential per-signer nonces from `ReplayAndEpochController` are
///     bypassed for signed option orders because the reusable-fill model
///     requires the same envelope to be presentable across multiple
///     `executeMatch` calls. Replay protection is provided instead by the
///     monotone `_filledQuantity1e8[orderId]` cap and by the terminal
///     `_cancelledOrder[orderId]` flag.
///   - The engine does NOT call `_consumeIntent` either — it emits its
///     own `OptionOrderFilled` and `OptionOrderCancelled` events for
///     reconstruction. `IntentConsumed` on the base is preserved for
///     other future engines that DO use the base sequential model.
///
///  Frozen semantics preserved from WP-08B:
///   - Buyer = SIDE_LONG, seller = SIDE_SHORT. Every matched pair MUST have
///     opposite sides.
///   - Buyer and seller MAY belong to different owners.
///   - Identical subKey self-trade is REJECTED.
///   - Roles are exchanged: one side signs `role = MAKER`, the other signs
///     `role = TAKER`. Post-only orders MUST sign `role = MAKER`.
///   - Both counterparties MUST sign the same `pricePerContract1e8` and
///     `premiumToken`.
///   - Both signed `limitPricePerContract1e8` values MUST accept the
///     signed price (buyer: price ≤ limit; seller: price ≥ limit).
///   - Buyer and seller MAY sign different `quantity1e8` maxima — the
///     engine executes only the per-call `fillQuantity1e8` bounded by
///     `min(buyer.remaining, seller.remaining)`.
///
///  Atomicity:
///   Order inside `executeMatch`:
///     1. `nonReentrant`.
///     2. Not paused.
///     3. Envelope binding + payload-hash validation for both sides.
///     4. EOA + ERC-1271 signature verification via OZ SignatureChecker.
///     5. Deadline + epoch freshness for both sides.
///     6. Order compatibility (series, premium token, side, price, role,
///        self-trade check).
///     7. Series metadata resolution (via `IOptionsRiskProvider`).
///     8. Lifecycle preconditions (min-valid-nonce, not cancelled, remaining
///        capacity, TIF rules — FOK requires fill == max && filledBefore == 0).
///     9. Fee hook quote for both sides (V1: rebate MUST be zero).
///    10. Advance canonical filled-quantity for both sides. Mark IOC
///        orders cancelled on any fill. Emit `OptionOrderFilled` per side.
///    11. Ledger `applyFill` for buyer (long).
///    12. Ledger `applyFill` for seller (short).
///    13. Vault `applyOptionPremiumTransfer` — atomic entitlement swap.
///    14. Sync seller-side reservation via MarginEngine target IM.
///    15. MarginEngine `isHealthy` for BOTH sides on POST-STATE witness.
///    16. Emit `OptionOrderPairExecuted`.
///   Any downstream revert unwinds the entire transaction (Solidity
///   atomicity). No partial mutation — including filled-quantity or
///   cancellation flags — can survive.
///
///  Reservation policy (preserved from WP-08B —
///  `OPTION_MARGIN_RESERVATION_SERIES_SETTLEMENT_TOKEN`):
///   - Reservations held in the series' `settlementAsset` which MUST equal
///     RISK_MODULE.QUOTE_TOKEN.
///   - Target = seller-side IM (long positions contribute zero in V1).
///   - The engine adjusts its OWN reservation via `applyLock` /
///     `applyUnlock` deltas. It never touches another engine's slot.
contract OptionMatchingEngineV2 is IOptionMatchingEngine, ReplayAndEpochController, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical Vault. Same object every consumer of the same
    ///         deployment sees. Immutable at construction.
    ICollateralVault public immutable VAULT;

    /// @notice Canonical `IRiskModule` sourced directly from the Vault's
    ///         `RISK_MODULE()` at construction. Enforces RM-1
    ///         (`SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT`).
    IRiskModule public immutable RISK_MODULE;

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

    /// @dev Terminal-reason encoding for `OptionOrderFilled.terminalReason`.
    uint8 internal constant TERMINAL_NONE = 0;
    uint8 internal constant TERMINAL_FULLY_FILLED = 1;
    uint8 internal constant TERMINAL_IOC_REMAINDER = 2;
    uint8 internal constant TERMINAL_FOK_CONSUMED = 3;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Guardian-only pause flag. Does NOT mutate any economic
    ///         state — refuses new executions only.
    bool public executionPaused;

    /// @notice Guardian address — capability-gated ONLY for pause.
    address public immutable GUARDIAN;

    /// @notice Governance address — capability-gated ONLY for guardian rotation.
    address public immutable GOVERNANCE;

    /// @dev Canonical cumulative filled quantity per `orderId`.
    ///      Reconstruction: sum of every `OptionOrderFilled.fillQuantity1e8`
    ///      for the same `orderId` since deployment.
    mapping(bytes32 => uint128) private _filledQuantity1e8;

    /// @dev Terminal cancellation flag per `orderId`. Transitions
    ///      false → true exactly once and never resets.
    mapping(bytes32 => bool) private _cancelledOrder;

    /// @dev Per-subKey monotonic minimum valid `envelope.nonce`. Zero on
    ///      first sighting. `advanceMinValidOrderNonce` bumps monotonically.
    mapping(bytes32 => uint256) private _minValidOrderNonce;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

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

        // Read RISK_MODULE from the Vault directly (RM-1 posture).
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
    ///      body runs.
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

    /// @inheritdoc IOptionMatchingEngine
    function filledQuantityOf(bytes32 orderId) external view returns (uint128) {
        return _filledQuantity1e8[orderId];
    }

    /// @inheritdoc IOptionMatchingEngine
    function isOrderCancelled(bytes32 orderId) external view returns (bool) {
        return _cancelledOrder[orderId];
    }

    /// @inheritdoc IOptionMatchingEngine
    function minValidOrderNonceOf(bytes32 subKey) external view returns (uint256) {
        return _minValidOrderNonce[subKey];
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

    /// @notice Governance-only unpause.
    function unpauseExecution() external {
        if (msg.sender != GOVERNANCE) revert InvalidDependency();
        executionPaused = false;
    }

    /*//////////////////////////////////////////////////////////////
                     LIFECYCLE MUTATIONS (OWNER PATH)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOptionMatchingEngine
    function cancelSignedOrder(IntentHash.SignedActionEnvelope calldata envelope) external {
        _requireEnvelopeBindingValid(envelope);
        bytes32 orderId = _hashSignedActionEnvelopeDigest(envelope);
        if (msg.sender != envelope.owner) revert NotOrderOwner(orderId, msg.sender, envelope.owner);
        if (_cancelledOrder[orderId]) revert OrderCancelled(orderId);
        _cancelledOrder[orderId] = true;
        emit OptionOrderCancelled(orderId, envelope.subKey, envelope.owner, msg.sender, Versions.EVENT_VERSION);
    }

    /// @inheritdoc IOptionMatchingEngine
    function advanceMinValidOrderNonce(uint32 subaccountId, uint256 newMin) external {
        if (subaccountId == 0) revert InvalidSubaccountId();
        address owner = msg.sender;
        if (!ISubaccountRegistry(REGISTRY).existsOf(owner, subaccountId)) {
            revert SubaccountNotFoundForOwner(owner, subaccountId);
        }
        bytes32 subKey = SubKey.deriveHere(REGISTRY, owner, subaccountId);
        uint256 current = _minValidOrderNonce[subKey];
        if (newMin <= current) revert MinValidOrderNonceNotAdvancing(subKey, current, newMin);
        _minValidOrderNonce[subKey] = newMin;
        emit OptionSubaccountMinValidOrderNonceAdvanced(subKey, owner, current, newMin, owner, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                        EXECUTION ENTRYPOINT
    //////////////////////////////////////////////////////////////*/

    /// @dev Scratchpad packing every value derived during `executeMatch`
    ///      that would otherwise blow the stack.
    struct ExecutionScratch {
        bytes32 buyerOrderId;
        bytes32 sellerOrderId;
        uint128 buyerFilledBefore;
        uint128 sellerFilledBefore;
        uint128 buyerFilledAfter;
        uint128 sellerFilledAfter;
        uint128 buyerFee;
        uint128 sellerFee;
        uint128 buyerRebate;
        uint128 sellerRebate;
        uint256 totalPremiumNative;
        bytes32 executionId;
    }

    /// @inheritdoc IOptionMatchingEngine
    function executeMatch(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        bytes calldata buyerSignature,
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        bytes calldata sellerSignature,
        OptionOrderTypes.OptionOrder calldata sellerOrder,
        uint128 fillQuantity1e8,
        uint256[] calldata buyerActiveSeriesIds,
        uint256[] calldata sellerActiveSeriesIds
    ) external nonReentrant returns (bytes32 executionId) {
        if (executionPaused) revert ExecutionPaused();
        ExecutionScratch memory s;

        _validateEnvelopes(buyerEnvelope, buyerOrder, sellerEnvelope, sellerOrder, s);
        _validateSignatures(buyerEnvelope, buyerSignature, sellerEnvelope, sellerSignature);

        _requireCompatibleOrders(buyerOrder, sellerOrder, buyerEnvelope.subKey, sellerEnvelope.subKey);
        _requireSeriesTradeable(buyerOrder.seriesId, buyerOrder.premiumToken);

        // Fee quotes (per-fill). Rebate is now allowed and applied via
        // the Vault primitives introduced by
        // `ONCHAIN-SUBACCOUNT-FEES-MANAGER-V2-INTEGRATION-V1`.
        (s.buyerFee, s.sellerFee, s.buyerRebate, s.sellerRebate) = _quoteFeesAndRebates(
            buyerEnvelope.subKey, sellerEnvelope.subKey, buyerOrder, fillQuantity1e8
        );

        // Signed positive-fee-cap enforcement. Charged AMOUNT (1e8) must not
        // exceed the per-side maximum implied by the signer's cap ppm.
        _requirePositiveFeeCapHonoured(buyerOrder, fillQuantity1e8, s.buyerFee);
        _requirePositiveFeeCapHonoured(sellerOrder, fillQuantity1e8, s.sellerFee);

        _advanceLifecycleAndEmit(buyerEnvelope, buyerOrder, sellerEnvelope, sellerOrder, fillQuantity1e8, s);

        _applyLedgerFills(
            buyerEnvelope.subKey,
            sellerEnvelope.subKey,
            buyerOrder.seriesId,
            fillQuantity1e8,
            buyerOrder.pricePerContract1e8
        );
        s.totalPremiumNative = _computeTotalPremiumNative(fillQuantity1e8, buyerOrder.pricePerContract1e8);
        if (s.totalPremiumNative > 0) {
            ICollateralVault(address(VAULT))
                .applyOptionPremiumTransfer(
                    buyerEnvelope.subKey, sellerEnvelope.subKey, buyerOrder.premiumToken, s.totalPremiumNative
                );
        }

        // Apply positive fees + rebates through the frozen Vault primitives.
        // Positive fees debit the trader's AVAILABLE balance and credit the
        // canonical protocol-fee subKey. Rebates debit the canonical
        // rebate-budget subKey and credit the trader.
        _applyFeesAndRebates(
            buyerEnvelope.subKey,
            sellerEnvelope.subKey,
            buyerOrder.premiumToken,
            s.buyerFee,
            s.sellerFee,
            s.buyerRebate,
            s.sellerRebate
        );

        _syncSellerReservation(sellerEnvelope.subKey, sellerActiveSeriesIds, buyerOrder.premiumToken);

        if (!MARGIN_ENGINE.isHealthy(buyerEnvelope.subKey, buyerActiveSeriesIds)) {
            revert UnsafePostTradeMargin(buyerEnvelope.subKey);
        }
        if (!MARGIN_ENGINE.isHealthy(sellerEnvelope.subKey, sellerActiveSeriesIds)) {
            revert UnsafePostTradeMargin(sellerEnvelope.subKey);
        }

        s.executionId =
            keccak256(abi.encode(s.buyerOrderId, s.sellerOrderId, block.number, block.timestamp, fillQuantity1e8));
        _emitExecution(buyerEnvelope, sellerEnvelope, buyerOrder, sellerOrder, fillQuantity1e8, s);
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
        bytes32 bHash = OptionOrderTypes.hashOrder(buyerOrder);
        bytes32 sHash = OptionOrderTypes.hashOrder(sellerOrder);
        if (bHash != buyerEnvelope.payloadHash) {
            revert OrderPayloadHashMismatch(buyerEnvelope.payloadHash, bHash);
        }
        if (sHash != sellerEnvelope.payloadHash) {
            revert OrderPayloadHashMismatch(sellerEnvelope.payloadHash, sHash);
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
        s.buyerOrderId = _hashSignedActionEnvelopeDigest(buyerEnvelope);
        s.sellerOrderId = _hashSignedActionEnvelopeDigest(sellerEnvelope);
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

    /// @dev Advance canonical lifecycle state for both sides, emit
    ///      per-side `OptionOrderFilled` events. Applies min-valid-nonce
    ///      + cancellation checks, TIF preconditions, and terminates IOC
    ///      orders on any fill.
    function _advanceLifecycleAndEmit(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        OptionOrderTypes.OptionOrder calldata sellerOrder,
        uint128 fillQuantity1e8,
        ExecutionScratch memory s
    ) internal {
        _requireOrderStillLive(s.buyerOrderId, buyerEnvelope.subKey, buyerEnvelope.nonce);
        _requireOrderStillLive(s.sellerOrderId, sellerEnvelope.subKey, sellerEnvelope.nonce);

        s.buyerFilledBefore = _filledQuantity1e8[s.buyerOrderId];
        s.sellerFilledBefore = _filledQuantity1e8[s.sellerOrderId];

        _requireFillFitsSide(s.buyerOrderId, buyerOrder, fillQuantity1e8, s.buyerFilledBefore);
        _requireFillFitsSide(s.sellerOrderId, sellerOrder, fillQuantity1e8, s.sellerFilledBefore);

        s.buyerFilledAfter = s.buyerFilledBefore + fillQuantity1e8;
        s.sellerFilledAfter = s.sellerFilledBefore + fillQuantity1e8;

        _filledQuantity1e8[s.buyerOrderId] = s.buyerFilledAfter;
        _filledQuantity1e8[s.sellerOrderId] = s.sellerFilledAfter;

        (bool bTerm, uint8 bReason) = _terminationForFill(buyerOrder, s.buyerFilledAfter);
        (bool sTerm, uint8 sReason) = _terminationForFill(sellerOrder, s.sellerFilledAfter);

        // Only set the cancellation flag when termination leaves UNFILLED
        // remainder (IOC-with-remainder). Orders where filledAfter has
        // reached the signed maximum are already blocked on retry by the
        // `_requireFillFitsSide` filledBefore >= signedMax check — so no
        // extra flag is needed and cancellation events remain focused on
        // owner-driven or IOC-driven terminations rather than routine
        // full-fill completion.
        if (bTerm && s.buyerFilledAfter < buyerOrder.quantity1e8) {
            _cancelledOrder[s.buyerOrderId] = true;
        }
        if (sTerm && s.sellerFilledAfter < sellerOrder.quantity1e8) {
            _cancelledOrder[s.sellerOrderId] = true;
        }

        emit OptionOrderFilled(
            s.buyerOrderId,
            buyerEnvelope.subKey,
            buyerOrder.seriesId,
            OptionOrderTypes.SIDE_LONG,
            buyerOrder.timeInForce,
            fillQuantity1e8,
            s.buyerFilledBefore,
            s.buyerFilledAfter,
            buyerOrder.quantity1e8,
            bTerm,
            bReason,
            msg.sender,
            Versions.EVENT_VERSION
        );
        emit OptionOrderFilled(
            s.sellerOrderId,
            sellerEnvelope.subKey,
            sellerOrder.seriesId,
            OptionOrderTypes.SIDE_SHORT,
            sellerOrder.timeInForce,
            fillQuantity1e8,
            s.sellerFilledBefore,
            s.sellerFilledAfter,
            sellerOrder.quantity1e8,
            sTerm,
            sReason,
            msg.sender,
            Versions.EVENT_VERSION
        );
    }

    /// @dev Fail if the order is stale (nonce below cutoff) or cancelled.
    function _requireOrderStillLive(bytes32 orderId, bytes32 subKey, uint256 envelopeNonce) internal view {
        uint256 minValid = _minValidOrderNonce[subKey];
        if (envelopeNonce < minValid) revert OrderNonceStale(subKey, envelopeNonce, minValid);
        if (_cancelledOrder[orderId]) revert OrderCancelled(orderId);
    }

    /// @dev Fail if the per-call fill quantity would exceed the side's
    ///      remaining signed capacity, if the fill is zero, or if a TIF
    ///      rule is violated (FOK: fill MUST equal signedMax AND
    ///      filledBefore MUST be zero).
    function _requireFillFitsSide(
        bytes32 orderId,
        OptionOrderTypes.OptionOrder calldata order,
        uint128 fillQuantity1e8,
        uint128 filledBefore
    ) internal pure {
        if (fillQuantity1e8 == 0) revert QuantityZero();
        if (order.quantity1e8 == 0) revert QuantityZero();
        if (filledBefore >= order.quantity1e8) {
            revert OrderAlreadyFullyFilled(orderId, filledBefore, order.quantity1e8);
        }
        uint128 remaining;
        unchecked {
            remaining = order.quantity1e8 - filledBefore;
        }
        if (fillQuantity1e8 > remaining) {
            revert FillQuantityInvalid(fillQuantity1e8, remaining, remaining);
        }
        if (order.timeInForce == OptionOrderTypes.TIF_FOK) {
            if (fillQuantity1e8 != order.quantity1e8 || filledBefore != 0) {
                revert FokRequiresFullFillFromZero(orderId, fillQuantity1e8, order.quantity1e8, filledBefore);
            }
        }
    }

    /// @dev Determine whether THIS fill terminates the order and the
    ///      reason. Fully-filled is terminal regardless of TIF. IOC is
    ///      terminal on any fill. FOK is terminal on the (only) fill.
    function _terminationForFill(OptionOrderTypes.OptionOrder calldata order, uint128 filledAfter)
        internal
        pure
        returns (bool terminal, uint8 reason)
    {
        if (filledAfter >= order.quantity1e8) {
            if (order.timeInForce == OptionOrderTypes.TIF_FOK) return (true, TERMINAL_FOK_CONSUMED);
            return (true, TERMINAL_FULLY_FILLED);
        }
        if (order.timeInForce == OptionOrderTypes.TIF_IOC) return (true, TERMINAL_IOC_REMAINDER);
        return (false, TERMINAL_NONE);
    }

    function _applyLedgerFills(
        bytes32 buyerSubKey,
        bytes32 sellerSubKey,
        uint256 seriesId,
        uint128 fillQuantity1e8,
        uint128 pricePerContract1e8
    ) internal {
        OPTIONS_LEDGER.applyFill(
            buyerSubKey, seriesId, OptionOrderTypes.SIDE_LONG, fillQuantity1e8, pricePerContract1e8
        );
        OPTIONS_LEDGER.applyFill(
            sellerSubKey, seriesId, OptionOrderTypes.SIDE_SHORT, fillQuantity1e8, pricePerContract1e8
        );
    }

    function _emitExecution(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        OptionOrderTypes.OptionOrder calldata sellerOrder,
        uint128 fillQuantity1e8,
        ExecutionScratch memory s
    ) internal {
        emit OptionOrderPairExecuted(
            s.executionId,
            s.buyerOrderId,
            s.sellerOrderId,
            buyerOrder.seriesId,
            buyerEnvelope.subKey,
            sellerEnvelope.subKey,
            buyerEnvelope.owner,
            sellerEnvelope.owner,
            buyerEnvelope.subaccountId,
            sellerEnvelope.subaccountId,
            fillQuantity1e8,
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
        if (sellerOrder.quantity1e8 == 0) revert QuantityZero();
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
        // Two POST_ONLY sides cannot pair (both maker).
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
        // Buyer's limit is a MAX.
        if (buyerOrder.pricePerContract1e8 > buyerOrder.limitPricePerContract1e8) {
            revert PremiumOutsideLimit(
                buyerOrder.pricePerContract1e8, buyerOrder.limitPricePerContract1e8, OptionOrderTypes.SIDE_LONG
            );
        }
        // Seller's limit is a MIN.
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

    /// @dev Query the fee hook for both sides. A side MAY receive a positive
    ///      fee (`feeAmount1e8 > 0, rebateAmount1e8 == 0`) OR a rebate
    ///      (`feeAmount1e8 == 0, rebateAmount1e8 > 0`) — but NEVER both. Any
    ///      hook returning both non-zero fails the execution closed via
    ///      `FeeHookRejected`. A hook returning `ok == false` also fails
    ///      closed. Rebates are now permitted (post-WP-09).
    function _quoteFeesAndRebates(
        bytes32 buyerSubKey,
        bytes32 sellerSubKey,
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        uint128 fillQuantity1e8
    ) internal view returns (uint128 buyerFee, uint128 sellerFee, uint128 buyerRebate, uint128 sellerRebate) {
        bool okBuyer;
        bool okSeller;
        (buyerFee, buyerRebate, okBuyer) = FEE_HOOK.quoteExecutionFee(
            buyerSubKey,
            buyerOrder.premiumToken,
            fillQuantity1e8,
            buyerOrder.pricePerContract1e8,
            OptionOrderTypes.ROLE_TAKER
        );
        (sellerFee, sellerRebate, okSeller) = FEE_HOOK.quoteExecutionFee(
            sellerSubKey,
            buyerOrder.premiumToken,
            fillQuantity1e8,
            buyerOrder.pricePerContract1e8,
            OptionOrderTypes.ROLE_MAKER
        );
        if (!okBuyer) revert FeeHookRejected(buyerSubKey);
        if (!okSeller) revert FeeHookRejected(sellerSubKey);
        if (buyerFee > 0 && buyerRebate > 0) revert FeeHookRejected(buyerSubKey);
        if (sellerFee > 0 && sellerRebate > 0) revert FeeHookRejected(sellerSubKey);
    }

    /// @dev Signed-cap enforcement. `feeAmount1e8` MUST be ≤
    ///      `ceil(premiumBasis1e8 * order.maxPositiveFeePpm / 1_000_000)`.
    ///      Applied on each side independently. Rebates (i.e. zero fee) are
    ///      never affected by this cap.
    function _requirePositiveFeeCapHonoured(
        OptionOrderTypes.OptionOrder calldata order,
        uint128 fillQuantity1e8,
        uint128 feeAmount1e8
    ) internal pure {
        if (feeAmount1e8 == 0) return; // rebate-only or exact-zero — the cap is trivially satisfied
        uint256 premiumBasis1e8 = (uint256(fillQuantity1e8) * uint256(order.pricePerContract1e8)) / 1e8;
        // ceil(premiumBasis1e8 * maxPpm / 1_000_000) — round UP so the cap
        // is at LEAST the honestly-requested amount.
        uint256 maxFee1e8 = (premiumBasis1e8 * uint256(order.maxPositiveFeePpm) + 999_999) / 1_000_000;
        if (uint256(feeAmount1e8) > maxFee1e8) {
            revert PositiveFeeRateExceedsSignedMaximum(
                feeAmount1e8, uint128(maxFee1e8), order.maxPositiveFeePpm
            );
        }
    }

    /// @dev Apply fees + rebates via the Vault primitives. Each side's fee
    ///      is charged first (positive-fee-cap already enforced), then its
    ///      rebate is credited. Amounts are scaled from 1e8 to native
    ///      QUOTE_TOKEN units — fees round UP against the trader (protects
    ///      the protocol) and rebates round DOWN (protects the budget).
    function _applyFeesAndRebates(
        bytes32 buyerSubKey,
        bytes32 sellerSubKey,
        address token,
        uint128 buyerFee1e8,
        uint128 sellerFee1e8,
        uint128 buyerRebate1e8,
        uint128 sellerRebate1e8
    ) internal {
        if (buyerFee1e8 > 0) {
            uint256 amount = _scale1e8ToNativeCeil(uint256(buyerFee1e8));
            if (amount > 0) ICollateralVault(address(VAULT)).applyOptionFeeCharge(buyerSubKey, token, amount);
        }
        if (sellerFee1e8 > 0) {
            uint256 amount = _scale1e8ToNativeCeil(uint256(sellerFee1e8));
            if (amount > 0) ICollateralVault(address(VAULT)).applyOptionFeeCharge(sellerSubKey, token, amount);
        }
        if (buyerRebate1e8 > 0) {
            uint256 amount = _scale1e8ToNativeFloor(uint256(buyerRebate1e8));
            if (amount > 0) ICollateralVault(address(VAULT)).applyOptionRebate(buyerSubKey, token, amount);
        }
        if (sellerRebate1e8 > 0) {
            uint256 amount = _scale1e8ToNativeFloor(uint256(sellerRebate1e8));
            if (amount > 0) ICollateralVault(address(VAULT)).applyOptionRebate(sellerSubKey, token, amount);
        }
    }

    /// @dev 1e8 → native, rounded UP (against trader for fees).
    function _scale1e8ToNativeCeil(uint256 amount1e8) internal view returns (uint256) {
        if (amount1e8 == 0) return 0;
        if (QUOTE_DECIMALS <= 8) {
            uint256 divisor = 10 ** (8 - uint256(QUOTE_DECIMALS));
            return (amount1e8 + divisor - 1) / divisor;
        }
        uint256 mult = 10 ** (uint256(QUOTE_DECIMALS) - 8);
        return amount1e8 * mult;
    }

    /// @dev 1e8 → native, rounded DOWN (against trader for rebates — protects budget).
    function _scale1e8ToNativeFloor(uint256 amount1e8) internal view returns (uint256) {
        if (amount1e8 == 0) return 0;
        if (QUOTE_DECIMALS <= 8) {
            uint256 divisor = 10 ** (8 - uint256(QUOTE_DECIMALS));
            return amount1e8 / divisor;
        }
        uint256 mult = 10 ** (uint256(QUOTE_DECIMALS) - 8);
        return amount1e8 * mult;
    }

    /// @dev `totalPremium_native = fillQuantity1e8 * pricePerContract1e8 / 1e8`
    ///      then scale from 1e8 to `10^quoteDecimals`. Round UP against the buyer.
    function _computeTotalPremiumNative(uint128 fillQuantity1e8, uint128 pricePerContract1e8)
        internal
        view
        returns (uint256 amount)
    {
        if (fillQuantity1e8 == 0 || pricePerContract1e8 == 0) return 0;
        uint256 totalPremium1e8 = (uint256(fillQuantity1e8) * uint256(pricePerContract1e8)) / 1e8;
        if (QUOTE_DECIMALS <= 8) {
            uint256 divisor = 10 ** (8 - uint256(QUOTE_DECIMALS));
            amount = (totalPremium1e8 + divisor - 1) / divisor;
        } else {
            uint256 mult = 10 ** (uint256(QUOTE_DECIMALS) - 8);
            amount = totalPremium1e8 * mult;
        }
    }

    /// @dev Adjust the seller-side engine reservation to the current post-state
    ///      target IM.
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
    function _scale1e18ToNative(uint256 value1e18) internal view returns (uint256 native) {
        if (value1e18 == 0) return 0;
        if (QUOTE_DECIMALS >= 18) {
            uint256 mult = 10 ** (uint256(QUOTE_DECIMALS) - 18);
            native = value1e18 * mult;
        } else {
            uint256 divisor = 10 ** (18 - uint256(QUOTE_DECIMALS));
            native = (value1e18 + divisor - 1) / divisor;
        }
    }
}

/// @dev Compile-time helper interface used ONLY by the constructor's
///      `_readRegistry`.
interface ICollateralVaultWithRegistry {
    function REGISTRY() external view returns (address);
}
