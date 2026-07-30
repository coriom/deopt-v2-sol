# ONCHAIN-SUBACCOUNT-ESCAPE-CONTROLLER-V1 (WP-10A)

**Status:** COMPLETE — verdicts landed 2026-07-30. Prior lifecycle,
risk, fee, and capability verdicts remain valid; this milestone layers
canonical fail-closed recovery state on top.

**Safety posture:** `EXPERIMENTAL — NOT SECURITY APPROVED`.

**Product-owner authorization:** `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS` (Coriolan Morel).

**Not authorized:** deployment, broadcast, Base Sepolia, Base mainnet,
real funds, backend/frontend changes, database migrations, final
recovery withdrawal, arbitrary collateral release, orphaned-reservation
release without objective proof, settlement-price selection, liquidation
execution, insurance-fund transfer, governance seizure, Perps
implementation, mutable emergency balance editing.

---

## 1. Objective

Implement a canonical per-subaccount escape state machine that:

1. invalidates stale signed actions;
2. prevents new risk-increasing economic activity;
3. preserves canonical balances, positions and reservations;
4. permits only explicitly approved risk-reducing or recovery-preparatory operations;
5. cannot be activated, cancelled or finalized by an unauthorized party;
6. cannot be bypassed by an execution engine;
7. is fully reconstructible after database loss;
8. prepares, but does not execute, final recovery.

## 2. Authoritative sources honoured

- `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md` (product-owner approval 2026-07-24).
- `docs/onchain-subaccounts-v1/escape-hatch/04_ACTIVATION_AND_STATE_MACHINE.md`.
- `docs/onchain-subaccounts-v1/escape-hatch/09_STALE_INTENTS_AND_RECOVERY_EPOCH.md`.
- `docs/onchain-subaccounts-v1/escape-hatch/15_SOLIDITY_INTERFACE_SPEC.md`.
- `src/hybrid-v2/interfaces/IEscapeController.sol` (frozen boundary from WP-01).
- `src/hybrid-v2/libraries/RecoveryTypes.sol` (frozen enum surface).
- `src/hybrid-v2/security/ReplayAndEpochController.sol` (WP-05 replay + epoch foundation).

Precedence order matched the launch prompt; no design conflicts arose.

## 3. State machine audit — `ESCAPE_STATE_MACHINE_RESOLVED`

The frozen `SM-Rec` (design 04) has 8 states, of which WP-10A
implements the `NORMAL → RECOVERY_PENDING → RECOVERY_ACTIVE` head plus
in-window `CANCELLED`. `SETTLEMENT_PENDING`, `WITHDRAWAL_ELIGIBLE`,
`RECOVERED`, and `MIGRATED` are OUT OF SCOPE for WP-10A and belong to
WP-10B `RecoveryFinalizer` (or future milestones).

| State | Entry authority | Delay | Epoch effect | Event | Reversible |
|---|---|---|---|---|---|
| `NORMAL` | initial | — | — | — | via activation |
| `RECOVERY_PENDING` | owner via `activateRecovery` | 0 (records timestamp) | none yet | `RecoveryRequested` | via `cancelRecovery` |
| `RECOVERY_ACTIVE` | owner or permissionless after delay | `ACTIVATION_DELAY` | `subaccountRecoveryEpoch++` | `RecoveryActivated` + `RecoveryEpochIncremented` | irreversible |
| `CANCELLED` | owner via `cancelRecovery` during PENDING | 0 | none (never rolls back) | `RecoveryCancelled` | via re-activation |
| `SETTLEMENT_PENDING` | WP-10B | — | — | WP-10B | — |
| `WITHDRAWAL_ELIGIBLE` | WP-10B | — | — | WP-10B | — |
| `RECOVERED` | WP-10B | — | — | WP-10B | — |
| `MIGRATED` | reserved for future migration | — | — | — | — |

**No jump from `RECOVERY_ACTIVE` back to `NORMAL` in WP-10A.** The
finalizer boundary (`isFinalizationReady`) ALWAYS returns `false`.

## 4. Implementation boundary — `ESCAPE_CONTROLLER_IMPLEMENTATION_BOUNDARY_RESOLVED`

**EC-1 standalone canonical controller.**

