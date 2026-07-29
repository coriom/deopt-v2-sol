// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title OptionOrderTypes
/// @notice Canonical EIP-712 payload types for signed single-series Options
///         orders consumed by `OptionMatchingEngineV2` (WP-08B).
/// @dev
///  Pure library. No storage. No behavior.
///
///  Design (Part D verdict `OPTION_ORDER_TYPED_DATA_MODEL_RESOLVED`):
///   - The outer envelope is the FROZEN
///     `IntentHash.SignedActionEnvelope` from WP-05, which binds:
///       * owner + subaccountId + subKey (identity);
///       * signer + engine (verifying contract);
///       * architectureVersion (rejects cross-architecture replay);
///       * nonce (sequential per-signer per-engine);
///       * deadline (unix, non-zero);
///       * ownerRecoveryEpoch + subaccountRecoveryEpoch (WP-05 replay state);
///       * action (constant per order kind — see `ACTION_OPTION_ORDER`);
///       * payloadHash = keccak256(abi.encode(OptionOrderPayload typehash + fields)).
///   - The inner payload is the `OptionOrder` struct below. Both counterparties
///     sign an outer envelope whose `payloadHash` binds their own OptionOrder.
///   - `abi.encode` is used exclusively — never `abi.encodePacked` — so
///     ambiguous byte-boundary collisions between `bytes32` fields are
///     structurally impossible.
///
///  Frozen semantics (superseded by
///  `ONCHAIN-SUBACCOUNT-OPTION-ORDER-LIFECYCLE-AND-NONCE-V2-PATCH`
///  verdict `OPTION_ORDER_FILLED_QUANTITY_CANONICAL_ONCHAIN`):
///   - `quantity1e8` is the SIGNED MAXIMUM fill quantity — an upper bound
///     the signer authorises the engine to fill in aggregate. The engine
///     stores canonical `filledQuantity1e8[orderId]` on chain and rejects
///     any per-call `fillQuantity1e8` that would push cumulative filled
///     past this maximum. GTC "remaining" state is authoritatively
///     on chain.
///   - `pricePerContract1e8` is the EXACT executable premium per contract
///     in 1e8 quote-token units. The counterparty's signed order MUST agree.
///     `limitPricePerContract1e8` bounds the acceptable execution price
///     (buyer signs a maximum, seller signs a minimum).
///   - The `nonce` field on the outer envelope is a signer-chosen ORDER
///     nonce, not a sequential replay counter. It participates in the
///     envelope digest (thus in the canonical `orderId`) AND in bulk
///     cancellation via `minValidOrderNonceOf(subKey)` — an owner-managed
///     monotonic cutoff. Individual per-order cancellation is available
///     via `cancelSignedOrder(envelope)`.
///
///  Time-in-force (superseded by lifecycle patch — Part O):
///   - `TIF_GTC = 0`   — order is executable until `deadline`. Cumulative
///                       on-chain `filledQuantity1e8[orderId]` may be
///                       incremented across multiple executions until it
///                       reaches `quantity1e8` (fully filled) or the
///                       owner cancels the order.
///   - `TIF_IOC = 1`   — the order MAY be executed at most once. Any
///                       successful fill (partial or full) TERMINALLY
///                       invalidates the order for the future — the engine
///                       records it as cancelled after the fill regardless
///                       of remaining signed quantity.
///   - `TIF_FOK = 2`   — the order MUST be executed exactly once, exactly
///                       fully. The per-call `fillQuantity1e8` MUST equal
///                       `quantity1e8` AND `filledQuantity1e8[orderId]`
///                       MUST be zero before the call. Any partial-fill
///                       attempt reverts atomically.
///   - `TIF_POST_ONLY = 3` — order is executable only in the MAKER role.
///                       The engine enforces role via a signed `role`
///                       field (see below); a POST_ONLY order signed with
///                       `role != ROLE_MAKER` reverts pre-consumption.
///
///  Role attribution (Part N + Part O + Part V test 26):
///   - Each order signs an explicit `role` field: `ROLE_MAKER = 0` or
///     `ROLE_TAKER = 1`. The engine enforces that ONE side is maker and the
///     OTHER is taker (never both maker, never both taker). Post-only only
///     accepts orders whose signed role equals `ROLE_MAKER`.
///
///  Side (Part N):
///   - `SIDE_LONG = 0` (buyer) — matches
///     `OptionsPositionsLedger.SIDE_LONG`.
///   - `SIDE_SHORT = 1` (seller) — matches
///     `OptionsPositionsLedger.SIDE_SHORT`.
///   Every matched pair MUST have opposite sides.
///
///  Non-signed metadata:
///   - `salt` — allows a signer to distinguish otherwise-identical intents.
///     Bound into `payloadHash` so different salts produce different
///     intent hashes.
library OptionOrderTypes {
    /// @notice Frozen action tag emitted in the WP-05 IntentConsumed event
    ///         when this engine consumes an option-order intent.
    bytes32 internal constant ACTION_OPTION_ORDER = keccak256("OPTION_ORDER_MATCH_V1");

    // --- Side encoding (matches OptionsPositionsLedger). ---
    uint8 internal constant SIDE_LONG = 0;
    uint8 internal constant SIDE_SHORT = 1;

    // --- Role encoding. ---
    uint8 internal constant ROLE_MAKER = 0;
    uint8 internal constant ROLE_TAKER = 1;

    // --- Time-in-force encoding. ---
    uint8 internal constant TIF_GTC = 0;
    uint8 internal constant TIF_IOC = 1;
    uint8 internal constant TIF_FOK = 2;
    uint8 internal constant TIF_POST_ONLY = 3;

    /// @notice EIP-712 typehash string for the `OptionOrder` payload.
    /// @dev Field order and names are FROZEN. Every field is a fixed-size
    ///      primitive so `abi.encode` produces a length-stable pre-image.
    string internal constant OPTION_ORDER_TYPE = "OptionOrder(" "uint256 seriesId," "uint8 side," "uint128 quantity1e8,"
        "uint128 pricePerContract1e8," "uint128 limitPricePerContract1e8," "address premiumToken," "uint8 timeInForce,"
        "uint8 role," "bytes32 salt" ")";

    /// @notice Precomputed EIP-712 typehash for the `OptionOrder` payload.
    bytes32 internal constant OPTION_ORDER_TYPEHASH = keccak256(bytes(OPTION_ORDER_TYPE));

    /// @notice Canonical payload struct signed by ONE counterparty of an Options match.
    /// @dev Both counterparties independently sign an outer envelope whose
    ///      `payloadHash = keccak256(abi.encode(<their OptionOrder>))`. The engine
    ///      cross-validates the two payloads for compatibility (opposite sides,
    ///      same series + premium token, compatible price + quantity + TIF + role).
    struct OptionOrder {
        uint256 seriesId; // canonical OptionProductRegistry series id
        uint8 side; // SIDE_LONG (buyer) or SIDE_SHORT (seller)
        uint128 quantity1e8; // SIGNED MAXIMUM fill quantity (post-patch)
        uint128 pricePerContract1e8; // agreed execution premium per contract, 1e8
        uint128 limitPricePerContract1e8; // buyer max / seller min, 1e8
        address premiumToken; // MUST equal series.settlementAsset
        uint8 timeInForce; // TIF_*
        uint8 role; // ROLE_MAKER or ROLE_TAKER
        bytes32 salt; // signer-controlled uniqueness field
    }

    /// @notice EIP-712 struct hash of an `OptionOrder` payload. Bound into the
    ///         outer envelope's `payloadHash`.
    function hashOrder(OptionOrder memory order) internal pure returns (bytes32 h) {
        h = keccak256(
            abi.encode(
                OPTION_ORDER_TYPEHASH,
                order.seriesId,
                order.side,
                order.quantity1e8,
                order.pricePerContract1e8,
                order.limitPricePerContract1e8,
                order.premiumToken,
                order.timeInForce,
                order.role,
                order.salt
            )
        );
    }
}
