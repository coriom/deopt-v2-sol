// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IOracleAdapter
/// @notice Minimal 1e8-price adapter consumed by `OptionsRiskModuleV2` for live
///         collateral valuation + Options intrinsic pricing (WP-08).
/// @dev
///  Bounded surface:
///   - Only two calls: `getPrice1e8` for revert-on-failure and `getPrice1e8Safe`
///     for the fail-closed path used by risk views.
///   - `updatedAt` MUST be strictly less than `block.timestamp + 1`. The risk
///     module additionally enforces its own configured freshness bound.
///   - No callback surface. No governance surface. No state mutation.
///
///  Convention (frozen):
///   - `getPrice1e8(base, quote)` returns the price of 1 unit of `base`
///     denominated in `quote`, normalized to 1e8. Downstream callers convert
///     to 1e18-scaled protocol values using the quote token's decimals.
///   - `updatedAt` is the source-side timestamp of the underlying feed. Router
///     implementations forward the freshest of any composed feeds.
///
///  Non-goals:
///   - NO write path (no publisher role, no push feed here).
///   - NO governance-set overrides (fallback + override policy is decided by
///     the concrete router/adapter's own timelock, out of scope for WP-08).
///   - NO Perps-specific price hooks (V1 has no Perps risk).
interface IOracleAdapter {
    /// @notice Returns the canonical 1e8-normalized price of `base` in `quote`.
    /// @dev Reverts if no usable feed exists. `updatedAt` is the source
    ///      timestamp of the freshest composed feed.
    function getPrice1e8(address base, address quote) external view returns (uint256 price1e8, uint256 updatedAt);

    /// @notice Best-effort variant: `ok = false` when no usable feed exists.
    ///         `price1e8` and `updatedAt` MUST both be zero when `ok = false`.
    function getPrice1e8Safe(address base, address quote)
        external
        view
        returns (uint256 price1e8, uint256 updatedAt, bool ok);
}
