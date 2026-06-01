// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title ICollateralVaultInternalTransfer
/// @notice V2G-R1 — proposed ABI extension on {CollateralVault} that
///         lets an internal-account holder (e.g. {ProtocolFeeVault})
///         move funds out to an external `to` recipient.
/// @dev    This interface is intentionally orphaned at V2G-R1 — the
///         live `CollateralVault` contract does NOT implement it yet.
///         The vault references it solely as a forward-compatible
///         hook for V2G-R5 (live deploy) and uses a mock
///         implementation in the V2G-R1 offline test suite.
///
///         Final on-chain shape will be reviewed during the
///         V2G-R PR window; for now this interface pins the call
///         signature so the production vault can compile and be
///         exercised offline without touching the live CV.
interface ICollateralVaultInternalTransfer {
    /// @notice Transfer `amount` of `asset` from the caller's
    ///         internal-account balance to the external `to` recipient.
    /// @dev    The implementation is expected to gate this with
    ///         `msg.sender == from` semantics — the caller can only
    ///         move its own balance, never another account's. The
    ///         underlying transfer mechanism (e.g. ERC20 `safeTransfer`,
    ///         idle-balance sync) is left to the CV implementation.
    function transferFromInternalAccount(address asset, address to, uint256 amount) external;
}
