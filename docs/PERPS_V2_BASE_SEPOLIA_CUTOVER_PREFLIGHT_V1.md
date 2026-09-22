# PERPS V2 BASE SEPOLIA CUTOVER PREFLIGHT V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_CUTOVER_PREFLIGHT_V1`
**Status**: **READY** to execute `PERPS_V2_BASE_SEPOLIA_CUTOVER_ARM_V1` next
**Sol HEAD**: `1f75e59634383ab0a3e1913e1ae290ba61ebdd1a` (production bytecode unchanged from `004bf78`)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged)
**Chain**: Base Sepolia (chainId 84532)

**Zero Base Sepolia writes performed in this milestone.**

---

## A. PRE-STAGE state revalidation (all green)

| Item | Actual | Expected |
|---|---|---|
| ENGINE_V2 runtime | 24_321 B | 24_321 |
| SEIZE / LIQ / PME_V2 / RISK_V2 / CLEARING_V2 sizes | 3_628 / 6_148 / 10_441 / 9_894 / 1_159 | match |
| ENGINE_V2 wiring (matching / risk / clearing / FMV2 / insurance / seizer / guardian) | all correct | all correct |
| ENGINE_V2.useFeesManagerV2 | true | true |
| FMV2.isFeeConsumer(ENGINE_V2) | true | true |
| ENGINE_V2.migrationState | 0 (OPEN) | OPEN |
| ENGINE_V2.migrationSnapshotHash | 0x0 | 0x0 |
| Vault.isAuthorizedEngine(V1) | true | true |
| Vault.isAuthorizedEngine(V2) | false | false |
| Deployer nonce | 768 | 768 (unchanged from PRE-STAGE) |
| V1 engine flags / owner / matchingEngine / riskModule / useFeesManagerV2 | unchanged | unchanged |
| Backend HEAD / worktree | clean, `ad8dd7466` | clean |

## B. ProtocolTimelock — minDelay proof

Deployed at `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588`, runtime **4_228 B**.

**Bytecode identity**: source `src/gouvernance/ProtocolTimelock.sol` (Sol HEAD `1f75e59`) compiled artifact `deployedBytecode` matches on-chain byte-for-byte (**100.0 % over 4_228 B**). ABI is fully trusted.

Live values:
- `minDelay()` → **`86_400` (24 h)**
- `GRACE_PERIOD()` → `1_209_600` (14 d)
- `MIN_DELAY_FLOOR()` → `3_600` (1 h)
- `MAX_DELAY_CEILING()` → `2_592_000` (30 d)
- `queuePaused()` → `false`
- `owner()` → `0xA6B9Bb5c…` (OPS Safe)
- `guardian()` → `0xA6B9Bb5c…` (OPS Safe — same as owner)

The prior `getMinDelay()` revert was ABI-name mismatch (source uses `public minDelay`, not the OZ `getMinDelay()`); resolved.

## C. Timelock role / expiry / cancel semantics

- **Proposer** = queues; live: `proposers[OPS_SAFE] = true`, `proposers[OWNER_EOA] = false`.
- **Executor** = executes at eta; live: `executors[OPS_SAFE] = true`, `executors[OWNER_EOA] = false`.
- **Guardian OR Owner** can `cancelTransaction` and `pauseQueueing` (both = OPS Safe here).
- **Duplicate operation** = same `(target, value, data, eta)` → `TransactionAlreadyQueued` revert. Uniqueness therefore comes from `eta`; there is no salt / predecessor concept.
- **Operation ID** = `keccak256(abi.encode(target, value, data, eta))`.
- **Execution window** = `[eta, eta + GRACE_PERIOD]` = `[eta, eta + 14 d]`. Stale after that.
- `queueTransaction` requires `eta >= block.timestamp + minDelay` = `now + 24 h`.
- Owner path uses standard OpenZeppelin 2-step ownership (`transferOwnership` / `acceptOwnership`).

## D. Exact Vault authorization inner calldata

```
target:   0x00340C360353a5AB784c5Bc5c44322A6AF0625D3    (CollateralVault)
value:    0
function: setAuthorizedEngine(address,bool)
args:     (0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9, true)
selector: 0x3331c56e
calldata: 0x3331c56e
          00000000000000000000000044702b0a3c329f2cc5b5c02c2123dc9386a46db9
          0000000000000000000000000000000000000000000000000000000000000001
```

## E. Exact Timelock `queueTransaction` payload (schedule, at ARM)

```
target:   0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588    (ProtocolTimelock)
value:    0
function: queueTransaction(address,uint256,bytes,uint256)
args:     (VAULT, 0, <inner Vault calldata §D>, <eta>)
selector: 0x8e361cdf
```

`eta` MUST satisfy `now + 86400 <= eta <= now + 86400 + 14 days` when submitted. Typical safe choice: `eta = ARM_block_timestamp + 25 h` (1 h buffer over minDelay).

**Verified on-chain**: `Timelock.hashOperation(VAULT, 0, calldata, eta_placeholder)` matches our locally computed `keccak256(abi.encode(...))` exactly (proven with placeholder `eta = 1_790_162_400`, on-chain `hashOperation` returned `0x9b55f5cac6e9313a77a41a9deb92a6ba6f716d7313d295bcc193b9ae660610f5` identical to local computation).

## F. Exact Timelock `executeTransaction` payload (execute, at eta+cutover)

