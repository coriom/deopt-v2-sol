# ONCHAIN-SUBACCOUNT-RECOVERY-FINALIZER-V1 (WP-10B)

**Status:** COMPLETE — verdicts landed 2026-07-30. All prior lifecycle,
risk, fee, capability, and WP-10A verdicts remain load-bearing; this
milestone completes the V1 escape/recovery flow with an objective
finalization step and canonical collateral exit.

**Safety posture:** `EXPERIMENTAL — NOT SECURITY APPROVED`.

**Product-owner authorization:** `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS` (Coriolan Morel).

**Not authorized:** deployment, broadcast, Base Sepolia, Base mainnet,
real funds, backend/frontend changes, database migrations, forced
Options settlement, liquidation execution, oracle-selected socialized
settlement, arbitrary reservation release, governance or guardian
collateral redirection, insurance-fund debit, write-off of user or
protocol liabilities, Perps implementation, generic Vault
debit/credit primitives.

---

## 1. Objective

Allow a recovering subaccount to exit only when the chain objectively
proves:

1. recovery mode is active;
2. the snapshotted recovery delay has elapsed;
3. the subaccount has no active Options position;
4. every canonical collateral token has zero unresolved reservation;
5. no other canonical V1 obligation remains;
6. the caller and recipient satisfy the approved authority model;
7. the complete withdrawal can occur without creating or hiding value;
8. finalization cannot be reversed;
9. the finalized subaccount cannot resume trading or receive stranded
   economic state;
10. database loss cannot alter readiness or permit a second withdrawal.

Fail closed whenever a required proof is unavailable.

## 2. Finalization model — `RECOVERY_FINALIZATION_MODEL_RESOLVED`

| Current state | Required evidence | Caller authority | Recipient | Canonical mutations | External transfers | Resulting state | Repeat-call behavior | Failure rollback | Event |
|---|---|---|---|---|---|---|---|---|---|
| `RECOVERY_ACTIVE` | ledger.activeSeriesCount(subKey) == 0; vault.lockedOf(subKey, token) == 0 for every canonical token | canonical owner (`Registry.ownerOf(subKey) == msg.sender`) | canonical owner (Registry-resolved) | state → `RECOVERED`; per-token balance → 0; totalAccounted[token] decremented by exact amount | SafeERC20 transfer of full canonical balance per non-zero token | `RECOVERED` | reverts `RecoveryNotActive(subKey, RECOVERED)` on re-entry | full atomic tx unwind on any transfer or proof failure | `RecoveryFinalized(subKey, owner, subaccountId, epoch, ts, N, caller, ver)` + N × `RecoveryFinalizationWithdrawn(subKey, recipient, token, amount, caller, ver)` |

Delay is captured by the `RECOVERY_ACTIVE` state itself — the escape
controller only advances a pending recovery to ACTIVE after the
snapshotted delay elapses (WP-10A). No separate delay check is
required in the finalizer.

## 3. Implementation boundary — `RECOVERY_FINALIZER_IMPLEMENTATION_BOUNDARY_RESOLVED`

**RF-1 standalone finalizer.**

- `src/hybrid-v2/recovery/RecoveryFinalizerV1.sol` (new file).
- Standalone contract; not inheriting the escape controller. Reads
  from `IEscapeController`, `ISubaccountRegistry`, `ICollateralVault`,
  `IOptionsPositionsLedger`. Invokes narrow capability-gated Vault
  and escape-controller mutators via authority checks.
- Immutable dependencies: `REGISTRY`, `VAULT`, `ESCAPE_CONTROLLER`,
  `POSITIONS_LEDGER`.
- No duplicated finalized state — the canonical mutation is
  `EscapeControllerV1.markFinalized(subKey)` which flips the
  authoritative `_recoveryState` slot from `RECOVERY_ACTIVE` to
  `RECOVERED`. The Vault primitive `applyRecoveryFinalization` is
  never state-mutating on the controller.

## 4. Authority and recipient — `RECOVERY_FINALIZATION_AUTHORITY_AND_RECIPIENT_RESOLVED`

- `finalize(uint32 subaccountId)` — canonical owner ONLY:
  `msg.sender == Registry.ownerOf(subKey)`.
- Non-owner callers revert `UnauthorizedCaller(expected, caller)`.
- Engine, guardian, governance CANNOT finalize (no privileged path).
- Smart-contract wallet finalizes via its own `execute`; canonical
  owner = wallet contract (INV-ID-06).
