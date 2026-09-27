# PERPS V2 BASE SEPOLIA V1 DB RETIREMENT V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_V1_DB_RETIREMENT_V1`
**Status**: **COMPLETE — DATABASE WRITES ONLY (4 canonical intent retirements)**
**Sol HEAD (pre)**: `492d632` (unchanged during milestone)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged during milestone; worktree clean)
**Chain**: Base Sepolia (chainId 84532) — **no chain writes performed**

Scope: exactly four canonical `retire_execution_intent` transitions of the real 2026 V1 execution intents identified by `PERPS_V2_BASE_SEPOLIA_V1_DRAIN_CLASSIFICATION_V1`. All 26 proven test-fixture rows preserved byte-identical; indexer state untouched; Timelock op untouched.

---

## A. Preflight

Repository HEADs and worktrees (pre-write):

```
sol      HEAD = 492d632  "docs(perps): PERPS_V2_BASE_SEPOLIA_CUTOVER_FREEZE_V1 — Phase C1 complete"
backend  HEAD = ad8dd7466 "feat(perps): PERPS_V2_BACKEND_ANVIL_BROADCAST_E2E_V1 — first real V2 send on Anvil"
sol.status     = clean (nothing to commit)
backend.status = clean (nothing to commit)
```

Base Sepolia chain state (pre-write, block 47_358_575):

```
PME_V1.paused                     = true
V1_ENGINE.liquidationPaused       = true
Vault.isAuthorizedEngine(V1)      = true
Vault.isAuthorizedEngine(V2)      = false
ENGINE_V2.migrationState          = 0 (OPEN)
ENGINE_V2.migrationSnapshotHash   = 0x0000…0000
Timelock.queuedTransactions(0xb42e46a9…4fd0) = true
```

Backend `.env.perps_closed_test_prepare_only.local`:

- `EXECUTOR_REAL_BROADCAST_ENABLED=false` (fail-closed broadcast)
- `INDEXER_ENABLED=false` (deliberate)
- `PERPS_ACTIVE_ENGINE_VERSION` unset → defaults to `v1` (per `src/execution/config.rs:200`)

Database connectivity:

```
host=127.0.0.1 port=5432 db=deopt_v2_backend user=deopt
PostgreSQL 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
```

## B. Four intents (per classification milestone)

```
2ba078ec-c519-43d8-9760-7b9578f0cdd4
7929e57c-7861-44eb-a8f7-314fd5e6f707
d327cec8-b1e5-49e8-8c13-fd5920ff82d9
5c7e988a-3e19-46d2-abf3-3d3349e9a6e3
```

## C. Retire-eligibility proof (per intent, pre-write)

| intent_id | protocol | status_pre | eligible | deadline_ms | expired | bc | raw_tx | tx_hash | rec | tx_rows | sig | sim |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2ba078ec-…f0cdd4 | perp_v1 | pending        | t | 1789618272000 | t | 0 | 0 | (none) | 0 | 0 | 0 | 0 |
| 7929e57c-…f5e6f707 | perp_v1 | calldata_ready | t | 1789635433000 | t | 0 | 0 | (none) | 0 | 0 | 1 | 0 |
| d327cec8-…20ff82d9 | perp_v1 | simulation_ok  | t | 1789665343000 | t | 0 | 0 | (none) | 0 | 0 | 1 | 1 |
| 5c7e988a-…49e9a6e3 | perp_v1 | simulation_ok  | t | 1789723041000 | t | 0 | 0 | (none) | 0 | 0 | 1 | 1 |

`eligible` derived from `ExecutionIntentStatus::is_retire_eligible()` at `src/execution/intent.rs:47-56` — passes for `Pending / DryRun / CalldataReady / SimulationOk / SimulationFailed`.

Every intent has:

- `protocol_version = 'perp_v1'` ✓
- retire-eligible status ✓
- expired `deadline_ms` (all deadlines > 63 h before `now_ms = 1_790_485_472_000`) ✓
- zero rows in `execution_intent_broadcasts` (no `raw_tx_hex`, no `tx_hash`, no submission) ✓
- zero rows in `execution_reconciliations` and `execution_transactions` ✓
- zero rows in `indexed_perp_trades` for their `onchain_intent_id` (0 matches over `0x88af064d…6669 | 0x7b8a9d3f…d9f0 | 0xa013ea17…0248 | 0xb6f424f2…36c0`) ✓
- chain-side execution BLOCKED by `PME_V1.paused=true` and `V1_ENGINE.liquidationPaused=true` ✓
- backend-side broadcast BLOCKED by `EXECUTOR_REAL_BROADCAST_ENABLED=false` and (independently) by `broadcast_policy.rs:402-403` `PerpsIntentDeadlineExpired` ✓

## D. Canonical retirement mechanism

`retire_execution_intent` operator binary (`src/bin/retire_execution_intent.rs`) calling `PgRepository::retire_execution_intent` (`src/db/repository.rs:1403-1452`). Each call is a single atomic transaction:

```
BEGIN;
SELECT status FROM execution_intents WHERE intent_id = $1 FOR UPDATE;
-- guard: is_retire_eligible() else ERROR
UPDATE execution_intents SET status='abandoned', updated_at_ms=$now WHERE intent_id=$1;
COMMIT;
```

Handcrafted SQL was NOT used. All four retirements went through the pre-built `target/debug/retire_execution_intent` binary (compiled from HEAD `ad8dd7466`; verified newer than every `src/` and `Cargo.*` file via `find -newer`).

## E. Mutation result — one per intent (sequential)

Each retirement was run as a standalone `retire_execution_intent <uuid>` invocation and read back immediately.

```
=== RETIREMENT #1: 2ba078ec-c519-43d8-9760-7b9578f0cdd4 ===
retired intent_id=2ba078ec-c519-43d8-9760-7b9578f0cdd4 previous_status=Pending new_status=abandoned
exit=0
readback: 2ba078ec-c519-43d8-9760-7b9578f0cdd4|abandoned|1790485653151

=== RETIREMENT #2: 7929e57c-7861-44eb-a8f7-314fd5e6f707 ===
retired intent_id=7929e57c-7861-44eb-a8f7-314fd5e6f707 previous_status=CalldataReady new_status=abandoned
exit=0
readback: 7929e57c-7861-44eb-a8f7-314fd5e6f707|abandoned|1790485702384

=== RETIREMENT #3: d327cec8-b1e5-49e8-8c13-fd5920ff82d9 ===
retired intent_id=d327cec8-b1e5-49e8-8c13-fd5920ff82d9 previous_status=SimulationOk new_status=abandoned
exit=0
readback: d327cec8-b1e5-49e8-8c13-fd5920ff82d9|abandoned|1790485725370

=== RETIREMENT #4: 5c7e988a-3e19-46d2-abf3-3d3349e9a6e3 ===
retired intent_id=5c7e988a-3e19-46d2-abf3-3d3349e9a6e3 previous_status=SimulationOk new_status=abandoned
exit=0
readback: 5c7e988a-3e19-46d2-abf3-3d3349e9a6e3|abandoned|1790485734705
```

## F. Before/after status matrix

| intent_id | status_pre | status_post | updated_at_ms_pre | updated_at_ms_post |
|---|---|---|---|---|
| 2ba078ec-…f0cdd4 | pending        | abandoned | 1789614672276 | 1790485653151 |
| 7929e57c-…f5e6f707 | calldata_ready | abandoned | 1789622666184 | 1790485702384 |
| d327cec8-…20ff82d9 | simulation_ok  | abandoned | 1789656700798 | 1790485725370 |
| 5c7e988a-…49e9a6e3 | simulation_ok  | abandoned | 1789695742483 | 1790485734705 |

## G. Fixture protection proof

Fixture fingerprint = SHA256 over ordered projection of every row with `created_at_ms = 1_700_000_000_000` (execution_intents), every row with `prepared_at_ms = 1_700_000_000_000` (execution_intent_broadcasts), and every row of `indexed_perp_trades`:

```
pre-write  sha256: be177aed009178458ae9b29fe44bd2cae7c2522be8c81aeeac2744dfee0c1383  /tmp/fixture_fingerprint_pre.tsv
post-write sha256: be177aed009178458ae9b29fe44bd2cae7c2522be8c81aeeac2744dfee0c1383  /tmp/fixture_fingerprint_post.tsv
diff /tmp/fixture_fingerprint_pre.tsv /tmp/fixture_fingerprint_post.tsv → FIXTURES BYTE-IDENTICAL
```

Row counts (unchanged):

- 24 execution_intents rows with `created_at_ms = 1_700_000_000_000` — untouched.
- 18 execution_intent_broadcasts rows with `prepared_at_ms = 1_700_000_000_000` — untouched.
- 3 indexed_perp_trades rows — untouched.

## H. DB mutation audit (updated within retirement window 1790485650000..1790485740000)

```
execution_intents         updates_in_window = 4   (exactly the 4 target rows)
execution_intent_broadcasts updates_in_window = 0
execution_intent_signatures updates_in_window = 0
execution_simulations       inserts_in_window = 0
execution_transactions      writes_in_window  = 0 (created_at_ms OR updated_at_ms)
execution_reconciliations   total row count   = 0 (table remains empty, unchanged)
indexed_perp_trades         total row count   = 3 (unchanged)
indexer_cursors             total row count   = 1 (unchanged; still 84532/perp_matching_engine → 41)
```

No cascaded delete, no cascaded insert, no ancillary row mutation. Exactly four intent rows changed, one atomic transaction each.

## I. Real-universe quiescence counts (post-retirement)

Real-universe = strict predicates with fixture-timestamp exclusion (`created_at_ms <> 1_700_000_000_000`, `prepared_at_ms <> 1_700_000_000_000`):

```
real_pending          (V1 perp_v1)                = 0
real_calldata_ready   (V1 perp_v1)                = 0
real_simulation_ok    (V1 perp_v1)                = 0
real_prepared         (V1 perp_v1 broadcasts)     = 0
real_submitted        (V1 perp_v1 broadcasts)     = 0
```

Canonical abandoned rows (V1, real universe) — 5 total:

```
7c6f413a-b219-4379-8f6e-a0f559d66ab6  abandoned  1789722739687  (historical — pre-existing)
2ba078ec-c519-43d8-9760-7b9578f0cdd4  abandoned  1790485653151  (this milestone)
7929e57c-7861-44eb-a8f7-314fd5e6f707  abandoned  1790485702384  (this milestone)
d327cec8-b1e5-49e8-8c13-fd5920ff82d9  abandoned  1790485725370  (this milestone)
5c7e988a-3e19-46d2-abf3-3d3349e9a6e3  abandoned  1790485734705  (this milestone)
```

Strict predicate (fixture-inclusive) count: **17** = 21 pre-retirement − 4 retired — expected exactly (Δ = 4).

## J. Chain state readback (post-write; block 47_358_807)

```
PME_V1.paused                     = true                (unchanged)
V1_ENGINE.liquidationPaused       = true                (unchanged)
V1_ENGINE.tradingPaused           = false               (unchanged)
V1_ENGINE.fundingPaused           = false               (unchanged)
V1_ENGINE.collateralOpsPaused     = false               (unchanged)
Vault.isAuthorizedEngine(V1)      = true                (unchanged)
Vault.isAuthorizedEngine(V2)      = false               (unchanged)
ENGINE_V2.migrationState          = 0 (OPEN)            (unchanged)
ENGINE_V2.migrationSnapshotHash   = 0x0                 (unchanged)
Timelock.queuedTransactions(op)   = true                (unchanged; still queued+ready+unexecuted)
```

V1 economic state:

```
marketState(1)                    = (1_001_002, 1_001_002, 0, 1_789_715_546)  ← identical to FREEZE poststate
marketState(2)                    = (0, 0, 0, 0)                              ← identical
totalResidualBadDebtBase          = 0                                          ← identical
```