```
target:   0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588    (ProtocolTimelock)
value:    0
function: executeTransaction(address,uint256,bytes,uint256)
args:     (VAULT, 0, <inner Vault calldata §D>, <same eta as §E>)
selector: 0x06a41d09
```

Must be sent from an executor (OPS Safe). msg.value must equal `value` (=0).

## G. Safe payload template (OPS Safe → Timelock, both actions)

- Safe: `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`, v1.4.1, threshold **2 of 3** owners: `0xb9F8dE807Ff98D5730035a8BFED4bDa33E886d06`, `0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d`, `0xa774C46C41064524dF895BD7bE9F294409798dFC`. No modules enabled.
- Safe nonce at check time: **10** (advance as needed).
- Safe transaction fields (both `queueTransaction` and `executeTransaction`):

```
to:              0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588
value:           0
data:            <§E schedule or §F execute calldata>
operation:       0    (CALL, not DELEGATECALL)
safeTxGas:       0
baseGas:         0
gasPrice:        0
gasToken:        0x0000000000000000000000000000000000000000
refundReceiver:  0x0000000000000000000000000000000000000000
signatures:      2/3 owner EIP-712 signatures over Safe tx-hash
```

## H. Early-schedule verdict — `EARLY_TIMELOCK_SCHEDULE_SAFE`

Proof:
- `queueTransaction` writes only `queuedTransactions[txHash] = true` inside the Timelock. Zero call to Vault.
- Vault state is unaffected until `executeTransaction` fires at eta.
- V2 engine gains no vault authority merely from scheduling.
- V1 has no dependency on Timelock queue contents.
- The scheduled operation may still be `cancelTransaction`ed by OPS Safe (owner/guardian) at any time before execution — so scheduling is fully reversible.

⇒ **Schedule during PHASE C0 (ARM). Wait ≥ 24 h. Execute during PHASE C5 (post-seal cutover).**

## I. V1 vs V2 RiskModule oracle-freshness reads

- `V1_RISK 0xf1b46040….maxOracleDelay()` = **`600` s** (10 min)
- `V2_RISK 0x8C3d9F71….maxOracleDelay()` = **`0` s** (constructor default = staleness gate disabled)
- Same `oracle()` (OracleRouter `0xB416…581`) is used by both engines.

`PerpRiskModule._isOracleDataFresh(updatedAt)`: `if (d == 0) return true;` — a zero `maxOracleDelay` means the freshness gate is disabled.

## J. Final oracle-freshness recommendation

**Recommendation**: mirror V1 exactly. Set `V2_RISK.maxOracleDelay = 600` (seconds). V1 has run under this policy on Base Sepolia without operational incidents; V2 inheriting the same value keeps behavior parity across cutover.

Calldata:
```
target:   0x8C3d9F71cA59B908Fa200546A63ea62F9C932998    (RISK_V2)
value:    0
function: setMaxOracleDelay(uint256)
args:     (600)
selector: 0xcd3b691c
calldata: 0xcd3b691c0000000000000000000000000000000000000000000000000000000000000258
authority: OWNER_EOA (direct call — RISK_V2.owner() = 0xc35F7A8A…)
phase: C0 (ARM)   — safe pre-freeze: RISK_V2 becomes engine-effective only after migration SEALED
```

Not `OPERATOR_DECISION_REQUIRED` in this preflight since V1 has a clear canonical value. If the operator prefers to change the policy at cutover, that decision can override this recommendation before C0 execution.

## K. Executor-grant timing — `EARLY_EXECUTOR_GRANT_SAFE`

- `PME_V2.isExecutor(0x58Ad…52B8)` = **`false`** (deferred at PRE-STAGE)
- `PME_V1.isExecutor(0x58Ad…52B8)` = `true`

Safe to grant in PHASE C0 because Engine `migrationState == OPEN` makes `applyTrade` fail-closed with selector `0x9aec415e` (verified via `eth_call` in PRE-STAGE readback). Granting PME executor status has no economic effect until migration seal.

Calldata:
```
target:   0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2    (PME_V2)
value:    0
function: setExecutor(address,bool)
args:     (0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8, true)
selector: 0x1e1bff3f
calldata: 0x1e1bff3f
          00000000000000000000000058ad437cb9e32b0faee810ef05810d5ba2ae52b8
          0000000000000000000000000000000000000000000000000000000000000001
authority: OWNER_EOA (PME_V2.owner = 0xc35F7A8A…)
```

## L. V1 freeze mechanism (minimum-safe)

**Primary lever**: `PME_V1.pause()` (owner OR guardian; both = `0xc35F7A8A…` EOA). Blocks *all* `executeTrade` / `executeBatch` / `executeTradeFromIntents` paths regardless of executor state. Does NOT touch positions, funding, liquidations, or Vault.

Calldata:
```
target:   0x774d96E5739bffadEE91508b4D3D74F5BE29F165    (PME_V1)
value:    0
function: pause()
selector: 0x8456cb59
calldata: 0x8456cb59
authority: OWNER_EOA
phase: C1 (FREEZE)
```

**Belt-and-suspenders**: Backend also stops issuing V1 broadcasts (config-only). Executor-side: `PME_V1.setExecutor(runtime, false)` is optional and unnecessary if `pause()` is set — but revocation makes the freeze double-gated. Recommended: only `pause()`; skip executor revoke to keep V1 pause reversible without a re-grant.