- No `tx.origin` anywhere; owner path is `msg.sender`-only.
- Recipient is Registry-derived — NEVER a caller-supplied argument.
  There is no permissionless-relayer path in V1 (the design's
  permissionless activation on the escape controller is a separate
  scope; withdrawal recipient must be the canonical owner).
- Account 0 rejected (`InvalidSubaccountId`).
- Unknown subaccount rejected (`SubaccountNotFound(owner, subaccountId)`).

## 5. Position proof — `RECOVERY_ZERO_OPTIONS_POSITION_PROOF_OBJECTIVE`

- `IOptionsPositionsLedger.activeSeriesCount(subKey)` (WP-06 canonical).
- Zero → no active series → no unresolved long or short quantity → no
  exercise or settlement lifecycle state that still creates an
  obligation. The counter is incremented on first non-zero position
  and decremented only when a fill / exercise / settlement drives the
  position to fully zero — the `_isPositionAllZero` guarantee
  frozen in WP-06 ensures a non-zero counter implies remaining exposure.
- No backend list, event projection, or user-supplied array is trusted.

## 6. Reservation proof — `RECOVERY_ZERO_RESERVATION_PROOF_OBJECTIVE`

- `ICollateralVault.lockedOf(subKey, token)` — aggregate
  `_totalLocked[subKey][token]` across ALL engines (WP-04B canonical).
- Iterated across every token in the canonical universe
  (`collateralTokenAt(0..collateralTokenCount())`), bounded by
  `MAX_COLLATERAL_TOKENS = 8`.
- The aggregate reservation is engine-agnostic: engines that have
  their capabilities revoked, engines that are paused, engines the
  backend no longer tracks — all contribute to the aggregate if they
  hold a `_lockedByEngine` entry.
- Capability revocation alone is INSUFFICIENT — the reservation
  slot survives the revocation; only an objective `applyUnlock` or
  timelocked `governanceReleaseOrphanedLock` can reduce it.
- Defensive re-check inside the Vault primitive
  (`applyRecoveryFinalization`) — even if the finalizer's up-front
  proof were bypassed, the primitive itself refuses to move a token
  whose aggregate lock is non-zero.

## 7. All V1 obligations — `RECOVERY_ALL_V1_OBLIGATIONS_OBJECTIVELY_RESOLVED`

| Obligation | Classification | Where captured |
|---|---|---|
| Options positions | canonical economic → zero proof | `activeSeriesCount(subKey) == 0` |
| Engine reservations | canonical economic → zero proof | `lockedOf(subKey, token) == 0` per canonical token |
| Premium liabilities | atomically settled per match | Vault premium transfer inside `executeMatch` |
| Positive fee debits | atomically settled per match | Vault fee charge inside `executeMatch` |
| Rebate credits | atomically settled per match | Vault rebate primitive inside `executeMatch` |
| Settlement liabilities | reflected in `activeSeriesCount` | zero → resolved |
| Signed replay state | monotone historical → irrelevant to finalization | WP-05 `_consumedIntent` |
| Partial fill state | reflected in remaining reservation | zero-reservation proof subsumes |
| IOC / FOK state | atomically consumed | no lingering state |
| Recovery epoch | monotone invalidator | itself not an obligation |
| Pending internal transfers | atomic — none exist | N/A |
| Protocol accounting | invariant `totalAccounted` — decremented atomically | `applyRecoveryFinalization` |
| Direct token donations | EXCLUDED from withdrawal | finalizer only debits `_balanceOf[subKey][token]`; surplus stays with vault |

## 8. Withdrawal model — `RECOVERY_WITHDRAWAL_ATOMIC_ALL_CANONICAL_TOKENS`

RW-1 chosen. Rationale:
- The design freezes finalization as a state-machine terminal step.
  Splitting withdrawal into a claim phase would introduce a limbo
  state, additional invariants, and re-entrancy surface for
  non-standard tokens. RW-1 completes atomically or fully reverts.
- The canonical universe is bounded to 8 tokens (frozen); the
  atomic loop is O(8) — well within block-gas bounds.
- Disabled tokens with stranded balances are still exited (append-only
  universe rule ensures they remain enumerable).
- Zero-balance tokens are skipped (primitive returns amount = 0, no
  event emitted).
