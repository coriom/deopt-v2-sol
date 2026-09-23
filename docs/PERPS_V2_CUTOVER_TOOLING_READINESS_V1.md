# PERPS V2 CUTOVER TOOLING READINESS V1

**Milestone**: `PERPS_V2_CUTOVER_TOOLING_READINESS_V1`
**Status**: **COMPLETE** — snapshot / clearing / first-close tooling proven end-to-end against live Base Sepolia state at a pinned block. Zero Base Sepolia writes performed.
**Sol HEAD (pre)**: `b17c4acaad31890bcde40c34f731f3f3755e0867`
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged, worktree clean)

---

## A. Preflight

- Sol HEAD `b17c4ac`, worktree clean before this milestone
- Backend HEAD `ad8dd7466`, worktree clean
- Python venv at `/tmp/deopt-venv` with `cbor2` + `pycryptodome` installed (avoids PEP 668 system-python constraint)
- RAM at start: 5.3 Gi available / 7.6 Gi total; no parallel Forge/Cargo runs performed
- Zero production Solidity change; `PERPS_ACTIVE_ENGINE_VERSION` in backend remains **v1** (never touched)

## B. Snapshot dry-run

**Pinned block**: `47_188_214` (2026-09-23 06:20 UTC-ish)
**Block hash**: `0x947db882e638a232efcd24612ae6929245f5cbaa64ca79f380f4a9ab6142dd2e`

### Trader universe discovery

**IMPORTANT operational finding**: `cast logs` on Base Sepolia through Alchemy silently returned empty results on every query I attempted. Direct raw JSON-RPC `eth_getLogs` via `curl` returned real data. All snapshot tooling must use raw JSON-RPC (not `cast logs`) for event enumeration.

Full-history raw scan (`eth_getLogs` from V1 deploy block `42_182_810` through pinned block `47_188_214`, all topics on V1 engine):

- V1_ENGINE emitted **27 events** across 15 unique `topic0`s.
- Only **4 events** carry `TradeExecuted` topic0 `0xa73bf9fa75c33ddc672c6fc71d4d4b4e5f85c018c8acc16855e94f564114ed60`.
- All 4 trades executed on `marketId = 1`.
- **6 unique traders** across `buyer` + `seller` topics:
  1. `0x290bd12c93e467bf51c51f5273d35bddb19e9274`
  2. `0x475fe397fa56884952d350aa9ee1c3946964bc0c`
  3. `0x66858286feea78a05ea093673ea1535e0a52002d`
  4. `0x77ca9dd6ccce2d692fb23877a2db7178807b0020`
  5. `0x8b94a83d1ad3bd2337b1886e7962ca8e0bba9a34`
  6. `0xff287410852b9328437eac353720e5476bc5f837`

### Per-position readback at pinned block

| trader | mktId | size1e8 | openNotional1e8 | lastCumFR1e18 |
|---|---:|---:|---:|---:|
| `0x290b…9274` | 1 | +1_000 | +3_000_000 | 0 |
| `0x475f…bc0c` | 1 | −2 | −6_000 | 0 |
| `0x6685…002d` | 1 | −1_000_000 | −2_468_310_000 | 0 |
| `0x77ca…0020` | 1 | −1_000 | −3_000_000 | 0 |
| `0x8b94…9a34` | 1 | +2 | +6_000 | 0 |
| `0xff28…f837` | 1 | +1_000_000 | +2_468_310_000 | 0 |

### OI reconciliation (Σ|size| by side vs `MarketState`)

- **market 1**: `Σ long = 1_001_002 == MarketState.longOI1e8 = 1_001_002` ✓, `Σ short = 1_001_002 == MarketState.shortOI1e8 = 1_001_002` ✓
- **market 2**: `Σ long = 0 == 0` ✓, `Σ short = 0 == 0` ✓
- `totalResidualBadDebtBase()` = 0; per-trader `getResidualBadDebt` = 0 for all 6 traders ✓

### Deterministic snapshot hash

