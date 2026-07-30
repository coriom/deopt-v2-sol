// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {RecoveryState, RecoveryScope} from "../libraries/RecoveryTypes.sol";

/// @title IEscapeController
/// @notice Recovery activation + safe-withdrawal + intent invalidation boundary.
/// @dev
///  Hybrid activation model M5 per escape-hatch design:
///   - Owner primitives always available (activate, cancel, invalidate, escapeWithdraw).
///   - Permissionless activation after objective on-chain conditions.
///   - Bounded governance surface (pause hard cap, fallback source list).
///
///  Recovery epoch semantics:
///   - `recoveryEpoch[subKey]` bumps on RECOVERY_PENDING → RECOVERY_ACTIVE and
///     via explicit `invalidateIntents` calls.
///   - `ownerRecoveryEpoch[owner]` bumps via `activateRecoveryAllSubaccounts`
///     and `invalidateAllIntents`.
///   - `effectiveRecoveryEpoch(subKey, owner) = max(...)`.
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete EscapeController implementation lives in
///  `ONCHAIN-SUBACCOUNT-ESCAPE-CONTROLLER-V1-A` (WP-10A). This file introduces
///  no state.
interface IEscapeController {
    /*//////////////////////////////////////////////////////////////
                              ACTIVATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initiate recovery on a specific `subaccountId` owned by the caller.
    function activateRecovery(uint32 subaccountId) external;

    /// @notice Initiate recovery across ALL subaccounts owned by the caller
    ///         by bumping the owner-wide recovery epoch.
    function activateRecoveryAllSubaccounts() external;

    /// @notice Cancel a pending recovery within the owner window.
    function cancelRecovery(uint32 subaccountId) external;

    /*//////////////////////////////////////////////////////////////
                       RESERVATION + WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Reserve a portion of the safe-withdrawable amount for later escape.
    function reserveRecoveryWithdrawal(uint32 subaccountId, address token, uint256 amount) external;

    /// @notice Withdraw up to the safe-withdrawable amount for `(subaccountId, token)`.
    function escapeWithdraw(uint32 subaccountId, address token, uint256 amount) external;

    /// @notice Bounded batch of escape withdrawals.
    /// @dev Length of `tokens` and `amounts` MUST match and MUST be <= MAX_BATCH_SIZE (16).
    function escapeWithdrawBatch(uint32 subaccountId, address[] calldata tokens, uint256[] calldata amounts) external;

    /*//////////////////////////////////////////////////////////////
                          INTENT INVALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Bump `recoveryEpoch[subKey]` to invalidate every outstanding signed intent
    ///         that targets `(msg.sender, subaccountId)`.
    function invalidateIntents(uint32 subaccountId) external;

    /// @notice Bump `ownerRecoveryEpoch[msg.sender]` to invalidate every outstanding
    ///         signed intent that targets the caller across all subaccounts.
    function invalidateAllIntents() external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function recoveryStateOf(bytes32 subKey) external view returns (RecoveryState);
    function recoveryEpochOf(bytes32 subKey) external view returns (uint256);
    function ownerRecoveryEpochOf(address owner) external view returns (uint256);
    function effectiveRecoveryEpoch(bytes32 subKey, address owner) external view returns (uint256);
    function pendingReservationOf(bytes32 subKey, address token) external view returns (uint256);
    function reservationExpiryOf(bytes32 subKey, address token) external view returns (uint64);

    /// @notice Block number at which the current recovery pause auto-clears.
    /// @dev Returns 0 when recovery is not paused.
    function recoveryPausedUntil() external view returns (uint64);

    /// @notice Timestamp at which `activateRecovery(subaccountId)` becomes eligible for permissionless callers.
    function activationEligibleAt(bytes32 subKey) external view returns (uint64);

    /// @notice `true` iff the target subaccount MAY execute a new
    ///         risk-increasing operation (state is `NORMAL` or
    ///         `CANCELLED`). Consumed by the Vault and Options engine
    ///         boundaries to fail closed during recovery. Introduced by
    ///         WP-10A.
    function isRiskIncreasingOperationAllowed(bytes32 subKey) external view returns (bool);

    /// @notice `true` iff the target subaccount is currently in a state
    ///         from which the `RecoveryFinalizer` may transition it to
    ///         `RECOVERED`. Introduced by WP-10A; consumed by WP-10B.
    function isFinalizationReady(bytes32 subKey) external view returns (bool);

    /// @notice Timestamp at which the target subaccount was moved to
    ///         `RECOVERED`. Zero when never finalized. Introduced by WP-10B.
    function finalizedAt(bytes32 subKey) external view returns (uint64);

    /// @notice Canonical `RecoveryFinalizer` address. Zero until governance
    ///         initialises it. Introduced by WP-10B.
    function recoveryFinalizer() external view returns (address);

    /// @notice Governance one-shot init of the `RecoveryFinalizer`
    ///         authorised to advance `RECOVERY_ACTIVE → RECOVERED`.
    ///         Introduced by WP-10B.
    function initializeRecoveryFinalizer(address finalizer) external;

    /// @notice Advance a subaccount from `RECOVERY_ACTIVE` to
    ///         `RECOVERED`. Only the initialised `RecoveryFinalizer` may call.
    ///         Introduced by WP-10B.
    function markFinalized(bytes32 subKey) external;

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Pause recovery activation for `autoClearInBlocks` blocks.
    /// @dev Caller is guardian OR owner. `autoClearInBlocks` MUST be
    ///      <= RECOVERY_PAUSE_MAX_DURATION (INV-OPS-07).
    function pauseRecovery(uint64 autoClearInBlocks) external;

    /// @notice Unpause recovery activation.
    /// @dev Owner-only via ProtocolTimelock.
    function unpauseRecovery() external;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RecoveryRequested(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 indexed subaccountId,
        uint256 nextEpoch,
        uint64 activationEligibleAt,
        uint16 eventVersion
    );

    event RecoveryActivated(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 indexed subaccountId,
        uint256 newEpoch,
        uint16 eventVersion
    );

    event RecoveryCancelled(
        bytes32 indexed subKey, address indexed owner, uint32 indexed subaccountId, uint16 eventVersion
    );

    event RecoveryEpochIncremented(
        bytes32 indexed subKey, address indexed owner, RecoveryScope scope, uint256 newEpoch, uint16 eventVersion
    );

    event RecoveryWithdrawalReserved(
        bytes32 indexed subKey, address indexed token, uint256 amount, uint64 expiry, uint16 eventVersion
    );

    event RecoveryWithdrawalExecuted(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 indexed subaccountId,
        address token,
        uint256 amount,
        uint16 eventVersion
    );

    event RecoveryPauseSet(bool paused, uint64 autoClearBlock, address indexed by, uint16 eventVersion);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error RecoveryAlreadyPending();
    error RecoveryNotPending();
    error RecoveryActivationDelayElapsed();
    error RecoveryPaused();
    error RecoveryNotActive();
    error RecoveryNotEligible();
    error UnauthorizedRecoveryCaller();
    error UnsafeRecoveryWithdrawal();
    error TokenPaused();
    error LiquidationPending();
    error BatchLengthMismatch();
    error BatchTooLarge();
    error PauseDurationTooLong();
}