`Engine.updateFunding` / `Engine.liquidate` remain callable — safe because they mutate global market state and any positions the migration is about to snapshot. Freeze order (§M) pins the snapshot AFTER quiescence to avoid mid-flight funding drift.

## M. Backend quiescence queries (READ-ONLY SQL)

Backend uses table `execution_intents` + `execution_intent_broadcasts` with `protocol_version IN ('perp_v1','perp_v2')` (migrations `0064`, `0066`). Intent status enum (`src/execution/intent.rs`): `Pending, DryRun, CalldataReady, SimulationOk, SimulationFailed, Prepared, Submitted, Confirmed, Failed, Abandoned`. Terminal states: `Confirmed`, `Failed`, `Abandoned`. In-flight requiring reconciliation: `Prepared`, `Submitted`. Retire-eligible: `Pending`, `DryRun`, `CalldataReady`, `SimulationOk`, `SimulationFailed`.

Quiescence predicates (must all return 0 rows / 0 count at snapshot block):

```sql
-- 1. no V1 intents that could still transition into on-chain execution
SELECT COUNT(*) FROM execution_intents
 WHERE protocol_version = 'perp_v1'
   AND status IN ('pending','dry_run','calldata_ready','simulation_ok');

-- 2. no unresolved V1 broadcasts (Prepared/Submitted)
SELECT COUNT(*) FROM execution_intent_broadcasts
 WHERE protocol_version = 'perp_v1'
   AND status IN ('prepared','submitted');

-- 3. reconciler caught up to snapshot block
SELECT last_block_processed FROM reconciler_state WHERE component='perp_v1';
-- must be >= V1_FINAL_BLOCK

-- 4. indexer caught up
SELECT MAX(block_number) FROM indexed_perp_trades WHERE protocol_version='perp_v1';
-- must be >= V1_FINAL_BLOCK (or emitter_address matches V1 and MAX reflects processed height)

-- 5. no worker can create new V1 intent (after PME pause):
--    verify backend config PERPS_ACTIVE_ENGINE_VERSION and any "closed-test disabled" flags
```

Exact reconciler-state / indexer-state table names may vary between environments; adjust based on `select tablename from pg_tables where tablename like '%reconcil%' or tablename like '%indexer%'`.

## N. Freeze / drain order + `V1_FINAL_BLOCK` rule

1. **T0** — Safe → `PME_V1.pause()`  → confirmed on-chain.
2. **T0..T1** — Backend reconciler + indexer catch up. All Prepared/Submitted V1 broadcasts must resolve to a terminal receipt (Confirmed / Failed) or Abandoned.
3. **T1** — `V1_FINAL_BLOCK = max(block_number of last reconciled V1 tx receipt, last indexer block)`.
4. Wait for ≥ 12 additional blocks (Base Sepolia reorg-safety margin) beyond `V1_FINAL_BLOCK`.
5. **T2** — pin `SNAPSHOT_BLOCK = V1_FINAL_BLOCK + 12`.
6. Verify `blockHash(SNAPSHOT_BLOCK)` is stable across two independent RPC calls ≥ 30 s apart.

`SNAPSHOT_BLOCK` becomes the immutable input to §O.

## O. Snapshot universe completeness method

Two independent sources, cross-verified:

**Source 1 — on-chain event log**: enumerate `PerpEngine.TradeExecuted(address indexed buyer, address indexed seller, uint256 indexed marketId, uint128 sizeDelta1e8, uint128 executionPrice1e8, bool buyerIsMaker)` — topic0 `0xa73bf9fa75c33ddc672c6fc71d4d4b4e5f85c018c8acc16855e94f564114ed60` — from V1 engine deploy block through `SNAPSHOT_BLOCK`. Union `{buyer, seller}` per marketId. Base Sepolia RPC (Alchemy) enforces a 2000-block window per `eth_getLogs` call; iterate in 2000-block chunks.

**Source 2 — backend index**: 
```sql
SELECT DISTINCT trader, market_id FROM indexed_perp_trades
 WHERE protocol_version = 'perp_v1' AND block_number <= <SNAPSHOT_BLOCK>;
```

Union both sources. For each candidate `(trader, marketId)`, read AT `SNAPSHOT_BLOCK`:
```
size1e8         = PerpEngine.getPositionSize(trader, marketId)
position        = PerpEngine.positions(trader, marketId)   // includes openNotional, funding checkpoint
```
Drop entries where `size1e8 == 0`.

Also union:
- All addresses with `getResidualBadDebt(trader) > 0` from event log `ResidualBadDebtUpdated(...)` scan
- Optionally, all trader addresses recorded in backend `perp_orders` / `perp_fills` for defense-in-depth

Reconcile: per market, `Σ size1e8` split by side must equal `MarketState.longOI1e8` / `shortOI1e8`. Mismatch → `SNAPSHOT_INCOMPLETE` abort.

**Current live universe** (probed at block `47_150_485`): 
- market 1 (ETH-PERP): `longOI = 1_001_002 (1e8)`, `shortOI = 1_001_002` → **exactly one matched pair expected** (≈ 0.01001002 ETH-PERP notional).
- market 2 (BTC-PERP): `longOI = shortOI = 0` → empty.
- `totalResidualBadDebtBase = 0`.

## P. Canonical manifest schema

