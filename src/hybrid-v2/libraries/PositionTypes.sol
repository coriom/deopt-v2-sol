// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title PositionTypes
/// @notice Shared position + liquidation types consumed by canonical ledger + risk interfaces.
/// @dev Transcribed verbatim from contract-spec 15. No behavior. No storage.
library PositionTypes {
    /// @notice Option position storage row per (subKey, seriesId).
    /// @dev
    ///  - `settlementState` values: 0 = unsettled, 1 = partially settled, 2 = fully settled.
    ///  - `exerciseState` values: 0 = unexercised, 1 = partially exercised, 2 = fully exercised.
    ///  - Precision `1e8` matches existing OptionProductRegistry conventions.
    struct OptionPosition {
        uint128 longQuantity1e8;
        uint128 shortQuantity1e8;
        uint128 premiumBasis1e8;
        uint128 shortPremiumRecv1e8;
        uint64 lastFillBlock;
        uint8 settlementState;
        uint8 exerciseState;
    }

    /// @notice Perp position storage row per (subKey, marketId).
    /// @dev
    ///  - `sizeSigned1e8`: positive = long, negative = short.
    ///  - `costBasisSigned1e18` + `realizedPnl1e18` use 1e18 precision for cost tracking.
    ///  - `fundingSnapshotSigned1e18` is the cumulative funding rate snapshot at last mutation.
    ///  - `liquidationState` values: 0 = healthy, 1 = flagged, 2 = liquidating.
    ///  - Reserved for perps engine milestone; interface-only in this cycle.
    struct PerpPosition {
        int128 sizeSigned1e8;
        int128 costBasisSigned1e18;
        int128 fundingSnapshotSigned1e18;
        int128 realizedPnl1e18;
        uint64 lastMutationBlock;
        uint8 liquidationState;
    }
}

/// @notice Aggregate liquidation status returned by the risk module.
enum LiquidationStatus {
    HEALTHY,
    WARN,
    ELIGIBLE_FOR_LIQUIDATION
}
