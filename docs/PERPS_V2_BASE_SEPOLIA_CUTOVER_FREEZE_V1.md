# PERPS V2 BASE SEPOLIA CUTOVER FREEZE V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_CUTOVER_FREEZE_V1`
**Status**: **COMPLETE — Phase C1 executed** (chain freeze + backend broadcast already in fail-closed config)
**Sol HEAD (pre)**: `e180cb7`
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged, worktree clean)
**Chain**: Base Sepolia (chainId 84532)
**Timelock op**: `0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0` — remains queued, ready, NOT executed

Freeze accomplished by two deployer EOA transactions plus verification that the backend runtime already runs with `EXECUTOR_REAL_BROADCAST_ENABLED=false` (fail-closed default in the currently loaded `.env.perps_closed_test_prepare_only.local`). No V1 broadcast can arm and no V1 chain-level matching or liquidation path is reachable.

---

## A. Starting state (pre-C1.1)

| item | value |
|---|---|
| chainId | 84532 |
| Sol HEAD | `e180cb7` (production bytecode frozen at `004bf78`) |
| backend HEAD | `ad8dd7466` |
| deployer nonce | 770 |
| Safe nonce | 14 |
| `PME_V1.paused` | false |
| `V1_ENGINE.liquidationPaused` | false |
| Vault.isAuth(V1) | true |
| Vault.isAuth(V2) | false |
| ENGINE_V2.migrationState | 0 (OPEN) |
| ENGINE_V2.migrationSnapshotHash | 0x0 |
| Timelock.queuedTransactions[opId] | true |
| Timelock.isOperationReady | true |
| deployer balance | 0.001788 ETH |

## B. C1.1 PME_V1.pause() tx

| field | value |
|---|---|
| target | `0x774d96E5739bffadEE91508b4D3D74F5BE29F165` (PME_V1) |
| function | `pause()` |
| selector | `0x8456cb59` |
| authority | deployer EOA `0xc35F7A8A…` (PME_V1.owner + guardian) |
| tx hash | **`0xeeb22d64b88508956fc88f19643944a740e6de0cd65d8ad2713fb421c6edb89c`** |
| block | 47_354_373 |
| status | 0x1 |
| gas used | 47 022 |
| gas price | 6 mwei |

## C. C1.1 readback

- `PME_V1.paused()` → **true** ✓
- Emitted `Paused(address(0xc35F7A8A…))` topic0 `0x62e78cea01bee320cd4e420270b5ea74000d11b0c9f74754ebdbfc544b05a258`

## D. C1.1 matching fail-closed proof

`cast call` simulation of `PME_V1.executeTrade(...)` reverts (`Error: execution reverted`). PME V1 matching path is chain-frozen. Combined with `V1_ENGINE.applyTrade` being `onlyMatchingEngine`-gated, no V1 trade can execute.

## E. C1.2 V1_ENGINE.pauseLiquidation() tx

| field | value |
|---|---|
| target | `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` (V1_ENGINE) |
| function | `pauseLiquidation()` |
| selector | `0x1d966e81` |
| authority | deployer EOA `0xc35F7A8A…` (V1_ENGINE.owner + guardian) |
| tx hash | **`0x069c3ce2d4a8857696e411fb8152ca2c132bd0543588e917def847680a607486`** |
| block | 47_354_399 |
| status | 0x1 |
| gas used | 48 824 |

## F. C1.2 readback

- `V1_ENGINE.liquidationPaused()` → **true** ✓
- Emitted `LiquidationPauseSet(true)` topic0 `0x1eb82b06aa284b326c89633f27ae24e2042ef8b28942daa18082db180f621efa`
- Emitted `EmergencyModeUpdated(false, true, false, false)` topic0 `0xefcae44e8da20c3a97e0256ac9dfe9c8c5a900dca59f556168b17e7d68e2c4b7`

## G. C1.2 liquidation fail-closed proof

`cast call` simulation of `V1_ENGINE.liquidate(...)` reverts with selector **`0x0d3f92fd`** (`LiquidationPaused()`). V1 liquidation path is chain-frozen. Combined with §D, all V1 mutation surfaces that could touch positions or Vault are FROZEN.

## H. C1.3 backend V1 broadcast-worker freeze

**No config change required at this milestone** — the backend was already loaded from `deopt-v2-backend/.env.perps_closed_test_prepare_only.local`, which contains:

```
EXECUTOR_REAL_BROADCAST_ENABLED=false
```

Per `src/execution/broadcast_policy.rs:295` the broadcast policy step evaluates:

