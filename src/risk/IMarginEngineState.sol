// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMarginEngineState
/// @notice Read-only state interface for MarginEngine, consumed primarily by RiskModule.
/// @dev
///  Core invariants expected from any implementation:
///   - open-series enumeration MUST only contain live/open series (quantity != 0)
///   - quantity MUST NEVER be type(int128).min
///   - getters should be safe for risk computation and not introduce unbounded / inconsistent scans
///
///  Consistency requirements:
///   - if `isOpenSeries(trader, optionId) == true`, then `getPositionQuantity(trader, optionId) != 0`
///   - if `optionId` is returned by `getTraderSeries*`, then quantity must be non-zero
///   - `getTraderSeriesLength(trader)` must match the logical length of the OPEN series set
///
///  Purpose:
///   - keep RiskModule coupled only to stable read surfaces
///   - support pagination for bounded risk scans
///   - expose a few infra addresses for integration sanity checks
interface IMarginEngineState {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Net position on one option series.
    /// @dev
    ///  - quantity > 0 : net long
    ///  - quantity < 0 : net short
    ///  - quantity == 0 : closed / absent
    ///  - quantity MUST NOT be type(int128).min
    struct Position {
        int128 quantity;
    }

    /*//////////////////////////////////////////////////////////////
                                CORE READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total absolute short quantity across all OPEN option series for a trader.
    /// @dev Intended as a fast aggregate helper for conservative risk logic.
    function totalShortContracts(address trader) external view returns (uint256);

    /// @notice Position on a given option series for a trader.
    /// @dev Must return quantity = 0 if no position exists. Should not revert for unknown/empty state.
    function positions(address trader, uint256 optionId) external view returns (Position memory);

    /// @notice Full list of OPEN series for a trader.
    /// @dev
    ///  Must be consistent with `positions()`:
    ///   - every returned id must satisfy quantity != 0
    ///   - quantity must never be type(int128).min
    function getTraderSeries(address trader) external view returns (uint256[] memory);

    /// @notice Length of OPEN series set for a trader.
    function getTraderSeriesLength(address trader) external view returns (uint256);

    /// @notice Paginated slice [start, end) over OPEN series set.
    /// @dev Expected behavior:
    ///  - clamp out-of-range bounds gracefully
    ///  - return empty array if start >= len or start >= end
    ///  - do not revert solely because end > len
    function getTraderSeriesSlice(address trader, uint256 start, uint256 end)
        external
        view
        returns (uint256[] memory slice);

    /*//////////////////////////////////////////////////////////////
                         OPTIONAL / AUXILIARY READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of OptionProductRegistry.
    function optionRegistry() external view returns (address);

    /// @notice Address of CollateralVault.
    function collateralVault() external view returns (address);

    /// @notice Address of oracle router / oracle adapter.
    function oracle() external view returns (address);

    /// @notice Address of risk module currently wired to MarginEngine.
    function riskModule() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                         QUALITY-OF-LIFE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns quantity directly, avoiding a struct copy for consumers.
    /// @dev Must follow the same invariant: never type(int128).min.
    function getPositionQuantity(address trader, uint256 optionId) external view returns (int128);

    /// @notice True if the given series is currently OPEN for trader.
    /// @dev Must be consistent with `positions()` and `getPositionQuantity()`.
    function isOpenSeries(address trader, uint256 optionId) external view returns (bool);
}