- Donations above `_totalAccounted[token]` remain with the vault
  (never withdrawn).

## 9. Vault recovery primitive — `VAULT_RECOVERY_WITHDRAWAL_PRIMITIVE_IMPLEMENTED_NARROWLY`

`CollateralVaultV2.applyRecoveryFinalization(subKey, token) returns (recipient, amount)`:

- Callable ONLY by the initialised `RecoveryFinalizer` (stored via
  governance one-shot `initializeRecoveryFinalizer`).
- Target subKey must be non-zero and registered.
- Token must be in the canonical universe (`_knownCollateralToken[token]`).
- Defensive re-check: `_totalLocked[subKey][token] == 0` — reverts
  `RecoveryFinalizationReservationRemains(subKey, token, remaining)`
  otherwise (preserves VAULT-B-I4 in depth).
- Debits `_balanceOf[subKey][token]` to zero; decrements
  `_totalAccounted[token]` by the exact amount; SafeERC20-transfers
  to the Registry-resolved owner; verifies exact physical outflow
  delta.
- `nonReentrant`.
- No caller-supplied amount, no caller-supplied recipient.
- No sibling account access.
- Emits `RecoveryFinalizationWithdrawn(subKey, recipient, token, amount, caller, ver)`.
- No-op when balance is zero (returns `(recipient, 0)`, no event).

## 10. Finalized-account semantics — `FINALIZED_SUBACCOUNT_PERMANENTLY_ECONOMICALLY_CLOSED`

Post-finalization (`RecoveryState.RECOVERED`), Vault checks fail closed via:
- `_requireNotFinalized(subKey)` — dedicated helper introduced by WP-10B
  that only trips on `RECOVERED`. Called by `_pullAndCredit` (deposit
  + depositFor), `applyOptionPremiumTransfer` (both sides),
  `internalTransfer` (destination side).
- `_requireNoActiveRecoveryOn(subKey)` — WP-10A helper that trips on any
  state ≠ NORMAL / CANCELLED. Blocks all risk-increasing paths
  (`applyLock`, `applyOptionPremiumTransfer` sides,
  `applyOptionFeeCharge`, `applyOptionRebate`, `withdraw`,
  `internalTransfer` source).

Combined outcome:

| Path | Post-finalization behavior |
|---|---|
| `deposit` / `depositFor` | reverts `SubaccountFinalized` |
| standard `withdraw` | reverts `RecoveryActiveForSubaccount` (state is `RECOVERED`, not `NORMAL`/`CANCELLED`) |
| `internalTransfer` IN | reverts `SubaccountFinalized` |
| `internalTransfer` OUT | reverts `RecoveryActiveForSubaccount` |
| new Options match | reverts `RecoveryActiveForSubaccount` at `executeMatch` guard |
| premium / fee / rebate mutation | reverts `RecoveryActiveForSubaccount` |
| reservation increase (`applyLock`) | reverts `RecoveryActiveForSubaccount` |
| position mutation | blocked upstream (no matcher can execute) |
| reactivation via escape controller | reverts `RecoveryAlreadyPending` / `InvalidRecoveryStateTransition` — RECOVERED not transitionable back |
| Registry re-registration under new subaccount id | permitted (per Registry spec — new subaccount id, new canonical subKey) |
| historical views (`balanceOf`, `activeSeriesCount`, events) | remain readable |
| governance clearing of finalized state | impossible — no admin path exists |

## 11. Pause interaction — `RECOVERY_FINALIZATION_AVAILABLE_UNDER_GLOBAL_TRADING_PAUSE`

- `applyRecoveryFinalization` deliberately does NOT consult
  `_withdrawalsPaused`, `_depositsPaused`, or `_internalTransfersPaused`.
  These pause flags protect against unrelated attack surfaces
  (compromised token, oracle failure) and MUST NOT be able to trap a
  recovering user's funds indefinitely (INV-OPS-05 — no permanent trap).
- The recovery-controller `pauseRecovery` DOES block owner-initiated
  activation (WP-10A pause path). It does NOT block finalization —
  once a subaccount is in `RECOVERY_ACTIVE`, the finalizer is
  reachable regardless of controller pause.
- Guardian cannot use any pause to redirect funds — the recipient is
  Registry-derived at the primitive.
- No proof requirement is weakened by pause.

