// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IEscapeController} from "../interfaces/IEscapeController.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {IOptionsPositionsLedger} from "../interfaces/IOptionsPositionsLedger.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {RecoveryState} from "../libraries/RecoveryTypes.sol";
import {SubKey} from "../libraries/SubKey.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title RecoveryFinalizerV1
/// @notice `ONCHAIN-SUBACCOUNT-RECOVERY-FINALIZER-V1` (WP-10B) canonical
///         atomic finalizer for a recovering subaccount. Withdraws every
///         non-zero canonical-universe token balance to the canonical owner
///         when — and only when — the chain proves:
///           1. `RECOVERY_ACTIVE` on the escape controller;
///           2. zero active Options positions on the canonical ledger;
///           3. zero aggregate reservations across every token in the
///              canonical collateral universe (bounded to 8);
///           4. no pending recovery pause blocking finalization.
///
///  Fail-closed contract:
///   - Every failing proof reverts with a precise custom error and leaves
///     ALL state / balances / accounting untouched.
///   - The transaction is atomic: recovery-state transition + N token
///     debits + N token transfers succeed as a whole or revert together.
///   - Recipient is ALWAYS the canonical Registry-resolved owner. No
///     third-party recipient argument is accepted.
///   - Withdrawal never touches locked / reserved balances (defensive
///     re-check inside the Vault primitive complements the finalizer's
///     up-front zero-reservation proof).
///   - Physical transfer failure fully rolls back all mutations
///     (Vault primitive is `nonReentrant` and verifies exact outflow
///     delta; the outer `finalize` is also `nonReentrant`).
///
///  Withdrawal model (Part I verdict:
///  `RECOVERY_WITHDRAWAL_ATOMIC_ALL_CANONICAL_TOKENS`): all canonical
///  tokens are iterated in one call. Disabled tokens with stranded
///  balances are STILL withdrawn (append-only universe rule). Direct
///  ERC-20 donations to the Vault above `_totalAccounted` are EXCLUDED
///  automatically — the finalizer only debits `_balanceOf[subKey][token]`.
///
///  Non-scope (frozen):
///   - No forced Options settlement.
///   - No liquidation.
///   - No orphaned-reservation release (V2-B path, governance-timelocked,
///     independent).
///   - No fallback settlement-price selection (F-A → F-D remains
///     `IRecoveryFinalizer` fallback-oracle scope, separate concrete).
///   - No insurance-fund debit.
///   - No write-off of user or protocol liabilities.
contract RecoveryFinalizerV1 is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    ISubaccountRegistry public immutable REGISTRY;
    ICollateralVault public immutable VAULT;
    IEscapeController public immutable ESCAPE_CONTROLLER;
    IOptionsPositionsLedger public immutable POSITIONS_LEDGER;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor argument was the zero address.
    error InvalidDependency();

    /// @notice `subaccountId == 0` is reserved and invalid.
    error InvalidSubaccountId();

    /// @notice Registry does not know `(owner, subaccountId)`.
    error SubaccountNotFound(address owner, uint32 subaccountId);

    /// @notice Caller is not the canonical owner resolved from the Registry.
    error UnauthorizedCaller(address expectedOwner, address caller);

    /// @notice Escape controller is not `RECOVERY_ACTIVE` for the subKey.
    error RecoveryNotActive(bytes32 subKey, RecoveryState currentState);

    /// @notice Subaccount still holds active Options positions.
    error ActivePositionsRemain(bytes32 subKey, uint32 activeCount);

    /// @notice Subaccount still has a non-zero aggregate reservation on
    ///         some canonical-universe token.
    error ReservationsRemain(bytes32 subKey, address token, uint256 remaining);

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once per successful finalization. Reconstructs
    ///         the state transition and the withdrawal recipient.
    /// @param subKey Canonical subaccount identifier.
    /// @param owner Canonical owner (recipient of all withdrawals).
    /// @param subaccountId Readable subaccount id.
    /// @param recoveryEpochAtFinalization Recovery epoch snapshot.
    /// @param finalizationTimestamp `block.timestamp` at finalization.
    /// @param tokensWithdrawn Number of canonical tokens with a
    ///        non-zero balance actually withdrawn (0..8).
    /// @param caller `msg.sender` (the owner).
    /// @param eventVersion Event schema version (spec 13).
    event RecoveryFinalized(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 indexed subaccountId,
        uint256 recoveryEpochAtFinalization,
        uint64 finalizationTimestamp,
        uint8 tokensWithdrawn,
        address caller,
        uint16 eventVersion
    );

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address registry_, address vault_, address escapeController_, address positionsLedger_) {
        if (
            registry_ == address(0) || vault_ == address(0) || escapeController_ == address(0)
                || positionsLedger_ == address(0)
        ) {
            revert InvalidDependency();
        }
        REGISTRY = ISubaccountRegistry(registry_);
        VAULT = ICollateralVault(vault_);
        ESCAPE_CONTROLLER = IEscapeController(escapeController_);
        POSITIONS_LEDGER = IOptionsPositionsLedger(positionsLedger_);
    }

    /*//////////////////////////////////////////////////////////////
                              FINALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Atomically finalize `subaccountId` for the caller and
    ///         withdraw every non-zero canonical-token balance to the
    ///         canonical owner.
    /// @dev
    ///  Checks (all must pass BEFORE any state / balance mutation):
    ///   1. `subaccountId != 0`;
    ///   2. `msg.sender == Registry.ownerOf(subKey)`;
    ///   3. `escape.recoveryStateOf(subKey) == RECOVERY_ACTIVE` — the
    ///      escape controller already enforces that the snapshotted
    ///      activation delay has elapsed before advancing to ACTIVE, so
    ///      this single check subsumes the delay proof;
    ///   4. `positionsLedger.activeSeriesCount(subKey) == 0`;
    ///   5. `vault.lockedOf(subKey, token) == 0` for every token in
    ///      the canonical universe.
    ///
    ///  Effects (atomic):
    ///   - `escape.markFinalized(subKey)` — transitions
    ///     `RECOVERY_ACTIVE → RECOVERED`;
    ///   - iterate canonical universe: for each token, call
    ///     `vault.applyRecoveryFinalization(subKey, token)` (no-op when
    ///     canonical balance is zero) — vault primitive debits the
    ///     exact balance and SafeERC20-transfers to canonical owner.
    ///   - emit `RecoveryFinalized`.
    ///
    ///  Any revert (proof, transfer, invariant) unwinds the entire tx
    ///  including the escape-state transition.
    /// @param subaccountId Readable subaccount id owned by `msg.sender`.
    /// @return recipient Canonical owner (equals `msg.sender`).
    /// @return tokensWithdrawn Number of tokens with non-zero balance debited.
    function finalize(uint32 subaccountId) external nonReentrant returns (address recipient, uint8 tokensWithdrawn) {
        if (subaccountId == 0) revert InvalidSubaccountId();
        address caller = msg.sender;
        if (!REGISTRY.existsOf(caller, subaccountId)) revert SubaccountNotFound(caller, subaccountId);
        bytes32 subKey = SubKey.deriveHere(address(REGISTRY), caller, subaccountId);
        recipient = REGISTRY.ownerOf(subKey);
        // The Registry may only ever bind one canonical owner per subKey;
        // this check defends against a misconfigured registry.
        if (recipient != caller) revert UnauthorizedCaller(recipient, caller);

        // Proof 1 — recovery state.
        RecoveryState state = ESCAPE_CONTROLLER.recoveryStateOf(subKey);
        if (state != RecoveryState.RECOVERY_ACTIVE) revert RecoveryNotActive(subKey, state);

        // Proof 2 — zero active Options positions.
        uint32 activeCount = POSITIONS_LEDGER.activeSeriesCount(subKey);
        if (activeCount != 0) revert ActivePositionsRemain(subKey, activeCount);

        // Proof 3 — zero aggregate reservation across the canonical
        // universe. Bounded by `MAX_COLLATERAL_TOKENS = 8`.
        uint256 universeCount = VAULT.collateralTokenCount();
        for (uint256 i = 0; i < universeCount; i++) {
            address token = VAULT.collateralTokenAt(i);
            uint256 locked = VAULT.lockedOf(subKey, token);
            if (locked != 0) revert ReservationsRemain(subKey, token, locked);
        }

        // Effects — atomic. Transition state, then debit each token.
        uint256 epochAtFinalization = ESCAPE_CONTROLLER.recoveryEpochOf(subKey);
        ESCAPE_CONTROLLER.markFinalized(subKey);

        for (uint256 i = 0; i < universeCount; i++) {
            address token = VAULT.collateralTokenAt(i);
            (, uint256 amount) = VAULT.applyRecoveryFinalization(subKey, token);
            if (amount != 0) {
                unchecked {
                    tokensWithdrawn += 1;
                }
            }
        }

        emit RecoveryFinalized(
            subKey,
            caller,
            subaccountId,
            epochAtFinalization,
            uint64(block.timestamp),
            tokensWithdrawn,
            caller,
            Versions.EVENT_VERSION
        );
    }

    /*//////////////////////////////////////////////////////////////
                              READINESS VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the aggregated readiness of `subKey`. Bounded gas
    ///         (O(universeCount) ≤ 8). Used by tooling + backends to
    ///         preview whether `finalize` would succeed at this block.
    ///         Return tuple: (ready, currentRecoveryState, activePositionsCount,
    ///         firstTokenWithReservationOrZero).
    function readinessOf(bytes32 subKey)
        external
        view
        returns (bool ready, RecoveryState state, uint32 activeCount, address firstReservationToken)
    {
        state = ESCAPE_CONTROLLER.recoveryStateOf(subKey);
        activeCount = POSITIONS_LEDGER.activeSeriesCount(subKey);
        firstReservationToken = _firstNonZeroReservation(subKey);
        ready = (state == RecoveryState.RECOVERY_ACTIVE && activeCount == 0 && firstReservationToken == address(0));
    }

    /// @notice Bounded scan of the canonical universe for the first
    ///         non-zero aggregate reservation. Returns `address(0)`
    ///         when every token is zero.
    function _firstNonZeroReservation(bytes32 subKey) internal view returns (address) {
        uint256 count = VAULT.collateralTokenCount();
        for (uint256 i = 0; i < count; i++) {
            address token = VAULT.collateralTokenAt(i);
            if (VAULT.lockedOf(subKey, token) != 0) return token;
        }
        return address(0);
    }
}