```
{
  "schemaVersion": 1,
  "chainId": 84532,
  "engineV1": "0xc6C592100723Fe0C66343A16e95eC34cC0c2141c",
  "pmeV1":    "0x774d96E5739bffadEE91508b4D3D74F5BE29F165",
  "snapshotBlockNumber": <uint256>,
  "snapshotBlockHash":   "0x<32 bytes>",

  "markets": [
    { "marketId": <uint>, "cumulativeFundingRate1e18": <int>,
      "lastFundingTimestamp": <uint>, "longOI1e8": <uint>, "shortOI1e8": <uint> }
  ],

  "positions": [
    { "trader": "0x…", "marketId": <uint>,
      "size1e8": <int>, "openNotional1e8": <int>,
      "lastCumulativeFundingRate1e18": <int> }
  ],

  "residualBadDebt": [
    { "trader": "0x…", "amountBase": <uint> }
  ],

  "pmeNonces": [
    { "trader": "0x…", "nonce": <uint> }
  ],

  "vaultBalances": [
    { "user": "0x…", "token": "0x…", "balance": <uint> }
  ]
}
```

Canonical ordering (mandatory before hashing):
- `markets`: ascending `marketId`
- `positions`: ascending `(trader raw bytes lowercase, marketId)`
- `residualBadDebt`: ascending `trader raw bytes lowercase`
- `pmeNonces`: ascending `trader raw bytes lowercase`
- `vaultBalances`: ascending `(user raw bytes lowercase, token raw bytes lowercase)`

## Q. Canonical hash algorithm

```
canonical(manifest)   → dict with sorted collections, addresses/bytes32 decoded to raw bytes
canonical_cbor        → cbor2.dumps(canonical(manifest), canonical=True)   # RFC 8949 §4.2 core deterministic
snapshotHash          = keccak256(canonical_cbor)
```

Helper script committed as `tools/perps_v2_cutover/snapshot_hash.py`. Runtime dependencies: `cbor2` and any keccak-256 provider (`pysha3` / `pycryptodome`). CLI:

```
python3 tools/perps_v2_cutover/snapshot_hash.py manifest.json
# prints canonical_cbor_bytes, canonical_cbor_hex, snapshot_hash
```

**Test vectors** (add before first cutover use):
- Empty manifest with only `schemaVersion`, `chainId`, `snapshotBlockNumber = 0`, `snapshotBlockHash = 0x00…` → deterministic hash `X_empty`.
- Same manifest with `positions` in reversed source order but identical content → same hash.
- One `size1e8` value changed by +1 → different hash.

Vectors will be added when the tool is first exercised against a live-shape empty manifest during PHASE C2 dry-run.

## R. Snapshot dry-run result

Deferred: requires backend PG access + full log scan. The tool is committed and ready. The current live universe (§O) is trivially small (≤ 2 positions on market 1) so the first real dry-run at ARM time will be inexpensive.

## S. Deterministic seed calldata procedure

Given manifest, emit seed transactions in canonical order:

1. **Per market** in ascending `marketId`:
   ```
   ENGINE_V2.adminSeedMarketFunding(marketId, cumulativeFundingRate1e18, lastFundingTimestamp)
       selector: 0x2c96f1bc
   ```
2. **Per position** in `(trader, marketId)` order:
   ```
   ENGINE_V2.adminSeedPosition(trader, marketId, size1e8, openNotional1e8, lastCumulativeFundingRate1e18)
       selector: 0x0ef3a5f7
   ```
3. **Per residual bad debt** in `trader` order:
   ```
   ENGINE_V2.adminSeedResidualBadDebt(trader, amountBase)
       selector: 0x6067ee86
   ```
4. **Seal (last, irreversible)**:
   ```
   ENGINE_V2.sealMigration(snapshotHash)
       selector: 0x05d5af5b
   ```

Idempotency: each seed reverts on duplicate (`MigrationPositionAlreadySeeded`, `MigrationMarketFundingAlreadySeeded`, `MigrationBadDebtAlreadySeeded`). Replay is safe (revert = no-op state change). `sealMigration` is one-way; once `migrationState == SEALED`, all `adminSeed*` calls revert with `MigrationAlreadySealed`.

All 4 selectors require `onlyOwner` (OWNER_EOA) AND `onlyMigrationOpen`.

## T. Clearing account economic semantics

`PerpClearingAccountV2` (`src/perp/PerpClearingAccountV2.sol`) is a minimal deposit-only vault holder:
- Immutable `collateralVault`. No owner, no upgrade, no drain surface.
- `fundClearing(asset, amount)`: pulls ERC20 from `msg.sender`, calls `Vault.deposit`. Permissionless.
- Balance moves ONLY via `Vault.transferBetweenAccounts` initiated by an authorized engine (`onlyMarginEngine`).

`PerpEngineTradingV2._routeIncomingCashflowWithDebtFirst` (from the V2 clearing spec docs):
- Trader with realized PnL < 0 → pays `|realized|` to `clearingAccount` first.
- Trader with realized > 0 → is credited from `clearingAccount`.
- Symmetric mutual close ⇒ clearing net Δ = 0.
- Asymmetry (one-sided close, timing gap, funding drift, rounding, bad-debt-first routing) requires clearing to front the credit.

## U. Clearing sizing formula + candidate amount

Let `N` = number of live migrated (trader, market) positions. Let `S_max` = max absolute `size1e8` across all positions. Let `P_max` = max plausible mark 1e8 (worst-case for the migration window). Let `μ` = max plausible per-position PnL delta expected during the first V2 close (bounded by execution-price guard `maxExecutionDeviationBps` × mark).

