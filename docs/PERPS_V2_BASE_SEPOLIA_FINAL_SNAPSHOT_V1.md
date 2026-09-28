# PERPS V2 BASE SEPOLIA FINAL SNAPSHOT V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_FINAL_SNAPSHOT_V1`
**Status**: **COMPLETE — READ-ONLY canonical migration package**
**Sol HEAD (pre)**: `aa70217` (unchanged during milestone)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Production Solidity bytecode**: frozen at `004bf78c32b2b5210cd7daabef2685cd461aeec7`
**Chain**: Base Sepolia (chainId 84532) — **no chain writes performed; no DB writes; no Safe/Timelock action**

Scope: pin `SNAPSHOT_BLOCK = 47_354_411`, reconstruct the canonical trader universe from raw eth_getLogs bound to that block, build + hash the canonical migration manifest via committed tooling (`snapshot_builder.py` + `snapshot_hash.py`), reconcile against the on-chain economic invariants, generate the seed-calldata iterator, size the clearing seed, compute first-close economics, verify executor ETH, and document the write-ahead migration plan. Every read at `blockTag = 47_354_411` (historical) with a parallel latest-vs-snapshot drift check.

---

## A. SNAPSHOT_BLOCK

`SNAPSHOT_BLOCK = 47_354_411` (= `V1_QUIESCENCE_BLOCK 47_354_399 + 12`-block reorg buffer, per committed rule; not substituted with a newer latest block).

## B. SNAPSHOT_BLOCK_HASH

```
0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89
```

## C. Block metadata

- **number**: `47_354_411`
- **hash**: `0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89`
- **parentHash**: `0xedde399ac1b4d5e737a7fdaa85b47fd2cb64b749d52d0d07ccf8626756e26077`
- **timestamp**: `1_790_477_110` (2026-09-27 02:45:10 UTC)
- **gasUsed**: `5_604_084`

## D. Block-hash stability proof

Two independent `eth_getBlockByNumber(0x2d17d2b, false)` reads separated by 15 s:

```
READ #1  hash = 0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89
READ #2  hash = 0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89   ← identical
current head = 47_396_560  (42_149 blocks past SNAPSHOT_BLOCK)
```

Depth of 42_149 blocks past SNAPSHOT_BLOCK is orders of magnitude larger than the committed 12-block reorg buffer. Finality certain.

## E. Exact trader universe (6)

Independent reconstruction bound to `SNAPSHOT_BLOCK`:

- prior artifact (`PERPS_V2_BASE_SEPOLIA_QUIESCENCE_RAW_LOG_FINALIZATION_V1`) covers `[42_182_810, 47_354_399]` and yields exactly 4 `V1_ENGINE.TradeExecuted` events.
- fresh boundary scan `[47_354_400, 47_354_411]` yields exactly 0 additional events (PME_V1 paused + V1_ENGINE.liquidationPaused since block 47_354_373 / 47_354_399).
- union = 4 events, 6 traders.

```
0x290bd12c93e467bf51c51f5273d35bddb19e9274
0x475fe397fa56884952d350aa9ee1c3946964bc0c
0x66858286feea78a05ea093673ea1535e0a52002d
0x77ca9dd6ccce2d692fb23877a2db7178807b0020
0x8b94a83d1ad3bd2337b1886e7962ca8e0bba9a34
0xff287410852b9328437eac353720e5476bc5f837
```

Set equality with expected canonical universe: **PROVEN**.

## F. Market states at `SNAPSHOT_BLOCK`

Read via `V1_ENGINE.marketState(uint256)((uint256,uint256,int256,uint64))` with `--block 47354411`:

```
market 1 : longOI = 1_001_002    shortOI = 1_001_002
           cumulativeFundingRate1e18 = 0
           lastFundingTimestamp = 1_789_715_546
market 2 : longOI = 0            shortOI = 0
           cumulativeFundingRate1e18 = 0
           lastFundingTimestamp = 0
```

## G. Per-trader migration state at `SNAPSHOT_BLOCK`

Read via `V1_ENGINE.positions(address,uint256)((int256,int256,int256))` (`size1e8`, `openNotional1e8`, `lastCumulativeFundingRate1e18`) with `--block 47354411`:

```
trader                                       size1e8       openNotional1e8   lastCumFundingRate1e18
0x290bd12c93e467bf51c51f5273d35bddb19e9274   +1_000        +3_000_000         0
0x475fe397fa56884952d350aa9ee1c3946964bc0c   −2            −6_000             0
0x66858286feea78a05ea093673ea1535e0a52002d   −1_000_000    −2_468_310_000     0
0x77ca9dd6ccce2d692fb23877a2db7178807b0020   −1_000        −3_000_000         0
0x8b94a83d1ad3bd2337b1886e7962ca8e0bba9a34  +2            +6_000              0
0xff287410852b9328437eac353720e5476bc5f837   +1_000_000    +2_468_310_000     0
```

Per-trader entry basis is deterministic from the raw event stream:
- E1/E2 (avg $300 mark = 300_000_000_000 in 1e8): 0x8b94 buyer (+1 twice), 0x475f seller (−1 twice) → 0x8b94 openNotional = 6000 = 2 × 300_000_000_000/1e8; 0x475f = −6000.
- E3 (avg $300 mark, size 1000): 0x290b buyer, 0x77ca seller → openNotional = ±3_000_000 = 1000 × 300_000_000_000/1e8.
- E4 (avg $2468.31 mark, size 1_000_000): 0xff28 buyer, 0x6685 seller → openNotional = ±2_468_310_000 = 1_000_000 × 246_831_000_000/1e8.

All `lastCumulativeFundingRate1e18` are `0` because `V1_ENGINE.marketState.cumulativeFundingRate1e18` was `0` at every event (funding never accrued on V1 during its lifetime).

## H. Funding / accounting state at `SNAPSHOT_BLOCK`

- Market 1: `cumulativeFundingRate1e18 = 0`, `lastFundingTimestamp = 1_789_715_546` (set at E4 block, matches).
- Market 2: `cumulativeFundingRate1e18 = 0`, `lastFundingTimestamp = 0` (never funded).
- Every trader's `lastCumulativeFundingRate1e18 = 0`, matching per-trader checkpoint = market baseline. Accrued-but-unrealized funding = `Σ position_size × (market.cum − position.checkpoint) = 0` on both markets.

## I. Residual bad debt at `SNAPSHOT_BLOCK`

- `V1_ENGINE.totalResidualBadDebtBase() = 0`
- Per-trader `getResidualBadDebt(t) = 0` for every trader in the universe (verified in `PERPS_V2_BASE_SEPOLIA_CUTOVER_FREEZE_V1`).
- Manifest `residualBadDebt = []`.

## J. Canonical manifest location

- **JSON**: `artifacts/perps_v2_final_snapshot/manifest.json` (3399 bytes)
- **CBOR (canonical)**: `artifacts/perps_v2_final_snapshot/manifest.cbor` (1638 bytes)

Manifest schema: `schemaVersion=1` per `docs/PERPS_V2_BASE_SEPOLIA_CUTOVER_PREFLIGHT_V1.md §P`. Fields:

```
schemaVersion, chainId, engineV1, pmeV1, snapshotBlockNumber, snapshotBlockHash,
markets[], positions[], residualBadDebt[], pmeNonces[], vaultBalances[]
```

Deterministic ordering rules (per `snapshot_hash.py`):
- `positions` sorted by `(trader, marketId)` ascending
- `markets` sorted by `marketId` ascending
- `residualBadDebt` / `pmeNonces` sorted by `trader` ascending
- `vaultBalances` sorted by `(user, token)` ascending
- addresses lowercased + hex-decoded to 20 raw bytes
- `snapshotBlockHash` hex-decoded to 32 raw bytes
- integers big-endian minimal-length (RFC 8949 §4.2 core deterministic encoding)

## K. Canonical byte length

`canonical_cbor_bytes = 1638`

## L. FINAL `snapshotHash`

```
0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d
```

## M. Independent hash verification

Two independent code paths compute the CBOR + keccak256:

- **Pass A** — committed tool `tools/perps_v2_cutover/snapshot_hash.py` (imports `cbor2`, `pycryptodome`).
- **Pass B** — inline reimplementation using the same libraries but a fresh Python subprocess and independently coded canonicalization.

Both emit byte-identical CBOR (1638 bytes each) and identical keccak256 digest:

```
Pass A snapshot_hash = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d
Pass B snapshot_hash = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d
```

Independent hash verification: **PROVEN**. `ENGINE_V2.migrationSnapshotHash` remains `0x0` on-chain (NOT called).

## N. Seed calldata count

`totalSteps = 8` (2 × `adminSeedMarketFunding` + 6 × `adminSeedPosition` + 0 × `adminSeedResidualBadDebt`). `sealMigration` is intentionally NOT in the seed iterator (separate C4.5 phase).

## O. Seed calldata summary