Chain state byte-identical to `PERPS_V2_BASE_SEPOLIA_CUTOVER_FREEZE_V1.md §J`. ✓

## K. Timelock op state

```
op_id       0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0
queued      true
ready       true         (ETA 1790475748 < now 1790485902)
executed    false
```

Not touched this milestone.

## L. Repository HEADs / worktrees (post-write)

```
sol      HEAD = 492d632   worktree = clean (before docs commit)
backend  HEAD = ad8dd7466 worktree = clean
```

Backend worktree remained clean throughout. No src/ changes, no Cargo* changes, no migration changes.

## M. Changed files

Sol repo:

- `docs/PERPS_V2_BASE_SEPOLIA_V1_DB_RETIREMENT_V1.md` (this file, NEW)

Backend repo:

- (none)

## N. Commit / push status

Sol repo docs commit + push per operator workflow.

## O. Transaction / mutation audit

```
Base Sepolia public transactions:  0
Safe nonce delta                    = 0
Deployer EOA nonce delta            = 0
Runtime executor nonce delta        = 0
DB mutations                        = 4 (canonical intent retirements — atomic, single-row each)
DB inserts                          = 0
DB fixture mutations                = 0
Chain read-only calls (audit)       ≈ 30 (cast call: state readbacks, no state change)
```

## P. Remaining blocker for `V1_QUIESCENCE_READY`

The strict `§I` runbook predicates in `PERPS_V2_BASE_SEPOLIA_CUTOVER_FREEZE_V1.md`:

- (1) `SELECT COUNT(*) FROM execution_intents WHERE protocol_version='perp_v1' AND status IN ('pending','dry_run','calldata_ready','simulation_ok')` — still returns 17 due to preserved fixture rows. Real-universe count = 0.
- (2) `SELECT COUNT(*) FROM execution_intent_broadcasts WHERE protocol_version='perp_v1' AND status IN ('prepared','submitted')` — still returns 9 due to preserved fixture rows. Real-universe count = 0.
- (3) `SELECT last_block_processed FROM reconciler_state ...` — table does not exist (architecturally invalid).
- (4) `SELECT MAX(block_number) FROM indexed_perp_trades WHERE protocol_version='perp_v1'` — returns NULL (indexer deliberately disabled; architecturally invalid for prepare-only rehearsal).

**Do NOT** yet declare `V1_QUIESCENCE_READY`.

## Q. Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_QUIESCENCE_RUNBOOK_FIX_V1`** (docs-only sol-repo change; NO chain writes, NO DB writes, NO backend changes). Scope:

1. Amend `§I` of `PERPS_V2_BASE_SEPOLIA_CUTOVER_FREEZE_V1.md` predicates (1) and (2) to add `AND created_at_ms <> 1_700_000_000_000` / `AND prepared_at_ms <> 1_700_000_000_000` fixture exclusions (fixtures now provably fingerprint-stable, deterministic, and non-broadcastable).
2. Replace `§I` predicate (3) with `SELECT COUNT(*) FROM execution_intent_broadcasts WHERE protocol_version='perp_v1' AND status NOT IN ('confirmed','failed') AND prepared_at_ms <> 1_700_000_000_000` (0 expected).
3. Replace `§I` predicate (4) with chain-authoritative invariant check (marketState + Σ per-trader position closure) — the indexer path is optional defense-in-depth for this operation and MUST NOT be fabricated.
4. Commit the runbook change to sol repo.

Once (Q) lands, the strict predicates return zero rows and `V1_QUIESCENCE_READY` may be declared, at which point `PERPS_V2_BASE_SEPOLIA_FINAL_SNAPSHOT_V1` becomes the next executable milestone.

**Do NOT recommend `PERPS_V2_BASE_SEPOLIA_FINAL_SNAPSHOT_V1` yet.**

## R. STOP

FOUR canonical DB retirements complete. No chain write, no Timelock execute, no snapshot, no clearing funding, no migration seed/seal, no backend V2 activation, no fixture mutation, no indexer mutation. Control returned to operator.