Worst-case clearing floor for the first V2 close:
```
required_native ≈ ceil( S_max * P_max * μ / PRICE_1E8 )
                + Σ rounding_slack
                + funding_conversion_residual
                + operational_buffer
```

For current live state (§O), all values are tiny:
- `S_max = 1_001_002 (1e8) ≈ 0.01001002` ETH-PERP
- `P_max ≈ 5_000` USDC/ETH (very generous upper bound for testnet ETH)
- `μ` = up to `maxExecutionDeviationBps / 10_000` — engine deviation guard clamps runaway prices
- Native settlement asset for ETH-PERP is mUSDC (6 decimals)

Even at 20 % relative PnL swing on the full 0.01 ETH position: `0.01 × 5_000 × 0.2 = 10 USDC ≈ 10_000_000 native`. Rounding slack over 6-decimal native across 2 positions: < 100 native.

**Proposed floor**: `MINIMUM_REQUIRED_CLEARING = 100 USDC = 100_000_000 native mUSDC`.
**Operational buffer**: `OPERATIONAL_BUFFER = 900 USDC = 900_000_000 native mUSDC`.
**PROPOSED_CLEARING_SEED = 1_000 USDC = 1_000_000_000 native mUSDC**.

If any live position is added/enlarged between now and ARM, recompute with actual `SNAPSHOT_BLOCK` values. If `S_max × P_max` exceeds ~5 % of the OPS Safe / operator mUSDC balance, escalate as `CLEARING_SIZING_OPERATOR_DECISION_REQUIRED`.

## V. Clearing funding calldata

Assuming funder is OWNER_EOA holding mUSDC:

```
# 1. Approve CLEARING_V2 to spend AMOUNT of mUSDC
target:   0x6eAe407f5640B006faC9965182e238582A3B412E   (mUSDC)
function: approve(address,uint256)
args:     (CLEARING_V2 0x54d49c…35c, AMOUNT_native)

# 2. Fund clearing
target:   0x54d49c088DD27cFc82685b867c182b4bB4aC435c   (CLEARING_V2)
function: fundClearing(address,uint256)
args:     (mUSDC 0x6eAe…12E, AMOUNT_native)
```

`fundClearing` is permissionless — any account with mUSDC + prior approval can call. Deployer EOA is the convenient default because it already exercises the keystore workflow, but an OPS-Safe-based fund is equally valid (just Safe → mUSDC.approve, Safe → CLEARING_V2.fundClearing).

## W. Vault-authorization ordering (before/after seed/seal)

`adminSeedPosition` / `adminSeedMarketFunding` / `adminSeedResidualBadDebt` in `PerpEngineTradingV2` do **not** call `CollateralVault` (they only mutate internal engine storage). `sealMigration` also does not call Vault (only enforces static preconditions and sets state).

⇒ **Vault authorization is NOT required for seed or seal.** Safest order:

```
C1 freeze     → C2 snapshot → C3 fund clearing → C4 seed + seal
                              (uses CLEARING_V2 which is already vault-connected)
              → C5 timelock EXECUTE Vault.setAuthorizedEngine(V2, true)
              → C6 backend activate v2
              → C7 first V2 close
```

Vault authorization AFTER seal is provably the narrowest-authority window: V2 gains vault power only after all economic state is pinned.

## X. V1 post-cutover Vault authorization — verdict

Concrete analysis of post-cutover V1 mutation surfaces:
- `V1_PME` is `paused` (§L) → no `executeTrade*` → no `V1_ENGINE.applyTrade`.
- `V1_ENGINE.liquidate(trader, marketId, size)` still callable by anyone if a V1-tracked position is unhealthy — but by §O we prove V1 has no unresolved positions AFTER seed migration into V2. Post-seed, V1's own `_positions[trader][marketId]` still contains the pre-migration value (V1 doesn't get cleared by V2 seeding). A liquidator could in principle call `V1_ENGINE.liquidate(...)` targeting the old V1 position and touch Vault via `CollateralSeizer` because `Vault.isAuthorizedEngine(V1) == true`.
- `V1_ENGINE.updateFunding(marketId)` is permissionless — can still run.
- `V1_ENGINE.updateImpactMid` is guarded by `impactMidSource` (unset on V1 in practice).

**Verdict**: leaving `Vault.isAuthorizedEngine(V1) == true` is a real economic risk vector post-cutover because a rogue liquidator could reach into Vault to seize collateral against the *V1-frozen* old position, which is no longer accounted anywhere active. Two mitigations, either sufficient:

1. **Additionally pause V1 liquidations** — `V1_ENGINE.pauseLiquidation()` (owner/guardian). Blocks `V1_ENGINE.liquidate`. Recommended default.
2. **Revoke V1 vault authority after seal** — Timelock-scheduled `Vault.setAuthorizedEngine(V1, false)`. Stronger, but permanent.

**Recommended CUTOVER-plus-1 milestone**: add `V1_ENGINE.pauseLiquidation()` to PHASE C1 (already an EOA-owner action; instant), AND schedule V1 vault deauth for a follow-up (`PERPS_V2_BASE_SEPOLIA_V1_DEAUTH_V1`) after 24-48 h of successful V2 operation.

