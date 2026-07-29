// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IntentHash} from "../libraries/IntentHash.sol";
import {OptionOrderTypes} from "../options/OptionOrderTypes.sol";

/// @title IOptionMatchingEngine
/// @notice External surface for `OptionMatchingEngineV2` (WP-08B), the first
///         Hybrid V2 milestone permitted to atomically compose multiple
///         canonical economic modules in one transaction (D.2).
/// @dev
///  Scope (frozen):
///   - Executes ONE matched buyer/seller pair per call.
///   - The backend proposes the match off-chain (D.1). This interface makes
///     no assumption about matching strategy.
///   - Every economic mutation is atomic within the transaction: any failure
///     rolls back positions, premium, replay + fee state.
///
///  Non-goals:
///   - No RFQ / multi-leg execution.
///   - No settlement, exercise, liquidation, or recovery execution.
///   - No on-chain order book. No global order iteration.
///   - No fill-quantity accumulator: PF-2 (each signed intent is a single
///     exact-fill; see `OptionOrderTypes`).
interface IOptionMatchingEngine {
    /// @notice One-shot execution of a pre-matched buyer/seller pair.
    /// @param buyerEnvelope  Frozen `SignedActionEnvelope` binding the buyer
    ///                       to their `OptionOrder` payload
    /// @param buyerSignature Buyer's ECDSA or ERC-1271 signature over the
    ///                       envelope digest
    /// @param buyerOrder     Buyer's `OptionOrder` — its `hashOrder(...)`
    ///                       MUST equal `buyerEnvelope.payloadHash`
    /// @param sellerEnvelope Seller-side envelope
    /// @param sellerSignature Seller-side signature
    /// @param sellerOrder    Seller-side order — its `hashOrder(...)` MUST
    ///                       equal `sellerEnvelope.payloadHash`
    /// @param buyerActiveSeriesIds Complete active-series witness for the
    ///                       buyer's POST-STATE portfolio (used by
    ///                       MarginEngine's `isHealthy`)
    /// @param sellerActiveSeriesIds Complete active-series witness for the
    ///                       seller's POST-STATE portfolio
    /// @return executionId   Deterministic execution identifier — bound to
    ///                       both intent hashes and re-derivable from events
    function executeMatch(
        IntentHash.SignedActionEnvelope calldata buyerEnvelope,
        bytes calldata buyerSignature,
        OptionOrderTypes.OptionOrder calldata buyerOrder,
        IntentHash.SignedActionEnvelope calldata sellerEnvelope,
        bytes calldata sellerSignature,
        OptionOrderTypes.OptionOrder calldata sellerOrder,
        uint256[] calldata buyerActiveSeriesIds,
        uint256[] calldata sellerActiveSeriesIds
    ) external returns (bytes32 executionId);

    /// @notice Emitted on every successful pair execution. Reconstruction of
    ///         book state does NOT require any backend or off-chain input
    ///         beyond the chain's event stream.
    event OptionOrderPairExecuted(
        bytes32 indexed executionId,
        bytes32 indexed buyerOrderHash,
        bytes32 indexed sellerOrderHash,
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
    /// @notice The two counterparties signed different quantities.
    error QuantityDisagreement(uint128 buyerQty, uint128 sellerQty);
    /// @notice The order quantity is zero.
    error QuantityZero();
    /// @notice The order series is zero, unknown, inactive, expired, or its
    ///         `settlementAsset` disagrees with the signed `premiumToken`.
    error InvalidSeries(uint256 seriesId);
    /// @notice A POST_ONLY-tagged order was submitted with a role other than
    ///         MAKER.
    error PostOnlyRoleViolation(bytes32 subKey);
    /// @notice IOC + FOK combinations that are structurally incompatible.
    error InvalidTifCombination(uint8 buyerTif, uint8 sellerTif);
    /// @notice The fee hook returned `ok = false` or a rebate > 0 in V1.
    error FeeHookRejected(bytes32 subKey);
    /// @notice Post-execution health check failed for one side.
    error UnsafePostTradeMargin(bytes32 subKey);
    /// @notice The engine paused execution flag is set.
    error ExecutionPaused();
}
