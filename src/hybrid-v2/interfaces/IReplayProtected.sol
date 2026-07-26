// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IReplayProtected
/// @notice Common per-engine replay-protection boundary.
/// @dev
///  Every matching engine implementing `IOptionMatchingEngine` or
///  `IPerpMatchingEngine` MUST also implement this interface (per contract-spec 08).
///
///  Semantics:
///   - `nonces(signer)` returns the next expected sequential nonce for `signer`
///     on THIS engine. Nonces are per-signer per-engine (no cross-engine coupling).
///   - `cancelNextNonce()` increments the caller's nonce by 1.
///   - `cancelNoncesUpTo(nextValid)` bulk-invalidates all nonces below `nextValid`.
///   - `isIntentConsumed(intentHash)` returns whether the D.2 intent hash has been
///     consumed on this engine. Intent-hash consumption prevents replay even when
///     off-chain state is lost (INV-AUTH-06).
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete replay + epoch mixins land in `ONCHAIN-SUBACCOUNT-REPLAY-AND-EPOCH-FOUNDATION-V1`
///  (WP-05). This file introduces no state.
interface IReplayProtected {
    /// @notice Next expected nonce for `signer` on this engine.
    function nonces(address signer) external view returns (uint256);

    /// @notice Cancel the caller's next nonce (increment by 1).
    function cancelNextNonce() external;

    /// @notice Bulk-cancel every nonce for the caller below `nextValid`.
    function cancelNoncesUpTo(uint256 nextValid) external;

    /// @notice Whether the D.2 intent hash has been consumed on this engine.
    function isIntentConsumed(bytes32 intentHash) external view returns (bool);
}