Adding V1 `pauseLiquidation` to §L freeze payload:
```
target:   0xc6C592100723Fe0C66343A16e95eC34cC0c2141c   (V1_ENGINE)
function: pauseLiquidation()
selector: 0x1d966e81
authority: OWNER_EOA (guardian OR owner)
phase: C1 (FREEZE, immediately after PME pause)
```

## Y. All V1 mutation surfaces (post-cutover classification)

| Surface | Path | Post-freeze status |
|---|---|---|
| `PME_V1.executeTrade / executeBatch / executeTradeFromIntents` | matching | **FROZEN** via `pause()` |
| `V1_ENGINE.applyTrade` | via PME | **INACCESSIBLE** (only PME_V1 can call; PME_V1 paused) |
| `V1_ENGINE.liquidate` | permissionless | **FROZEN** if §X mitigation 1 applied (`pauseLiquidation()`) |
| `V1_ENGINE.updateFunding` | permissionless | STILL ACTIVE — harmless: does not touch positions or Vault |
| `V1_ENGINE.updateImpactMid` | `impactMidSource`-only | INACCESSIBLE (source is unset on V1) |
| `V1_ENGINE` admin surface (setMatching / setRisk / setInsurance / setFeesManager*) | owner-only (`0xc35F7A8A…`) | STILL ACTIVE by policy (owner can still reconfigure) — no risk to V2 |
| `V1_ENGINE.recordResidualBadDebt` and other V1-only bad-debt admin | owner-only | STILL ACTIVE; not migration-relevant post-seal |
| Vault.transferBetweenAccounts via `onlyMarginEngine(V1)` | via V1 Engine | requires §X mitigation 2 (Vault deauth) or mitigation 1 for full assurance |

Any STILL-ACTIVE and migration-relevant surface is closed by §X mitigations. Migration-irrelevant surfaces (funding update on empty markets, owner reconfig on the now-frozen V1) are safe to leave alone.

## Z. Backend V2 activation plan

Backend HEAD `ad8dd7466` already validates V2 env-var completeness (`src/execution/config.rs:398`+). Activation is a config change + restart, no code change.

Future `.env.base-sepolia` additions (do NOT set until PHASE C6):
```
PERPS_ACTIVE_ENGINE_VERSION=v2
PERP_ENGINE_V2_ADDRESS=0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9
PERP_MATCHING_ENGINE_V2_ADDRESS=0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2
PERP_RISK_MODULE_V2_ADDRESS=0x8C3d9F71cA59B908Fa200546A63ea62F9C932998
PERP_CLEARING_ACCOUNT_V2_ADDRESS=0x54d49c088DD27cFc82685b867c182b4bB4aC435c
FEES_MANAGER_V2_ADDRESS=0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f
PERP_ENGINE_SEIZURE_LIB_ADDRESS=0xf0C5652277CF88B508E05F7aB54949fCDF0360A5
PERP_ENGINE_LIQUIDATION_LIB_ADDRESS=0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D
```

**Preflight (backend startup gate — verify these READ TRUE before starting up in v2 mode)**:
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
11. Clearing vault-balance ≥ `MINIMUM_REQUIRED_CLEARING`
12. Runtime signer `executor` has ≥ some min ETH for gas

**Rollback behavior**: if v2 startup preflight fails, backend refuses to start (no automatic silent downgrade to v1). Operator either fixes v2 state or reverts `.env.base-sepolia` to v1 addresses + restarts. `PERPS_ACTIVE_ENGINE_VERSION` is authoritative; there is no runtime-mutable override.

## AA. First V2 close calculator

At cutover, before signing the first V2 mutual close, run this READ-ONLY model:

Inputs (read at execution block):
- `p = positions(trader_long, marketId)`  ← migrated basis
- `q = positions(trader_short, marketId)` ← migrated basis
- `m = MarketState(marketId).cumulativeFundingRate1e18`
- `x_price = agreed execution price 1e8`
- `RC = getRiskConfig(marketId)`  → maker/taker orientation
- `feeTier = FMV2.getFeeQuote(consumer, notional, side, ...)`

Compute (all in native settlement units):
```
notional_native = |sizeDelta| * x_price / 1e8       (scaled to settlement decimals)

realizedPnl_long  = sizeDelta_long  * (x_price - p.openNotional / p.size1e8) / 1e8
realizedPnl_short = sizeDelta_short * (x_price - q.openNotional / q.size1e8) / 1e8

fundingDelta_long  = (m - p.lastCumulativeFundingRate1e18) * p.size1e8 / 1e18
fundingDelta_short = (m - q.lastCumulativeFundingRate1e18) * q.size1e8 / 1e18

maker_fee = FMV2.quote(maker_side, notional_native, tier)
taker_fee = FMV2.quote(taker_side, notional_native, tier)

expected_settlement_long  = realizedPnl_long  - fundingDelta_long  - maker_or_taker_fee_long
expected_settlement_short = realizedPnl_short - fundingDelta_short - maker_or_taker_fee_short
expected_clearing_delta   = 0   (for a matched mutual close after fee routing)
expected_vault_delta      = expected_settlement_long + expected_settlement_short + Σ fees_to_recipient
```

Reject the trade if `expected_clearing_delta > CLEARING_V2.balance × 0.5` — always leave headroom for rounding.

The exact formulas are already implemented inside `PerpEngineV2` (see `_applyRealizedCashflow`, `_routeIncomingCashflowWithDebtFirst`, `_chargeTradingFeeV2`). The calculator only needs to reproduce them in test-code form to derive an `expected_*` reference to compare against the on-chain result post-trade.

