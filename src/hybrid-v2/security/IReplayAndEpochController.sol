// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IReplayProtected} from "../interfaces/IReplayProtected.sol";

/// @title IReplayAndEpochController
/// @notice Extended replay boundary that adds recovery-epoch views + mutators to the
///         `IReplayProtected` foundation from WP-01.
/// @dev
///  Frozen contract for downstream matching engines (WP-08, future perps) + the escape
///  controller (WP-10). All storage semantics are documented in `ReplayAndEpochController`.
///
///  Owner-facing epoch advancement is self-service (msg.sender == owner):
///   - `advanceMyOwnerRecoveryEpoch()` invalidates every signed action for msg.sender
///     across every subaccount, bumping `_ownerRecoveryEpoch[msg.sender]`.
///   - `advanceMySubaccountRecoveryEpoch(subaccountId)` invalidates every signed action
///     targeting one specific subaccount belonging to msg.sender.
///
///  Recovery-authority-driven epoch advancement (WP-10 EscapeController) reaches
///  storage via the internal primitives; those primitives are not exposed in this
///  interface — inheritors expose their own authority-gated external functions.
///
///  Deadlines + envelope digests are validated by inheritors when a matching engine
///  processes a signed action. Their primitives are internal to `ReplayAndEpochController`.
interface IReplayAndEpochController is IReplayProtected {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when `_consumeIntent` succeeds.
    /// @dev Concrete engines invoke `_consumeIntent` as part of processing a signed
    ///      action; this event marks the intent hash as canonically consumed and provides
    ///      the reconstruction hook required by INV-AUTH-05 + INV-AUTH-06.
    /// @param intentHash EIP-712 digest of the consumed envelope.
    /// @param signer Declared signer identity for the envelope.
    /// @param engine Executing engine (equals `address(this)`).
    /// @param action Action namespace bound in the envelope.
    /// @param eventVersion Event schema version (spec 13).
    event IntentConsumed(
        bytes32 indexed intentHash, address indexed signer, address indexed engine, bytes32 action, uint16 eventVersion
    );

    /// @notice Emitted when a signer advances their own next nonce via `cancelNextNonce` or
    ///         `cancelNoncesUpTo`. Provides both old + new values for reconstruction.
    event NonceCancelled(
        address indexed signer, uint256 previousNonce, uint256 newNonce, address actor, uint16 eventVersion
    );

    /// @notice Emitted when a per-subaccount recovery epoch advances.
    /// @param subKey Canonical internal key for the subaccount.
    /// @param owner Canonical owner (informational — subKey is authoritative).
    /// @param subaccountId Subaccount id (informational).
    /// @param previousEpoch Prior epoch value.
    /// @param newEpoch New epoch value (previousEpoch + 1 for owner path).
    /// @param actor `msg.sender` that triggered the advance (may equal `owner` on the owner
    ///        path; may equal a recovery-authority contract on WP-10 paths).
    /// @param eventVersion Event schema version (spec 13).
    event SubaccountRecoveryEpochAdvanced(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 subaccountId,
        uint256 previousEpoch,
        uint256 newEpoch,
        address actor,
        uint16 eventVersion
    );

    /// @notice Emitted when an owner-wide recovery epoch advances.
    /// @param owner Canonical owner whose owner-wide epoch advanced.
    /// @param previousEpoch Prior epoch value.
    /// @param newEpoch New epoch value.
    /// @param actor `msg.sender` that triggered the advance.
    /// @param eventVersion Event schema version (spec 13).
    event OwnerRecoveryEpochAdvanced(
        address indexed owner, uint256 previousEpoch, uint256 newEpoch, address actor, uint16 eventVersion
    );

    /*//////////////////////////////////////////////////////////////
                              VIEW ACCESSORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Immutable Registry reference used to derive canonical subKeys for the owner path.
    function registry() external view returns (address);

    /// @notice Architecture version required in every signed envelope processed by this contract.
    function architectureVersion() external view returns (uint256);

    /// @notice Current per-subaccount recovery epoch for `subKey`. Zero means never advanced.
    function subaccountRecoveryEpoch(bytes32 subKey) external view returns (uint256);

    /// @notice Current owner-wide recovery epoch for `owner`. Zero means never advanced.
    function ownerRecoveryEpoch(address owner) external view returns (uint256);

    /// @notice Return both epochs required to build a fresh signed envelope for
    ///         (owner, subaccountId). Bounded O(1); the returned pair pins the effective
    ///         epoch context at the time of the call.
    /// @return ownerEpoch The current owner-wide recovery epoch for `owner`.
    /// @return subaccountEpoch The current per-subaccount recovery epoch for
    ///         `SubKey.deriveHere(registry, owner, subaccountId)`.
    function currentEpochPair(address owner, uint32 subaccountId)
        external
        view
        returns (uint256 ownerEpoch, uint256 subaccountEpoch);

    /*//////////////////////////////////////////////////////////////
                             OWNER-PATH MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Advance the caller's owner-wide recovery epoch by one. Invalidates every
    ///         signed action that binds the caller as `owner` at every subaccount.
    /// @dev msg.sender = the owner whose epoch is being advanced. Emits
    ///      `OwnerRecoveryEpochAdvanced(msg.sender, prev, prev+1, msg.sender, eventVersion)`.
    ///      Reverts `OwnerRecoveryEpochOverflow(owner)` if the current epoch equals
    ///      `type(uint256).max`.
    function advanceMyOwnerRecoveryEpoch() external;

    /// @notice Advance the per-subaccount recovery epoch for a subaccount belonging to
    ///         `msg.sender`. Invalidates every signed action targeting THAT subaccount.
    /// @dev Requires `registry.existsOf(msg.sender, subaccountId) == true`. Reverts
    ///      `SubaccountNotFoundForOwner` otherwise. Reverts
    ///      `SubaccountRecoveryEpochOverflow` on saturation.
    function advanceMySubaccountRecoveryEpoch(uint32 subaccountId) external;
}