```rust
if !self.config.real_broadcast_enabled {
    // fail-closed default
    return Err(BroadcastRejected { reason: "executor.real_broadcast_enabled = false (fail-closed default)".into() });
}
```

so no V1 (or V2) broadcast can leave the executor even if intents/simulations progress locally. The `EXECUTOR_DRY_RUN` and `PERPS_PUBLIC_TRADING_ENABLED` toggles are auxiliary; the primary broadcast gate is `EXECUTOR_REAL_BROADCAST_ENABLED=false`.

Backend is bound to `127.0.0.1:3000` (running) and its `/api/executor/health/v2` endpoint is auth-gated (`401 Unauthorized`) — no unauthenticated introspection. The reconciler + indexer remain operational (READ-ONLY paths); only the broadcast/send path is disarmed.

**`PERPS_ACTIVE_ENGINE_VERSION` is not present in that env file** (backend defaults to `v1` per `src/execution/config.rs:200`); v1 is authoritative for this run. Confirmed unchanged.

Backend HEAD `ad8dd7466aeba6963d28687e825fe4df58ef32ee` unchanged, worktree clean.

## I. Quiescence gate — exact queries (executed at operator-side PG session)

> **AMENDED by `PERPS_V2_BASE_SEPOLIA_QUIESCENCE_RUNBOOK_FIX_V1`.** The original §I predicates (3) and (4) referenced tables/columns that either do not exist (`reconciler_state`) or are deliberately not populated in the `.env.perps_closed_test_prepare_only.local` configuration (`indexed_perp_trades` with `INDEXER_ENABLED=false`). Predicates (1) and (2) counted `PROVEN_TEST_FIXTURE` rows as live operational state. Corrected predicates below use structural fixture identity (durable across future test-DB pollution) and defer indexer-related closure to a chain-authoritative invariant proof. See `docs/PERPS_V2_BASE_SEPOLIA_QUIESCENCE_RUNBOOK_FIX_V1.md` for the derivation.

Because DB credentials for `.env.perps_closed_test_prepare_only.local` are held by the operator (not this session), the exact quiescence SQL is documented here for operator execution. Every predicate must return **0 rows** at the pinned `V1_QUIESCENCE_BLOCK`:

