// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IFallbackOracle
/// @notice Fallback + TWAP price view boundary for recovery finalization.
/// @dev
///  Read-only interface. Concrete implementations wire specific sources
///  (Chainlink historical rounds, Pyth EMA, Uniswap V3 TWAPs) subject to
///  governance timelock per escape-hatch design.
///
///  Returning `(0, 0)` MUST indicate unavailability without reverting so
///  the finalizer can fall through the F-A → F-D hierarchy safely.
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete FallbackOracle implementation lives in
///  `ONCHAIN-SUBACCOUNT-RECOVERY-FINALIZER-V1-B` (WP-10B). This file
///  introduces no state.
interface IFallbackOracle {
    /// @notice Fallback price for `underlying` and the observation timestamp.
    /// @return price1e8 Fallback price in 1e8 precision; `0` if unavailable.
    /// @return observedAt Unix seconds at which the fallback source observed the price; `0` if unavailable.
    function fallbackPrice(address underlying) external view returns (uint256 price1e8, uint256 observedAt);

    /// @notice TWAP price for `underlying` over `windowSeconds`.
    /// @return price1e8 TWAP price in 1e8 precision; `0` if unavailable.
    /// @return windowStart Unix seconds at which the window began; `0` if unavailable.
    /// @return windowEnd Unix seconds at which the window ended; `0` if unavailable.
    function twapPrice(address underlying, uint32 windowSeconds)
        external
        view
        returns (uint256 price1e8, uint256 windowStart, uint256 windowEnd);
}