## 12. Atomicity — `RECOVERY_FINALIZATION_ATOMICITY_MODEL_RESOLVED`

`finalize(subaccountId)` order:

1. Enter `nonReentrant`.
2. `subaccountId != 0` check.
3. Registry-resolve owner (`ownerOf(subKey)`); reject if not caller.
4. Escape-controller state must be `RECOVERY_ACTIVE`.
5. `activeSeriesCount(subKey) == 0`.
6. Loop canonical universe: `lockedOf(subKey, token) == 0` for every token.
7. Snapshot recovery epoch.
8. `escape.markFinalized(subKey)` — transitions state to `RECOVERED`
   and stamps `_finalizedAt[subKey]`.
9. Loop canonical universe: `vault.applyRecoveryFinalization(subKey, token)`.
   Each call debits the exact canonical balance, updates
   `_totalAccounted`, transfers to owner, emits per-token event.
10. Emit `RecoveryFinalized` with the token-withdrawn count.

Any revert at any step unwinds:
- the `RECOVERED` state transition,
- every balance debit,
- every totalAccounted decrement,
- every emitted event (reverting-tx events are dropped by the EVM).

`nonReentrant` on both `finalize` (outer) AND the Vault primitive (inner).

## 13. Events + errors — Parts N + O

**Events:**
- `RecoveryFinalized(subKey, owner, subaccountId, recoveryEpochAtFinalization, finalizationTimestamp, tokensWithdrawn, caller, eventVersion)` — one per successful finalization.
- `RecoveryFinalizationWithdrawn(subKey, recipient, token, amount, caller, eventVersion)` — one per non-zero token withdrawn.

Together they reconstruct:
- whether the account finalized;
- when it finalized (`finalizationTimestamp` + `finalizedAt(subKey)` view);
- every token amount withdrawn;
- whether any claim remains (RW-1: no, all-or-none);
- canonical recipient (`owner` in Finalized event, `recipient` in Withdrawn event);
- finalized recovery epoch.

No signatures, proofs, or secrets emitted.

**Errors (finalizer):**
- `InvalidDependency`, `InvalidSubaccountId`, `SubaccountNotFound(owner, id)`,
- `UnauthorizedCaller(expectedOwner, caller)`,
- `RecoveryNotActive(subKey, currentState)`,
- `ActivePositionsRemain(subKey, activeCount)`,
- `ReservationsRemain(subKey, token, remaining)`.

**Errors (Vault primitive):**
- `OnlyRecoveryFinalizer`,
- `RecoveryFinalizationReservationRemains(subKey, token, remainingLocked)`,
- inherited: `SubKeyRequired`, `InvalidToken`, `OptionPremiumUnknownSubaccount`, `OptionPremiumUnknownToken`, `InvalidTokenBalanceDelta`.

**Errors (escape controller additions):**
- `RecoveryFinalizerAlreadyInitialized`, `InvalidRecoveryFinalizer`,
  `OnlyRecoveryFinalizer`, `CannotFinalizeFromState(state)`.

**Errors (Vault core additions):**
- `SubaccountFinalized(subKey)`,
- `RecoveryFinalizerAlreadyInitialized`, `InvalidRecoveryFinalizer`.

No string reverts.

## 14. Test evidence

**Baseline (pre-WP-10B):** 1309 tests / 0 failed.

**Post-WP-10B additions (all in `test/hybrid-v2/recovery/`):**
- `RecoveryFinalizerV1.t.sol` — 29 unit + fuzz + integration tests
  (construction, authority, state gate, position proof, reservation
  proof, withdrawal matrix incl. multi-token / disabled-token /
  zero-balance / donation-surplus / sibling-isolation, finalized-state
  restrictions on all vault paths + engine match, DB-loss
  reconstruction).
- `RecoveryFinalizerV1Invariant.t.sol` — 6 stateful invariants for
  `RECOVERY-FINAL-I5`/`I6`/`I7`/`I9`/`I12`/`I15` at 64×64 runs.
  `I1`, `I2`, `I3`, `I4`, `I8`, `I10`, `I11`, `I13`, `I14`, `I16` are
  covered by construction (handler cannot mutate them) + deterministic
  tests.
- `EscapeControllerV1Invariant.t.sol` — `ESCAPE-I12` updated
  (finalization-ready view now mirrors `state == RECOVERY_ACTIVE`).

**Closing:** see RUN_STATE / result doc for closing counts.