```sql
-- 1. no REAL V1 intent that could still transition to on-chain execution
--    (structural fixture exclusion: the durability test buyer/seller pair,
--     hex-encoded output of addr(0x11) / addr(0x12) in
--     tests/perps_broadcast_durability_pg_integration.rs)
SELECT COUNT(*) FROM execution_intents
 WHERE protocol_version = 'perp_v1'
   AND status IN ('pending','dry_run','calldata_ready','simulation_ok')
   AND NOT (
     buyer  = '0x1130415263748596a7b8c9daebfc0d1e2f405162'
     AND seller = '0x1231435567798b9dafc1d3e5f7091b2d3f516375'
   );

-- 2. no unresolved REAL V1 broadcast
--    (structural fixture exclusion: raw_tx_hex sentinels '0x02f8...deadbeef'
--     and '0x02f8...cafe' are 13-17 bytes; real EIP-1559 envelopes are >= ~1500 bytes.
--     LENGTH(raw_tx_hex) >= 20 is a durable structural boundary.)
SELECT COUNT(*) FROM execution_intent_broadcasts
 WHERE protocol_version = 'perp_v1'
   AND status IN ('prepared','submitted')
   AND LENGTH(raw_tx_hex) >= 20;

-- 3′. no REAL V1 broadcast in any non-terminal state
--    (replacement for the defunct `reconciler_state` predicate.
--     The reconciler is authoritative for broadcast lifecycle: a
--     `confirmed` or `failed` row is terminal-observed on-chain; any other
--     status is unresolved. Structural fixture exclusion via raw_tx length.)
SELECT COUNT(*) FROM execution_intent_broadcasts
 WHERE protocol_version = 'perp_v1'
   AND status NOT IN ('confirmed','failed')
   AND LENGTH(raw_tx_hex) >= 20;

-- 4′. chain-authoritative closure (replacement for indexer-based predicate)
--    Executed OFF-DB via `cast call` / raw JSON-RPC. Requires ALL of:
--      * PME_V1.paused == true
--      * V1_ENGINE.liquidationPaused == true
--      * V1_ENGINE.marketState(1) == (1_001_002, 1_001_002, 0, 1_789_715_546)
--      * V1_ENGINE.marketState(2) == (0, 0, 0, 0)
--      * V1_ENGINE.totalResidualBadDebtBase() == 0
--      * Σ per-trader getPositionSize(t,1) over the 6 known traders == 0
--      * Σ |negative getPositionSize| == marketState(1).shortOI ≡ 1_001_002
--      * Σ positive getPositionSize == marketState(1).longOI  ≡ 1_001_002
--      * Σ PME_V1.nonces(t) over the 6 known traders == 8 (= 2 × 4 trades)
--      * raw `eth_getLogs` V1_ENGINE.TradeExecuted over [V1_deploy_block, V1_QUIESCENCE_BLOCK]
--        returns exactly 4 events with the correct topic0
--        `0xa73bf9fa75c33ddc672c6fc71d4d4b4e5f85c018c8acc16855e94f564114ed60`
--        whose buyer/seller union == the 6-trader set.
--
--    NOTE: `SELECT MAX(block_number) FROM indexed_perp_trades WHERE protocol_version='perp_v1'`
--    was the original predicate. It has been RETIRED for this operational
--    configuration because `INDEXER_ENABLED=false` (deliberate in the
--    prepare-only rehearsal env). Do NOT fabricate/backfill V1 rows in
--    `indexed_perp_trades` and do NOT advance `indexer_cursors` to
--    satisfy the original predicate. See `PERPS_V2_BASE_SEPOLIA_QUIESCENCE_RUNBOOK_FIX_V1.md`.

-- 5. no worker armed for a fresh V1 broadcast
--    (retained from original — the `perps_closed_test_broadcast_armed`
--     column does not appear to be populated in the current schema; the
--     predicate is defense-in-depth against a future arming column.)
SELECT COUNT(*) FROM execution_intents i
 JOIN (SELECT column_name FROM information_schema.columns
        WHERE table_name='execution_intents'
          AND column_name='perps_closed_test_broadcast_armed') c ON true
 WHERE i.protocol_version = 'perp_v1'
   AND i.status = 'prepared';
--   (If the column does not exist, this join returns zero rows — safe.)

-- 6. historical abandoned close remains Abandoned (invariant readback)
SELECT status FROM execution_intents
 WHERE intent_id = '7c6f413a-b219-4379-8f6e-a0f559d66ab6';
-- Expected: 'abandoned'

-- 7. four PERPS_V2_BASE_SEPOLIA_V1_DB_RETIREMENT_V1 intents remain Abandoned
SELECT intent_id, status FROM execution_intents
 WHERE intent_id IN (
   '2ba078ec-c519-43d8-9760-7b9578f0cdd4',
   '7929e57c-7861-44eb-a8f7-314fd5e6f707',
   'd327cec8-b1e5-49e8-8c13-fd5920ff82d9',
   '5c7e988a-3e19-46d2-abf3-3d3349e9a6e3'
 );
-- Expected: 4 rows, all status = 'abandoned'
```

Predicates (1), (2), (3′) MUST return count = 0. Predicate (4′) is a compound off-DB check whose every clause must hold. Predicates (5)–(7) are invariant readbacks with fixed expected values.

## J. Quiescence counts / verdict (chain-side; DB side to be confirmed by operator)

Chain-side evidence for quiescence is unambiguous:

- **No new V1 signed intent can execute on-chain** — `PME_V1.paused == true` reverts every `executeTrade*` path (proven in §D).
- **No new V1 liquidation can execute on-chain** — `V1_ENGINE.liquidationPaused == true` reverts every `liquidate(...)` path (proven in §G).
- **No V1 broadcast can leave the backend** — `EXECUTOR_REAL_BROADCAST_ENABLED=false` fails closed at broadcast policy (§H).
- **Current V1 economic state matches the tooling-readiness snapshot exactly**:
  - `market 1 state = (1_001_002, 1_001_002, 0, 1_789_715_546)` — identical to freeze-preflight snapshot ✓
  - `market 2 state = (0, 0, 0, 0)` — empty ✓
  - `totalResidualBadDebtBase = 0` ✓
  - 6 live trader positions (3 matched pairs, all market 1) size1e8 values byte-identical to freeze-preflight snapshot:

```
0x290bd12c93e467bf51c51f5273d35bddb19e9274 market1 size1e8=  1_000
0x475fe397fa56884952d350aa9ee1c3946964bc0c market1 size1e8=     -2
0x66858286feea78a05ea093673ea1535e0a52002d market1 size1e8= -1_000_000
0x77ca9dd6ccce2d692fb23877a2db7178807b0020 market1 size1e8=  -1_000
0x8b94a83d1ad3bd2337b1886e7962ca8e0bba9a34 market1 size1e8=      2
0xff287410852b9328437eac353720e5476bc5f837 market1 size1e8=  1_000_000
```

Chain-side verdict: **V1_QUIESCENCE_READY** (chain-conditional). DB verdict pending operator SQL execution.