- `src/hybrid-v2/recovery/EscapeControllerV1.sol` — new file.
- Standalone contract implementing `IEscapeController`.
- Does NOT inherit `ReplayAndEpochController`; holds its OWN
  monotonic recovery-epoch storage (`_subaccountRecoveryEpoch`,
  `_ownerRecoveryEpoch`). Storage is NOT duplicated — the Vault + Engine
  guard consults `escape.isRiskIncreasingOperationAllowed(subKey)`
  and `escape.subaccountRecoveryEpoch(subKey)` via the interface,
  never their own copies.
- Immutable dependencies:
  - `REGISTRY` (`ISubaccountRegistry`);
  - `GOVERNANCE` (pause / unpause authority);
  - `ACTIVATION_DELAY` (seconds, bounded by 72 hours);
  - `PAUSE_MAX_DURATION_BLOCKS` (bounded by 14 days at 12s/block).

## 5. Authority boundary — `OWNER_CONTROLLED_ESCAPE_ACTIVATION_VALIDATED`

- `activateRecovery(subaccountId)` — canonical owner only
  (`msg.sender == Registry.ownerOf(subKey)`). Account 0 rejected via
  `InvalidSubaccountId`. Unknown subaccount rejected via
  `SubaccountNotFound(owner, subaccountId)`.
- `activateRecoveryAllSubaccounts` — `msg.sender` is the owner scope.
- `cancelRecovery(subaccountId)` — canonical owner only; only during
  `RECOVERY_PENDING`.
- `invalidateIntents(subaccountId)` / `invalidateAllIntents()` —
  canonical owner only.
- `pauseRecovery` / `unpauseRecovery` — governance-only. Guardian is
  intentionally NOT authorized for user recovery pause (the launch
  prompt's guardian scope is bounded to protocol-halt paths on the
  Vault).
- Owner-path activation is PAUSE-IMMUNE ONLY when the caller is the
  canonical owner; permissionless finalization is blocked while the
  pause is active.
- No `tx.origin`, no signature-based activation in WP-10A. Envelope
  replay model would apply to future delegate paths gated by
  `CAP_RECOVERY_ACTIVATE`; not in scope here.

## 6. Epoch invalidation — `ESCAPE_ACTIVATION_ATOMICALLY_INVALIDATES_STALE_INTENTS`

- `RECOVERY_PENDING → RECOVERY_ACTIVE` atomically calls the internal
  epoch-advance primitive on the escape controller's OWN storage.
- Sibling subaccounts of the same owner remain in `NORMAL`; only the
  targeted `subKey` has its epoch bumped (`ESCAPE-I5`).
- Owner-wide bump via `activateRecoveryAllSubaccounts` /
  `invalidateAllIntents` bumps the owner-scope epoch only; per-subaccount
  epochs are untouched.
- Effective epoch = `max(subaccountRecoveryEpoch, ownerRecoveryEpoch)`
  (design D-EH-06 hybrid namespace).
- Failed activation does NOT advance the epoch (reverts before the
  internal primitive is reached).
- Cancellation NEVER rolls the epoch back — the storage is monotonic
  (`ESCAPE-I4`).
- Historical fills and cancellations remain untouched — the escape
  controller does not touch Vault balances, positions, or reservations
  (`ESCAPE-I6`).

## 7. Delay model — `ESCAPE_DELAY_MODEL_RESOLVED`

- `ACTIVATION_DELAY` is an immutable seconds value bound at
  deployment. Bounded by `MAX_ACTIVATION_DELAY = 72 hours` (design
  spec 04 rationale for accidental-bump + MEV griefing protection).
- Zero delay permitted for tests and small deployments; the immediate
  promotion path is proven under `test_activateRecovery_zeroDelayImmediateActive`.
- `activationEligibleAt(subKey)` view returns `pendingSince + ACTIVATION_DELAY`.
- Overflow guard: `+ ACTIVATION_DELAY` uses `unchecked` — the bounded
  delay (72 hours) plus a bounded pending-timestamp cannot overflow
  `uint64` for any realistic deployment lifetime.
- Shortening an active delay is impossible — the delay is immutable at
  the controller level; each pending recovery snapshots its own
  `pendingSince` and derives the deadline from the frozen delay.
- Pause matrix — `_recoveryPausedUntil` (block-count based) bounded by
  `PAUSE_MAX_DURATION_BLOCKS`; auto-clears at that block number.