**Do NOT hardcode `+244_274 / -244_274`** — that number came from a specific Anvil regression with a specific mark price and V2 fee tier. Live Base Sepolia values differ.

## AB. Pre-seal abort matrix

| Signal | Safe action |
|---|---|
| `SNAPSHOT_BLOCK` reorg (blockHash changes) | Repin later block, restart from §N step 5 |
| Manifest hash mismatch between two independent generators | Investigate divergent source; do NOT proceed |
| Per-market OI ≠ Σ side sizes | `SNAPSHOT_INCOMPLETE` — extend universe discovery; may indicate missed trader |
| Position mismatch (backend index ≠ on-chain) | Trust on-chain; log discrepancy; do NOT proceed until reconciled |
| Funding mismatch (market snapshot funding ≠ engine live) | Delay: run `updateFunding` if needed; re-snap |
| Seed transaction reverts | STOP; check `MigrationXxx` error; verify args match manifest exactly |
| Residual bad debt mismatch | STOP; investigate before seal |
| Clearing balance < `MINIMUM_REQUIRED_CLEARING` | Top up via §V before seal |
| `Vault.isAuthorizedEngine(V2)` unexpectedly true | STOP; investigate Timelock/Safe activity |
| PME_V2 executor unexpectedly configured wrong | STOP; verify §K value |
| Backend preflight (§Z) not READY | STOP; do NOT seal until backend gate green |

**Default action when in doubt**: ABORT. V1 remains frozen but sealed contracts remain unsealed until every gate passes.

## AC. Post-seal recovery plan

Seal is irreversible. If AFTER seal any of the following occurs:

| Failure | Safe degraded state | Recovery |
|---|---|---|
| Timelock `executeTransaction` reverts | V1 frozen, V2 sealed but not vault-authorized, no trading | Cancel the queued op (Safe→Timelock.cancel), re-queue with a fresh eta; if the revert is Vault-side, unblock Vault first |
| Backend v2 startup fails | V1 frozen, V2 sealed, backend down | Diagnose env / preflight (§Z); do NOT downgrade backend to v1 (V1 PME is paused) — fix v2 config and restart |
| Runtime executor unavailable | V1 frozen, V2 sealed & authorized, no broadcasts | Rotate executor (owner→`PME_V2.setExecutor(new,true)`); update backend `EXECUTOR_ADDRESS`; restart |
| First V2 close simulation fails | V1 frozen, V2 sealed, no first trade | Compare simulation against §AA model; if divergent, do NOT sign; escalate |

No contract-level rollback exists for `sealMigration`. The design assumes the pre-seal gate matrix (§AB) is thorough enough that seal only fires on a verified state.

## AD. Time-aware CUTOVER DAG

### PHASE C0 — ARM (V1 fully live, safe pre-work)

| # | Action | Authority | Target | Signature / calldata | Deps | Readback |
|---:|---|---|---|---|---|---|
| C0.1 | Set V2 risk oracle policy | OWNER EOA | RISK_V2 | `setMaxOracleDelay(600)` §J | — | `maxOracleDelay()==600` |
| C0.2 | Grant PME_V2 executor | OWNER EOA | PME_V2 | `setExecutor(runtime, true)` §K | — | `isExecutor(runtime)==true` |
| C0.3 | Safe → Timelock queue Vault auth flip | OPS Safe (2/3) | Timelock | `queueTransaction(VAULT, 0, §D, eta)` §E, eta = ARM_ts + 25 h | — | `isQueued == true`, op_id matches §E |
| C0.4 | Optional: draft snapshot dry-run | anyone | — | `tools/perps_v2_cutover/snapshot_hash.py` on current-block manifest | — | reproducible hash |

### PHASE C1 — FREEZE (V1 stops)

| # | Action | Authority | Target | Signature | Deps | Readback |
|---:|---|---|---|---|---|---|
| C1.1 | Pause V1 matching | OWNER EOA | PME_V1 | `pause()` §L | — | `paused()==true` |
| C1.2 | Pause V1 liquidations (§X mitigation) | OWNER EOA | V1_ENGINE | `pauseLiquidation()` | — | `liquidationPaused()==true` |
| C1.3 | Backend: stop V1 broadcast worker (config) | operator | backend | env flag / worker disable | — | reconciler shows no new V1 broadcasts |

### PHASE C2 — DRAIN + SNAPSHOT

| # | Action | Authority | Target | Signature | Deps | Readback |
|---:|---|---|---|---|---|---|
| C2.1 | Wait for reconciler + indexer to reach V1_FINAL_BLOCK | operator | backend | monitor | C1.* | quiescence SQL (§M) → 0 rows |
| C2.2 | Compute V1_FINAL_BLOCK + wait 12 blocks | operator | RPC | § N | C2.1 | stable blockHash |
| C2.3 | Pin SNAPSHOT_BLOCK | operator | — | manifest generator §O + P | C2.2 | manifest generator emits deterministic output |
| C2.4 | Compute snapshotHash | operator | — | `snapshot_hash.py manifest.json` §Q | C2.3 | two independent generators agree |

### PHASE C3 — FUND