Manifest saved to `/tmp/deopt-deploy-journal/dryrun_manifest.json` (6 positions, 2 markets, 0 bad-debt entries, 6 pmeNonces, 6 vaultBalances).

Canonical CBOR bytes: **1_638**.
**Snapshot hash** = `0xa1fc95af69cddaf834484f57e104e1512bf107d93a6358ca7001c8c21e8aeec3`

Determinism proven: reordering the JSON file's collections (positions/markets/vaultBalances/pmeNonces sorted in reverse) yields **identical CBOR** and **identical snapshot hash**. Any single-field mutation (e.g. `+1` to any `size1e8`) yields a completely different hash (per §Q of the cutover preflight, hash-sensitivity property).

## C. Clearing sizing calculator

Live dry-run (`clearing_sizing.py dryrun_manifest.json market_params_live.json`) with `worstMarkAssumptionUsd1e18 = 10_000 USD/ETH`, `worstPnlSwingBps = 5_000` (50 %):

- 6 positions considered; largest per-position `worst_pnl_native = 50_000_000` (= 50 mUSDC) for the 0.01 ETH positions
- `MINIMUM_REQUIRED_CLEARING` = 100_100_800 native ≈ 100.10 mUSDC (floored by `operationalMinimumNative` when raw calc is smaller; here the raw calc is exactly 100.1 mUSDC = 2×50 mUSDC + 4×0.0001 mUSDC + 6×100 slack)
- `OPERATIONAL_BUFFER` (×9) = 900_907_200 native ≈ 900.91 mUSDC
- **PROPOSED_CLEARING_SEED** = 1_001_008_000 native = **1_001.008 mUSDC**

Even with a very conservative 50 % swing bound (roughly 10× the engine deviation guard hard cap), the seed is under 1 001 mUSDC — trivial for OPS Safe / operator to source.

## D. First-V2-close calculator

Live dry-run (`first_close_calc.py live_trade.json`) on the largest matched pair, using the current oracle mark:

- `mark_price_1e8` at pinned block = `274_721_000_000` (= $2 747.21 / ETH)
- Trade: buyer `0xff28…f837` (long 0.01 ETH @ entry $246.83) closes vs seller `0x6685…002d` (short 0.01 ETH @ entry $246.83), buyerIsMaker = true, FMV2 launch schedule (maker 50 ppm / taker 300 ppm)

| field | native | human |
|---|---:|---|
| notional_native | 27 472 100 | 27.472 100 mUSDC |
| buyer realized PnL | +2 789 000 | +2.789 000 mUSDC (close $27.47 − entry $24.68) |
| buyer funding | 0 | 0 (`cumFundingRate == last`) |
| buyer fee (maker) | 1 373 | 0.001 373 mUSDC (50 ppm × notional) |
| **buyer vault Δ** | **+2 787 627** | **+2.787 627 mUSDC** |
| seller realized PnL | −2 789 000 | −2.789 000 mUSDC |
| seller funding | 0 | 0 |
| seller fee (taker) | 8 241 | 0.008 241 mUSDC (300 ppm × notional) |
| **seller vault Δ** | **−2 797 241** | **−2.797 241 mUSDC** |
| total_fee_native | 9 614 | 0.009 614 mUSDC |
| **clearing vault Δ** | **0** | **0.000 000 mUSDC** (symmetric close after fees route to feeRecipient) |

All five component metrics — realized PnL, funding, fee, per-side vault delta, clearing residual — are output separately so the operator can compare each against the on-chain settlement receipt post-trade.

## E. Backend V2 env / activation checklist (DO NOT ACTIVATE YET)

Backend HEAD `ad8dd7466` is fully V2-capable (see `src/execution/config.rs:398+`, `src/fees/onchain_summary.rs`, `src/fees/perp_consumer.rs`). Activation is a config change + restart. The following goes into `.env.base-sepolia` **only at CUTOVER phase C6**:

```
PERPS_ACTIVE_ENGINE_VERSION=v2                                                  # flip only at C6
PERP_ENGINE_V2_ADDRESS=0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9
PERP_MATCHING_ENGINE_V2_ADDRESS=0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2
PERP_RISK_MODULE_V2_ADDRESS=0x8C3d9F71cA59B908Fa200546A63ea62F9C932998
PERP_CLEARING_ACCOUNT_V2_ADDRESS=0x54d49c088DD27cFc82685b867c182b4bB4aC435c
FEES_MANAGER_V2_ADDRESS=0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f              # unchanged
PERP_ENGINE_SEIZURE_LIB_ADDRESS=0xf0C5652277CF88B508E05F7aB54949fCDF0360A5
PERP_ENGINE_LIQUIDATION_LIB_ADDRESS=0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D
```

**Backend v2 startup preflight (all must be READ TRUE before starting up in v2 mode)**:

1. `chainId == 84532`
2. `ENGINE_V2.migrationState() == 1` (SEALED)
3. `ENGINE_V2.migrationSnapshotHash() == <locally computed snapshotHash>`
4. `PME_V2.perpEngine() == ENGINE_V2`
5. `ENGINE_V2.riskModule() == RISK_V2`
6. `ENGINE_V2.clearingAccount() == CLEARING_V2`
7. `Vault.isAuthorizedEngine(ENGINE_V2) == true`
8. `ENGINE_V2.feesManagerV2() == FMV2` && `ENGINE_V2.useFeesManagerV2() == true` && `FMV2.isFeeConsumer(ENGINE_V2) == true`
9. `PME_V2.isExecutor(runtimeExecutor) == true`
10. `PME_V2.paused() == false`, `ENGINE_V2.tradingPaused() == false`
11. `Vault.balances(CLEARING_V2, mUSDC) >= MINIMUM_REQUIRED_CLEARING` (from §C)
12. Runtime executor ETH balance sufficient for a first send (top-up if < 0.01 ETH)

**Rollback stance**: if v2 startup preflight fails, the backend refuses to start (no silent v1 downgrade). Recovery = fix v2 state (or roll `.env.base-sepolia` back to v1 addresses) + restart. `PERPS_ACTIVE_ENGINE_VERSION` is the only authoritative switch — no runtime override.

Current state (unchanged during this milestone): `PERPS_ACTIVE_ENGINE_VERSION` remains v1.

## F. Full ordered cutover checklist (with STOP conditions)

Each numbered step below has explicit ABORT criteria. Default behavior at any abort: **halt on frozen V1 state; do not seal**.