## 8. Operation restriction matrix — `ESCAPE_OPERATION_RESTRICTION_MATRIX_RESOLVED`

Enforced at canonical Vault + Engine mutation boundaries via
`_requireNoActiveRecoveryOn(subKey)` (Vault) and
`_requireBothSidesNotInRecovery(...)` (Engine).

| Operation | Classification | Enforcement site |
|---|---|---|
| `deposit` | allowed | (no check) |
| `depositFor` | allowed | (no check) |
| standard `withdraw` | forbidden | `CollateralVaultV2.withdraw` |
| `internalTransfer` OUT | forbidden | `CollateralVaultV2.internalTransfer` (source side only) |
| `internalTransfer` IN | allowed | (no check on destination) |
| `applyOptionPremiumTransfer` | forbidden (both sides) | `CollateralVaultV2.applyOptionPremiumTransfer` |
| `applyOptionFeeCharge` (positive fee debit) | forbidden | `CollateralVaultV2.applyOptionFeeCharge` |
| `applyOptionRebate` (rebate credit) | forbidden | `CollateralVaultV2.applyOptionRebate` |
| new Options fill (matcher) | forbidden | `OptionMatchingEngineV2.executeMatch` |
| additional GTC fill | forbidden | same |
| Options cancellation | allowed | (no check — engine-level cancel remains available) |
| nonce-floor advancement | allowed | (WP-05 primitives untouched) |
| `applyLock` (collateral lock) | forbidden | `CollateralVaultV2.applyLock` |
| `applyUnlock` (release own reservation) | allowed | (risk-reducing) |
| exercise / settlement | allowed / WP-10B | (no check in WP-10A) |
| liquidation | allowed | (takes priority per design 10) |
| oracle / risk views | allowed | (view-only) |
| final recovery withdrawal | forbidden in WP-10A | `EscapeControllerV1.escapeWithdraw` reverts `RecoveryFinalizationNotYetImplemented` |
| orphaned lock release | governance-timelocked | (existing V2-B path, unchanged) |

## 9. Enforcement architecture — Part J

- The Vault mutation primitives consult
  `IEscapeController.isRiskIncreasingOperationAllowed(subKey)` via the
  internal helper `_requireNoActiveRecoveryOn`. Fail-closed once the
  controller is initialised.
- The Options matching engine consults the same predicate via
  `_requireBothSidesNotInRecovery(buyerSubKey, sellerSubKey)`. The
  engine reads the controller reference from the Vault
  (`VAULT.escapeController()`) — SINGLE SOURCE OF TRUTH.
- Direct-call bypass is defended in depth: even if an engine holds
  capability and bypasses the matcher, the Vault primitives (premium /
  fee / rebate / lock) still refuse.
- Capability possession alone is INSUFFICIENT during recovery
  (`ESCAPE-I13`).
- Governance one-shot `initializeEscapeController(address controller)`
  on the Vault sets the immutable-like slot. Uninitialised state
  (pre-deployment) is permissive; this is the deployment window before
  governance wires the controllers. Post-init, fail-closed.

## 10. Cancellation model — `ESCAPE_PENDING_CANCELLATION_IMPLEMENTED_WITHOUT_EPOCH_ROLLBACK`

- Owner-only via `cancelRecovery(subaccountId)`.
- Only during `RECOVERY_PENDING`. Post `RECOVERY_ACTIVE` cancellation
  reverts with `RecoveryNotPending()` (the epoch has already
  permanently invalidated intents; there is no rollback semantics that
  could safely restore them).
- Cancellation NEVER rolls the epoch back. `_subaccountRecoveryEpoch`
  is monotone — the epoch is only advanced on the
  `PENDING → ACTIVE` transition, so during PENDING the epoch is still
  at its pre-activation value, and cancellation leaves it unchanged.
- Old signatures signed under the pre-activation epoch remain valid
  after cancellation (since the epoch never advanced).
- Balances, positions, and reservations are untouched by
  cancellation.
- Event: `RecoveryCancelled(subKey, owner, subaccountId, eventVersion)`.

## 11. Finalization boundary — `RECOVERY_FINALIZATION_BOUNDARY_RESOLVED`