Ordered iterator at `artifacts/perps_v2_final_snapshot/seed_calldata.json`. Every step targets `ENGINE_V2 = 0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9` under `OWNER` authority (`onlyOwner`) with `onlyMigrationOpen` precondition. Selectors derived from the frozen ABI:

```
adminSeedMarketFunding(uint256,int256,uint64)          selector 0x2c96f1bc
adminSeedPosition(address,uint256,int256,int256,int256) selector 0x0ef3a5f7
adminSeedResidualBadDebt(address,uint256)              selector 0x6067ee86
sealMigration(bytes32)                                 selector 0x05d5af5b   (C4.5 — separate phase)
```

Ordinals:

```
#1  adminSeedMarketFunding(1, 0, 1_789_715_546)                                    calldata 0x2c96f1bc0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006aace45a
#2  adminSeedMarketFunding(2, 0, 0)                                                calldata 0x2c96f1bc000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
#3  adminSeedPosition(0x290b…9274, 1, +1_000, +3_000_000, 0)                        calldata (see artifacts/…/seed_calldata.json ordinal 3)
#4  adminSeedPosition(0x475f…bc0c, 1, −2, −6_000, 0)                                (ordinal 4)
#5  adminSeedPosition(0x6685…002d, 1, −1_000_000, −2_468_310_000, 0)                (ordinal 5)
#6  adminSeedPosition(0x77ca…0020, 1, −1_000, −3_000_000, 0)                        (ordinal 6)
#7  adminSeedPosition(0x8b94…9a34, 1, +2, +6_000, 0)                                (ordinal 7)
#8  adminSeedPosition(0xff28…f837, 1, +1_000_000, +2_468_310_000, 0)                (ordinal 8)
```

**Iterator completeness proof (assertion in generator)**: `manifest.positions == package.positionSteps.args (trader,marketId)`; `manifest.markets == package.marketFundingSteps.args.marketId`; `manifest.residualBadDebt == package.residualBadDebtSteps.args.trader`. Assertion passes.

**Explicitly NOT seeded**:

- `pmeNonces` — belong to `PerpMatchingEngineV2` (independent nonce space; V2 starts fresh).
- `vaultBalances` — the `CollateralVault` is shared between V1 and V2 (single storage; no per-engine migration required). Vault authorization flip happens later via the queued Timelock op.

**OI double-seeding safety**: `adminSeedPosition` internally calls `_updateMarketOpenInterest` (line 253 of `PerpEngineTradingV2.sol`), which increments `_marketStates.long/shortOpenInterest1e8` deterministically. `adminSeedMarketFunding` only sets `cumulativeFundingRate1e18` and `lastFundingTimestamp`; it does NOT touch OI. Therefore OI is seeded once, from positions. At seal, `market OI == Σ |size| by side` holds by construction.

## P. Clearing minimum

`MINIMUM_REQUIRED_CLEARING = 100_000_000 native mUSDC = 100.000000 mUSDC`.

Derivation (via `clearing_sizing.py`):

```
per-position worst-PnL (@ mark $5000/ETH, worst_swing_bps=2000 = 20%):
  0x290b size 1_000       worst_pnl_native =  10_000    ($0.010)
  0x475f size 2           worst_pnl_native =  20        ($0.000_020)
  0x6685 size 1_000_000   worst_pnl_native = 10_000_000 ($10.000)
  0x77ca size 1_000       worst_pnl_native =  10_000    ($0.010)
  0x8b94 size 2           worst_pnl_native =  20        ($0.000_020)
  0xff28 size 1_000_000   worst_pnl_native = 10_000_000 ($10.000)
Σ                                        = 20_020_040  ($20.020)
+ slack 6 × 100                          =    600
sum_worst_pnl                            = 20_020_640  ($20.021)
operational_minimum                      = 100_000_000 ($100.000)
MINIMUM_REQUIRED_CLEARING                = max(sum, op_min) = 100_000_000 ($100.000)
```

## Q. Clearing proposed seed

`PROPOSED_CLEARING_SEED = 1_000_000_000 native mUSDC = 1000.000000 mUSDC`.

Derivation: `MINIMUM + 9 × MINIMUM = 10 × MINIMUM = 1000 mUSDC`. (Buffer multiplier = 9 from `market_params.json`.)

Parameters file: `artifacts/perps_v2_final_snapshot/market_params.json` (worst mark $5000/ETH, $200_000/BTC; 20% worst swing; op_min 100 mUSDC).

## R. Current clearing balance