```
=========================================================
CUTOVER SEQUENCE (post-ARM)
=========================================================

PHASE C1 — FREEZE
─────────────────
[ ] F.1  OWNER EOA → PME_V1.pause()  (sel 0x8456cb59)
         READBACK: PME_V1.paused() == true
         STOP if:  tx status != 1, or readback false, or unexpected event

[ ] F.2  OWNER EOA → V1_ENGINE.pauseLiquidation()  (sel 0x1d966e81)
         READBACK: V1_ENGINE.liquidationPaused() == true
         STOP if:  same

[ ] F.3  Backend operator: stop V1 broadcast worker (config disable, no chain write)
         READBACK: no new broadcasts arm within 60 s
         STOP if:  new V1 broadcasts arm after disable

PHASE C2 — DRAIN + SNAPSHOT
────────────────────────────
[ ] D.1  Wait for reconciler + indexer to catch up
         READBACK: quiescence SQL (§M of preflight) all return 0 rows
         STOP if:  any Prepared/Submitted V1 broadcast persists > 15 min

[ ] D.2  Pin V1_FINAL_BLOCK = MAX(last reconciled block, last indexer block)
         Wait ≥ 12 additional blocks (Base Sepolia reorg buffer)

[ ] D.3  Pin SNAPSHOT_BLOCK = V1_FINAL_BLOCK + 12
         Read blockHash twice, ≥ 30 s apart, via two independent RPCs
         STOP if:  blockHash differs between reads

[ ] D.4  Discover trader universe:
         (a) raw eth_getLogs (TradeExecuted topic0) across [V1_deploy .. SNAPSHOT_BLOCK]
         (b) backend `indexed_perp_trades DISTINCT trader WHERE protocol_version='perp_v1' AND block <= SNAPSHOT_BLOCK`
         Union the two sets.
         Cross-check per-market Σ|size| == market.longOI/shortOI at SNAPSHOT_BLOCK.
         STOP if:  reconciliation fails

[ ] D.5  Build manifest via `snapshot_builder.py --block SNAPSHOT_BLOCK ...`
         Compute snapshotHash via `snapshot_hash.py manifest.json`
         Rebuild + rehash from a scrubbed copy (independent verifier) — hashes must equal
         STOP if:  independent generators disagree

PHASE C3 — FUND CLEARING
─────────────────────────
[ ] C.1  Run `clearing_sizing.py manifest.json market_params.json` with SNAPSHOT_BLOCK-time
         mark price ceilings; take the emitted PROPOSED_CLEARING_SEED as target
[ ] C.2  funder → mUSDC.approve(CLEARING_V2, AMOUNT)
[ ] C.3  funder → CLEARING_V2.fundClearing(mUSDC, AMOUNT)
         READBACK: Vault.balances(CLEARING_V2, mUSDC) >= MINIMUM_REQUIRED_CLEARING
         STOP if:  post-fund balance < minimum, or fee-on-transfer swallowed part of amount

PHASE C4 — SEED + SEAL
───────────────────────
[ ] S.1  For each market (ascending marketId):
             OWNER EOA → ENGINE_V2.adminSeedMarketFunding(marketId, cum, ts)   (sel 0x2c96f1bc)
         READBACK: marketState(mid) matches manifest exactly
         STOP if:  any mismatch or MigrationMarketFundingAlreadySeeded revert

[ ] S.2  For each position (canonical (trader, marketId) ascending):
             OWNER EOA → ENGINE_V2.adminSeedPosition(...)   (sel 0x0ef3a5f7)
         READBACK: positions(trader, marketId) matches manifest exactly
         STOP if:  any mismatch or MigrationPositionAlreadySeeded

[ ] S.3  For each residualBadDebt entry (ascending trader):
             OWNER EOA → ENGINE_V2.adminSeedResidualBadDebt(trader, amount)   (sel 0x6067ee86)
         READBACK: getResidualBadDebt(trader) matches manifest
         STOP if:  mismatch

[ ] S.4  Full-manifest equality check (all markets + positions + bad-debt values reread on V2)
         STOP if:  any drift vs manifest
         STOP if:  V1 state has drifted since SNAPSHOT_BLOCK for any migrated field
         STOP if:  CLEARING_V2 vault balance < MINIMUM_REQUIRED_CLEARING

[ ] S.5  OWNER EOA → ENGINE_V2.sealMigration(snapshotHash)   (sel 0x05d5af5b)
         READBACK: migrationState() == 1 (SEALED),
                   migrationSnapshotHash() == locally computed snapshotHash
         STOP if:  status != 1 or readback mismatch

         ─── FROM THIS POINT, MIGRATION IS IRREVERSIBLE ───

PHASE C5 — VAULT AUTHORIZATION (Timelock execute)
──────────────────────────────────────────────────
[ ] V.1  Wait until block.timestamp >= ETA (from ARM phase C0-03)
         READBACK: Timelock.isOperationReady(VAULT, 0, innerCalldata, ETA) == true
         STOP if:  isOperationReady returns false, or eta expired (past eta+14d)

[ ] V.2  OPS Safe (2/3) → Timelock.executeTransaction(VAULT, 0, innerCalldata, ETA)
                                                                (sel 0x06a41d09)
         READBACK: Vault.isAuthorizedEngine(ENGINE_V2) == true,
                   Vault.isAuthorizedEngine(V1_ENGINE) == true (untouched)
         STOP if:  Safe execution reverts, or Vault flip does not take effect

PHASE C6 — BACKEND V2 ACTIVATE
───────────────────────────────
[ ] B.1  Update .env.base-sepolia (all keys per §E)
[ ] B.2  Restart backend
         READBACK: 12-item startup preflight (§E) all green
         STOP if:  any preflight red — do NOT downgrade to v1 (V1 PME paused)

PHASE C7 — FIRST V2 CLOSE
──────────────────────────
[ ] X.1  Run `first_close_calc.py trade.json` with actual snapshot basis + current
         oracle mark; capture expected buyer/seller/clearing vault deltas + fees + funding
[ ] X.2  Traders EIP-712 sign the V2 mutual-close intent
[ ] X.3  Backend arms + broadcasts via runtime executor → PME_V2.executeTrade
         READBACK: receipt.status == 1
                   on-chain buyer vault Δ == expected (±0)
                   on-chain seller vault Δ == expected (±0)
                   on-chain clearing vault Δ == expected (±dust for rounding)
                   FeeChargedV2 event emitted with expected amount
         STOP if:  any delta divergence, or missing FeeChargedV2 event
```