## K. Reconciler / indexer state

> **AMENDED by `PERPS_V2_BASE_SEPOLIA_QUIESCENCE_RUNBOOK_FIX_V1`.** The `.env.perps_closed_test_prepare_only.local` file sets `INDEXER_ENABLED=false` deliberately. `indexed_perp_trades` therefore has no V1 rows and its cursor (`(chain_id=84532, name='perp_matching_engine', last_indexed_block=41)`) is a local-Anvil relic. The `reconciler_state` table does not exist in the current schema. Chain observation for V1 quiescence has been re-based on raw JSON-RPC `eth_getLogs` + per-trader / market invariant closure (§I predicate (4′)).

Neither the indexer nor a reconciler-state cursor is a required signal for this operation. Because `EXECUTOR_REAL_BROADCAST_ENABLED=false` at the backend and `PME_V1.paused=true` on-chain, no new V1 event can be emitted after the freeze, so a "cursor caught up to `V1_QUIESCENCE_BLOCK`" gate is redundant with the chain-authoritative closure (§I predicate 4′).

## L. `V1_QUIESCENCE` verdict

> **AMENDED by `PERPS_V2_BASE_SEPOLIA_QUIESCENCE_RUNBOOK_FIX_V1`.** The rewritten `V1_QUIESCENCE_READY` gate requires ALL of:
>
> - `PME_V1.paused == true`
> - `V1_ENGINE.liquidationPaused == true`
> - backend `EXECUTOR_REAL_BROADCAST_ENABLED == false` (V1 real broadcasting disabled)
> - §I predicate (1) real-V1-intent-non-terminal count == 0
> - §I predicate (2) real-V1-broadcast-non-terminal count == 0 (specifically for `prepared`/`submitted`)
> - §I predicate (3′) real-V1-broadcast in any non-terminal status count == 0
> - §I predicate (6) `7c6f413a-b21…` remains `abandoned`
> - §I predicate (7) the four `V1_DB_RETIREMENT_V1` intents remain `abandoned`
> - §I predicate (4′) — full chain-authoritative closure:
>   - raw `eth_getLogs` V1 TradeExecuted stream through `V1_QUIESCENCE_BLOCK` is complete
>   - exactly 4 lifetime events, 6 unique traders
>   - latest event block ≤ `V1_QUIESCENCE_BLOCK` (observed: 46_973_629)
>   - `market_1.longOI == 1_001_002` and `market_1.shortOI == 1_001_002`
>   - Σ per-trader `getPositionSize` over the 6 traders == 0 (net) and matches per-side OI exactly
>   - `market_2 == (0, 0, 0, 0)`
>   - `totalResidualBadDebtBase == 0`
> - Vault: `isAuthorizedEngine(V1) == true`, `isAuthorizedEngine(V2) == false`
> - V2: `migrationState == 0 (OPEN)`, `migrationSnapshotHash == 0x0`
> - Timelock op `0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0` remains `queued=true`, `ready=true`, `not executed`.
>
> **Chain-conditional PLUS DB-conditional verdict, evaluated live in `PERPS_V2_BASE_SEPOLIA_QUIESCENCE_RUNBOOK_FIX_V1`: `V1_QUIESCENCE_READY`.**

Chain evidence alone remains fail-closed (PME_V1 paused + V1_ENGINE.liquidationPaused + backend broadcast disabled). The DB predicates now use durable structural fixture exclusion — see the runbook-fix milestone doc for the fixture-identity proof.

## M. `V1_QUIESCENCE_BLOCK`

Candidate `V1_QUIESCENCE_BLOCK = 47_354_399` (block containing tx `0x069c3c…607486`, i.e. C1.2 confirmation). Any V1-mutation-relevant transaction after this block would necessarily have reverted on-chain due to the pauses recorded here.

Do NOT yet declare `SNAPSHOT_BLOCK`. Per §N of the cutover preflight runbook, `SNAPSHOT_BLOCK = V1_QUIESCENCE_BLOCK + 12` (Base Sepolia reorg buffer) and must be verified via two independent `blockHash` reads ≥ 30 s apart. That is next-milestone work.

## N. FREEZE_POSTSTATE_ONLY

Captured at block 47_354_623 (post-C1.2 readback block). Not the canonical migration snapshot — exists only to detect unexpected mutation between C1.2 and the eventual pinned SNAPSHOT_BLOCK.

- `market 1`: longOI=1_001_002, shortOI=1_001_002, cumFR=0, lastFundingTs=1_789_715_546
- `market 2`: all zero
- 6 traders / 6 positions on market 1 (dumped in §J)
- `totalResidualBadDebtBase = 0`
- ENGINE_V2 wiring unchanged since ARM
- Vault authorization state unchanged
- Timelock op state unchanged