## 15. DB-loss reconstruction — `RECOVERY_FINALIZATION_RECONSTRUCTIBLE_AND_DB_INDEPENDENT`

- On-chain views (`recoveryStateOf`, `finalizedAt`,
  `recoveryEpochOf`, `balanceOf`, `totalAccounted`, `activeSeriesCount`,
  `lockedOf`) are the sole source of truth.
- The `RecoveryFinalized` + `RecoveryFinalizationWithdrawn` events are
  reconstructible from full log history.
- Duplicate finalization impossible — second `finalize` reverts
  `RecoveryNotActive(subKey, RECOVERED)`.
- Deposit / credit paths reject post-finalization at the Vault, so a
  wiped indexer cannot re-fund a finalized account by rebuilding
  bad state.
- Deterministic test `test_reconstruction_finalizationOnChainIsAuthoritative`.

## 16. Gas + DoS — `RECOVERY_FINALIZER_GAS_BOUNDED`

- Readiness view: O(collateralTokenCount) ≤ 8 SLOADs; ~50k gas at 8 tokens.
- Position proof: O(1) — single SLOAD of `activeSeriesCount`.
- Reservation proof: O(collateralTokenCount) ≤ 8 SLOADs.
- Finalization loop: O(collateralTokenCount) ≤ 8 iterations, each doing
  one balance read, one debit, one totalAccounted decrement, one
  SafeERC20 transfer, one balance-delta verify, one event emit.
- No engine enumeration, no order enumeration, no global account
  iteration, no unbounded proof.
- Recovery finalization never introduces a new block-gas blocker;
  worst case (8 non-standard tokens) remains well under any
  reasonable block gas ceiling.

## 17. Storage review — Part U

New storage on `EscapeControllerV1`:
- `address _recoveryFinalizer` (one-shot governance-set).
- `mapping(bytes32 => uint64) _finalizedAt` — finalization timestamp
  per subKey (zero when never finalized).

New storage on `CollateralVaultV2Core`:
- `address _recoveryFinalizer` (one-shot governance-set).

`RecoveryFinalizerV1` holds ONLY immutable dependencies — no mutable
storage. No cached readiness, no withdrawal history mapping, no
governance override slot, no arbitrary recipient state.

Finalized state has exactly one canonical owner: `RecoveryState.RECOVERED`
on the escape controller. Balances/positions/reservations live in their
canonical modules unchanged (except zeroed by the finalizer).

## 18. Files created / modified

**Production source:**
- `src/hybrid-v2/recovery/RecoveryFinalizerV1.sol` (new).
- `src/hybrid-v2/recovery/EscapeControllerV1.sol` — added
  `_recoveryFinalizer` slot, `_finalizedAt` mapping,
  `initializeRecoveryFinalizer`, `markFinalized`, `finalizedAt`,
  `recoveryFinalizer` views; `isFinalizationReady` now returns
  `state == RECOVERY_ACTIVE`; new errors.
- `src/hybrid-v2/vault/CollateralVaultV2Core.sol` — added
  `_recoveryFinalizer` slot, one-shot init, views, new
  `_requireNotFinalized` helper + `SubaccountFinalized` error;
  `_pullAndCredit` now calls the finalized guard.
- `src/hybrid-v2/vault/CollateralVaultV2.sol` — added
  `applyRecoveryFinalization` primitive + event/errors; wired
  `_requireNotFinalized` into premium transfer (both sides) and
  internal transfer destination.
- `src/hybrid-v2/interfaces/IEscapeController.sol` — added
  `finalizedAt`, `recoveryFinalizer`, `initializeRecoveryFinalizer`,
  `markFinalized` declarations; `isFinalizationReady` semantics
  clarified.
- `src/hybrid-v2/interfaces/ICollateralVault.sol` — added
  `initializeRecoveryFinalizer`, `recoveryFinalizer`,
  `recoveryFinalizerInitialized`, `applyRecoveryFinalization`.

**Tests:**
- `test/hybrid-v2/recovery/RecoveryFinalizerV1.t.sol` (new, 29 tests).
- `test/hybrid-v2/recovery/RecoveryFinalizerV1Invariant.t.sol` (new, 6 invariants).
- `test/hybrid-v2/recovery/handlers/RecoveryFinalizerHandler.sol` (new handler).
- `test/hybrid-v2/recovery/EscapeControllerV1Invariant.t.sol` — updated
  `invariant_I12_finalizationReadyIffActive` (renamed from
  `finalizationAlwaysFalseInWP10A`) to reflect the new finalizer boundary.