## G. Remaining blockers

- **BLOCKS_ARM**: none (already advanced through C0-01 + C0-02; awaiting C0-03 Safe execution)
- **BLOCKS_FREEZE**: none — all levers EOA-callable
- **BLOCKS_SEAL** (pre-C4.5):
  - Backend PG access must be reachable at cutover time for the DB half of the trader-universe discovery in D.4 (raw eth_getLogs half is proven working here)
  - Runbook seed calldata generator must be extended to iterate the manifest (small script to emit `cast send` command list)
- **BLOCKS_FIRST_V2_TRADE** (post-seal):
  - Runtime executor `0x58Ad…52B8` balance was 0.00195 ETH at PRE-STAGE; needs top-up before X.3 if not already funded
  - PME_V2 EIP-712 signing needs the two counterparty test wallets ready

## H. Base Sepolia state (unchanged during this milestone)

| item | value | expected |
|---|---|---|
| chainId | 84532 | 84532 |
| deployer nonce | 770 | 770 (== 768 + 2 from C0-01+C0-02 executed earlier this session) |
| Safe nonce | 10 | 10 (unchanged, no Safe tx broadcast) |
| Vault.isAuthorizedEngine(V1) | true | true |
| Vault.isAuthorizedEngine(V2) | false | false |
| ENGINE_V2.migrationState | 0 (OPEN) | OPEN |
| ENGINE_V2.migrationSnapshotHash | 0x0 | 0x0 |
| Timelock.queuePaused | false | false |
| Backend HEAD | `ad8dd7466` | unchanged |
| Backend `PERPS_ACTIVE_ENGINE_VERSION` | v1 | v1 (never touched) |

## I. Changed docs / scripts

- `docs/PERPS_V2_CUTOVER_TOOLING_READINESS_V1.md` (this file, NEW)
- `tools/perps_v2_cutover/snapshot_builder.py` (NEW — read state at pinned block → manifest JSON)
- `tools/perps_v2_cutover/clearing_sizing.py` (NEW — manifest + params → seed sizing)
- `tools/perps_v2_cutover/first_close_calc.py` (NEW — manifest position + exec price → per-component deltas)
- `tools/perps_v2_cutover/snapshot_hash.py` was already committed in the preflight milestone; unchanged here

No production Solidity change.

## J. Next milestone

Depends on ARM phase completion:
- If C0-03 (OPS Safe → Timelock queue) still pending → resume `PERPS_V2_BASE_SEPOLIA_CUTOVER_ARM_V1` when a fresh Safe payload with sufficient ETA buffer (recommend +48 h from build time) is signable
- Once Timelock op is queued AND matures (T + 24 h from queue) → `PERPS_V2_BASE_SEPOLIA_CUTOVER_EXECUTION_PREFLIGHT_V1` (final gate before FREEZE)

**Deliverable**: `PERPS_V2_CUTOVER_TOOLING_READINESS_V1_COMPLETE`.