- `isFinalizationReady(subKey)` returns `false` in WP-10A for every
  subKey. The WP-10B `RecoveryFinalizer` will replace this with an
  objective predicate consulting positions ledger, margin engine,
  reservation state, and settlement finalization progress.
- WP-10A NEVER exposes any function that:
  - transfers collateral to the owner;
  - clears an engine reservation;
  - selects a settlement price;
  - socialises protocol loss.
- The reservation + escape-withdraw externals revert
  `RecoveryFinalizationNotYetImplemented`.

## 12. Orphaned reservation proof — `ORPHANED_RESERVATION_PROOF_REMAINS_FAIL_CLOSED`

- WP-10A does NOT provide any proof-status view. The V2-B
  `_requireOrphanedReleaseProof(subKey, token, engine, amount)` remains
  the sole gate for engine-reservation release, and it stays
  fail-closed:
  - engine capabilities being zero is NOT sufficient;
  - recovery delay elapsed is NOT sufficient;
  - governance request is NOT sufficient;
  - backend reports of no open orders are NOT sufficient.
- WP-10A does not weaken this rule; the finalizer boundary
  (`isFinalizationReady`) returns `false` unconditionally.

## 13. Pause, guardian, governance — Part N

- Global protocol pause (Vault-level) remains a distinct state machine
  from user escape.
- Guardian may pause Vault paths (unchanged from V2-B). Guardian
  CANNOT finalize a user recovery. Guardian CANNOT redirect collateral.
- Governance may pause/unpause recovery activation but CANNOT force a
  state transition, rewrite recovery timestamps, or bypass the
  finalizer boundary. Governance CANNOT mark obligations resolved
  without proof (that gate lives in the future finalizer).
- Timelock authority (via governance) controls the pause primitive.
- Recovery activation on the owner-path is intentionally NOT
  pause-guarded — the owner ALWAYS starts the recovery clock; only
  permissionless finalization is blocked when paused.

## 14. Events + errors — Part O + P

Events (from `IEscapeController`):
- `RecoveryRequested(subKey, owner, subaccountId, nextEpoch, activationEligibleAt, eventVersion)`
- `RecoveryActivated(subKey, owner, subaccountId, newEpoch, eventVersion)`
- `RecoveryCancelled(subKey, owner, subaccountId, eventVersion)`
- `RecoveryEpochIncremented(subKey, owner, scope, newEpoch, eventVersion)`
- `RecoveryPauseSet(paused, autoClearBlock, by, eventVersion)`

Errors (from `IEscapeController` + local):
- `RecoveryAlreadyPending`, `RecoveryNotPending`, `RecoveryPaused`,
  `PauseDurationTooLong`, `RecoveryNotActive`, `RecoveryNotEligible`.
- `InvalidDependency`, `ActivationDelayTooLong`, `PauseMaxDurationTooLong`.
- `InvalidSubaccountId`, `SubaccountNotFound(owner, subaccountId)`.
- `OnlyGovernance`, `ActivationDelayNotElapsed(pendingSince, eligibleAt)`,
  `InvalidRecoveryStateTransition(from, to)`,
  `UnauthorizedCallerForSubaccount(expected, caller, subaccountId)`,
  `RecoveryFinalizationNotYetImplemented`.
- Engine: `IOptionMatchingEngine.RecoveryActiveForSubaccount(subKey)`.
- Vault: `CollateralVaultV2Core.RecoveryActiveForSubaccount(subKey)`.

No string reverts anywhere.

## 15. Test evidence

**Baseline (pre-WP-10A):** 1246 tests / 0 failed.

**Post-WP-10A additions:**
- `test/hybrid-v2/recovery/EscapeControllerV1.t.sol` — 44 unit + fuzz
  tests covering construction, authority, delay boundaries,
  cancellation window, epoch invariants, pause + auto-clear, finalizer
  boundary, and risk-increasing view semantics.
- `test/hybrid-v2/recovery/EscapeControllerV1Invariant.t.sol` — 6
  stateful invariants proving `ESCAPE-I1`, `I3`, `I4`, `I5`, `I12`,
  `I15`, `I16` at 64×64 runs (bounded fuzz budget). Handler:
  `test/hybrid-v2/recovery/handlers/EscapeControllerHandler.sol`.