**Docs:**
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_RECOVERY_FINALIZER_V1.md` (this file).
- `docs/ONCHAIN_SUBACCOUNT_RECOVERY_FINALIZER_V1_RESULT.md` (result doc).
- `RUN_STATE.md` — dated section prepended.

## 19. Verdicts returned

- `RECOVERY_FINALIZATION_MODEL_RESOLVED`
- `RECOVERY_FINALIZER_IMPLEMENTATION_BOUNDARY_RESOLVED`
- `RECOVERY_FINALIZATION_AUTHORITY_AND_RECIPIENT_RESOLVED`
- `RECOVERY_ZERO_OPTIONS_POSITION_PROOF_OBJECTIVE`
- `RECOVERY_ZERO_RESERVATION_PROOF_OBJECTIVE`
- `RECOVERY_ALL_V1_OBLIGATIONS_OBJECTIVELY_RESOLVED`
- `RECOVERY_WITHDRAWAL_ATOMIC_ALL_CANONICAL_TOKENS`
- `VAULT_RECOVERY_WITHDRAWAL_PRIMITIVE_IMPLEMENTED_NARROWLY`
- `FINALIZED_SUBACCOUNT_PERMANENTLY_ECONOMICALLY_CLOSED`
- `RECOVERY_FINALIZATION_AVAILABLE_UNDER_GLOBAL_TRADING_PAUSE`
- `RECOVERY_FINALIZATION_ATOMICITY_MODEL_RESOLVED`
- `RECOVERY_FINALIZATION_RECONSTRUCTIBLE_AND_DB_INDEPENDENT`
- `RECOVERY_FINALIZER_GAS_BOUNDED`
- `NO_FORCED_SETTLEMENT_LIQUIDATION_OR_ARBITRARY_RESERVATION_RELEASE_IMPLEMENTED`
- `ONCHAIN_SUBACCOUNT_RECOVERY_FINALIZER_V1_COMPLETE`
- `READY_FOR_ONCHAIN_SUBACCOUNT_EVENT_SURFACE_AND_DEPLOYMENT_MANIFEST_V1`

## 20. Non-goals (recap)

- No forced Options settlement.
- No liquidation execution.
- No fallback-oracle price selection (F-A → F-D remains
  `IRecoveryFinalizer` fallback interface scope — separate concrete
  contract not required by WP-10B).
- No arbitrary reservation release (V2-B `governanceReleaseOrphanedLock`
  remains the only path, gated by `_requireOrphanedReleaseProof`).
- No governance or guardian recipient.
- No insurance-fund debit.
- No user or protocol liability write-off.
- No Perps integration.
- No generic Vault debit/credit primitives — the recovery primitive is
  narrow (owner-only recipient, canonical-only tokens, no
  caller-supplied amount).

## 21. Dated cross-references

- `ONCHAIN_SUBACCOUNT_ESCAPE_CONTROLLER_V1.md` (2026-07-30 / WP-10A) —
  WP-10B extends `IEscapeController` with `markFinalized` and
  `finalizedAt`; changes `isFinalizationReady` semantics from
  "always false in WP-10A" to "true iff state == RECOVERY_ACTIVE".
  Prior WP-10A verdicts remain valid.
- `ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_B.md` (WP-04B) — WP-10B adds
  `applyRecoveryFinalization` narrow primitive and
  `SubaccountFinalized` credit guard. Prior VAULT-B invariants
  remain load-bearing; the primitive uses the same balance /
  totalAccounted / SafeERC20 patterns.
- `ONCHAIN_SUBACCOUNT_OPTIONS_POSITIONS_LEDGER_V1.md` (WP-06) —
  `activeSeriesCount(subKey)` view consumed as the finalizer's
  position proof. No ledger changes required.
- `ONCHAIN_SUBACCOUNT_EXPERIMENTAL_IMPLEMENTATION_PLAN_V1.md` —
  WP-10B closes the WP-10 pair; next milestone is WP-11
  event-surface + deployment manifest.

## 22. Exact next milestone

`ONCHAIN-SUBACCOUNT-EVENT-SURFACE-AND-DEPLOYMENT-MANIFEST-V1`.