## O. Timelock queued / ready / not-executed proof

- `Timelock.queuedTransactions[0xb42e46a9…4fd0]` = **true** ✓
- `Timelock.isOperationReady(VAULT, 0, innerCalldata, 1790475748)` = **true** ✓
- Vault authorization unchanged (see §P) — proves the queued op has NOT been executed

Executable window remains open through **2026-10-11 02:22:28 UTC** (eta + 14 d GRACE_PERIOD). Do NOT execute in this milestone.

## P. Vault authorization proof

- `Vault.isAuthorizedEngine(V1) = true` ✓
- `Vault.isAuthorizedEngine(V2) = false` ✓ (Timelock has not executed the queued flip)

## Q. V2 OPEN / snapshot-zero proof

- `ENGINE_V2.migrationState() = 0` (OPEN) ✓
- `ENGINE_V2.migrationSnapshotHash() = 0x0` ✓

## R. Deployer nonce delta

Before: 770 · After: **772** · Δ = **+2** ✓ (matches exactly C1.1 + C1.2)

## S. Safe nonce unchanged

Before: 14 · After: **14** · Δ = **0** ✓ (no Safe transaction in this milestone)

## T. Public-chain transaction audit

| # | tx | authority | target | fn | expected? |
|---:|---|---|---|---|---|
| 1 | `0xeeb22d64…dbb89c` | deployer EOA | PME_V1 | `pause()` | ✓ authorized |
| 2 | `0x069c3ce2…607486` | deployer EOA | V1_ENGINE | `pauseLiquidation()` | ✓ authorized |

No Timelock write. No Safe write. No Vault write. No executor write. No unexplained transaction.

## U. Remaining blockers (downstream)

- **BLOCKS_SNAPSHOT_PIN**: operator-side quiescence SQL (§I) all-zero result; `SNAPSHOT_BLOCK = V1_QUIESCENCE_BLOCK + 12` + double-read blockHash stability
- **BLOCKS_SEAL**:
  - Manifest at `SNAPSHOT_BLOCK` via `tools/perps_v2_cutover/snapshot_builder.py` + hash via `snapshot_hash.py`
  - Clearing seed via `clearing_sizing.py`, then `mUSDC.approve(CLEARING_V2, AMOUNT)` + `CLEARING_V2.fundClearing(...)`
  - Seed calldata iterator (thin wrapper over the manifest → `adminSeedMarketFunding` / `adminSeedPosition` / `adminSeedResidualBadDebt` calls)
- **BLOCKS_FIRST_V2_TRADE** (post-seal):
  - Runtime executor `0x58Ad…52B8` balance 0.001952 ETH — top up before broadcast
  - Backend V2 activation env update + restart (per tooling-readiness §E)
  - PME_V2 EIP-712 counterparty wallet readiness

## V. Changed docs

- `docs/PERPS_V2_BASE_SEPOLIA_CUTOVER_FREEZE_V1.md` (this file, NEW)

No production Solidity change. No script change. No backend source or config change.

## W. Documentation commit / pushed HEAD

To be created next.

## X. Backend HEAD / active generation

- HEAD `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged)
- Worktree clean
- Active env: `.env.perps_closed_test_prepare_only.local` (fail-closed for real broadcast)
- `PERPS_ACTIVE_ENGINE_VERSION` defaults to `v1` — unchanged

## Deliverable

`PERPS_V2_BASE_SEPOLIA_CUTOVER_FREEZE_V1_COMPLETE` — chain freeze in force; backend broadcast already fail-closed. Timelock op remains queued/ready/not-executed. V1 economic state byte-identical to freeze-preflight snapshot at freeze block. Zero Safe / Timelock / Vault / executor writes in this milestone.

## Exact next milestone

Chain-side verdict is `V1_QUIESCENCE_READY`. DB-side verdict pending operator SQL. Assuming DB predicates pass:

**`PERPS_V2_BASE_SEPOLIA_FINAL_SNAPSHOT_V1`** — pin `SNAPSHOT_BLOCK = V1_QUIESCENCE_BLOCK + 12` (with reorg-buffer + blockHash-stability double-read), build the final canonical manifest via `snapshot_builder.py`, compute `snapshotHash` via `snapshot_hash.py`, and produce the seed-calldata iterator for phase C4.

If any DB predicate fails: **`PERPS_V2_BASE_SEPOLIA_V1_DRAIN_V1`** — allow reconciler + indexer to complete without any writes, re-run §I predicates until all return 0 rows.
