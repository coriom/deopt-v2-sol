// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IOptionsPositionsLedger} from "../interfaces/IOptionsPositionsLedger.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {PositionTypes} from "../libraries/PositionTypes.sol";
import {Capabilities} from "../libraries/Capabilities.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title OptionsPositionsLedger
/// @notice Canonical immutable per-`subKey` Options-position accounting for the
///         DeOpt V2 hybrid subaccount architecture (WP-06).
/// @dev
///  Frozen scope (spec 04 + spec 15):
///   - `positions[subKey][seriesId]` — one `OptionPosition` struct per pair.
///   - Gross long + short quantities (never signed-net). Long and short MAY
///     coexist on the same `(subKey, seriesId)` — this is a hedged position.
///   - `applyFill` accumulates the specified side only; no automatic netting.
///   - `applyExercise` decrements the LONG side only; monotonic
///     `exerciseState`.
///   - `applySettlement` marks the position settled; monotonic
///     `settlementState`; fully settled positions cannot be re-mutated.
///   - `applyLiquidation` decrements the SHORT side only.
///   - `activeSeriesCount[subKey]` tracks the number of series with any
///     non-zero position field; incremented on the transition from
///     all-zero to non-zero, decremented on the reverse.
///
///  Explicitly OUT OF SCOPE (owned by later milestones):
///   - Collateral custody, reservations, capabilities (owned by WP-04).
///   - Signature / replay validation (owned by WP-05 + WP-08 engine).
///   - Product / series registry validity (owned by future
///     OptionProductRegistry consumer or WP-08 engine — the ledger accepts
///     any non-zero opaque `uint256 seriesId`).
///   - Vault balance debits / credits, premium transfers, protocol fees,
///     rebates, oracle prices, liquidation collateral seizure — owned by
///     WP-08 MarginEngine / OptionMatchingEngine + WP-04B Vault. The
///     ledger emits informational settlement / exercise / liquidation
///     events with the pass-through fields it CAN observe; the paired
///     Vault event (emitted by the engine in the same atomic transaction)
///     carries the actual economic delta.
///
///  Capability model:
///   - The Vault (spec 07) is the sole capability authority. Every mutation
///     consults `ICollateralVault.engineCapabilityBits(msg.sender)` and
///     requires the exact `CAP_*` bit set for that action:
///       - `applyFill`         : `CAP_APPLY_OPTIONS_POSITION_DELTA`
///       - `applyExercise`     : `CAP_SETTLE_OPTION`
///       - `applySettlement`   : `CAP_SETTLE_OPTION`
///       - `applyLiquidation`  : `CAP_LIQUIDATE_OPTIONS`
///   - No local `authorizedEngine` boolean. No local capability mapping.
///   - Guardian revocation on the Vault immediately blocks future
///     mutations (the ledger reads the current bits on every call); it
///     does NOT alter existing position state.
///   - Governance / guardian have NO direct position-editor path.
///
///  Replay model:
///   - The ledger does NOT maintain a fill / execution / settlement id
///     mapping. Duplicate protection lives on the calling engine's WP-05
///     replay controller (per spec 04 §Idempotency FROZEN). Executing an
///     engine call twice is prevented by the engine's per-signer sequential
///     nonce or its consumed-intent hash; if either the ledger call or the
///     engine's own post-ledger logic reverts, the whole transaction
///     unwinds atomically, so no partial ledger mutation can outlive a
///     failed engine execution.
///
///  Reconstruction:
///   - Every mutation emits an event carrying the readable `owner` +
///     `subaccountId` alongside the indexed `subKey`. Full history is
///     replayable from block 0 (INV-REC-02 / INV-REC-06).
contract OptionsPositionsLedger is IOptionsPositionsLedger {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical identity source. Immutable at construction.
    ISubaccountRegistry public immutable REGISTRY;

    /// @notice Capability authority (the CollateralVault). Immutable at construction.
    /// @dev The ledger reads `engineCapabilityBits(msg.sender)` on every mutation.
    ///      No local capability storage; the vault is the sole grant / revoke path
    ///      (spec 07 + WP-03 FROZEN).
    ICollateralVault public immutable CAPABILITY_AUTHORITY;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Side value used by `applyFill` and side-scoped events for a long fill.
    uint8 public constant SIDE_LONG = 0;

    /// @notice Side value used by `applyFill` and side-scoped events for a short fill.
    uint8 public constant SIDE_SHORT = 1;

    /// @notice Lifecycle state values shared by `settlementState` and `exerciseState`.
    uint8 public constant STATE_NONE = 0;
    uint8 public constant STATE_PARTIAL = 1;
    uint8 public constant STATE_FULL = 2;

    /// @notice Frozen V1 per-subaccount maximum active-series count.
    /// @dev Product-owner decision `PRODUCT_OWNER_DECISION_FROZEN_FOR_HYBRID_V2_V1`
    ///      (Coriolan Morel, 2026-07-27). Immutable for the deployment; there
    ///      is NO governance setter. Raising this value requires a new
    ///      versioned ledger deployment and cutover. Rationale + full
    ///      enforcement contract in
    ///      `ONCHAIN_SUBACCOUNT_RISK_EXECUTION_BOUNDS_AND_COLLATERAL_UNIVERSE_V1.md`.
    uint32 public constant MAX_ACTIVE_SERIES_PER_SUBACCOUNT = 32;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Canonical isolated position per (subKey, seriesId).
    mapping(bytes32 => mapping(uint256 => PositionTypes.OptionPosition)) internal _positions;

    /// @dev Number of series with any non-zero position for a subKey. Increments on
    ///      first non-zero mutation for a series; decrements when the series returns
    ///      to fully-zero (long + short + basis + received all zero). Bounded per
    ///      subKey by the number of distinct series the subaccount has traded.
    mapping(bytes32 => uint32) internal _activeSeriesCount;

    /*//////////////////////////////////////////////////////////////
                          CONTRACT-LOCAL ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor arg `registry_` is the zero address.
    error InvalidRegistry();

    /// @notice Constructor arg `capabilityAuthority_` is the zero address.
    error InvalidCapabilityAuthority();

    /// @notice `subKey` argument is `bytes32(0)`.
    error SubKeyRequired();

    /// @notice `seriesId` argument is `0`.
    error SeriesIdRequired();

    /// @notice `liquidatorSubKey` argument to `applyLiquidation` is `bytes32(0)`.
    error LiquidatorSubKeyRequired();

    /// @notice `liquidatorSubKey` argument to `applyLiquidation` is not registered
    ///         in the Registry.
    error LiquidatorSubKeyNotFound();

    /// @notice `applyExercise` cannot mutate a position whose `settlementState`
    ///         is already `STATE_FULL`.
    error OptionExerciseAfterFullSettlement();

    /// @notice `applyLiquidation` cannot mutate a position whose `settlementState`
    ///         is already `STATE_FULL`.
    error OptionLiquidationAfterFullSettlement();

    /// @notice `applyFill` on a position whose settlement state is already
    ///         `STATE_FULL` is rejected.
    error OptionFillAfterFullSettlement();

    /// @notice A `uint128`-typed field would exceed `type(uint128).max`.
    error OptionQuantityOverflow();

    /// @notice A `uint128` premium accumulator would exceed `type(uint128).max`.
    error OptionPremiumBasisOverflow();

    /// @notice `activeSeriesCount[subKey]` would exceed `type(uint32).max`.
    /// @dev Preserved as a defensive floor even though the frozen
    ///      `MAX_ACTIVE_SERIES_PER_SUBACCOUNT` (32) trips first.
    error OptionActiveSeriesOverflow();

    /// @notice A zero → non-zero position transition would push
    ///         `activeSeriesCount[subKey]` above the frozen
    ///         `MAX_ACTIVE_SERIES_PER_SUBACCOUNT` (32).
    /// @dev Enforced only on the zero → non-zero transition
    ///      (see `_maybeIncrementActive`). Mutations of already-active
    ///      positions, risk-reducing paths (exercise, liquidation,
    ///      settlement), and reactivation after freeing capacity are NOT
    ///      blocked.
    error ActiveSeriesLimitExceeded(bytes32 subKey, uint32 currentCount, uint32 maximum);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param registry_ Canonical SubaccountRegistry deployment. MUST NOT be zero.
    /// @param capabilityAuthority_ CollateralVault deployment. MUST NOT be zero.
    ///        The vault is the sole capability grant / revoke path (spec 07).
    constructor(address registry_, address capabilityAuthority_) {
        if (registry_ == address(0)) revert InvalidRegistry();
        if (capabilityAuthority_ == address(0)) revert InvalidCapabilityAuthority();
        REGISTRY = ISubaccountRegistry(registry_);
        CAPABILITY_AUTHORITY = ICollateralVault(capabilityAuthority_);
    }

    /*//////////////////////////////////////////////////////////////
                         MUTATIONS (interface impl)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOptionsPositionsLedger
    function applyFill(bytes32 subKey, uint256 seriesId, uint8 side, uint128 quantity1e8, uint128 price1e8) external {
        _requireCapability(Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA);
        (address owner, uint32 subaccountId) = _requireKnownSubaccount(subKey);
        if (seriesId == 0) revert SeriesIdRequired();
        if (quantity1e8 == 0) revert OptionQuantityZero();

        PositionTypes.OptionPosition storage p = _positions[subKey][seriesId];
        if (p.settlementState == STATE_FULL) revert OptionFillAfterFullSettlement();

        bool sideOpen; // pre-mutation zero-side flag for OptionPositionOpened

        if (side == SIDE_LONG) {
            sideOpen = p.longQuantity1e8 == 0;
            uint256 newLong = uint256(p.longQuantity1e8) + uint256(quantity1e8);
            if (newLong > type(uint128).max) revert OptionQuantityOverflow();

            uint256 addedBasis = _premiumFromFill(quantity1e8, price1e8);
            uint256 newBasis = uint256(p.premiumBasis1e8) + addedBasis;
            if (newBasis > type(uint128).max) revert OptionPremiumBasisOverflow();

            _maybeIncrementActive(subKey, p);
            // Re-opening long after a fully-exercised prior long: the exercise
            // state reflects the CURRENT long-side batch. Reset so downstream
            // invariants ("exerciseState == FULL implies long == 0") remain
            // sound across American-style reuse of a series.
            if (sideOpen && p.exerciseState == STATE_FULL) {
                p.exerciseState = STATE_NONE;
            }
            p.longQuantity1e8 = uint128(newLong);
            p.premiumBasis1e8 = uint128(newBasis);
        } else if (side == SIDE_SHORT) {
            sideOpen = p.shortQuantity1e8 == 0;
            uint256 newShort = uint256(p.shortQuantity1e8) + uint256(quantity1e8);
            if (newShort > type(uint128).max) revert OptionQuantityOverflow();

            uint256 addedRecv = _premiumFromFill(quantity1e8, price1e8);
            uint256 newRecv = uint256(p.shortPremiumRecv1e8) + addedRecv;
            if (newRecv > type(uint128).max) revert OptionPremiumBasisOverflow();

            _maybeIncrementActive(subKey, p);
            p.shortQuantity1e8 = uint128(newShort);
            p.shortPremiumRecv1e8 = uint128(newRecv);
        } else {
            revert OptionInvalidSide();
        }

        p.lastFillBlock = uint64(block.number);

        if (sideOpen) {
            emit OptionPositionOpened(
                subKey, seriesId, side, quantity1e8, price1e8, msg.sender, owner, subaccountId, Versions.EVENT_VERSION
            );
        } else {
            emit OptionPositionModified(
                subKey,
                seriesId,
                side,
                int128(uint128(quantity1e8)),
                price1e8,
                msg.sender,
                owner,
                subaccountId,
                Versions.EVENT_VERSION
            );
        }
    }

    /// @inheritdoc IOptionsPositionsLedger
    function applyExercise(bytes32 subKey, uint256 seriesId, uint128 quantity1e8, uint128 settlementPrice1e8) external {
        _requireCapability(Capabilities.CAP_SETTLE_OPTION);
        (address owner, uint32 subaccountId) = _requireKnownSubaccount(subKey);
        if (seriesId == 0) revert SeriesIdRequired();
        if (quantity1e8 == 0) revert OptionQuantityZero();

        PositionTypes.OptionPosition storage p = _positions[subKey][seriesId];
        if (p.settlementState == STATE_FULL) revert OptionExerciseAfterFullSettlement();
        if (p.exerciseState == STATE_FULL) revert OptionInsufficientLongForExercise();
        if (quantity1e8 > p.longQuantity1e8) revert OptionInsufficientLongForExercise();

        uint128 newLong;
        unchecked {
            newLong = p.longQuantity1e8 - quantity1e8;
        }
        p.longQuantity1e8 = newLong;
        p.exerciseState = newLong == 0 ? STATE_FULL : STATE_PARTIAL;
        p.lastFillBlock = uint64(block.number);

        // Economic PnL / asset transfer is owned by the settlement engine (WP-08).
        // The ledger emits the informational event with `delta = 0`; the engine
        // emits a paired richer Vault event in the same atomic transaction.
        emit OptionExercised(
            subKey, seriesId, quantity1e8, settlementPrice1e8, int256(0), owner, subaccountId, Versions.EVENT_VERSION
        );

        if (newLong == 0) {
            emit OptionPositionClosed(
                subKey, seriesId, SIDE_LONG, msg.sender, owner, subaccountId, Versions.EVENT_VERSION
            );
        }
        _maybeDecrementActive(subKey, p);
    }

    /// @inheritdoc IOptionsPositionsLedger
    function applySettlement(bytes32 subKey, uint256 seriesId, uint128 settlementPrice1e8) external {
        _requireCapability(Capabilities.CAP_SETTLE_OPTION);
        (address owner, uint32 subaccountId) = _requireKnownSubaccount(subKey);
        if (seriesId == 0) revert SeriesIdRequired();

        PositionTypes.OptionPosition storage p = _positions[subKey][seriesId];
        if (p.settlementState == STATE_FULL) revert OptionAlreadySettled();

        // Snapshot active-set membership BEFORE mutation. A settlement of a
        // never-touched series is a state-transition-only no-op (no economic
        // effect) and MUST NOT alter `_activeSeriesCount`. Unlike `applyExercise`
        // / `applyLiquidation` (which revert if the relevant side is zero and
        // therefore guarantee `wasActive == true`), `applySettlement` accepts a
        // clean row — so we guard the decrement explicitly. Required by
        // INV-COMP-I2 (count equals |active set|) — patched under
        // `RISK-MODULE-V2-COMPLETENESS-AND-SLOT-PATCH`.
        bool wasActive = !_isPositionAllZero(p);

        // Settlement zeros both sides that remain — long is settled at intrinsic
        // (economic value credited to the vault by WP-08 in the same tx); short
        // obligations are extinguished at the settlement price. The ledger owns
        // ONLY the position-quantity + state transition. Both sides transition to
        // zero, and both sides individually emit `OptionPositionClosed` if they
        // were non-zero pre-settlement.
        bool hadLong = p.longQuantity1e8 > 0;
        bool hadShort = p.shortQuantity1e8 > 0;

        p.longQuantity1e8 = 0;
        p.shortQuantity1e8 = 0;
        p.settlementState = STATE_FULL;
        if (hadLong && p.exerciseState != STATE_FULL) {
            // Any remaining long that was not exercised is settled implicitly.
            p.exerciseState = STATE_FULL;
        }
        p.lastFillBlock = uint64(block.number);

        emit OptionSettled(subKey, seriesId, settlementPrice1e8, int256(0), owner, subaccountId, Versions.EVENT_VERSION);
        if (hadLong) {
            emit OptionPositionClosed(
                subKey, seriesId, SIDE_LONG, msg.sender, owner, subaccountId, Versions.EVENT_VERSION
            );
        }
        if (hadShort) {
            emit OptionPositionClosed(
                subKey, seriesId, SIDE_SHORT, msg.sender, owner, subaccountId, Versions.EVENT_VERSION
            );
        }
        if (wasActive) {
            _maybeDecrementActive(subKey, p);
        }
    }

    /// @inheritdoc IOptionsPositionsLedger
    function applyLiquidation(bytes32 subKey, uint256 seriesId, uint128 quantity1e8, bytes32 liquidatorSubKey)
        external
    {
        _requireCapability(Capabilities.CAP_LIQUIDATE_OPTIONS);
        (address owner, uint32 subaccountId) = _requireKnownSubaccount(subKey);
        if (seriesId == 0) revert SeriesIdRequired();
        if (quantity1e8 == 0) revert OptionQuantityZero();
        if (liquidatorSubKey == bytes32(0)) revert LiquidatorSubKeyRequired();
        // Registry-back the liquidator subKey so we cannot attribute a seizure
        // to a non-existent account. This validation is O(1).
        if (REGISTRY.ownerOf(liquidatorSubKey) == address(0)) revert LiquidatorSubKeyNotFound();

        PositionTypes.OptionPosition storage p = _positions[subKey][seriesId];
        if (p.settlementState == STATE_FULL) revert OptionLiquidationAfterFullSettlement();
        if (quantity1e8 > p.shortQuantity1e8) revert OptionInsufficientShortForLiquidation();

        uint128 newShort;
        unchecked {
            newShort = p.shortQuantity1e8 - quantity1e8;
        }
        p.shortQuantity1e8 = newShort;
        p.lastFillBlock = uint64(block.number);

        // Ledger emits `seizedCollateral = 0` — the actual collateral seizure
        // amount is owned by WP-08 MarginEngine + WP-04B Vault which emit
        // paired events in the same atomic transaction.
        emit OptionPositionLiquidated(
            subKey, seriesId, quantity1e8, uint128(0), liquidatorSubKey, Versions.EVENT_VERSION
        );

        if (newShort == 0) {
            emit OptionPositionClosed(
                subKey, seriesId, SIDE_SHORT, msg.sender, owner, subaccountId, Versions.EVENT_VERSION
            );
        }
        _maybeDecrementActive(subKey, p);

        // Silence stale-fill-block linter — liquidator context is bound into the event above.
        owner;
        subaccountId;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IOptionsPositionsLedger
    function positionOf(bytes32 subKey, uint256 seriesId) external view returns (PositionTypes.OptionPosition memory) {
        return _positions[subKey][seriesId];
    }

    /// @inheritdoc IOptionsPositionsLedger
    function activeSeriesCount(bytes32 subKey) external view returns (uint32) {
        return _activeSeriesCount[subKey];
    }

    /// @inheritdoc IOptionsPositionsLedger
    function maxActiveSeriesPerSubaccount() external pure returns (uint32) {
        return MAX_ACTIVE_SERIES_PER_SUBACCOUNT;
    }

    /// @inheritdoc IOptionsPositionsLedger
    function isActiveSeries(bytes32 subKey, uint256 seriesId) external view returns (bool) {
        if (subKey == bytes32(0) || seriesId == 0) return false;
        return !_isPositionAllZero(_positions[subKey][seriesId]);
    }

    /// @inheritdoc IOptionsPositionsLedger
    function verifyActiveSeriesArrayComplete(bytes32 subKey, uint256[] calldata seriesIds)
        external
        view
        returns (bool)
    {
        if (subKey == bytes32(0)) return false;
        // Early-reject inputs beyond the frozen per-subaccount cap. Because
        // `_maybeIncrementActive` enforces the same cap on the mutation side,
        // no valid canonical set can exceed it — a longer supplied array is
        // by construction non-canonical. Rejecting up front bounds worst-case
        // gas at `MAX_ACTIVE_SERIES_PER_SUBACCOUNT` per verify call.
        if (seriesIds.length > MAX_ACTIVE_SERIES_PER_SUBACCOUNT) return false;
        // Length must equal the canonical active-series count. Any missing or
        // extra active series breaks this equality before any per-element cost.
        if (seriesIds.length != _activeSeriesCount[subKey]) return false;
        uint256 prev = 0;
        uint256 n = seriesIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 sid = seriesIds[i];
            // Reject zero seriesId (matches mutation-side `SeriesIdRequired`) +
            // enforce strictly increasing order (uniqueness + canonical order).
            if (sid == 0) return false;
            if (sid <= prev) return false;
            // Every element must correspond to an active position row.
            if (_isPositionAllZero(_positions[subKey][sid])) return false;
            prev = sid;
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _requireCapability(uint256 requiredMask) internal view {
        uint256 bits = CAPABILITY_AUTHORITY.engineCapabilityBits(msg.sender);
        if (bits & requiredMask != requiredMask) revert OptionMissingCapability();
    }

    /// @dev Registry-backed subKey validation. Returns the canonical owner +
    ///      subaccountId that the ledger binds into events. Account 0 subKeys
    ///      cannot exist (Registry rejects `subaccountId == 0`), so a valid
    ///      Registry lookup already implies a non-zero subaccountId.
    function _requireKnownSubaccount(bytes32 subKey) internal view returns (address owner, uint32 subaccountId) {
        if (subKey == bytes32(0)) revert SubKeyRequired();
        owner = REGISTRY.ownerOf(subKey);
        if (owner == address(0)) revert OptionSubKeyNotFound();
        subaccountId = REGISTRY.subaccountIdOf(subKey);
    }

    /// @dev `applyFill` pre-mutation hook: if EVERY position field is currently
    ///      zero (i.e. the fill is a zero → non-zero transition), enforce the
    ///      frozen per-subaccount `MAX_ACTIVE_SERIES_PER_SUBACCOUNT` cap and
    ///      then increment the active-series counter. Enforcement happens
    ///      BEFORE the position row is mutated, so a rejected 33rd activation
    ///      produces zero partial state (RISK-BOUND-I3).
    function _maybeIncrementActive(bytes32 subKey, PositionTypes.OptionPosition storage p) internal {
        if (_isPositionAllZero(p)) {
            uint32 c = _activeSeriesCount[subKey];
            if (c >= MAX_ACTIVE_SERIES_PER_SUBACCOUNT) {
                revert ActiveSeriesLimitExceeded(subKey, c, MAX_ACTIVE_SERIES_PER_SUBACCOUNT);
            }
            // Defensive overflow guard preserved. Under the frozen cap the
            // limit trips first, but we keep the type-max floor to protect
            // against a future cap raise beyond `type(uint32).max`.
            if (c == type(uint32).max) revert OptionActiveSeriesOverflow();
            unchecked {
                _activeSeriesCount[subKey] = c + 1;
            }
        }
    }

    /// @dev Post-mutation hook for exercise / settlement / liquidation: if the
    ///      mutation zeroed every position field, decrement the active-series
    ///      counter. `settlementState == STATE_FULL` counts as "still active" in
    ///      the counter until the position row is fully zero, so we compare the
    ///      quantity/basis fields directly.
    function _maybeDecrementActive(bytes32 subKey, PositionTypes.OptionPosition storage p) internal {
        if (_isPositionAllZero(p)) {
            uint32 c = _activeSeriesCount[subKey];
            if (c > 0) {
                unchecked {
                    _activeSeriesCount[subKey] = c - 1;
                }
            }
        }
    }

    /// @dev A position is considered "not active" when every quantity + basis
    ///      accumulator is zero. Lifecycle flags (settled / exercised) are
    ///      historical and do not by themselves make the series active; the
    ///      counter tracks reconciler iteration surface.
    function _isPositionAllZero(PositionTypes.OptionPosition storage p) internal view returns (bool) {
        return p.longQuantity1e8 == 0 && p.shortQuantity1e8 == 0 && p.premiumBasis1e8 == 0 && p.shortPremiumRecv1e8 == 0;
    }

    /// @dev Compute `quantity1e8 * price1e8 / 1e8` in `uint256` to avoid uint128
    ///      overflow. Returned value is then range-checked at the caller against
    ///      `type(uint128).max` before being stored in the `uint128` field.
    function _premiumFromFill(uint128 quantity1e8, uint128 price1e8) internal pure returns (uint256) {
        return (uint256(quantity1e8) * uint256(price1e8)) / 1e8;
    }
}