| # | Action | Authority | Target | Signature | Deps | Readback |
|---:|---|---|---|---|---|---|
| C3.1 | Approve mUSDC | funder EOA / Safe | mUSDC | `approve(CLEARING_V2, AMOUNT)` §V | — | allowance == AMOUNT |
| C3.2 | fundClearing | funder | CLEARING_V2 | `fundClearing(mUSDC, AMOUNT)` §V | C3.1 | Vault balance of CLEARING_V2 ≥ MINIMUM_REQUIRED_CLEARING |

### PHASE C4 — SEED + SEAL

| # | Action | Authority | Target | Signature | Deps | Readback |
|---:|---|---|---|---|---|---|
| C4.1 | adminSeedMarketFunding per market | OWNER EOA | ENGINE_V2 | §S(1) | C2.4 | market state matches manifest |
| C4.2 | adminSeedPosition per (trader, market) | OWNER EOA | ENGINE_V2 | §S(2) | C4.1 | positions match manifest |
| C4.3 | adminSeedResidualBadDebt per trader | OWNER EOA | ENGINE_V2 | §S(3) | C4.2 | residual bad-debt matches manifest |
| C4.4 | Verify seeded state == manifest | anyone | ENGINE_V2 | reads | C4.3 | full manifest equality |
| C4.5 | sealMigration(snapshotHash) | OWNER EOA | ENGINE_V2 | §S(4) | C4.4 + C3.2 | `migrationState==1 (SEALED)`, `migrationSnapshotHash == locally computed` |

### PHASE C5 — VAULT AUTHORITY (Timelock execute)

| # | Action | Authority | Target | Signature | Deps | Readback |
|---:|---|---|---|---|---|---|
| C5.1 | Wait until `block.timestamp >= eta` (from C0.3) | — | — | — | C4.5 | `isOperationReady(VAULT,0,§D,eta) == true` |
| C5.2 | Safe → Timelock.executeTransaction | OPS Safe (2/3) | Timelock | §F | C5.1 | `Vault.isAuthorizedEngine(ENGINE_V2) == true` |

### PHASE C6 — BACKEND ACTIVATE

| # | Action | Authority | Target | Signature | Deps | Readback |
|---:|---|---|---|---|---|---|
| C6.1 | Backend env update + restart | operator | backend | §Z | C5.2 | backend startup preflight all green |
| C6.2 | Broadcast worker readiness | operator | backend | monitor | C6.1 | reconciler up, executor balance OK |

### PHASE C7 — FIRST V2 CLOSE

| # | Action | Authority | Target | Signature | Deps | Readback |
|---:|---|---|---|---|---|---|
| C7.1 | Compute expected settlement (§AA calculator) | anyone | — | read | C6.2 | numbers within tolerance |
| C7.2 | Sign V2 mutual-close intent (buyer + seller) | traders | PME_V2 EIP-712 domain §PRE-STAGE | — | C7.1 | signatures valid |
| C7.3 | Backend arms + broadcasts via runtime executor | backend | PME_V2 | `executeTrade` | C7.2 | receipt.status==1, on-chain settlement matches §AA prediction |

## AE. Remaining blockers

**BLOCKS_CUTOVER_ARM (PHASE C0)**: none.

**BLOCKS_FREEZE (PHASE C1)**: none — all levers are EOA-callable.

**BLOCKS_SEED (PHASE C4)**: 
- Snapshot dry-run has not yet been executed on live data (requires cbor2 install + backend PG access when performed). Non-blocking to ARM; blocking to SEAL.

**BLOCKS_FIRST_V2_TRADE (PHASE C7)**:
- Backend runtime executor balance is low (0.001951 ETH at PRE-STAGE; may need top-up before C7).
- First-close calculator implementation not yet coded (spec present in §AA; concrete Rust/Python calculator to be added before C7).

## AF. Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_CUTOVER_ARM_V1`** — execute PHASE C0 only:
- C0.1 `RISK_V2.setMaxOracleDelay(600)` (EOA)
- C0.2 `PME_V2.setExecutor(runtime, true)` (EOA)
- C0.3 Safe→Timelock `queueTransaction(VAULT, 0, §D, eta=now+25 h)` (Safe 2/3)

V1 remains fully live during C0. After C0.3 execution, we wait ≥ 24 h for eta eligibility, then run the subsequent freeze/seed/seal cutover.

## AG. Changed docs / scripts

- `docs/PERPS_V2_BASE_SEPOLIA_CUTOVER_PREFLIGHT_V1.md` (this file, NEW)
- `tools/perps_v2_cutover/snapshot_hash.py` (NEW helper — canonical manifest CBOR + keccak256)

No production Solidity changed.

## AH. Sol commit / pushed HEAD

To be created at the end of this milestone (doc + tools commit).

## AI. Backend HEAD

`ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged, worktree clean).

## AJ. Proof Base Sepolia unchanged

- Deployer nonce read at start and end of milestone: **768 == 768** (Δ 0).
- Zero `cast send` / `forge --broadcast` invocations.
- Zero Safe transaction created or signed.
- Zero Timelock `queueTransaction`, `cancelTransaction`, or `executeTransaction` calls.
- Zero Vault mutation.
- Zero RiskModule mutation.
- Zero PME executor grant.
- Zero migration seed / seal.
- Zero clearing funding transfer.
- Zero backend restart.
- All chain interactions used only `cast call`, `cast code`, `cast chain-id`, `cast block-number`, `cast balance`, `cast nonce`, `cast keccak`, `cast abi-encode`, `cast calldata`, `cast block` (read).
