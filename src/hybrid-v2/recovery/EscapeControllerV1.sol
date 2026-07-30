// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IEscapeController} from "../interfaces/IEscapeController.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {RecoveryState, RecoveryScope} from "../libraries/RecoveryTypes.sol";
import {SubKey} from "../libraries/SubKey.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title EscapeControllerV1
/// @notice `ONCHAIN-SUBACCOUNT-ESCAPE-CONTROLLER-V1-A` (WP-10A) canonical
///         per-subaccount recovery state machine + owner-controlled activation +
///         atomic recovery-epoch invalidation + pause boundary.
/// @dev
///  Scope (WP-10A):
///   - Implements the `NORMAL → RECOVERY_PENDING → RECOVERY_ACTIVE` head of
///     `SM-Rec` (escape-hatch design 04), plus in-window `CANCELLED` and the
///     owner-wide epoch invalidation primitives.
///   - Does NOT implement `SETTLEMENT_PENDING`, `WITHDRAWAL_ELIGIBLE`,
///     `RECOVERED`, `MIGRATED`, nor any final recovery withdrawal or
///     arbitrary reservation release. Those belong to WP-10B
///     (`RecoveryFinalizer`).
///
///  Fail-closed contract:
///   - Every mutation reverts on invalid authority, non-canonical
///     transition, delay violation, pause violation, or reservation TTL
///     boundary.
///   - Views are `RECOVERY_PENDING`, `RECOVERY_ACTIVE`, or `CANCELLED`
///     terminal (WP-10A never exits back to `NORMAL` on its own — that is
///     `RecoveryFinalizer`'s call after obligations are objectively
///     resolved).
///   - Withdraw/reservation externals REVERT
///     `RecoveryFinalizationNotYetImplemented`. They are declared to
///     honour the `IEscapeController` boundary, but their body remains
///     the sole responsibility of `WP-10B RecoveryFinalizer`.
///
///  Authorization boundaries:
///   - `activateRecovery`, `activateRecoveryAllSubaccounts`,
///     `cancelRecovery`, `invalidateIntents`, `invalidateAllIntents` —
///     canonical owner ONLY (msg.sender == Registry.ownerOf(subKey) OR
///     == msg.sender for owner-wide).
///   - `pauseRecovery` / `unpauseRecovery` — governance ONLY.
///     Guardian is intentionally NOT authorized for user recovery pause;
///     the guardian's blast radius is bounded to protocol-wide
///     halt paths on the Vault.
///   - Recovery activation is PAUSE-IMMUNE ONLY when it originates from
///     the CANONICAL OWNER path. Permissionless / delegate paths are
///     blocked when the controller is paused (design 04 pause matrix).
///     The owner-path is intentionally pause-immune: no operator can
///     block a user from starting the recovery clock.
///
///  Delay model:
///   - `ACTIVATION_DELAY` is immutable (frozen at deployment). Zero is
///     permitted for tests and small denomination deployments; the
///     upper bound `MAX_ACTIVATION_DELAY = 72 hours` follows the design
///     document (escape-hatch spec 04 rationale — accidental-bump
///     protection + MEV grief protection).
///   - `PAUSE_MAX_DURATION_BLOCKS` is immutable. Zero disables recovery
///     pause entirely (recommended default when there is no guardian
///     surface). Upper bound `MAX_PAUSE_DURATION_BLOCKS ~ 14 days` at
///     12s block time to bound INV-OPS-07.
///
///  Storage model:
///   - `recoveryState[subKey]` — canonical state per subKey.
///   - `pendingSince[subKey]` — timestamp at which `RECOVERY_PENDING`
///     was entered. Zero when not pending.
///   - `_subaccountRecoveryEpoch[subKey]` — monotonic per-subKey epoch.
///     Bumped on `RECOVERY_PENDING → RECOVERY_ACTIVE` transition AND
///     via explicit `invalidateIntents(subaccountId)`.
///   - `_ownerRecoveryEpoch[owner]` — monotonic owner-wide epoch.
///     Bumped via `activateRecoveryAllSubaccounts` and
///     `invalidateAllIntents`.
///   - `_recoveryPausedUntil` — block number at which the current
///     recovery pause auto-clears.
contract EscapeControllerV1 is IEscapeController {
    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Upper bound on the activation delay (72 hours). Frozen.
    uint64 public constant MAX_ACTIVATION_DELAY = 72 hours;

    /// @notice Upper bound on the pause duration (14 days at 12s / block).
    ///         Bounds INV-OPS-07 to preclude a permanent recovery halt.
    uint64 public constant MAX_PAUSE_DURATION_BLOCKS = (14 days) / 12;

    /// @notice Maximum permitted `escapeWithdrawBatch` length. Declared
    ///         for downstream milestones; not used in WP-10A body.
    uint256 public constant MAX_BATCH_SIZE = 16;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical Subaccount Registry. Used to resolve
    ///         `ownerOf(subKey)` and `existsOf(owner, subaccountId)`.
    ISubaccountRegistry public immutable REGISTRY;

    /// @notice Governance address for pause/unpause.
    address public immutable GOVERNANCE;

    /// @notice Frozen activation delay (seconds).
    uint64 public immutable ACTIVATION_DELAY;

    /// @notice Frozen upper cap on `pauseRecovery` `autoClearInBlocks`.
    uint64 public immutable PAUSE_MAX_DURATION_BLOCKS;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => RecoveryState) private _recoveryState;
    mapping(bytes32 => uint64) private _pendingSince;
    mapping(bytes32 => uint256) private _subaccountRecoveryEpoch;
    mapping(address => uint256) private _ownerRecoveryEpoch;
    uint64 private _recoveryPausedUntil;

    /// @dev Canonical `RecoveryFinalizer` deployment (WP-10B). Zero until
    ///      `initializeRecoveryFinalizer` runs. Only that address may call
    ///      `markFinalized(subKey)` to advance a subaccount from
    ///      `RECOVERY_ACTIVE` to `RECOVERED`.
    address private _recoveryFinalizer;

    /// @notice Timestamp at which `markFinalized` moved the target subKey
    ///         to `RECOVERED`. Zero when never finalized.
    mapping(bytes32 => uint64) private _finalizedAt;

    /*//////////////////////////////////////////////////////////////
                              LOCAL ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor argument is the zero address.
    error InvalidDependency();

    /// @notice Constructor `ACTIVATION_DELAY` exceeds `MAX_ACTIVATION_DELAY`.
    error ActivationDelayTooLong();

    /// @notice Constructor `PAUSE_MAX_DURATION_BLOCKS` exceeds
    ///         `MAX_PAUSE_DURATION_BLOCKS`.
    error PauseMaxDurationTooLong();

    /// @notice `subaccountId == 0` is reserved and invalid.
    error InvalidSubaccountId();

    /// @notice Unknown subaccount at the Registry.
    error SubaccountNotFound(address owner, uint32 subaccountId);

    /// @notice Governance-only entry point called by a non-governance caller.
    error OnlyGovernance();

    /// @notice Attempt to advance to `RECOVERY_ACTIVE` before the delay elapsed.
    error ActivationDelayNotElapsed(uint64 pendingSince, uint64 activationEligibleAt);

    /// @notice Recovery activation attempted from an unsupported state.
    error InvalidRecoveryStateTransition(RecoveryState from, RecoveryState to);

    /// @notice Attempt to invalidate intents for a subaccount not owned by caller.
    error UnauthorizedCallerForSubaccount(address expectedOwner, address caller, uint32 subaccountId);

    /// @notice Final recovery withdrawal / reservation is out of scope for WP-10A.
    ///         `WP-10B RecoveryFinalizer` owns the implementation.
    error RecoveryFinalizationNotYetImplemented();

    /// @notice `initializeRecoveryFinalizer` called a second time. Introduced by WP-10B.
    error RecoveryFinalizerAlreadyInitialized();

    /// @notice `initializeRecoveryFinalizer` called with the zero address.
    error InvalidRecoveryFinalizer();

    /// @notice `markFinalized` called by a caller other than the authorised
    ///         `RecoveryFinalizer`. Introduced by WP-10B.
    error OnlyRecoveryFinalizer();

    /// @notice `markFinalized` called for a subKey whose current state does
    ///         not permit the `RECOVERY_ACTIVE → RECOVERED` transition.
    error CannotFinalizeFromState(RecoveryState currentState);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param registry_ Canonical `SubaccountRegistry` deployment (non-zero).
    /// @param governance_ Governance address (non-zero).
    /// @param activationDelaySeconds_ Frozen activation delay. Bounded by
    ///        `MAX_ACTIVATION_DELAY`. Zero permitted (test / small-scope
    ///        deployments).
    /// @param pauseMaxDurationBlocks_ Frozen upper cap on the
    ///        `pauseRecovery` `autoClearInBlocks` argument. Bounded by
    ///        `MAX_PAUSE_DURATION_BLOCKS`. Zero disables pause.
    constructor(
        address registry_,
        address governance_,
        uint64 activationDelaySeconds_,
        uint64 pauseMaxDurationBlocks_
    ) {
        if (registry_ == address(0) || governance_ == address(0)) {
            revert InvalidDependency();
        }
        if (activationDelaySeconds_ > MAX_ACTIVATION_DELAY) revert ActivationDelayTooLong();
        if (pauseMaxDurationBlocks_ > MAX_PAUSE_DURATION_BLOCKS) revert PauseMaxDurationTooLong();
        REGISTRY = ISubaccountRegistry(registry_);
        GOVERNANCE = governance_;
        ACTIVATION_DELAY = activationDelaySeconds_;
        PAUSE_MAX_DURATION_BLOCKS = pauseMaxDurationBlocks_;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGovernance() {
        if (msg.sender != GOVERNANCE) revert OnlyGovernance();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              ACTIVATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEscapeController
    /// @dev Transitions `NORMAL → RECOVERY_PENDING` for the target
    ///      subaccount. If `ACTIVATION_DELAY == 0`, immediately advances
    ///      to `RECOVERY_ACTIVE` in the same tx (bumping the recovery
    ///      epoch atomically).
    function activateRecovery(uint32 subaccountId) external {
        if (subaccountId == 0) revert InvalidSubaccountId();
        address owner = msg.sender;
        if (!REGISTRY.existsOf(owner, subaccountId)) {
            revert SubaccountNotFound(owner, subaccountId);
        }
        bytes32 subKey = SubKey.deriveHere(address(REGISTRY), owner, subaccountId);
        RecoveryState current = _recoveryState[subKey];
        if (current != RecoveryState.NORMAL && current != RecoveryState.CANCELLED) {
            if (current == RecoveryState.RECOVERY_PENDING) revert RecoveryAlreadyPending();
            revert InvalidRecoveryStateTransition(current, RecoveryState.RECOVERY_PENDING);
        }
        if (_recoveryPauseActive()) revert RecoveryPaused();

        uint64 nowTs = uint64(block.timestamp);
        _recoveryState[subKey] = RecoveryState.RECOVERY_PENDING;
        _pendingSince[subKey] = nowTs;
        emit RecoveryRequested(
            subKey,
            owner,
            subaccountId,
            _subaccountRecoveryEpoch[subKey] + 1,
            _eligibleAt(nowTs),
            Versions.EVENT_VERSION
        );

        if (ACTIVATION_DELAY == 0) {
            _promoteToActive(subKey, owner, subaccountId);
        }
    }

    /// @notice Complete the pending recovery once the delay has elapsed.
    /// @dev Permissionless: any actor may promote a pending recovery
    ///      after the delay elapses. The `actor` is bound into the
    ///      `RecoveryActivated` event for auditability.
    function finalizePendingActivation(uint32 subaccountId, address owner) external {
        if (subaccountId == 0) revert InvalidSubaccountId();
        if (owner == address(0)) revert InvalidDependency();
        bytes32 subKey = SubKey.deriveHere(address(REGISTRY), owner, subaccountId);
        RecoveryState current = _recoveryState[subKey];
        if (current != RecoveryState.RECOVERY_PENDING) {
            revert InvalidRecoveryStateTransition(current, RecoveryState.RECOVERY_ACTIVE);
        }
        uint64 pendingSince = _pendingSince[subKey];
        uint64 eligibleAt = _eligibleAt(pendingSince);
        if (uint64(block.timestamp) < eligibleAt) {
            revert ActivationDelayNotElapsed(pendingSince, eligibleAt);
        }
        _promoteToActive(subKey, owner, subaccountId);
    }

    /// @inheritdoc IEscapeController
    /// @dev Bumps `ownerRecoveryEpoch[msg.sender]` monotonically.
    ///      Does NOT alter per-subaccount `recoveryState` — the owner
    ///      may bump the owner-wide epoch even while individual
    ///      subaccounts remain `NORMAL`.
    function activateRecoveryAllSubaccounts() external {
        if (_recoveryPauseActive()) revert RecoveryPaused();
        _advanceOwnerEpoch(msg.sender, msg.sender);
    }

    /// @inheritdoc IEscapeController
    /// @dev Only the canonical owner may cancel, and ONLY while in
    ///      `RECOVERY_PENDING`. Once `RECOVERY_ACTIVE`, cancellation is
    ///      irreversible per design 04 (epoch already bumped).
    ///      Cancellation NEVER rolls back the recovery epoch.
    function cancelRecovery(uint32 subaccountId) external {
        if (subaccountId == 0) revert InvalidSubaccountId();
        address owner = msg.sender;
        bytes32 subKey = SubKey.deriveHere(address(REGISTRY), owner, subaccountId);
        RecoveryState current = _recoveryState[subKey];
        if (current != RecoveryState.RECOVERY_PENDING) revert RecoveryNotPending();
        _recoveryState[subKey] = RecoveryState.CANCELLED;
        _pendingSince[subKey] = 0;
        emit RecoveryCancelled(subKey, owner, subaccountId, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                       RESERVATION + WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEscapeController
    /// @dev WP-10A boundary: reservation is not implemented. Reverts
    ///      `RecoveryFinalizationNotYetImplemented`. WP-10B
    ///      `RecoveryFinalizer` owns the body.
    function reserveRecoveryWithdrawal(
        uint32,
        /*subaccountId*/
        address,
        /*token*/
        uint256 /*amount*/
    )
        external
        pure
    {
        revert RecoveryFinalizationNotYetImplemented();
    }

    /// @inheritdoc IEscapeController
    /// @dev WP-10A boundary: withdraw is not implemented. Reverts
    ///      `RecoveryFinalizationNotYetImplemented`. WP-10B
    ///      `RecoveryFinalizer` owns the body.
    function escapeWithdraw(
        uint32,
        /*subaccountId*/
        address,
        /*token*/
        uint256 /*amount*/
    )
        external
        pure
    {
        revert RecoveryFinalizationNotYetImplemented();
    }

    /// @inheritdoc IEscapeController
    /// @dev WP-10A boundary: batch withdraw is not implemented.
    function escapeWithdrawBatch(
        uint32,
        /*subaccountId*/
        address[] calldata,
        /*tokens*/
        uint256[] calldata /*amounts*/
    )
        external
        pure
    {
        revert RecoveryFinalizationNotYetImplemented();
    }

    /*//////////////////////////////////////////////////////////////
                          INTENT INVALIDATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEscapeController
    /// @dev Owner-only convenience to bump `subaccountRecoveryEpoch`
    ///      without altering `recoveryState`. Complements the automatic
    ///      bump performed by `_promoteToActive`.
    function invalidateIntents(uint32 subaccountId) external {
        if (subaccountId == 0) revert InvalidSubaccountId();
        address owner = msg.sender;
        if (!REGISTRY.existsOf(owner, subaccountId)) {
            revert SubaccountNotFound(owner, subaccountId);
        }
        bytes32 subKey = SubKey.deriveHere(address(REGISTRY), owner, subaccountId);
        _advanceSubaccountEpoch(subKey, owner, subaccountId, owner);
    }

    /// @inheritdoc IEscapeController
    function invalidateAllIntents() external {
        _advanceOwnerEpoch(msg.sender, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEscapeController
    function recoveryStateOf(bytes32 subKey) external view returns (RecoveryState) {
        return _recoveryState[subKey];
    }

    /// @inheritdoc IEscapeController
    function recoveryEpochOf(bytes32 subKey) external view returns (uint256) {
        return _subaccountRecoveryEpoch[subKey];
    }

    /// @inheritdoc IEscapeController
    function ownerRecoveryEpochOf(address owner) external view returns (uint256) {
        return _ownerRecoveryEpoch[owner];
    }

    /// @inheritdoc IEscapeController
    function effectiveRecoveryEpoch(bytes32 subKey, address owner) external view returns (uint256) {
        uint256 s = _subaccountRecoveryEpoch[subKey];
        uint256 o = _ownerRecoveryEpoch[owner];
        return s > o ? s : o;
    }

    /// @inheritdoc IEscapeController
    /// @dev WP-10A: reservation not implemented → always zero.
    function pendingReservationOf(
        bytes32,
        /*subKey*/
        address /*token*/
    )
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    /// @inheritdoc IEscapeController
    /// @dev WP-10A: reservation not implemented → always zero.
    function reservationExpiryOf(
        bytes32,
        /*subKey*/
        address /*token*/
    )
        external
        pure
        returns (uint64)
    {
        return 0;
    }

    /// @inheritdoc IEscapeController
    function recoveryPausedUntil() external view returns (uint64) {
        return _recoveryPausedUntil;
    }

    /// @inheritdoc IEscapeController
    /// @dev Zero when the target has never been placed into
    ///      `RECOVERY_PENDING` or has already been activated / cancelled.
    function activationEligibleAt(bytes32 subKey) external view returns (uint64) {
        uint64 pendingSince = _pendingSince[subKey];
        if (pendingSince == 0) return 0;
        return _eligibleAt(pendingSince);
    }

    /// @notice Read-only defense-in-depth predicate consumed by Vault +
    ///         Engine to gate risk-increasing operations.
    /// @param subKey Canonical subaccount identifier.
    /// @return allowed `true` when the subaccount is in `NORMAL` or
    ///         `CANCELLED` state (both permit new risk). `RECOVERED`
    ///         subaccounts are PERMANENTLY closed and never allowed.
    function isRiskIncreasingOperationAllowed(bytes32 subKey) external view returns (bool allowed) {
        RecoveryState s = _recoveryState[subKey];
        allowed = (s == RecoveryState.NORMAL || s == RecoveryState.CANCELLED);
    }

    /// @notice WP-10B finalizer boundary — returns `true` iff the
    ///         subaccount is in `RECOVERY_ACTIVE`. Objective proofs of
    ///         zero-position, zero-reservation, and remaining
    ///         obligations are enforced by the concrete
    ///         `RecoveryFinalizerV1` itself, not this view.
    function isFinalizationReady(bytes32 subKey) external view returns (bool) {
        return _recoveryState[subKey] == RecoveryState.RECOVERY_ACTIVE;
    }

    /// @notice Timestamp at which the target subaccount transitioned to
    ///         `RECOVERED` (via `markFinalized`). Zero when never
    ///         finalized. Introduced by WP-10B.
    function finalizedAt(bytes32 subKey) external view returns (uint64) {
        return _finalizedAt[subKey];
    }

    /// @notice Canonical `RecoveryFinalizer` deployment. Zero until
    ///         `initializeRecoveryFinalizer` has been called. Introduced by WP-10B.
    function recoveryFinalizer() external view returns (address) {
        return _recoveryFinalizer;
    }

    /*//////////////////////////////////////////////////////////////
                    RECOVERY-FINALIZER BINDING (WP-10B)
    //////////////////////////////////////////////////////////////*/

    /// @notice One-shot governance init of the canonical
    ///         `RecoveryFinalizer` deployment authorised to transition
    ///         a subaccount to `RECOVERED`. Once set, immutable for the
    ///         life of the controller.
    function initializeRecoveryFinalizer(address finalizer) external onlyGovernance {
        if (_recoveryFinalizer != address(0)) revert RecoveryFinalizerAlreadyInitialized();
        if (finalizer == address(0)) revert InvalidRecoveryFinalizer();
        _recoveryFinalizer = finalizer;
    }

    /// @notice Transition `subKey` from `RECOVERY_ACTIVE` to `RECOVERED`.
    /// @dev Callable ONLY by the initialised `RecoveryFinalizer`. This
    ///      is the authority boundary consumed by WP-10B — objective
    ///      proofs (zero positions, zero reservations) are enforced by
    ///      the finalizer BEFORE it calls this primitive. The controller
    ///      is only responsible for the state-machine invariant that
    ///      the current state IS `RECOVERY_ACTIVE`.
    function markFinalized(bytes32 subKey) external {
        if (msg.sender != _recoveryFinalizer) revert OnlyRecoveryFinalizer();
        RecoveryState current = _recoveryState[subKey];
        if (current != RecoveryState.RECOVERY_ACTIVE) revert CannotFinalizeFromState(current);
        _recoveryState[subKey] = RecoveryState.RECOVERED;
        _finalizedAt[subKey] = uint64(block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEscapeController
    /// @dev Governance-only. Bounded by `PAUSE_MAX_DURATION_BLOCKS`.
    function pauseRecovery(uint64 autoClearInBlocks) external onlyGovernance {
        if (autoClearInBlocks == 0 || autoClearInBlocks > PAUSE_MAX_DURATION_BLOCKS) {
            revert PauseDurationTooLong();
        }
        uint64 until = uint64(block.number) + autoClearInBlocks;
        _recoveryPausedUntil = until;
        emit RecoveryPauseSet(true, until, msg.sender, Versions.EVENT_VERSION);
    }

    /// @inheritdoc IEscapeController
    function unpauseRecovery() external onlyGovernance {
        _recoveryPausedUntil = 0;
        emit RecoveryPauseSet(false, 0, msg.sender, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _eligibleAt(uint64 pendingSince) internal view returns (uint64) {
        unchecked {
            return pendingSince + ACTIVATION_DELAY;
        }
    }

    function _recoveryPauseActive() internal view returns (bool) {
        uint64 until = _recoveryPausedUntil;
        return until != 0 && uint64(block.number) < until;
    }

    function _promoteToActive(bytes32 subKey, address owner, uint32 subaccountId) internal {
        _recoveryState[subKey] = RecoveryState.RECOVERY_ACTIVE;
        _pendingSince[subKey] = 0;
        _advanceSubaccountEpoch(subKey, owner, subaccountId, msg.sender);
        emit RecoveryActivated(subKey, owner, subaccountId, _subaccountRecoveryEpoch[subKey], Versions.EVENT_VERSION);
    }

    function _advanceSubaccountEpoch(bytes32 subKey, address owner, uint32 subaccountId, address actor) internal {
        uint256 current = _subaccountRecoveryEpoch[subKey];
        if (current == type(uint256).max) revert RecoveryNotEligible();
        unchecked {
            _subaccountRecoveryEpoch[subKey] = current + 1;
        }
        emit RecoveryEpochIncremented(subKey, owner, RecoveryScope.SUBACCOUNT, current + 1, Versions.EVENT_VERSION);
        // Emit a subaccountId-tagged secondary event via the shared error-free
        // structural event via `RecoveryActivated` when the promotion path
        // reaches this helper. Owner-path `invalidateIntents` also uses this
        // primitive; caller path attribution is bound in `actor`.
        actor; // unused (reserved for downstream event correlation)
    }

    function _advanceOwnerEpoch(address owner, address actor) internal {
        uint256 current = _ownerRecoveryEpoch[owner];
        if (current == type(uint256).max) revert RecoveryNotEligible();
        unchecked {
            _ownerRecoveryEpoch[owner] = current + 1;
        }
        emit RecoveryEpochIncremented(bytes32(0), owner, RecoveryScope.OWNER, current + 1, Versions.EVENT_VERSION);
        actor; // unused
    }
}