`CLEARING_V2 = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c`

```
Vault.balances(CLEARING_V2, mUSDC) @ SNAPSHOT_BLOCK (47_354_411)   = 0
Vault.balances(CLEARING_V2, mUSDC) @ latest        (47_396_781)    = 0
```

## S. Required funding delta

```
additional_funding_required = max(0, PROPOSED_CLEARING_SEED − current_balance)
                            = max(0, 1_000_000_000 − 0)
                            = 1_000_000_000 native mUSDC
                            = 1000.000000 mUSDC
```

This funding transfer is deferred to `PERPS_V2_BASE_SEPOLIA_CLEARING_FUND_V1` (next milestone). No transfer executed in this milestone.

## T. First-close expected economics

Baseline flat close (`artifacts/perps_v2_final_snapshot/first_close.json`) — matched pair `0xff28…f837` (long, maker) vs `0x66858286…002d` (short, taker), closing full size 1_000_000 (= 0.01 ETH) at execution price `246_831_000_000` (= entry price, zero PnL baseline):

```
notional_native                     = 24_683_100   ($24.683100)

BUYER (long)  0xff287410…f837  maker=true
  realized_pnl_1e8              = 0
  realized_pnl_native           = 0
  funding_1e8                   = 0
  funding_native                = 0
  fee_native                    = 1_234       ($0.001234 = notional × 50 ppm)
  vault_delta_native            = −1_234

SELLER (short)  0x66858286…002d  maker=false
  realized_pnl_1e8              = 0
  realized_pnl_native           = 0
  funding_1e8                   = 0
  funding_native                = 0
  fee_native                    = 7_404       ($0.007404 = notional × 300 ppm)
  vault_delta_native            = −7_404

total_fee_native                    = 8_638      ($0.008638; flows to FeesManagerV2.feeRecipient)
clearing_vault_delta_native         = 0          (symmetric close, matched openNotional; residual = 0)
```

This is calculation only; **no trade submitted**. Fee schedule (50 ppm maker / 300 ppm taker) matches `FeesManagerV2` current configuration (already set via A14 in `PERPS_V2_BASE_SEPOLIA_DEPLOY_V2_ONLY_V1`). Non-flat first-close variants (mark drift, funding shift) can be recomputed via `first_close_calc.py` against the same manifest.

## U. Executor ETH readiness

Current balances at block `47_396_756` (gas price 6 mwei):

```
RUNTIME_EXECUTOR (0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8) = 0.001952 ETH
OWNER (deployer, 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27)  = 0.001787 ETH
```

Gas budget at current price:

```
seed phase (9 owner-EOA txes @ ~120k gas)     = 1_080_000 gas = 6.48e12 wei ≈ 0.0000065 ETH
first V2 close (executor, ~300k gas)           =   300_000 gas = 1.80e12 wei ≈ 0.0000018 ETH
```

Both EOAs have >100× the immediate gas budget. **Operational recommendation**: top both up to `>= 0.005 ETH` before the seed/close phases to absorb gas-price spikes (Base Sepolia occasionally hits 1+ gwei during traffic bursts). This is NOT done in this milestone.

Minimum operational target: **`OWNER >= 0.005 ETH`**, **`EXECUTOR >= 0.005 ETH`**.

## V. Latest-vs-snapshot drift proof

Every economic value read at `--block 47354411` compared against a fresh read at `latest (47_396_781)`:

```
marketState(1)      snap = (1_001_002, 1_001_002, 0, 1_789_715_546)   latest = same   ✓
marketState(2)      snap = (0, 0, 0, 0)                                latest = same   ✓
totalResidualBadDebtBase snap = 0                                       latest = 0     ✓

per-trader (size1e8 / PME nonce):
  0x290b…9274   size1e8: snap=+1000       latest=+1000       nonce: snap=1 latest=1  ✓
  0x475f…bc0c   size1e8: snap=−2          latest=−2          nonce: snap=2 latest=2  ✓
  0x6685…002d   size1e8: snap=−1_000_000  latest=−1_000_000  nonce: snap=1 latest=1  ✓
  0x77ca…0020   size1e8: snap=−1_000      latest=−1_000      nonce: snap=1 latest=1  ✓
  0x8b94…9a34   size1e8: snap=+2          latest=+2          nonce: snap=2 latest=2  ✓
  0xff28…f837   size1e8: snap=+1_000_000  latest=+1_000_000  nonce: snap=1 latest=1  ✓

*** NO DRIFT — snapshot economic state == latest ***
```

Chain freeze re-verified at latest:

```
PME_V1.paused                    = true
V1_ENGINE.liquidationPaused      = true
Vault.isAuthorizedEngine(V1)     = true
Vault.isAuthorizedEngine(V2)     = false
ENGINE_V2.migrationState         = 0 (OPEN)
ENGINE_V2.migrationSnapshotHash  = 0x0
Timelock queuedTransactions(op)  = true (queued+ready+unexecuted; 13.01 days until GRACE_PERIOD expiry)
```

## W. Chain / DB write audit

```
Base Sepolia writes             = 0
Safe writes                     = 0
Timelock executions             = 0
Deployer nonce delta            = 0
Executor nonce delta            = 0
Safe nonce delta                = 0
DB writes                       = 0
Backend state changes           = 0
Backend HEAD                    = ad8dd7466 (unchanged)
Backend worktree                = clean (unchanged)
```

## X. Changed files

Sol repo:

- `docs/PERPS_V2_BASE_SEPOLIA_FINAL_SNAPSHOT_V1.md` — NEW (this file).
- `artifacts/perps_v2_final_snapshot/manifest.json` — NEW (canonical migration manifest, 3399 B).
- `artifacts/perps_v2_final_snapshot/manifest.cbor` — NEW (deterministic canonical bytes, 1638 B).
- `artifacts/perps_v2_final_snapshot/market_params.json` — NEW (clearing-sizing parameters).
- `artifacts/perps_v2_final_snapshot/seed_calldata.json` — NEW (ordered seed-calldata iterator, 9723 B).
- `artifacts/perps_v2_final_snapshot/clearing_sizing_report.txt` — NEW (recomputed sizing).
- `artifacts/perps_v2_final_snapshot/first_close.json` — NEW (first-close scenario input).
- `artifacts/perps_v2_final_snapshot/first_close_report.txt` — NEW (first-close economics).

Backend repo:

- (none)

No production Solidity modification.

## Y. Commit + push

Pushed on top of `aa70217` as a new docs+artifacts commit.

## Z. Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_CLEARING_FUND_V1`**

Scope of the next milestone (do NOT execute here):

- Signer transfers `1000.000000 mUSDC` (`1_000_000_000` native) from a funded EOA to `CLEARING_V2` via `mUSDC.approve(CLEARING_V2, 1_000_000_000)` + `CLEARING_V2.fundClearing(mUSDC, 1_000_000_000)`.
- Readback: `Vault.balances(CLEARING_V2, mUSDC) >= 1_000_000_000` (== `MINIMUM_REQUIRED_CLEARING`).
- Fail-closed on: post-fund balance < minimum; fee-on-transfer skims part of the amount; funding txes exceed operator authority.

**Do NOT execute automatically.**

## Write-ahead migration plan (for reference)

```
C3   fund CLEARING_V2 with 1000.000000 mUSDC                       PERPS_V2_BASE_SEPOLIA_CLEARING_FUND_V1
C4   execute 8-step seed iterator (adminSeedMarketFunding × 2 +
     adminSeedPosition × 6) from OWNER EOA                          PERPS_V2_BASE_SEPOLIA_MIGRATION_SEED_V1
C4v  reconcile V2 seeded state against manifest byte-for-byte      (verification step of C4)
C4.5 sealMigration(0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d)
     from OWNER EOA (asserts migrationState==OPEN → SEALED)         PERPS_V2_BASE_SEPOLIA_MIGRATION_SEAL_V1
C5   execute already-queued Timelock op 0xb42e46a90289…4fd0
     (Vault.setAuthorizedEngine(ENGINE_V2, true))                    PERPS_V2_BASE_SEPOLIA_VAULT_AUTH_V1
     readback: Vault.isAuthorizedEngine(V2) == true
C6   backend V2 activation (flip PERPS_ACTIVE_ENGINE_VERSION=v2)     PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ACTIVATE_V1
C7   first controlled V2 close/trade (flat baseline; verify economics
     match §T byte-for-byte)                                         PERPS_V2_BASE_SEPOLIA_FIRST_V2_CLOSE_V1
```

Each phase is a discrete milestone with its own preflight, gate, and readback. Do NOT collapse into this snapshot milestone.

## STOP

Snapshot pinned. Manifest built. Hash generated + independently verified. Seed iterator produced. Clearing sized. First-close computed. Executor ETH assessed. Drift check clean. Timelock op still armed.

**No chain writes. No DB writes. No sealMigration. No fundClearing. No backend activation. No V2 trade.** Control returned to operator.