- `test/hybrid-v2/recovery/EscapeControllerV1Integration.t.sol` — 13
  integration tests proving engine-level guard, Vault direct-bypass
  guards on 5 mutation primitives (`applyOptionPremiumTransfer`,
  `applyOptionFeeCharge`, `applyLock`, `withdraw`,
  `internalTransfer`), permitted paths (deposit, internal-transfer-in,
  cancellation during PENDING), and DB-loss reconstruction (Part T).

**Full validation:** all prior 1246 baseline tests pass unchanged;
new suites are additive. See RUN_STATE for closing numbers.

## 16. DB-loss reconstruction — `ESCAPE_STATE_RECONSTRUCTIBLE_AND_DB_INDEPENDENT`

- On-chain state is the sole source of truth. `recoveryStateOf`,
  `recoveryEpochOf`, `ownerRecoveryEpochOf`, `effectiveRecoveryEpoch`,
  `activationEligibleAt`, `recoveryPausedUntil` all read directly from
  contract storage.
- Recovery state cannot be cleared, shortened, disabled, or reset by
  any off-chain actor (`ESCAPE-I16` — structural).
- Every state-changing transition emits an indexed event carrying
  `subKey`, `owner`, and (where relevant) `subaccountId`, epoch, and
  timestamps — reconstructible after complete indexer / DB loss
  (`ESCAPE-I15`).
- The integration test `test_reconstruction_stateSurvivesIndexerLoss`
  proves that clearing any off-chain ghost mirror does NOT restore
  stale orders or reset the recovery state.

## 17. Gas + DoS — `ESCAPE_CONTROLLER_GAS_BOUNDED`

- All state transitions are O(1):
  - `activateRecovery`: 1 storage write + 1 event; 1 optional promotion.
  - `cancelRecovery`: 2 storage writes + 1 event.
  - `finalizePendingActivation`: 2 storage writes + 2 events.
  - `invalidateIntents` / `invalidateAllIntents`: 1 storage write + 1 event.
  - `pauseRecovery` / `unpauseRecovery`: 1 storage write + 1 event.
- Views are all single SLOADs.
- No order enumeration, no position enumeration, no collateral
  iteration, no global account iteration, no unbounded proof.
- No new gas blocker introduced.

## 18. Storage review — Part V

New storage introduced on `EscapeControllerV1`:
- `mapping(bytes32 => RecoveryState) _recoveryState`;
- `mapping(bytes32 => uint64) _pendingSince`;
- `mapping(bytes32 => uint256) _subaccountRecoveryEpoch`;
- `mapping(address => uint256) _ownerRecoveryEpoch`;
- `uint64 _recoveryPausedUntil`.

New storage introduced on `CollateralVaultV2Core`:
- `address _escapeController` (one-shot governance-set slot).

**Not stored:** balances, positions, reservations, margin values,
signatures, open-order lists, copied epochs, backend coordination
state, arbitrary governance flags. No reset of historical recovery
epochs. No governance rewrite of user state.

## 19. Files created / modified

**Production source:**
- `src/hybrid-v2/recovery/EscapeControllerV1.sol` (new).
- `src/hybrid-v2/interfaces/IEscapeController.sol` — added
  `isRiskIncreasingOperationAllowed`, `isFinalizationReady` views.
- `src/hybrid-v2/interfaces/ICollateralVault.sol` — added
  `initializeEscapeController`, `escapeController`,
  `escapeControllerInitialized` declarations.
- `src/hybrid-v2/interfaces/IOptionMatchingEngine.sol` — added
  `RecoveryActiveForSubaccount(bytes32)` error.
- `src/hybrid-v2/vault/CollateralVaultV2Core.sol` — added
  `_escapeController` storage slot, `initializeEscapeController`,
  views, `_requireNoActiveRecoveryOn` internal helper, related
  events and errors.
- `src/hybrid-v2/vault/CollateralVaultV2.sol` — inserted recovery
  guards into `applyLock`, `applyOptionPremiumTransfer` (both sides),
  `applyOptionFeeCharge`, `applyOptionRebate`, `withdraw`,
  `internalTransfer` (source side).
- `src/hybrid-v2/options/OptionMatchingEngineV2.sol` — added
  `_requireBothSidesNotInRecovery` helper called in `executeMatch`.

