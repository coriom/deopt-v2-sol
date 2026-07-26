// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {PositionTypes} from "../libraries/PositionTypes.sol";

/// @title IPerpsPositionsLedger (future)
/// @notice Reserved canonical perp-position storage boundary keyed by `subKey`.
/// @dev
///  Options ship first per Principle 14. This interface freezes the boundary
///  contract for the future perps engine milestone so downstream design work
///  (risk module, capabilities, event schema, reconstruction) can proceed
///  without ABI drift.
///
///  No engine implementation is authorized by this milestone. The concrete
///  PerpsPositionsLedger implementation is deferred to a future perps
///  milestone.
///
///  Sibling isolation (INV-POS-05) is enforced by keying. Duplicate-fill
///  prevention (INV-ACC-05) is enforced by the calling matching engine's
///  intent-hash consumption.
interface IPerpsPositionsLedger {
    /*//////////////////////////////////////////////////////////////
                             ENGINE MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Apply a perp fill delta.
    /// @dev Caller MUST hold `Capabilities.CAP_APPLY_PERP_POSITION_DELTA`.
    function applyPerpFill(bytes32 subKey, uint256 marketId, int128 sizeDelta1e8, uint128 price1e8, bool takerIsBuyer)
        external;

    /// @notice Apply the cumulative funding index for `(subKey, marketId)`.
    /// @dev Caller MUST hold `Capabilities.CAP_APPLY_PERP_POSITION_DELTA`.
    function applyFundingIndex(bytes32 subKey, uint256 marketId) external;

    /// @notice Force-close a perp position on `subKey` during liquidation.
    /// @dev Caller MUST hold `Capabilities.CAP_LIQUIDATE_PERPS`.
    function applyPerpLiquidation(bytes32 subKey, uint256 marketId, int128 sizeCloseDelta1e8, bytes32 liquidatorSubKey)
        external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fetch the perp position row for `(subKey, marketId)`.
    function positionOf(bytes32 subKey, uint256 marketId) external view returns (PositionTypes.PerpPosition memory);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PerpPositionOpened(
        bytes32 indexed subKey,
        uint256 indexed marketId,
        int128 sizeSigned1e8,
        uint128 price1e8,
        address owner,
        uint32 subaccountId,
        uint16 eventVersion
    );

    event PerpPositionModified(
        bytes32 indexed subKey,
        uint256 indexed marketId,
        int128 sizeDelta1e8,
        uint128 price1e8,
        address owner,
        uint32 subaccountId,
        uint16 eventVersion
    );

    event PerpPositionClosed(
        bytes32 indexed subKey, uint256 indexed marketId, address owner, uint32 subaccountId, uint16 eventVersion
    );

    event PerpFundingApplied(
        bytes32 indexed subKey, uint256 indexed marketId, int128 fundingDelta1e18, uint16 eventVersion
    );

    event PerpPositionLiquidated(
        bytes32 indexed subKey,
        uint256 indexed marketId,
        int128 sizeCloseDelta1e8,
        uint128 seizedCollateral,
        bytes32 indexed liquidatorSubKey,
        uint16 eventVersion
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error PerpSubKeyNotFound();
    error PerpMarketNotFound();
    error PerpMarketInactive();
    error PerpSizeDeltaZero();
    error PerpMissingCapability();
    error PerpNotLiquidatable();
}
