// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {PositionTypes} from "../libraries/PositionTypes.sol";

/// @title IOptionsPositionsLedger
/// @notice Canonical options-position storage boundary keyed by `subKey`.
/// @dev
///  Positions are indexed by `(subKey, seriesId)`. All mutations are
///  capability-gated via `ICollateralVault.engineCapabilityBits`.
///
///  Sibling isolation (INV-POS-05) is enforced by keying: no function accepts
///  a sibling subKey delta. Duplicate-fill prevention (INV-ACC-05) is enforced
///  by the calling matching engine's intent-hash consumption.
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete OptionsPositionsLedger implementation lives in
///  `ONCHAIN-SUBACCOUNT-OPTIONS-POSITIONS-LEDGER-V1` (WP-06). This file
///  introduces no state.
interface IOptionsPositionsLedger {
    /*//////////////////////////////////////////////////////////////
                             ENGINE MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Apply a fill delta to `subKey` on `seriesId`.
    /// @dev Caller MUST hold `Capabilities.CAP_APPLY_OPTIONS_POSITION_DELTA`.
    /// @param subKey The subaccount to mutate.
    /// @param seriesId The option series id.
    /// @param side Encoded side (`0` = long buy, `1` = short sell) per spec 04.
    /// @param quantity1e8 Fill quantity in 1e8 precision.
    /// @param price1e8 Fill price in 1e8 precision.
    function applyFill(bytes32 subKey, uint256 seriesId, uint8 side, uint128 quantity1e8, uint128 price1e8) external;

    /// @notice Apply an exercise on `subKey`'s long position in `seriesId`.
    /// @dev Caller MUST hold `Capabilities.CAP_SETTLE_OPTION`. Reverts if
    ///      insufficient long or already exercised.
    function applyExercise(bytes32 subKey, uint256 seriesId, uint128 quantity1e8, uint128 settlementPrice1e8) external;

    /// @notice Finalize settlement for `subKey`'s position in `seriesId`.
    /// @dev Caller MUST hold `Capabilities.CAP_SETTLE_OPTION`. Reverts if
    ///      already fully settled.
    function applySettlement(bytes32 subKey, uint256 seriesId, uint128 settlementPrice1e8) external;

    /// @notice Force-close a short position on `subKey` during liquidation.
    /// @dev Caller MUST hold `Capabilities.CAP_LIQUIDATE_OPTIONS`. Reverts if
    ///      insufficient short.
    function applyLiquidation(bytes32 subKey, uint256 seriesId, uint128 quantity1e8, bytes32 liquidatorSubKey) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fetch the position row for `(subKey, seriesId)`.
    function positionOf(bytes32 subKey, uint256 seriesId) external view returns (PositionTypes.OptionPosition memory);

    /// @notice Number of active series for `subKey`.
    /// @dev Hint for off-chain reconciliation iteration. Bounded per subKey
    ///      by the frozen `MAX_ACTIVE_SERIES_PER_SUBACCOUNT` cap.
    function activeSeriesCount(bytes32 subKey) external view returns (uint32);

    /// @notice Canonical, immutable, per-subaccount maximum active-series
    ///         count for this ledger deployment.
    /// @dev Product-owner decision `PRODUCT_OWNER_DECISION_FROZEN_FOR_HYBRID_V2_V1`
    ///      (Coriolan Morel, 2026-07-27). Value = 32 in V1. Raising it
    ///      requires a new versioned ledger deployment and cutover — there
    ///      is NO governance setter. `applyFill` reverts
    ///      `ActiveSeriesLimitExceeded` on any zero → non-zero transition
    ///      that would exceed this value.
    function maxActiveSeriesPerSubaccount() external view returns (uint32);

    /// @notice O(1) canonical membership check for the active-series set of `subKey`.
    /// @dev A series is "active" when its `OptionPosition` row has any non-zero
    ///      quantity or premium-accumulator field. Semantics match the
    ///      `activeSeriesCount` counter (WP-06 `_isPositionAllZero`).
    ///      Returns `false` on `bytes32(0)` subKey or zero `seriesId`.
    function isActiveSeries(bytes32 subKey, uint256 seriesId) external view returns (bool);

    /// @notice Complete on-chain proof that `seriesIds` is EXACTLY the set of
    ///         active option series for `subKey`.
    /// @dev The proof is discharged by the conjunction of three conditions,
    ///      any single failure of which returns `false`:
    ///        1. `seriesIds.length == activeSeriesCount(subKey)` — count equality
    ///           binds cardinality;
    ///        2. `seriesIds` is strictly increasing — enforces uniqueness AND a
    ///           canonical ordering (deterministic across callers);
    ///        3. every element is active per `isActiveSeries` — every supplied
    ///           id maps to a real active row.
    ///      Together these three conditions prove set equality: the supplied
    ///      array is a length-N set of distinct active members, and the active
    ///      set has cardinality N, therefore the supplied set IS the active set
    ///      (no omission, no duplication, no substitution).
    ///
    ///      Pure view: no reverts on invalid input. Consumers (e.g. WP-08
    ///      MarginEngine) MUST call this BEFORE treating any caller-supplied
    ///      series array as canonical portfolio evidence. Rationale + verdict
    ///      recorded in `ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_COMPLETENESS_AND_SLOT_PATCH.md`
    ///      §Part C.
    function verifyActiveSeriesArrayComplete(bytes32 subKey, uint256[] calldata seriesIds) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event OptionPositionOpened(
        bytes32 indexed subKey,
        uint256 indexed seriesId,
        uint8 indexed side,
        uint128 quantity1e8,
        uint128 price1e8,
        address engine,
        address owner,
        uint32 subaccountId,
        uint16 eventVersion
    );

    event OptionPositionModified(
        bytes32 indexed subKey,
        uint256 indexed seriesId,
        uint8 indexed side,
        int128 quantityDelta1e8,
        uint128 price1e8,
        address engine,
        address owner,
        uint32 subaccountId,
        uint16 eventVersion
    );

    event OptionPositionClosed(
        bytes32 indexed subKey,
        uint256 indexed seriesId,
        uint8 indexed side,
        address engine,
        address owner,
        uint32 subaccountId,
        uint16 eventVersion
    );

    event OptionExercised(
        bytes32 indexed subKey,
        uint256 indexed seriesId,
        uint128 quantity1e8,
        uint128 settlementPrice1e8,
        int256 delta,
        address owner,
        uint32 subaccountId,
        uint16 eventVersion
    );

    event OptionSettled(
        bytes32 indexed subKey,
        uint256 indexed seriesId,
        uint128 settlementPrice1e8,
        int256 pnlDelta,
        address owner,
        uint32 subaccountId,
        uint16 eventVersion
    );

    event OptionPositionLiquidated(
        bytes32 indexed subKey,
        uint256 indexed seriesId,
        uint128 quantity1e8,
        uint128 seizedCollateral,
        bytes32 indexed liquidatorSubKey,
        uint16 eventVersion
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error OptionSubKeyNotFound();
    error OptionSeriesNotFound();
    error OptionSeriesInactive();
    error OptionInvalidSide();
    error OptionQuantityZero();
    error OptionInsufficientLongForExercise();
    error OptionInsufficientShortForLiquidation();
    error OptionAlreadySettled();
    error OptionMissingCapability();
}