**Tests:**
- `test/hybrid-v2/recovery/EscapeControllerV1.t.sol` (new, 44 tests).
- `test/hybrid-v2/recovery/EscapeControllerV1Invariant.t.sol` (new, 6 invariants).
- `test/hybrid-v2/recovery/handlers/EscapeControllerHandler.sol` (new handler).
- `test/hybrid-v2/recovery/EscapeControllerV1Integration.t.sol` (new, 13 integration tests).

**Docs:**
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_ESCAPE_CONTROLLER_V1.md` (this file).
- `docs/ONCHAIN_SUBACCOUNT_ESCAPE_CONTROLLER_V1_RESULT.md` (result doc).
- `RUN_STATE.md` — dated section prepended.

## 20. Verdicts returned

- `ESCAPE_STATE_MACHINE_RESOLVED`
- `ESCAPE_CONTROLLER_IMPLEMENTATION_BOUNDARY_RESOLVED`
- `OWNER_CONTROLLED_ESCAPE_ACTIVATION_VALIDATED`
- `ESCAPE_ACTIVATION_ATOMICALLY_INVALIDATES_STALE_INTENTS`
- `ESCAPE_DELAY_MODEL_RESOLVED`
- `ESCAPE_OPERATION_RESTRICTION_MATRIX_RESOLVED`
- `ESCAPE_PENDING_CANCELLATION_IMPLEMENTED_WITHOUT_EPOCH_ROLLBACK`
- `RECOVERY_FINALIZATION_BOUNDARY_RESOLVED`
- `ORPHANED_RESERVATION_PROOF_REMAINS_FAIL_CLOSED`
- `ESCAPE_STATE_RECONSTRUCTIBLE_AND_DB_INDEPENDENT`
- `ESCAPE_CONTROLLER_GAS_BOUNDED`
- `NO_FINAL_RECOVERY_WITHDRAWAL_OR_ARBITRARY_RESERVATION_RELEASE_IMPLEMENTED`
- `ONCHAIN_SUBACCOUNT_ESCAPE_CONTROLLER_V1_COMPLETE`
- `READY_FOR_ONCHAIN_SUBACCOUNT_RECOVERY_FINALIZER_V1`

## 21. Non-goals / out of scope (recap)

- Deployment, broadcast, real funds.
- Backend / frontend changes.
- Final recovery withdrawal (`escapeWithdraw`, `escapeWithdrawBatch`,
  `reserveRecoveryWithdrawal` all revert `RecoveryFinalizationNotYetImplemented`).
- Arbitrary reservation clearing.
- Settlement-price selection / fallback finalization (WP-10B).
- Liquidation execution.
- Insurance-fund transfer.
- Perps recovery integration.
- Mutable emergency balance editing.

## 22. RecoveryFinalizer dependency (WP-10B)

The future `RecoveryFinalizer` MUST:
- Call `EscapeControllerV1.recoveryStateOf(subKey)` to confirm state is
  `RECOVERY_ACTIVE` or beyond before executing any recovery withdrawal.
- Implement the objective `isFinalizationReady(subKey)` check
  consulting positions ledger, reservation state, and settlement
  finalization progress.
- Own the `_recoveryDebit` internal Vault hook (per design 15) — the
  Vault currently has NO such hook; WP-10B will add it.
- Own the fallback finalization flows (F-A → F-B → F-C → F-D).
- Own `escapeWithdraw`, `escapeWithdrawBatch`,
  `reserveRecoveryWithdrawal` implementations (currently reverting stubs).

## 23. Supersession note

None of the prior tracked docs are invalidated:
- `ONCHAIN_SUBACCOUNT_OPTION_MATCHING_ENGINE_V2_V1.md`
- `ONCHAIN_SUBACCOUNT_OPTION_ORDER_LIFECYCLE_AND_NONCE_V2_PATCH.md`
- `ONCHAIN_SUBACCOUNT_OPTION_ORDER_LIFECYCLE_V2_VALIDATION_CLOSURE.md`
- `ONCHAIN_SUBACCOUNT_FEES_MANAGER_V2_INTEGRATION_V1.md`

Their verdicts remain load-bearing. WP-10A adds a recovery-mode guard
that gates their mutation primitives; the underlying invariants
continue to hold. `IOptionMatchingEngine`, `ICollateralVault`, and
`IEscapeController` have been extended with additive declarations only.
No signature or storage layout changes to prior surfaces.
