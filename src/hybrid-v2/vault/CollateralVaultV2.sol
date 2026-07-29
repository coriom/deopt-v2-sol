// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CollateralVaultV2Core} from "./CollateralVaultV2Core.sol";
import {Capabilities} from "../libraries/Capabilities.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title CollateralVaultV2
/// @notice Abstract Vault-owned reservation + withdrawal + internal-transfer + pause
///         layer for the DeOpt V2 hybrid subaccount architecture (WP-04B).
/// @dev
///  Extends `CollateralVaultV2Core` (WP-04A custody + deposit + solvency) with:
///   - per-engine reservation accounting (`applyLock` / `applyUnlock`);
///   - aggregate locked collateral (`_totalLocked`);
///   - owner-direct withdrawal + same-owner internal transfer, both gated by an
///     abstract RiskModule hook so production Vault stays truthful;
///   - deposit / withdrawal / internal-transfer pause matrix (guardian OR
///     governance to pause; governance to unpause);
///   - `governanceReleaseOrphanedLock` — timelocked release of a reservation
///     held by a fully-revoked engine.
///
///  Explicit non-scope of V2-B (owned by later milestones):
///   - `withdrawFor(subKey, to, token, amount)` — engine-driven withdrawal (WP-08).
///   - `creditCollateral(subKey, token, amount)` — engine-driven credit primitive (WP-08).
///   - `applyFeeDebit` / `applyRebateCredit` — depend on FeesManager +
///     protocolFeeVaultSubKey (WP-09).
///   - `applyLiquidationDebit` — depends on positions ledger + insurance fund (WP-08).
///   - `applySettlementCreditDebit` — depends on options settlement engine (WP-08).
///   - Yield adapter integration (`moveToStrategy` / `moveFromStrategy` /
///     `setYieldOptIn`) — orthogonal integration, deferred to a later milestone.
///   - `protocolFeeVaultSubKey()` / `insuranceFundSubKey()` — well-known internal
///     account subKeys; require FeesManager + InsuranceFund wiring.
///   - Recovery reservations / recovery-side pauses (WP-10 escape controller).
///
///  Therefore this contract remains `abstract` (does NOT declare `is
///  ICollateralVault`) — every un-implemented interface function belongs to a
///  named downstream milestone. A production concrete `CollateralVaultV2` will
///  extend this abstract once all owner milestones have landed. A test-only
///  harness (in `test/hybrid-v2/vault/harness/`) provides a concrete deployment
///  for WP-04B tests with configurable risk hooks.
///
///  Risk boundary: `_requireWithdrawalAllowed` and `_requireInternalTransferAllowed`
///  are pure `virtual` — no default implementation, no permissive fallback.
///  Concrete production inheritors MUST wire a real `IRiskModule` in WP-07 and
///  override these hooks to consult `riskModule.withdrawalAllowed` /
///  `riskModule.transferAllowed`.
abstract contract CollateralVaultV2 is CollateralVaultV2Core {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Aggregate locked collateral per (subKey, token). Sum of all
    ///      `_lockedByEngine[subKey][token][*]` across every engine.
    mapping(bytes32 => mapping(address => uint256)) internal _totalLocked;

    /// @dev Per-engine reservation held for (subKey, token). Only the owning
    ///      engine may `applyUnlock` its own entry. Guardian revocation does NOT
    ///      release reservations; escape via `governanceReleaseOrphanedLock`.
    mapping(bytes32 => mapping(address => mapping(address => uint256))) internal _lockedByEngine;

    /// @dev Pause flags. Owner set via `pauseX` (guardian OR governance);
    ///      cleared via `unpauseX` (governance only).
    bool internal _depositsPaused;
    bool internal _withdrawalsPaused;
    bool internal _internalTransfersPaused;

    /// @notice Reserved storage slot for `SUBACCOUNT-ESCAPE-HATCH-DESIGN-V1`
    ///         (INV-OPS-05 / ISR-015). WP-04B DOES NOT write this slot — it
    ///         exists so the escape-controller milestone (WP-10) can plug in
    ///         time-based auto-clear of withdrawal pauses without a storage
    ///         layout change.
    uint64 public withdrawPauseAutoClearBlock;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an engine reserves collateral against `subKey`.
    event CollateralLocked(
        bytes32 indexed subKey, address indexed token, address indexed engine, uint256 amount, uint16 eventVersion
    );

    /// @notice Emitted when an engine releases its own reservation against `subKey`.
    event CollateralUnlocked(
        bytes32 indexed subKey, address indexed token, address indexed engine, uint256 amount, uint16 eventVersion
    );

    /// @notice Emitted on owner-direct withdrawal.
    event Withdraw(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 indexed subaccountId,
        address token,
        uint256 amount,
        address receiver,
        uint16 eventVersion
    );

    /// @notice Emitted on same-owner internal transfer.
    event InternalTransfer(
        bytes32 indexed fromSubKey,
        bytes32 indexed toSubKey,
        address indexed token,
        uint256 amount,
        address owner,
        uint32 fromSubaccountId,
        uint32 toSubaccountId,
        uint16 eventVersion
    );

    /// @notice Emitted when governance releases a reservation held by a revoked engine.
    event OrphanedLockReleased(
        bytes32 indexed subKey,
        address indexed token,
        address indexed engine,
        uint256 amount,
        string reason,
        uint16 eventVersion
    );

    /// @notice Emitted on every pause/unpause of one of the V2-B flags.
    event PauseFlagChanged(bytes32 indexed flag, bool paused, address indexed by, uint16 eventVersion);

    /// @notice Emitted on every successful atomic Options premium transfer
    ///         between two subKeys (possibly of different owners).
    /// @dev The primitive moves canonical entitlement only — no ERC-20 token
    ///      call is issued. Payer's accounted balance decreases by `amount`;
    ///      receiver's accounted balance increases by `amount`;
    ///      `_totalAccounted[token]` is UNCHANGED. Reconstructible in isolation
    ///      from this event alone (no dependency on any other event).
    event OptionPremiumTransferred(
        bytes32 indexed payerSubKey,
        bytes32 indexed receiverSubKey,
        address indexed token,
        uint256 amount,
        address engine,
        uint16 eventVersion
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is neither the current guardian nor governance.
    error OnlyGuardianOrGovernance();

    /// @notice Requested amount exceeds the subaccount's available balance
    ///         (balance minus totalLocked).
    error InsufficientAvailableCollateral(uint256 requested, uint256 available);

    /// @notice Engine tried to unlock or release more than its own reservation.
    error InsufficientEngineReservation(uint256 requested, uint256 reserved);

    /// @notice Post-withdrawal risk check refused. Thrown by the concrete risk hook.
    error UnsafeWithdrawal();

    /// @notice Post-transfer risk check refused. Thrown by the concrete risk hook.
    error UnsafeTransfer();

    /// @notice `fromSubaccountId == toSubaccountId` on internal transfer.
    error InternalTransferSameSubaccount();

    /// @notice Cross-owner transfer attempted. Reserved for future delegate flow.
    error InternalTransferCrossOwner();

    /// @notice Operation currently paused. `flag` identifies which pause bucket.
    error PausedOperation(bytes32 flag);

    /// @notice Sub-key argument is `bytes32(0)` on a capability-gated function.
    error SubKeyRequired();

    /// @notice `_totalLocked[subKey][token]` exceeds `_balanceOf[subKey][token]` — a
    ///         structural invariant violation that MUST NOT occur under correct usage.
    ///         Any view or mutation observing this state MUST revert rather than
    ///         silently underflow or hide the corruption.
    error CorruptedLockInvariant(bytes32 subKey, address token);

    /// @notice `governanceReleaseOrphanedLock` refused because the engine still
    ///         holds one or more capability bits.
    error EngineStillAuthorized(address engine);

    /// @notice `governanceReleaseOrphanedLock` refused because the abstract
    ///         `_requireOrphanedReleaseProof` hook reported that unresolved
    ///         obligations still back the reservation.
    error UnresolvedOrphanedObligation(bytes32 subKey, address token, address engine, uint256 amount);

    /// @notice `applyOptionPremiumTransfer` refused because payer and receiver
    ///         resolve to the same canonical subKey — self-trade prevention.
    error OptionPremiumSelfTransfer(bytes32 subKey);

    /// @notice `applyOptionPremiumTransfer` refused because either the payer
    ///         or the receiver subKey is not registered in the canonical registry.
    error OptionPremiumUnknownSubaccount(bytes32 subKey);

    /// @notice `applyOptionPremiumTransfer` refused because the premium token
    ///         is not part of the canonical collateral universe (never enabled
    ///         even once). Distinct from `TokenNotSupported` which fires for
    ///         a token that was disabled but is still in the universe.
    error OptionPremiumUnknownToken(address token);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGuardianOrGovernance() {
        if (msg.sender != _guardian && msg.sender != governance) revert OnlyGuardianOrGovernance();
        _;
    }

    modifier whenDepositsNotPaused() {
        if (_depositsPaused) revert PausedOperation(bytes32("deposits"));
        _;
    }

    modifier whenWithdrawalsNotPaused() {
        if (_withdrawalsPaused) revert PausedOperation(bytes32("withdrawals"));
        _;
    }

    modifier whenInternalTransfersNotPaused() {
        if (_internalTransfersPaused) revert PausedOperation(bytes32("internalTransfers"));
        _;
    }

    /*//////////////////////////////////////////////////////////////
                          ABSTRACT RISK HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Concrete inheritors MUST implement this to consult the deployed
    ///      `IRiskModule.withdrawalAllowed(subKey, token, amount)`. The hook
    ///      MUST revert `UnsafeWithdrawal()` (or bubble a risk-module error) when
    ///      the post-withdrawal state would be unsafe. No default is provided —
    ///      an always-true production hook is explicitly forbidden by WP-04B.
    function _requireWithdrawalAllowed(bytes32 subKey, address token, uint256 amount) internal view virtual;

    /// @dev Concrete inheritors MUST implement this to consult the deployed
    ///      `IRiskModule.transferAllowed(sourceSubKey, token, amount)`. The hook
    ///      MUST revert `UnsafeTransfer()` (or bubble a risk-module error) when
    ///      the post-transfer source state would be unsafe. No default is
    ///      provided.
    function _requireInternalTransferAllowed(bytes32 sourceSubKey, address token, uint256 amount) internal view virtual;

    /// @dev Concrete inheritors MUST implement this to prove that the reservation
    ///      being released via `governanceReleaseOrphanedLock` has NO remaining
    ///      economic obligation. Capability revocation alone is NOT sufficient
    ///      proof — this hook is the WP-04B safety-patch elevation of that
    ///      requirement into a chain-side check.
    ///
    ///      A concrete implementation MUST demonstrate that AT LEAST all of the
    ///      following hold for `(subKey, token, engine, amount)` before returning:
    ///        - every position or open obligation backed by this reservation is
    ///          closed / settled / liquidated;
    ///        - no pending execution can consume the reservation;
    ///        - no recovery-side reservation covers the same collateral.
    ///      Production wiring lives in WP-10 escape/recovery integration; the
    ///      hook receives the full `(subKey, token, engine, amount)` context so
    ///      a downstream inheritor can consult the positions ledger, recovery
    ///      state and settlement queues.
    ///
    ///      NO default implementation. NO permissive production fallback. Test
    ///      harnesses MAY implement the hook as a configurable allow / reject.
    function _requireOrphanedReleaseProof(bytes32 subKey, address token, address engine, uint256 amount)
        internal
        view
        virtual;

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT PAUSE OVERRIDE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc CollateralVaultV2Core
    function deposit(uint32 subaccountId, address token, uint256 amount)
        external
        override
        nonReentrant
        whenDepositsNotPaused
    {
        _executeDeposit(subaccountId, token, amount);
    }

    /// @inheritdoc CollateralVaultV2Core
    function depositFor(address owner, uint32 subaccountId, address token, uint256 amount)
        external
        override
        nonReentrant
        whenDepositsNotPaused
    {
        _executeDepositFor(owner, subaccountId, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                   CAPABILITY-GATED LOCK / UNLOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Reserve `amount` of `token` for `subKey` on behalf of the calling engine.
    /// @dev Capability: `CAP_LOCK_COLLATERAL`. Fails on zero subKey / zero amount /
    ///      insufficient available. `nonReentrant` on top of the capability check.
    function applyLock(bytes32 subKey, address token, uint256 amount) external nonReentrant {
        _requireCapability(Capabilities.CAP_LOCK_COLLATERAL);
        if (subKey == bytes32(0)) revert SubKeyRequired();
        if (amount == 0) revert AmountZero();

        uint256 balance = _balanceOf[subKey][token];
        uint256 locked = _totalLocked[subKey][token];
        if (locked > balance) revert CorruptedLockInvariant(subKey, token);
        uint256 available = balance - locked;
        if (available < amount) revert InsufficientAvailableCollateral(amount, available);

        _lockedByEngine[subKey][token][msg.sender] += amount;
        _totalLocked[subKey][token] = locked + amount;

        emit CollateralLocked(subKey, token, msg.sender, amount, Versions.EVENT_VERSION);
    }

    /// @notice Release `amount` of the caller's OWN reservation on `(subKey, token)`.
    /// @dev Capability: `CAP_UNLOCK_OWN_RESERVATION`. Cannot touch another engine's
    ///      reservation (isolation invariant VAULT-B-I4). Underflow on the
    ///      per-engine slot triggers `InsufficientEngineReservation`.
    function applyUnlock(bytes32 subKey, address token, uint256 amount) external nonReentrant {
        _requireCapability(Capabilities.CAP_UNLOCK_OWN_RESERVATION);
        if (subKey == bytes32(0)) revert SubKeyRequired();
        if (amount == 0) revert AmountZero();

        uint256 engineLocked = _lockedByEngine[subKey][token][msg.sender];
        if (engineLocked < amount) revert InsufficientEngineReservation(amount, engineLocked);

        _lockedByEngine[subKey][token][msg.sender] = engineLocked - amount;
        _totalLocked[subKey][token] -= amount;

        emit CollateralUnlocked(subKey, token, msg.sender, amount, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                    CAPABILITY-GATED OPTION PREMIUM
    //////////////////////////////////////////////////////////////*/

    /// @notice Atomically transfer `amount` of canonical `token` entitlement
    ///         from `payerSubKey` to `receiverSubKey`. The payer and receiver
    ///         MAY belong to different owners.
    /// @dev
    ///  Capability: `CAP_APPLY_OPTIONS_PREMIUM`. NARROWLY-SCOPED cross-owner
    ///  premium primitive introduced by
    ///  `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` (WP-08B). Rejects:
    ///   - zero amount (`AmountZero`);
    ///   - either subKey zero (`SubKeyRequired`);
    ///   - either subKey not registered (`OptionPremiumUnknownSubaccount`);
    ///   - `payerSubKey == receiverSubKey` (`OptionPremiumSelfTransfer`) —
    ///     self-trade is impossible through this primitive;
    ///   - token not in the canonical collateral universe
    ///     (`OptionPremiumUnknownToken`) — the token MUST have been enabled
    ///     at least once via `addSupportedToken`. This is DISTINCT from the
    ///     current deposit-enablement flag: a token that has been temporarily
    ///     disabled for new deposits can still route premium (its balance
    ///     remains part of the canonical liquidation universe);
    ///   - payer's available balance (balance - totalLocked) < amount
    ///     (`InsufficientAvailableCollateral`) — locked collateral cannot be
    ///     used to pay premium;
    ///   - corrupted lock invariant (`CorruptedLockInvariant`).
    ///
    ///  Effect (all under `nonReentrant`):
    ///   - `_balanceOf[payerSubKey][token] -= amount`.
    ///   - `_balanceOf[receiverSubKey][token] += amount`.
    ///   - `_totalAccounted[token]` unchanged (debit == credit).
    ///   - Payer's reservations untouched (`_lockedByEngine` / `_totalLocked`
    ///     unchanged). Debit is drawn ONLY from AVAILABLE balance.
    ///   - Emits `OptionPremiumTransferred(payer, receiver, token, amount,
    ///     caller, eventVersion)`.
    ///
    ///  No ERC-20 transfer call. No physical vault balance movement. The
    ///  primitive represents an on-book entitlement swap and inherits the
    ///  canonical solvency guarantee `Σ balanceOf[*] == totalAccounted[token]
    ///  <= physicalBalance[token]`.
    ///
    ///  Isolation:
    ///   - The caller's own reservations (via `applyLock`) are NEVER touched
    ///     by this primitive.
    ///   - Any other engine's reservations on either subKey are NEVER touched.
    ///   - `_activeSeriesCount`, position rows, and every economic slot
    ///     outside `_balanceOf` are untouched.
    ///
    ///  Downstream:
    ///   - The OptionMatchingEngineV2 pairs this call with a per-fill
    ///     `applyLock` on the seller's margin obligation. A failure of the
    ///     downstream margin check reverts BOTH operations atomically (Solidity
    ///     transaction atomicity).
    function applyOptionPremiumTransfer(bytes32 payerSubKey, bytes32 receiverSubKey, address token, uint256 amount)
        external
        nonReentrant
    {
        _requireCapability(Capabilities.CAP_APPLY_OPTIONS_PREMIUM);
        if (amount == 0) revert AmountZero();
        if (payerSubKey == bytes32(0) || receiverSubKey == bytes32(0)) revert SubKeyRequired();
        if (payerSubKey == receiverSubKey) revert OptionPremiumSelfTransfer(payerSubKey);
        // Both subKeys MUST be registered — protects against fabricated subKeys.
        if (REGISTRY.ownerOf(payerSubKey) == address(0)) {
            revert OptionPremiumUnknownSubaccount(payerSubKey);
        }
        if (REGISTRY.ownerOf(receiverSubKey) == address(0)) {
            revert OptionPremiumUnknownSubaccount(receiverSubKey);
        }
        // Token MUST have entered the canonical universe at least once — the
        // append-only membership flag matches the frozen liquidation-completeness
        // universe rule.
        if (!_knownCollateralToken[token]) revert OptionPremiumUnknownToken(token);

        uint256 balance = _balanceOf[payerSubKey][token];
        uint256 locked = _totalLocked[payerSubKey][token];
        if (locked > balance) revert CorruptedLockInvariant(payerSubKey, token);
        uint256 available = balance - locked;
        if (available < amount) revert InsufficientAvailableCollateral(amount, available);

        // Effects — atomic entitlement swap.
        unchecked {
            _balanceOf[payerSubKey][token] = balance - amount;
            _balanceOf[receiverSubKey][token] += amount;
        }

        emit OptionPremiumTransferred(payerSubKey, receiverSubKey, token, amount, msg.sender, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                     GOVERNANCE ORPHANED-LOCK RELEASE
    //////////////////////////////////////////////////////////////*/

    /// @notice Timelocked release of a reservation held by a fully-revoked engine.
    /// @dev Governance-only. Preconditions per spec 07 + the WP-04B safety patch:
    ///       - engine capability bitmap is exactly zero (i.e., engine is fully
    ///         revoked and cannot itself `applyUnlock`) — DEFENSIVE only, not
    ///         sufficient by itself;
    ///       - reservation exists at `_lockedByEngine[subKey][token][engine]`;
    ///       - amount does not exceed the reservation;
    ///       - `_requireOrphanedReleaseProof(subKey, token, engine, amount)` — the
    ///         abstract objective-proof hook — must NOT revert. Concrete
    ///         inheritors override this hook to consult the positions ledger /
    ///         recovery state / settlement queues (WP-10). No production default.
    ///
    ///      Effect: decrements the per-engine reservation and the aggregate
    ///      `_totalLocked`. No token movement. The released amount returns to
    ///      the subaccount's available balance (no third-party recipient).
    ///      `reason` is documented in the emitted event for auditability.
    ///
    ///      All accounting state mutations occur AFTER the proof hook succeeds,
    ///      so a rejecting hook rolls back the entire operation (VAULT-B-I16).
    function governanceReleaseOrphanedLock(
        bytes32 subKey,
        address token,
        address engine,
        uint256 amount,
        string calldata reason
    ) external onlyGovernance {
        if (engine == address(0)) revert InvalidEngine();
        if (subKey == bytes32(0)) revert SubKeyRequired();
        if (amount == 0) revert AmountZero();
        if (_engineCapabilityBits[engine] != 0) revert EngineStillAuthorized(engine);

        uint256 reserved = _lockedByEngine[subKey][token][engine];
        if (reserved < amount) revert InsufficientEngineReservation(amount, reserved);

        // Safety-patch gate: capability revocation is NOT sufficient. Concrete
        // inheritors MUST prove the reservation has no remaining economic
        // obligation. Reverts BEFORE any state mutation so rollback is total.
        _requireOrphanedReleaseProof(subKey, token, engine, amount);

        _lockedByEngine[subKey][token][engine] = reserved - amount;
        _totalLocked[subKey][token] -= amount;

        emit OrphanedLockReleased(subKey, token, engine, amount, reason, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                           OWNER WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw `amount` of `token` from the caller's subaccount.
    /// @dev Owner-only (`msg.sender == owner`). Requires:
    ///       - owner != 0, subaccountId != 0, token != 0, amount != 0;
    ///       - subaccount registered;
    ///       - amount <= available (balance minus totalLocked);
    ///       - abstract risk hook approves.
    ///      Token disablement DOES NOT block withdrawal (Part L — exits must
    ///      remain possible when safe). Reverts on any exact-outflow mismatch.
    function withdraw(uint32 subaccountId, address token, uint256 amount)
        external
        nonReentrant
        whenWithdrawalsNotPaused
    {
        address owner = msg.sender;
        if (owner == address(0)) revert InvalidOwner();
        if (subaccountId == 0) revert InvalidSubaccountId();
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) revert AmountZero();
        if (!REGISTRY.existsOf(owner, subaccountId)) revert SubaccountNotFound(owner, subaccountId);

        bytes32 subKey = REGISTRY.subKeyOf(owner, subaccountId);

        uint256 balance = _balanceOf[subKey][token];
        uint256 locked = _totalLocked[subKey][token];
        if (locked > balance) revert CorruptedLockInvariant(subKey, token);
        uint256 available = balance - locked;
        if (available < amount) revert InsufficientAvailableCollateral(amount, available);

        _requireWithdrawalAllowed(subKey, token, amount);

        _balanceOf[subKey][token] = balance - amount;
        _totalAccounted[token] -= amount;

        uint256 physicalBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(owner, amount);
        uint256 physicalAfter = IERC20(token).balanceOf(address(this));
        // Reject fee-on-transfer on outbound: physicalBefore - physicalAfter MUST equal amount.
        uint256 outflow = physicalBefore - physicalAfter;
        if (outflow != amount) revert InvalidTokenBalanceDelta(amount, outflow);

        emit Withdraw(subKey, owner, subaccountId, token, amount, owner, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL TRANSFER
    //////////////////////////////////////////////////////////////*/

    /// @notice Move `amount` of `token` from `fromSubaccountId` to `toSubaccountId`,
    ///         both owned by `msg.sender`.
    /// @dev Same-owner only. Both accounts must be registered (destination may
    ///      lazy-register Account 1). Token MUST be currently enabled (spec 10 —
    ///      internal transfers require an active token allowlist entry, unlike
    ///      withdrawals). Source post-transfer must pass the risk hook.
    ///      Physical custody unchanged. `_totalAccounted` unchanged. Reservations
    ///      unchanged on both sides.
    function internalTransfer(address token, uint32 fromSubaccountId, uint32 toSubaccountId, uint256 amount)
        external
        nonReentrant
        whenInternalTransfersNotPaused
    {
        address owner = msg.sender;
        if (owner == address(0)) revert InvalidOwner();
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) revert AmountZero();
        if (fromSubaccountId == 0 || toSubaccountId == 0) revert InvalidSubaccountId();
        if (fromSubaccountId == toSubaccountId) revert InternalTransferSameSubaccount();
        if (!_tokenEnabled[token]) revert TokenNotSupported();
        if (!REGISTRY.existsOf(owner, fromSubaccountId)) revert SubaccountNotFound(owner, fromSubaccountId);

        // Destination lazy registration: only permitted for Account 1 (spec 10).
        if (toSubaccountId == 1 && !REGISTRY.existsOf(owner, 1)) {
            REGISTRY.registerLazyDefault(owner);
        }
        if (!REGISTRY.existsOf(owner, toSubaccountId)) revert SubaccountNotFound(owner, toSubaccountId);

        bytes32 fromSubKey = REGISTRY.subKeyOf(owner, fromSubaccountId);
        bytes32 toSubKey = REGISTRY.subKeyOf(owner, toSubaccountId);

        uint256 fromBalance = _balanceOf[fromSubKey][token];
        uint256 fromLocked = _totalLocked[fromSubKey][token];
        if (fromLocked > fromBalance) revert CorruptedLockInvariant(fromSubKey, token);
        uint256 fromAvailable = fromBalance - fromLocked;
        if (fromAvailable < amount) revert InsufficientAvailableCollateral(amount, fromAvailable);

        _requireInternalTransferAllowed(fromSubKey, token, amount);

        _balanceOf[fromSubKey][token] = fromBalance - amount;
        _balanceOf[toSubKey][token] += amount;
        // _totalAccounted UNCHANGED — no value creation or destruction.

        emit InternalTransfer(
            fromSubKey, toSubKey, token, amount, owner, fromSubaccountId, toSubaccountId, Versions.EVENT_VERSION
        );
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    function pauseDeposits() external onlyGuardianOrGovernance {
        if (!_depositsPaused) {
            _depositsPaused = true;
            emit PauseFlagChanged(bytes32("deposits"), true, msg.sender, Versions.EVENT_VERSION);
        }
    }

    function unpauseDeposits() external onlyGovernance {
        if (_depositsPaused) {
            _depositsPaused = false;
            emit PauseFlagChanged(bytes32("deposits"), false, msg.sender, Versions.EVENT_VERSION);
        }
    }

    function pauseWithdrawals() external onlyGuardianOrGovernance {
        if (!_withdrawalsPaused) {
            _withdrawalsPaused = true;
            emit PauseFlagChanged(bytes32("withdrawals"), true, msg.sender, Versions.EVENT_VERSION);
        }
    }

    function unpauseWithdrawals() external onlyGovernance {
        if (_withdrawalsPaused) {
            _withdrawalsPaused = false;
            emit PauseFlagChanged(bytes32("withdrawals"), false, msg.sender, Versions.EVENT_VERSION);
        }
    }

    function pauseInternalTransfers() external onlyGuardianOrGovernance {
        if (!_internalTransfersPaused) {
            _internalTransfersPaused = true;
            emit PauseFlagChanged(bytes32("internalTransfers"), true, msg.sender, Versions.EVENT_VERSION);
        }
    }

    function unpauseInternalTransfers() external onlyGovernance {
        if (_internalTransfersPaused) {
            _internalTransfersPaused = false;
            emit PauseFlagChanged(bytes32("internalTransfers"), false, msg.sender, Versions.EVENT_VERSION);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Aggregate locked collateral for `(subKey, token)`.
    /// @dev Matches `ICollateralVault.lockedOf`.
    function lockedOf(bytes32 subKey, address token) external view returns (uint256) {
        return _totalLocked[subKey][token];
    }

    /// @notice Per-engine reservation on `(subKey, token)`.
    /// @dev Matches `ICollateralVault.lockedByEngineOf`.
    function lockedByEngineOf(bytes32 subKey, address token, address engine) external view returns (uint256) {
        return _lockedByEngine[subKey][token][engine];
    }

    /// @notice `balance - totalLocked` for `(subKey, token)`.
    /// @dev Matches `ICollateralVault.availableOf`. Reverts
    ///      `CorruptedLockInvariant` if the aggregate lock exceeds balance
    ///      (indicates upstream corruption; the view refuses to silently
    ///      underflow or hide the anomaly).
    function availableOf(bytes32 subKey, address token) external view returns (uint256) {
        uint256 balance = _balanceOf[subKey][token];
        uint256 locked = _totalLocked[subKey][token];
        if (locked > balance) revert CorruptedLockInvariant(subKey, token);
        return balance - locked;
    }

    function depositsPaused() external view returns (bool) {
        return _depositsPaused;
    }

    function withdrawalsPaused() external view returns (bool) {
        return _withdrawalsPaused;
    }

    function internalTransfersPaused() external view returns (bool) {
        return _internalTransfersPaused;
    }
}
