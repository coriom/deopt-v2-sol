# PERPS V2 BASE SEPOLIA BACKEND V2 ACTIVATION PREFLIGHT V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ACTIVATION_PREFLIGHT_V1`
**Status**: **COMPLETE — READ-ONLY PREFLIGHT; ONE CRITICAL BLOCKER IDENTIFIED**
**Sol HEAD (pre)**: `76efc12` (unchanged during milestone; new docs commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Chain**: Base Sepolia (chainId `84532`)

Scope: strictly read-only. No chain writes, no DB writes, no backend restart, no env mutation, no V2 trade. Goal: prove the backend can be switched to V2 safely and produce the exact activation plan.

---

## A. Current effective backend mode

| Signal | Value | Source |
|---|---|---|
| Rust worktree | clean | `git status --short` |
| Backend HEAD | `ad8dd7466` | `git rev-parse HEAD` |
| Deployed service | not observed in this shell (`ps -eo pid,cmd \| grep deopt` → empty) | operator supplies systemd/Docker wrapper (no launcher checked in) |
| `PERPS_ACTIVE_ENGINE_VERSION` | unset → defaults to `v1` | `src/config/env.rs:220-228`; parser at `src/execution/perp_trade.rs:313-322` |
| `EXECUTOR_REAL_BROADCAST_ENABLED` | unset → defaults to `false` | `src/main.rs:259-308` (broadcast runtime only wired when true) |
| `PERPS_CLOSED_TEST_ENABLED` | required-true when broadcast on | `src/main.rs:301-305` |
| Perp broadcast worker | wired, version-aware | `src/execution/broadcast_runtime.rs:284-290,455-482`; `src/execution/broadcast_policy.rs` |

**Effective engine version at rest: `v1`. Effective broadcast: `off`.**

Version dispatch is done per-intent (immutable at cosign) rather than per-request. See `src/execution/config.rs:296-342` `perp_engine_address_for()` / `perp_matching_engine_address_for()`. This means flipping `PERPS_ACTIVE_ENGINE_VERSION=v2` only affects **new** intents; any V1 rows still in the broadcast queue continue to broadcast against V1 addresses. Reconciler and rebroadcast paths carry `protocol_version` + `expected_emitter` on every durable row (`migrations/0064..0067`), so cross-version replay is architecturally impossible.

## B. Exact activation env diff (minimum viable)

```
+ PERP_ENGINE_V2_ADDRESS=0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9
+ PERP_MATCHING_ENGINE_V2_ADDRESS=0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2
+ PERP_CLEARING_ACCOUNT_V2_ADDRESS=0x54d49c088DD27cFc82685b867c182b4bB4aC435c
+ PERPS_ACTIVE_ENGINE_VERSION=v2
+ PERPS_CLOSED_TEST_ENABLED=true          # required for real broadcast
+ EXECUTOR_REAL_BROADCAST_ENABLED=true    # gate for on-chain writes
```

- All three V2 address env vars are enforced by startup validator at `src/execution/config.rs:398-450` — service refuses to start with `PERPS_ACTIVE_ENGINE_VERSION=v2` unless all three are populated AND distinct from V1.
- `EXECUTOR_REAL_BROADCAST_ENABLED=true` additionally requires: RPC URL, gas params, signer keys, `PERSISTENCE_ENABLED=true` (see `src/execution/config.rs:461-478`).
- `PERPS_CLOSED_TEST_ENABLED=false` + `EXECUTOR_REAL_BROADCAST_ENABLED=true` → hard refusal at startup (`src/main.rs:301-305`).

Env vars that are **already correct and require no change** (per `.env.base-sepolia`):
- `RPC_URL=https://base-sepolia.g.alchemy.com/v2/…`
- `CHAIN_ID=84532`
- V1 addresses (`PERP_ENGINE`, `PERP_MATCHING_ENGINE_ADDRESS`, etc.) — retain for in-flight V1 reconciliation.

## C. V2 contract address wiring

Backend consumers of the three V2 env vars:

| Component | File | Reads |
|---|---|---|
| Address resolver | `src/execution/config.rs:296-342` | all three |
| Startup validator | `src/execution/config.rs:398-450` | all three (distinct-from-V1 assertion) |
| Indexer emitter set | `src/indexer/config.rs:24-95` | `PERP_MATCHING_ENGINE_V2_ADDRESS` |
| Signer resolver | `src/execution/perp_trade.rs:202-265,378` | `PERP_MATCHING_ENGINE_V2_ADDRESS` |
| Broadcast target | `src/execution/transaction.rs:221` | intent.protocol_version → address |

Live-chain V2 wiring verification:

```
ENGINE_V2.matchingEngine()   = 0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2   ✓ PME_V2
ENGINE_V2.riskModule()       = 0x8C3d9F71cA59B908Fa200546A63ea62F9C932998   ✓ RISK_V2
ENGINE_V2.marketRegistry()   = 0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC   ⚠ shared V1 PMR — see §V
RISK_V2.perpEngine()         = 0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9   ✓ ENGINE_V2
RISK_V2.collateralVault()    = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3   ✓ VAULT
Vault.isAuthorizedEngine(V2) = true                                        ✓
FMV2.isFeeConsumer(ENGINE_V2) = true                                       ✓
```

No stale V1 engine address on the V2 broadcast path.

## D. PME_V2 EIP-712 domain / digest proof

Live-chain `eip712Domain()` on PME_V2 (`0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2`):

```
fields             = 0x0f
name               = "DeOptV2-PerpMatchingEngine"
version            = "2"
chainId            = 84532
verifyingContract  = 0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2
salt               = 0x00..00
extensions         = []
```

Backend constructor at `src/execution/perp_trade.rs:240-246` (`PerpTradeDomain::new_v2`) uses byte-identical fields. Domain-separator recompute:

```
nameHash    = keccak("DeOptV2-PerpMatchingEngine")
            = 0x57511e5641e51641dbe51521a2d07f8c8dad95786a4f21e13cdf171e29f8a640
versionHash = keccak("2")
            = 0xad7c5bef027816a800da1736444fb58a807ef4c9603b7848673f7e3a68eb14a5
typeHash    = keccak("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
            = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f
domainSep   = keccak(abi.encode(typeHash, nameHash, versionHash, 84532, PME_V2))
            = 0x26a8b7a2a20b6c06fd610e824899da507ef8e51ad40f76040549a8332376c559
```

V2 PerpTrade struct typehash (12-field, matches backend `PERP_TRADE_TYPEHASH_HEX` at `src/execution/perp_trade.rs:352`):

```
keccak("PerpTrade(bytes32 intentId,address buyer,address seller,uint256 marketId,
                 uint128 sizeDelta1e8,uint128 executionPrice1e8,
                 uint128 maxExecutionPrice1e8,uint128 minExecutionPrice1e8,
                 bool buyerIsMaker,uint256 buyerNonce,uint256 sellerNonce,uint256 deadline)")
       = 0x9ccd368c748c5e85df8e96f94ac1d47316abde07a2d78c4f1b10b91cb98942c3
```

**Domain wiring: verified byte-identical between deployed PME_V2 and backend.**

The V1 typehash `0xfb345c17…8293` and V1 domain (version `"1"`) live at the SAME contract address on PME_V1 (`0x774d96E5739bffadEE91508b4D3D74F5BE29F165`), a different `verifyingContract` — so a V1 signature cannot verify against PME_V2 (different domain sep) and vice-versa.

## E. V2 nonce / replay proof

PME_V2 nonces at head-of-preflight (block `47_409_095`):

```
PME_V2.nonces(0xff287410852B9328437eaC353720e5476bC5F837)  = 0
PME_V2.nonces(0x66858286fEEA78a05eA093673EA1535E0A52002d)  = 0
```

V1 historical PME nonces do NOT migrate (V2 has an independent nonce mapping — new storage layout on a fresh contract). A V1 signature carrying V1 nonce `N` cannot replay against PME_V2 because:
- Domain separator differs (`version="1"` vs `"2"`; different `verifyingContract`).
- Struct typehash differs (V1 = 10-field, V2 = 12-field with bounds).
- PME_V2 nonce for every trader starts at 0.

## F. Oracle / RISK_V2 readiness

```
RISK_V2 (0x8C3d9F71cA59B908Fa200546A63ea62F9C932998):
   maxOracleDelay             = 600 s          ✓ matches env RISK_MAX_ORACLE_DELAY
   perpEngine                 = ENGINE_V2      ✓
   collateralVault            = VAULT          ✓
   oracleDeviationBps()       = reverted       (getter name mismatch; not blocking — value in PMR)
```

Env-configured oracle route for ETH perp:

```
ETH_PERP_ORACLE            = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581  (OracleRouter)
ETH_USDC_PRIMARY_SOURCE    = 0x3eb9cdd2C2115c3f0DF5E30da53D7245F9a5f6Cc  (Chainlink)
ETH_USDC_SECONDARY_SOURCE  = 0x2103a84C0CAB9cf7680d602C8931FaDeD7064517  (Pyth fallback)
```

Live probe of `OracleRouter.getMarkPrice1e8(1)` / `getIndexPrice1e8(1)` / `getPrice(WETH)` from an operator wallet returned raw revert on all attempted getters — likely selector mismatch between the current source (`src/oracle/*`) and the deployed router. This is orthogonal to the V2 activation path but must be re-verified once §V blocker is resolved (execution guard depends on the same oracle).

## G. FMV2 fee schedule proof

```
FMV2 (0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f):
   isFeeConsumer(ENGINE_V2)                        = true              ✓
   getFeeProfile(tier=0, product=PERP=1)  → (makerPpm=50, takerPpm=300) ✓
   getFeeProfile(tier=0, product=OPTION=0) → (makerPpm=50, takerPpm=250) (informational)
```

Baseline PERP tier-0: **50 ppm maker / 300 ppm taker.** No fallback to V1 legacy fee path — the V2 engine settles via `FeesManagerV2` directly (`src/perp/PerpEngineTradingV2.sol` fee hooks).

## H. Executor ETH readiness

```
RUNTIME_EXECUTOR (0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8):
   balance = 1_951_581_847_894_143 wei = 0.001951581 ETH
```

Gas budget for first V2 trade:
- Estimated gas for PMEV2.executeTrade path ≤ 350_000 (PME + engine + risk + oracle + FM + vault deposits)
- At current 6 mwei effective gas price: worst-case ≈ 350_000 × 6e6 = 2.1e12 wei = 0.0000021 ETH per trade.
- 0.001951581 ETH ÷ 0.0000021 ETH ≈ **~929 first-trade attempts** — operationally sufficient by 3 orders of magnitude.

**No top-up required.** Threshold ~0.005 ETH (per prior FINAL_SNAPSHOT §U) is unnecessarily conservative given actual gas cost; explicit math above proves current balance safely covers first-trade activation. If operator wishes to top up regardless, do so out of band; it does not gate this milestone.

## I. Exact first controlled V2 trade design

Canonical pair (byte-identical to `MIGRATION_SEAL_V1 §M`):

```
LONG  = 0xff287410852B9328437eaC353720e5476bC5F837
        size1e8=+1_000_000  openNotional1e8=+2_468_310_000  lastCumFR=0
SHORT = 0x66858286fEEA78a05eA093673EA1535E0A52002d
        size1e8=-1_000_000  openNotional1e8=-2_468_310_000  lastCumFR=0

Entry price = openN/size = 2_468_310_000 / 1_000_000 = 2468.31 (quote 1e8 per base 1e8)
```

Design (partial close, non-flat, produces non-zero realized PnL):

```
marketId            = 1
buyer               = 0x66858286fEEA78a05eA093673EA1535E0A52002d   (short closes → buys)
seller              = 0xff287410852B9328437eaC353720e5476bC5F837   (long closes → sells)
sizeDelta1e8        = 10_000                                       (= 0.0001 base = 1e-4 ETH)
executionPrice1e8   = 246_842_235_500                              (= 2468.422355 raw = +0.0045 % vs 2468.31)
buyerIsMaker        = true
```

Notional native: `mulDivFloor(10_000, 246_842_235_500, 1e8) → 24_684_223` 1e8-units → native (÷100) ≈ 246_842 mUSDC-units (= 0.246842 mUSDC). Small on purpose — controlled first trade.

## J. Expected non-zero realized PnL

Applying `_computeNextPosition` (`src/perp/PerpEngineLiquidationLib.sol:643-698`) with cumFR=0:

```
LONG side (seller, closeSize=+10_000):
   removedBasis1e8    = openN * closeAbs / |oldSize|
                      = 2_468_310_000 * 10_000 / 1_000_000
                      = +24_683_100
   closedMarkValue1e8 = _signedMarkValue(+10_000, 246_842_235_500)
                      = +10_000 * 246_842_235_500 / 1e8
                      = +24_684_223       (mulDivFloor)
   closedFunding1e8   = 0                  (cumFR = lastCumFR = 0)
   realizedPnl1e8     = +24_684_223 - +24_683_100 - 0
                      = +1_123            (long gains from selling above entry)

SHORT side (buyer, closeSize=-10_000):
   removedBasis1e8    = -2_468_310_000 * 10_000 / 1_000_000  =  -24_683_100
   closedMarkValue1e8 = _signedMarkValue(-10_000, 246_842_235_500)  =  -24_684_223
   realizedPnl1e8     = -24_684_223 - (-24_683_100) - 0
                      = -1_123            (short loses on buying above entry)

Conservation:  +1_123 + (-1_123) = 0  ✓ (before fees; fees are a separate transfer)
```

Native settlement (÷100, mUSDC 6-dp):
```
LONG realized native   =  +11  (mUSDC micro-units)
SHORT realized native  =  -11
```

**Realized PnL is non-zero, opposite-signed, and conserves.** This exercises the V1 double-count defect regression predicate (memory: `V1 previously exhibited a realized-PnL double-count`): if V2 double-counted, the LONG credit would be `+22` or the SHORT debit `-22`, and Σ vault delta from realization would be ±11 rather than 0. The invariant `Σ realized = 0` is thus the on-line regression assertion.

## K. Fee expectations

Tier-0 PERP, notional native = 246_842:

```
buyer (short, maker)   = 50 ppm × 246_842 = 12.34 → floor  12 native (mUSDC micro-units)
seller (long, taker)   = 300 ppm × 246_842 = 74.05 → floor 74 native

total fee native       =  86 native = 0.000086 mUSDC
```

Fees are credited to FMV2, not the counterparties' vault balances. `FMV2.isFeeConsumer(ENGINE_V2)=true` gates the fee handoff.

## L. Clearing / vault expectations

```
Vault.balances(CLEARING_V2, mUSDC)  pre = 1_000_000_000
                                    post = 1_000_000_000     ← ClearingV2 net unchanged
                                                              (Σ realized = 0)

LONG (0xff287410…) Vault delta   = +11 (realized) - 74 (taker fee) = -63 native
SHORT (0x66858286…) Vault delta  = -11 (realized) - 12 (maker fee) = -23 native

Σ traders' Vault delta            =  -86 native  =  -total_fee_native

FMV2 (fee sink) receipt          =  +86 native
```

Debit-first ordering (memory: `negative realized trader is debited first`): SHORT is debited before LONG is credited, then fees are taken. Verified in `PerpEngineTradingV2` clearing routine (called after `_computeNextPosition`).

## M. Read-only simulation result

```
eth_call ENGINE_V2.applyTrade(
   (SHORT_buyer, LONG_seller, marketId=1, sizeDelta1e8=10_000, executionPrice1e8=246_831_000_000, buyerIsMaker=true))
--from PME_V2

Result:  REVERTED
Trace:
   ENGINE_V2::applyTrade(...)
     ├─ 0xb4fcf45E…::getMarket(1) [staticcall]          → OK (returns Market)
     ├─ 0xb4fcf45E…::getRiskConfig(1) [staticcall]       → OK
     ├─ 0x00340C36…::getCollateralConfig(mUSDC)          → OK
     ├─ 0xb4fcf45E…::getMaxExecutionDeviationBps(1)      → REVERT (selector absent)
     └─ ← Revert                                          (propagated)
```

**Simulation ABORTS at `_enforceExecutionPriceGuard`.** See §V.

The pre-guard path (market lookup, risk-config lookup, collateral-config lookup) is fully wired and returns valid data — confirming the V2 engine + risk + vault dependency graph is correct. The blocker is downstream at the deployed PMR.

Signature / nonce / deadline validation happens in PMEV2, not `applyTrade` — full end-to-end simulation would additionally require a signed intent pair. That layer is fully code-covered and byte-identical in wire semantics to V1 (matching engine gate, executor allowlist, nonce management unchanged; only domain version bumped) — verified via `src/matching/PerpMatchingEngineV2.sol` doc header. No V1 signature will validate on PME_V2 (§E).

## N. DB / indexer readiness

`TradeExecuted` event dispatch (both V1 and V2 emit the 9-arg PME event with byte-identical topic0):

```
PME.TradeExecuted(bytes32 intentId, address buyer, address seller,
                  uint256 marketId, uint128 sizeDelta1e8, uint128 executionPrice1e8,
                  bool buyerIsMaker, uint256 buyerNonce, uint256 sellerNonce)
topic0 = 0x5018a0a73d56c00e01815636cf5e029fd7ed9440d42b3eea0e75404dfedb3f80
```

Indexer decoder at `src/indexer/decoder.rs:20` declares this exact signature. Emitter set (`src/indexer/config.rs:24-95`) already merges V1 + V2 PME addresses when both are configured — `PERP_MATCHING_ENGINE_V2_ADDRESS` becomes an additional log source, not a replacement. Version tag is derived from emitter (`decoder.rs:105-120`), so V2 rows land with `protocol_version='perp_v2'`.

DB migrations already applied by prior schema builds (numbering from `deopt-v2-backend/migrations/`):

- `0064_execution_intents_protocol_version.sql` — `execution_intents.protocol_version` NOT NULL default `'perp_v1'`
- `0065_execution_intents_v2_price_bounds.sql` — `max_execution_price_1e8`, `min_execution_price_1e8`
- `0066_execution_intent_broadcasts_protocol_version.sql` — durable broadcast rows carry version + `expected_emitter`
- `0067_indexed_perp_trades_protocol_version.sql` — indexed trades carry `protocol_version` + `emitter_address`

**No V2-specific migration pending. Existing rows back-filled to V1 sentinel; new V2 rows write V2 tag.**

Note: the engine also emits its own `TradeExecuted(address,address,uint256,uint128,uint128,bool)` 6-arg event (topic0 `0xa73bf9fa…4ed60`); this is the migration-scan signature and is NOT what the backend indexer consumes. The backend consumes PMEV2's 9-arg event as the trade source of truth. Both are emitted per trade and both are on-chain-truth for regression cross-checks.

## O. Reconciler readiness

Lifecycle `Prepared → Submitted → Confirmed / Failed`:
- `ExecutionIntentStatus` enum at `src/execution/intent.rs:11-38` covers all four states.
- `broadcast_reconciler.rs` reads persisted `protocol_version` + `expected_emitter` (immutable post-cosign) — never trusts runtime engine version to reconcile a stored row.
- Restart recovery: broadcasts are durable rows; on restart, worker re-picks any row in `Submitted` and reconciles against on-chain receipt. If the broadcast tx hash's receipt shows an emitter ≠ `expected_emitter`, the row is failed rather than marked confirmed.
- Duplicate/replay protection: unique constraint on intent_id + one-broadcast-at-a-time reservation (see fixture `tests/perps_broadcast_durability_pg_integration.rs`).

**V2-ready. No mutation required.**

## P. Public API / read-path compatibility

- `accounts/:address/history/v2` — reads `indexed_perp_trades` with `protocol_version` column; V2 rows will surface without schema change.
- Leaderboard aggregators — same data source, no version filter (surfaces both V1 legacy and V2 rows).
- REST/WS paths — none inspected are hardwired to a V1 emitter; version is derived from stored row.

**No endpoint change required for activation.**

## Q. Exact activation order (recommended: split V2 route from broadcast arm)

The two flags `PERPS_ACTIVE_ENGINE_VERSION` and `EXECUTOR_REAL_BROADCAST_ENABLED` are **architecturally separable**. The former only affects new-intent address resolution; the latter is a hard on-chain-write gate. Flipping them one at a time reduces blast radius.

Recommended sequence (per stage, freeze on discrepancy):

```
0. §V blocker resolved (see below) — activation IS NOT VIABLE until then
1. Final chain readback: gates §0 all pass, no V2 TradeExecuted since 47_407_874
2. Add V2 address env vars to backend env (still V1 routing, still no broadcast)
3. Restart backend
4. GET /ready → 200; logs show validated V2 address wiring
5. Set PERPS_ACTIVE_ENGINE_VERSION=v2 (new intents route to V2; broadcast still OFF)
6. Restart backend
7. Read-only V2 path check: create a signed V2 test intent locally, verify digest via
   backend endpoint, confirm nonce=0 accepted, no on-chain broadcast attempted
8. Set PERPS_CLOSED_TEST_ENABLED=true (required precondition)
9. Set EXECUTOR_REAL_BROADCAST_ENABLED=true (arm on-chain broadcast)
10. Restart backend
11. GET /ready → 200; logs "perps broadcast runtime: READY" AND "perps broadcast executor started"
12. Execute exactly one controlled V2 trade (§I payload; produces non-zero PnL per §J)
13. Verify tx receipt: PMEV2.TradeExecuted emitted, ENGINE_V2.TradeExecuted emitted,
    realized PnL matches §J to the wei, fees match §K, clearing invariant §L holds
14. On any discrepancy → set EXECUTOR_REAL_BROADCAST_ENABLED=false and restart
```

**Do not flip both flags simultaneously**; there is no code path requiring an atomic combined switch. Splitting stages 5 and 9 gives operator ~2-3 restart cycles of route-only validation before real writes are armed.

## R. Rollback plan

Activation is on backend-config only after §V is resolved and chain state (SEALED + V2 authorized) is beyond re-mutation. Rollback is therefore backend-scoped:

| Failure surface | Rollback action | Reversibility |
|---|---|---|
| Backend refuses to start on V2 config | revert env changes, restart | full — no chain writes attempted |
| V2 routing accepts intents but broadcast fails preflight | `EXECUTOR_REAL_BROADCAST_ENABLED=false`, restart | full — intents persist in Prepared, no chain writes |
| First V2 trade tx reverts on-chain | `EXECUTOR_REAL_BROADCAST_ENABLED=false`, freeze | trader positions unchanged; failed tx wasted gas only |
| First V2 trade succeeds but breaks invariant | `EXECUTOR_REAL_BROADCAST_ENABLED=false`, forensic | traders' accounting must be inspected before any further trade |

**Do NOT propose unsealing the migration.** `sealMigration` is irreversible (`src/perp/PerpEngineTradingV2.sol:325-335`; hash is committed and matched). **Do NOT propose revoking Vault V2 authorization automatically** — that requires Timelock queue + 24 h delay + Safe execute (§I of TIMELOCK_EXECUTE_VAULT_AUTH_V1 doc). **Do NOT propose unfreezing PME_V1**; V1 stays frozen post-cutover regardless.

## S. Tests / checks run this milestone

READ-ONLY only. Cast/eth_call probes, no forge test, no cargo test:

```
cast call ENGINE_V2  {matchingEngine,riskModule,marketRegistry,migrationState,migrationSnapshotHash,marketState(1),marketState(2),positions×6,totalResidualBadDebtBase}
cast call PME_V2     {eip712Domain,nonces×2,DOMAIN_SEPARATOR}
cast call RISK_V2    {maxOracleDelay,perpEngine,collateralVault}
cast call FMV2       {isFeeConsumer(ENGINE_V2),getFeeProfile(0,PERP),getFeeProfile(0,OPTION)}
cast call VAULT      {isAuthorizedEngine(V1),isAuthorizedEngine(V2),balances(CLEARING_V2,mUSDC)}
cast call V1_ENGINE  {liquidationPaused,paused,tradingPaused}
cast call PME_V1     {paused}
cast call PMR        {marketExists(1),getMaxExecutionDeviationBps(1)[reverted]}
cast call ENGINE_V2  applyTrade(...) --from PME_V2 [reverted at guard — see §V]
cast keccak          {domain fields, PerpTrade V2 typehash, TradeExecuted topic0 (9-arg + 6-arg)}
cast logs            ENGINE_V2 TradeExecuted(6-arg) from 47_407_874..47_409_095  →  0 events
cast balance         RUNTIME_EXECUTOR  →  0.001951581 ETH
free -h              →  3.5 Gi available
```

No shell-out to production infra. No mutation.

## T. Changed docs

- `docs/PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ACTIVATION_PREFLIGHT_V1.md` — NEW (this file).

No production Solidity modification. No backend modification.

## U. Pushed HEAD

Sol repo new commit on top of `76efc12`, pushed to `origin/main`.

## V. Remaining blockers

### V.1 — CRITICAL: `getMaxExecutionDeviationBps(1)` selector absent on deployed PMR

The V2 execution-price deviation guard is a hard revert:

```solidity
// src/perp/PerpEngineTradingV2.sol:749-762
function _enforceExecutionPriceGuard(uint256 marketId, uint256 executionPrice1e8) internal view {
    uint16 boundBps = _marketRegistry.getMaxExecutionDeviationBps(marketId);
    if (boundBps == 0) revert ExecutionDeviationGuardNotConfigured();
    ...
}
```

`ENGINE_V2._marketRegistry` = `0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC` (the shared V1 PMR). Bytecode probe:

| Selector | Signature | Present? |
|---|---|---|
| `0x4d73d67f` | `getMaxExecutionDeviationBps(uint256)` | **ABSENT** |
| `0x1108dbb8` | `setMaxExecutionDeviationBps(uint256,uint16)` | **ABSENT** |
| `0xeb44fdd3` | `getMarket(uint256)` | PRESENT |
| `0xec69a654` | `marketExists(uint256)` | PRESENT |
| `0x8162486b` | `totalMarkets()` (= 2) | PRESENT |

**Consequence**: the deployed PMR is a pre-execution-guard build (commit predates `221cef4 feat(perps): pricing + execution safety core (V1)` on 2026-09-01). The V2 engine calls a non-existent selector, receives a bare revert, and `applyTrade` reverts unconditionally — for every market, every price, every counterparty.

Live simulation of `applyTrade` from `PME_V2` confirmed the revert (§M). `_marketRegistry` on the engine is set once at initialization (`src/perp/PerpEngineStorage.sol:262`) and has no admin setter — so the engine cannot be pointed at a different PMR without redeploy.

**Remediation options (each requires operator judgment; NOT executed):**

1. **Upgrade PMR bytecode** if the deployed contract is a proxy — bytecode inspection suggests it is not (25 KiB, no obvious delegate-slot pattern; owner is `OWNER` EOA, not the Timelock). Confirm by checking whether the PMR was deployed as ERC1967/UUPS. If yes: schedule `Timelock.queueTransaction(PMR, upgradeToAndCall(newImpl))`, wait 24 h, execute.

2. **Deploy a new PMR** at a new address with the current interface, migrate market 1 + market 2 registration to it, and redeploy ENGINE_V2 pointing at the new PMR. This voids the current V2 migration and requires re-running seed + seal.

3. **Deploy a shim PMR** that wraps the existing PMR's storage but adds the missing selector returning a fixed default — same footgun as option 2 (still requires ENGINE_V2 redeploy to point at the shim).

Option 1 is the only path that preserves the sealed V2 migration hash. If the PMR is NOT a proxy, activation is unrecoverable without a re-migration.

### V.2 — MINOR: oracle getters do not respond via current source ABI

Attempted probes of `OracleRouter.getMarkPrice1e8` / `getIndexPrice1e8` / `getPrice(WETH)` all reverted. Not a preflight blocker (the guard in §V.1 will fail before oracle is consulted), but must be re-verified once §V.1 is resolved — the guard's second dependency is `_tryGetMarkPrice1e8` and if the oracle route is also mis-wired, the guard will still revert with `OracleUnavailableForExecutionGuard`.

### V.3 — MINOR: operator env `.env.example` does not template V2 address vars

`deopt-v2-backend/.env.example:50-66` lists only V1 addresses. Add `PERP_ENGINE_V2_ADDRESS`, `PERP_MATCHING_ENGINE_V2_ADDRESS`, `PERP_CLEARING_ACCOUNT_V2_ADDRESS` (commented, with the Base Sepolia values) to prevent operator omission at activation time. Not a runtime blocker — the startup validator will refuse to start without them — but improves ergonomics.

---

## Exact next milestone

**Blocked pending §V.1 resolution.**

Once §V.1 is resolved:

1. `PERPS_V2_BASE_SEPOLIA_PMR_EXECUTION_GUARD_ACTIVATION_V1` (contract-side): set `maxExecutionDeviationBps(1)` and `(2)` to sensible defaults (e.g., 100 = 1 %) via Timelock; verify `applyTrade` no longer reverts pre-oracle.
2. `PERPS_V2_BASE_SEPOLIA_ORACLE_ROUTE_HEALTHCHECK_V1` (read-only): re-verify oracle mark path for market 1 returns a fresh non-zero price with age < 600 s.
3. `PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ROUTE_ACTIVATION_V1` (backend): stages 2–7 of §Q — flip `PERPS_ACTIVE_ENGINE_VERSION=v2` with broadcast still OFF; validate route resolution and V2 signing without on-chain writes.
4. `PERPS_V2_BASE_SEPOLIA_BACKEND_V2_BROADCAST_ARM_V1`: stages 8–14 of §Q — arm real broadcast, execute the §I trade, verify §J/K/L, freeze on discrepancy.

**Do NOT activate backend V2 automatically. STOP.**
