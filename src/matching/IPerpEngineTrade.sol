// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPerpEngineTrade
/// @notice Minimal perpetual execution interface consumed by PerpMatchingEngine.
/// @dev
///  Conventions:
///   - sizeDelta1e8 = absolute trade size in 1e8 underlying units
///   - executionPrice1e8 = quote price normalized in 1e8
///   - buyerIsMaker:
///       * true  => buyer = maker, seller = taker
///       * false => buyer = taker, seller = maker
///   - buyer always receives +sizeDelta1e8
///   - seller always receives -sizeDelta1e8
///
///  Interface philosophy:
///   - keep the trade payload minimal and deterministic
///   - expose enough engine state for external execution infra
///   - avoid coupling matching to internal perp accounting details
interface IPerpEngineTrade {
    uint256 constant PRICE_SCALE = 1e8;

    struct Trade {
        address buyer;
        address seller;
        uint256 marketId;
        uint128 sizeDelta1e8;
        uint128 executionPrice1e8;
        bool buyerIsMaker;
    }

    /// @notice Matching engine currently authorized to submit trades.
    function matchingEngine() external view returns (address);

    /// @notice Owner of the perp engine.
    function owner() external view returns (address);

    /// @notice Legacy global pause flag.
    function paused() external view returns (bool);

    /// @notice Dedicated trading pause flag.
    /// @dev More precise than `paused()` for offchain execution infra.
    function tradingPaused() external view returns (bool);

    /// @notice Apply one matched perpetual trade.
    /// @dev Must revert if caller is not the authorized matching engine
    ///      or if trade validation / risk checks fail.
    function applyTrade(Trade calldata t) external;
}