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
    /// @dev Hint for off-chain reconciliation iteration. Bounded per subKey.
    function activeSeriesCount(bytes32 subKey) external view returns (uint32);

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
