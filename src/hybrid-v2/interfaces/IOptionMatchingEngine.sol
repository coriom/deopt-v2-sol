// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IntentHash} from "../libraries/IntentHash.sol";
import {OptionOrderTypes} from "../options/OptionOrderTypes.sol";

/// @title IOptionMatchingEngine
/// @notice External surface for `OptionMatchingEngineV2` — the first Hybrid V2
///         milestone permitted to atomically compose multiple canonical
///         economic modules in one transaction (D.2).
/// @dev
///  Scope (frozen — WP-08B + post-lifecycle-patch):
///   - Executes ONE matched buyer/seller pair per call. The per-call
///     `fillQuantity1e8` is bounded by the minimum of each side's remaining
///     signed quantity.
///   - The backend proposes the match off-chain (D.1). This interface makes
///     no assumption about matching strategy.
///   - Every economic mutation is atomic within the transaction: any failure
///     rolls back positions, premium, fee state AND lifecycle state
///     (filled-quantity, cancellation flags, min-valid-nonce advances).
///
///  Non-goals:
///   - No RFQ / multi-leg execution.
///   - No settlement, exercise, liquidation, or recovery execution.
///   - No on-chain order book. No global order iteration.
///
///  Post-lifecycle-patch (`ONCHAIN-SUBACCOUNT-OPTION-ORDER-LIFECYCLE-AND-NONCE-V2-PATCH`)
///  cardinal properties:
///   - Canonical `filledQuantity1e8[orderId]` is stored on chain — the
///     replay guard is monotone against the signed maximum, NOT sequential
///     nonces.
///   - Owners may run multiple concurrent live orders per subaccount by
///     signing with distinct salts (and, optionally, distinct order
///     nonces).
///   - Owners MAY cancel a specific signed order via `cancelSignedOrder`.
///   - Owners MAY bulk-cancel every order they have signed under a subKey
///     with `envelope.nonce < newMin` by advancing
///     `minValidOrderNonceOf(subKey)`.
///   - IOC orders are TERMINALLY invalidated after any successful fill.
///   - FOK orders MUST fill fully in one call from a zero-filled starting
///     state.
///   - Lifecycle state (filled quantity, cancellation, min-valid-nonce) is
///     fully reconstructible from emitted events with no backend or
///     off-chain database dependency.
interface IOptionMatchingEngine {
    /// @notice One-shot execution of a pre-matched buyer/seller pair.
    /// @param buyerEnvelope  Frozen `SignedActionEnvelope` binding the buyer
    ///                       to their `OptionOrder` payload.
    /// @param buyerSignature Buyer's ECDSA or ERC-1271 signature over the
    ///                       envelope digest.
    /// @param buyerOrder     Buyer's `OptionOrder` — its `hashOrder(...)`
    ///                       MUST equal `buyerEnvelope.payloadHash`.
    /// @param sellerEnvelope Seller-side envelope.
    /// @param sellerSignature Seller-side signature.
    /// @param sellerOrder    Seller-side order — its `hashOrder(...)` MUST
    ///                       equal `sellerEnvelope.payloadHash`.
    /// @param fillQuantity1e8 Requested per-call fill quantity, in 1e8
    ///                       precision. MUST satisfy
    ///                       `0 < fillQuantity1e8 <= min(buyer.remaining,
    ///                       seller.remaining)`. FOK orders additionally
    ///                       require `fillQuantity1e8 == quantity1e8` and
    ///                       zero prior filled quantity for that side.
    /// @param buyerActiveSeriesIds Complete active-series witness for the
    ///                       buyer's POST-STATE portfolio (used by
    ///                       MarginEngine's `isHealthy`).
    /// @param sellerActiveSeriesIds Complete active-series witness for the
    ///                       seller's POST-STATE portfolio.
    /// @return executionId   Deterministic execution identifier — bound to
    ///                       both intent hashes and re-derivable from events.
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
    ) external returns (bytes32 executionId);

    /// @notice Owner-triggered individual cancellation of a specific signed
    ///         order. Marks the order canonically cancelled — no future
    ///         `executeMatch` call may fill against it.
    /// @dev `msg.sender` MUST equal `envelope.owner`. Cancelling an
    ///      already-cancelled or fully-filled order reverts (idempotency at
    ///      the call site would obscure order-lifecycle state — the caller
    ///      MUST query current status first). Cancellation is reversible
    ///      only by re-signing a fresh envelope with a new salt/nonce.
    /// @param envelope The signed envelope identifying the order to cancel.
    ///                 The engine derives the canonical `orderId` from the
    ///                 EIP-712 typed-data digest of this envelope.
    function cancelSignedOrder(IntentHash.SignedActionEnvelope calldata envelope) external;

    /// @notice Owner-triggered bulk cancellation for a subKey. Advances the
    ///         canonical `minValidOrderNonceOf(subKey)` to `newMin`,
    ///         terminally invalidating every unfilled order previously
    ///         signed for that subKey whose `envelope.nonce < newMin`.
    /// @dev `msg.sender` MUST equal the canonical owner of the subaccount.
    ///      The advance MUST be strictly monotone — any call with
    ///      `newMin <= current` reverts. This is the ONLY safe primitive
    ///      for the owner to withdraw broad market presence at once
    ///      without individually cancelling every live order.
    /// @param subaccountId The subaccount whose min-valid-nonce is being
    ///                     advanced.
    /// @param newMin The new minimum valid order nonce. MUST be strictly
    ///               greater than the current value.
    function advanceMinValidOrderNonce(uint32 subaccountId, uint256 newMin) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Cumulative filled quantity for `orderId`, in 1e8 precision.
    ///         Zero for orders never filled or unknown to the engine.
    ///         Together with the signed `quantity1e8` (obtainable from the
    ///         reconstructed envelope), this determines remaining
    ///         capacity: `remaining = signedMax - filled`.
    function filledQuantityOf(bytes32 orderId) external view returns (uint128);

    /// @notice Whether `orderId` has been marked terminally cancelled by
    ///         either owner action (individual cancellation, min-nonce
    ///         advance) or engine-driven termination (IOC after first fill).
    function isOrderCancelled(bytes32 orderId) external view returns (bool);

    /// @notice The current minimum valid `envelope.nonce` for orders signed
    ///         against `subKey`. Any envelope with `nonce < minValid` is
    ///         terminally invalid.
    function minValidOrderNonceOf(bytes32 subKey) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every successful pair execution. Reconstruction of
    ///         book state does NOT require any backend or off-chain input
    ///         beyond the chain's event stream.
    event OptionOrderPairExecuted(
        bytes32 indexed executionId,
        bytes32 indexed buyerOrderId,
        bytes32 indexed sellerOrderId,
        uint256 seriesId,
        bytes32 buyerSubKey,
        bytes32 sellerSubKey,
        address buyerOwner,
        address sellerOwner,
        uint32 buyerSubaccountId,
        uint32 sellerSubaccountId,
        uint128 filledQuantity1e8,
        uint128 pricePerContract1e8,
        uint256 totalPremium,
        address premiumToken,
        uint8 buyerRole,
        uint8 sellerRole,
        uint128 buyerFee,
        uint128 sellerFee,
        address actor,
        uint16 eventVersion
    );

    /// @notice Emitted once per SIDE on every successful fill. Encodes the
    ///         canonical lifecycle transition needed to reconstruct
    ///         `filledQuantity1e8[orderId]` and terminal cancellation from
    ///         chain events alone.
    /// @param orderId Canonical EIP-712 order id (envelope digest).
    /// @param subKey Owning subKey of this side of the fill.
    /// @param seriesId Series id of the executed contract.
    /// @param side `SIDE_LONG (0)` for the buyer, `SIDE_SHORT (1)` for the seller.
    /// @param timeInForce Signed TIF for the order.
    /// @param fillQuantity1e8 Quantity filled by THIS execution.
    /// @param filledBefore1e8 Filled quantity BEFORE this execution.
    /// @param filledAfter1e8 Filled quantity AFTER this execution.
    /// @param orderMaxQuantity1e8 Signed maximum quantity for this order.
    /// @param terminal Whether this fill terminates the order for the future
    ///                 (fully-filled, IOC-terminated, FOK-consumed).
    /// @param terminalReason Encoded reason: 0 = not terminal, 1 = fully
    ///                       filled, 2 = IOC remainder terminated, 3 = FOK
    ///                       consumed.
    /// @param actor `msg.sender` of the `executeMatch` call.
    /// @param eventVersion Event schema version.
    event OptionOrderFilled(
        bytes32 indexed orderId,
        bytes32 indexed subKey,
        uint256 indexed seriesId,
        uint8 side,
        uint8 timeInForce,
        uint128 fillQuantity1e8,
        uint128 filledBefore1e8,
        uint128 filledAfter1e8,
        uint128 orderMaxQuantity1e8,
        bool terminal,
        uint8 terminalReason,
        address actor,
        uint16 eventVersion
    );

    /// @notice Emitted when an owner cancels a specific signed order.
    /// @param orderId Canonical EIP-712 order id.
    /// @param subKey Owning subKey.
    /// @param owner Canonical owner (`msg.sender`).
    /// @param actor `msg.sender` — always equals `owner` in V1.
    /// @param eventVersion Event schema version.
    event OptionOrderCancelled(
        bytes32 indexed orderId, bytes32 indexed subKey, address indexed owner, address actor, uint16 eventVersion
    );

    /// @notice Emitted when an owner advances a subKey's min-valid order
    ///         nonce. Every unfilled order previously signed for `subKey`
    ///         with `envelope.nonce < newMin` is terminally invalid.
    /// @param subKey The subaccount subKey.
    /// @param owner Canonical owner (`msg.sender`).
    /// @param previousMin Prior value.
    /// @param newMin New value (strictly greater than `previousMin`).
    /// @param actor `msg.sender`.
    /// @param eventVersion Event schema version.
    event OptionSubaccountMinValidOrderNonceAdvanced(
        bytes32 indexed subKey,
        address indexed owner,
        uint256 previousMin,
        uint256 newMin,
        address actor,
        uint16 eventVersion
    );

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor arguments missing required non-zero value.
    error InvalidDependency();
    /// @notice Two engine dependencies disagree on their canonical reference.
    error DependencyMismatch();
    /// @notice A caller-supplied order payload does not match its envelope's
    ///         `payloadHash`.
    error OrderPayloadHashMismatch(bytes32 expected, bytes32 provided);
    /// @notice The signature does not recover to (or 1271-approve as) the
    ///         canonical envelope owner.
    error InvalidSigner(bytes32 subKey, address recovered, address owner);
    /// @notice The two matched orders reference different Options series.
    error SeriesMismatch(uint256 buyerSeriesId, uint256 sellerSeriesId);
    /// @notice The two matched orders reference different premium tokens.
    error PremiumTokenMismatch(address buyerToken, address sellerToken);
    /// @notice Both orders are on the same side, or neither side is long/short.
    error SameSideMatch(uint8 buyerSide, uint8 sellerSide);
    /// @notice Both orders resolve to the same canonical subKey.
    error SelfTrade(bytes32 subKey);
    /// @notice Roles are inconsistent (both maker, both taker, or invalid values).
    error InvalidMakerTakerAssignment(uint8 buyerRole, uint8 sellerRole);
    /// @notice The matched execution premium exceeds a side's signed limit.
    error PremiumOutsideLimit(uint128 executionPrice, uint128 limit, uint8 side);
    /// @notice The two counterparties signed different execution premiums.
    error PremiumDisagreement(uint128 buyerPrice, uint128 sellerPrice);
    /// @notice The order quantity is zero.
    error QuantityZero();
    /// @notice The order series is zero, unknown, inactive, expired, or its
    ///         `settlementAsset` disagrees with the signed `premiumToken`.
    error InvalidSeries(uint256 seriesId);
    /// @notice A POST_ONLY-tagged order was submitted with a role other than
    ///         MAKER.
    error PostOnlyRoleViolation(bytes32 subKey);
    /// @notice A pair of TIF values that cannot coexist (e.g. two POST_ONLY sides).
    error InvalidTifCombination(uint8 buyerTif, uint8 sellerTif);
    /// @notice The fee hook returned `ok = false` or a rebate > 0 in V1.
    error FeeHookRejected(bytes32 subKey);
    /// @notice Post-execution health check failed for one side.
    error UnsafePostTradeMargin(bytes32 subKey);
    /// @notice The engine paused execution flag is set.
    error ExecutionPaused();

    /*//////////// Lifecycle-specific errors (post-patch) ////////////*/

    /// @notice Per-call `fillQuantity1e8` is zero, exceeds a side's remaining
    ///         signed capacity, or is otherwise invalid for the TIF context.
    error FillQuantityInvalid(uint128 requested, uint128 buyerRemaining, uint128 sellerRemaining);
    /// @notice The signed order has already been fully filled — no capacity
    ///         remains for another fill.
    error OrderAlreadyFullyFilled(bytes32 orderId, uint128 filled, uint128 signedMax);
    /// @notice The signed order was previously cancelled by the owner
    ///         (individual cancel, IOC termination, or min-nonce cutoff).
    error OrderCancelled(bytes32 orderId);
    /// @notice The signed envelope's `nonce` is strictly below the current
    ///         `minValidOrderNonceOf(subKey)` and is therefore terminally
    ///         invalid.
    error OrderNonceStale(bytes32 subKey, uint256 provided, uint256 minValid);
    /// @notice FOK order requires the entire signed quantity to be filled
    ///         in one call from a zero prior-filled state.
    error FokRequiresFullFillFromZero(bytes32 orderId, uint128 requested, uint128 signedMax, uint128 filledBefore);
    /// @notice `cancelSignedOrder` caller is not the canonical envelope owner.
    error NotOrderOwner(bytes32 orderId, address caller, address owner);
    /// @notice `advanceMinValidOrderNonce` was called with a value that would
    ///         not strictly advance the current cutoff.
    error MinValidOrderNonceNotAdvancing(bytes32 subKey, uint256 current, uint256 provided);

    /*/////// WP-09 signed positive-fee-cap enforcement error ///////*/

    /// @notice The actual positive fee amount returned by the fee hook
    ///         exceeds the per-side maximum implied by the order's signed
    ///         `maxPositiveFeePpm`. The signed cap is denominated in ppm of
    ///         the fill's premium basis. Applied per side independently;
    ///         rebates (zero positive fee) are never affected.
    error PositiveFeeRateExceedsSignedMaximum(uint128 feeAmount1e8, uint128 maxAllowed1e8, uint32 signedMaxPpm);

    /// @notice `executeMatch` was called with either side of the match
    ///         resident in a recovery-mode state that forbids new
    ///         risk-increasing execution. Introduced by WP-10A.
    error RecoveryActiveForSubaccount(bytes32 subKey);
}
