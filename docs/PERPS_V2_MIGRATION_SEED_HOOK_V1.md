# PERPS_V2_MIGRATION_SEED_HOOK_V1

One-time V1 → V2 state-seeding mechanism for the deployed
`PerpEngine` (V1) → `PerpEngineV2` migration. Local-only in this
milestone. **NO deployment. NO Base Sepolia writes.**

Companion to:
- `docs/PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1.md` (V2 accounting model)
- `docs/PERPS_V2_CLEARING_ACCOUNT_CONTRACT_V1.md` (V2 clearing custody)

---

## 1. Storage inventory (§1)

Sources: `src/perp/PerpEngineStorage.sol`, `PerpEngineTypes.sol`.

### Class A — MUST migrate exactly (per-trader/per-market)

| Slot | Type | Comment |
|---|---|---|
| `_positions[trader][marketId]` | `Position { size1e8, openNotional1e8, lastCumulativeFundingRate1e18 }` | Full struct verbatim. |
| `_marketStates[marketId].cumulativeFundingRate1e18` | `int256` | Per-market funding baseline. |
| `_marketStates[marketId].lastFundingTimestamp` | `uint64` | Last funding update timestamp. |
| `_residualBadDebtBase[trader]` | `uint256` | Only if trader has residual bad debt. |

### Class B — deterministically reconstructible from A

| Slot | Reconstruction rule |
|---|---|
| `_marketStates[marketId].longOpenInterest1e8` | `Σ |size|` over traders with `size1e8 > 0` in that market. |
| `_marketStates[marketId].shortOpenInterest1e8` | `Σ |size|` over traders with `size1e8 < 0`. |
| `traderMarkets[trader]` | List of markets where `size1e8 != 0` for the trader. |
| `traderMarketIndexPlus1[trader][marketId]` | Index into `traderMarkets[trader]` for that market. |
| `totalAbsLongSize1e8[trader]` | Trader-side long aggregate. |
| `totalAbsShortSize1e8[trader]` | Trader-side short aggregate. |
| `totalResidualBadDebtBase` | Σ of per-trader residual bad debt. |

V2 recomputes all class-B fields inside `adminSeedPosition` by delegating
to V1's own `_syncPositionIndexing` and `_updateMarketOpenInterest`
helpers — the same helpers a real trade uses. Correctness is guaranteed
by construction.

### Class C — intentionally fresh in V2

| Slot | V2 baseline | Rationale |
|---|---|---|
| `PerpMatchingEngineV2.nonces[trader]` | 0 | EIP-712 domain "2" + new `verifyingContract` prevent V1 signature replay onto V2. See §14. |
| `intentFilled[hash]`, `intentNonceUsed[trader][nonce]` | 0 | Same domain-separation rationale. |

### Class D — irrelevant to position economics

Market configs (registry-owned), pause flags, oracle bindings, matching-
engine address, guardian address, `_impactMidSamples` (refreshed by
keeper). All handled by ordinary deployment `setXxx` sequence.

## 2. Migration invariant (§2)

For every migrated `(trader, marketId)`:

```
V2.size1e8                     == V1.size1e8
V2.openNotional1e8             == V1.openNotional1e8
V2.lastCumulativeFundingRate1e18 == V1.lastCumulativeFundingRate1e18
```

Per market:
```
V2.cumulativeFundingRate1e18 == V1.cumulativeFundingRate1e18
V2.lastFundingTimestamp      == V1.lastFundingTimestamp
```

Vault balances unchanged for every trader, every fee sink, and the
clearing account (the last is funded separately per §13). Migration
itself emits ZERO collateral transfer.

## 3. Funding baseline strategy (§3): STRATEGY A — exact snapshot

- Migrate `_marketStates.cumulativeFundingRate1e18` and
  `lastFundingTimestamp` exactly.
- Migrate each position's `lastCumulativeFundingRate1e18` exactly.

Rationale: this makes V2 look like it took a clean-copy snapshot at the
migration block. Any accrued-but-unrealized funding on migrated positions
after seal equals

```
Σ position_size · (market_cumulative_now − position_checkpoint)
```

identical to V1. No fake funding is created. Strategy B (rebaselining)
would require recalculating each position's checkpoint against a
normalized baseline, which is more complex and offers no benefit.

For the current Base Sepolia A/B state, funding is disabled — cumulative
and timestamp are zero — but the API remains correct generally.

## 4. Migration state machine (§4)

```
DEPLOYED / MIGRATION_OPEN                (default; enum state 0)
       │
       │ operator calls adminSeedPosition, adminSeedMarketFunding,
       │ adminSeedResidualBadDebt (all onlyOwner + onlyMigrationOpen)
       ▼
seed complete
       │
       │ operator calls sealMigration(snapshotHash) (onlyOwner)
       ▼
MIGRATION_SEALED / NORMAL_OPERATION      (enum state 1; irreversible)
```

Enforced in `PerpEngineTradingV2.sol`:
- `migrationState` (`enum MigrationState { OPEN, SEALED }`) default = OPEN.
- `onlyMigrationOpen` modifier gates all `adminSeed*` calls.
- `onlyMigrationSealed` modifier gates `applyTrade`, `liquidate`,
  and `updateFunding`.

**No `unsealMigration` function exists.** Reopen guesses
(`unsealMigration`, `reopenMigration`, `resetMigration`) tested and
proven to revert (test `testACL_12_MigrationCannotReopen`).

## 5. Trade / liquidation / funding gate (§5)

- `applyTrade` modifier chain: `onlyMigrationSealed`, `onlyMatchingEngine`, `whenTradingNotPaused`, `nonReentrant`.
- `liquidate` modifier chain: `onlyMigrationSealed`, `whenLiquidationNotPaused`, `nonReentrant`.
- `updateFunding` modifier chain: `onlyMigrationSealed`, `whenFundingNotPaused`.

Before seal: every ordinary position-mutating path reverts with
`MigrationNotSealed()`. Verified by:
- `testACL_06_TradingBeforeSealRejected`
- `testACL_07_LiquidationBeforeSealRejected`
- `testFuzz_BeforeSealNoTradingWriteSucceeds`

## 6. Seed APIs (§6)

```solidity
function adminSeedPosition(
    address trader,
    uint256 marketId,
    int256 size1e8,
    int256 openNotional1e8,
    int256 lastCumulativeFundingRate1e18
) external onlyOwner onlyMigrationOpen;

function adminSeedMarketFunding(
    uint256 marketId,
    int256 cumulativeFundingRate1e18,
    uint64 lastFundingTimestamp
) external onlyOwner onlyMigrationOpen;

function adminSeedResidualBadDebt(
    address trader,
    uint256 amountBase
) external onlyOwner onlyMigrationOpen;

function sealMigration(bytes32 snapshotHash) external onlyOwner onlyMigrationOpen;
```

Rejections:
- `MigrationAlreadySealed` — called after seal.
- `NotAuthorized` — non-owner caller.
- `ZeroAddress` — trader / market-related zero.
- `UnknownMarket` — unknown marketId.
- `MigrationInvalidSize` — `size1e8 == 0`.
- `MigrationInvalidBasisSign` — sign(openNotional) ≠ sign(size).
- `MigrationPositionAlreadySeeded(trader, marketId)` — duplicate.
- `MigrationMarketFundingAlreadySeeded(marketId)` — duplicate.
- `MigrationResidualBadDebtAlreadySeeded(trader)` — duplicate.

## 7. Derived state (§7)

`adminSeedPosition` reuses two existing V1 helpers:

- `_syncPositionIndexing(trader, marketId, 0, size)` — populates
  `traderMarkets[trader]`, `traderMarketIndexPlus1[trader][marketId]`,
  `totalAbsLongSize1e8[trader]`, `totalAbsShortSize1e8[trader]`.
- `_updateMarketOpenInterest(marketId, 0, size)` — populates
  `_marketStates[marketId].longOpenInterest1e8` and
  `.shortOpenInterest1e8`.

Because these are the same helpers a real trade uses, class-B state is
guaranteed consistent by construction. No separate OI setter, no
post-seal reconstruction pass required.

## 8. OI semantics (§8)

V1 definition (from `_updateMarketOpenInterest`):
```
longOpenInterest1e8  = Σ size_i for size_i > 0
shortOpenInterest1e8 = Σ |size_i| for size_i < 0
```

Not `max(long, short)`, not `sum(abs)`. The engine's launch/cap
enforcement uses `_effectiveMarketOpenInterest1e8 = max(long, short)`.

Deterministic tests:
- `testEcon_F_MultipleTradersSameMarket` — long/short with different sizes.
- `testEcon_I_AggregateOIReconstructionExact` — multi-trader asymmetric.
- `testFuzz_OIExactAcrossMultipleSeeds` — 256 fuzz iterations across 3 traders.

Zero positions are never seeded (`MigrationInvalidSize`), so they never
contribute to OI.

## 9. Snapshot manifest / commitment (§9)

`sealMigration(bytes32 snapshotHash)` stores the hash on-chain
(`migrationSnapshotHash` public) and emits `MigrationSealed(snapshotHash,
sealer)`. The `snapshotHash` MUST be `keccak256` of a canonical
off-chain manifest containing at minimum:

```
chainId
V1 engine address
V1 clearing / vault / matching-engine / market-registry addresses
snapshot block number
list of (trader, marketId, size1e8, openNotional1e8, lastCumulativeFundingRate1e18)
list of (marketId, cumulativeFundingRate1e18, lastFundingTimestamp)
list of (trader, residualBadDebtBase) if any
Vault trader balance list
fee-sink balance
clearing-address vault balance at snapshot time
```

**On-chain enforcement is limited to non-zero hash presence.** Manifest
correctness itself is verified off-chain by auditors, since the raw
manifest is too large for on-chain replay. The manifest is committed to
the sealed hash so any future auditor can prove `keccak256(manifest) ==
migrationSnapshotHash()` and hence prove seeding matches.

Deterministic tests:
- `testHash_CommittedAtSeal` — hash stored + event emitted.
- `testHash_ZeroRejected` — `MigrationSnapshotHashZero`.
- `testHash_SensitivityToCanonicalFields` — mutating any manifest field
  changes the hash (pairwise inequality across 4 variants).

## 10. Seal validation (§10)

Seal preconditions checked on-chain:
- `snapshotHash != 0` → `MigrationSnapshotHashZero`
- `clearingAccount != 0` → `MigrationClearingNotConfigured`
- `matchingEngine != 0` → `MigrationMatchingEngineNotConfigured`
- `address(_riskModule) != 0` → `MigrationRiskModuleNotConfigured`

Consistency guaranteed by construction (not seal-time re-checked):
- OI consistency (§7).
- Position uniqueness (`_positionSeeded` map).
- Entry-basis sign coherence (`MigrationInvalidBasisSign`).

Explicitly NOT checked at seal (out of scope of the engine):
- Vault authorization of the engine (a vault-owner action).
- Clearing floor liquidity (off-chain solvency policy).
- Off-chain manifest correctness (auditors verify).

Fuzz-tested precondition rejections:
- `testSeal_RequiresMatchingEngine`
- `testSeal_RequiresRiskModule`
- `testClearing_MustBeSetBeforeSeal`

## 11. Entry-basis invariants (§11)

For every non-zero migrated position:
- `size1e8 > 0` ⇒ `openNotional1e8 > 0` (long has positive basis)
- `size1e8 < 0` ⇒ `openNotional1e8 < 0` (short has negative basis)

Violations revert `MigrationInvalidBasisSign`. Tests:
- `testInvariant_LongWithNegativeBasisRejected`
- `testInvariant_ShortWithPositiveBasisRejected`
- `testInvariant_ZeroSizeRejected`

For the current Base Sepolia A/B state:
- A: `size = +1_000_000`, `openNotional = +2_468_310_000`
- B: `size = -1_000_000`, `openNotional = -2_468_310_000`
- funding checkpoint: 0 (funding disabled)

## 12. Collateral no movement (§12)

Verified by:
- `testEcon_J_CollateralUnchangedByMigration` — direct pre/post assertion.
- `testEcon_K_FeeSinkUnchanged` — fee sink not touched.
- `testEcon_L_ClearingUnchangedByMigration` — clearing balance not
  touched by seeding (only by the separate `fundClearing` call).
- `testFuzz_SeedingNeverMovesVault` — 256 iterations.

Migration paths emit NO `Deposited`, `Withdrawn`, `InternalTransfer`,
or `TradeExecuted` event. Only migration-specific events
(`MigrationPositionSeeded`, `MigrationMarketFundingSeeded`,
`MigrationResidualBadDebtSeeded`, `MigrationSealed`).

## 13. Clearing seeding is separate (§13)

The migration surface has no clearing-funding path. Clearing liquidity
is funded via the already-proven `PerpClearingAccountV2.fundClearing()`
before, during, or after seeding — completely orthogonal to position
migration.

Recommended future ordering:
```
setClearingAccount(clearing)
[optional: fundClearing()]
adminSeedPosition(...)  × N
adminSeedMarketFunding(...) × M
adminSeedResidualBadDebt(...) × K
fundClearing()  # target floor before seal
sealMigration(snapshotHash)
```

`fundClearing` is unaffected by migration state — it's a
`PerpClearingAccountV2` method, not a `PerpEngineV2` method.

## 14. V2 matching nonces (§14): FRESH AT ZERO

V2 `PerpMatchingEngineV2.nonces[trader]` starts at 0.

**Safety proof of no replay across versions:**

- V1 domain: `EIP712("DeOptV2-PerpMatchingEngine", "1")` +
  V1 `verifyingContract`.
- V2 domain: `EIP712("DeOptV2-PerpMatchingEngine", "2")` +
  V2 `verifyingContract` (fresh address).
- `keccak256(EIP712Domain type + name + version + chainId +
  verifyingContract)` differs across V1/V2 both in `version` and
  `verifyingContract`.
- A V1 signature therefore never recovers the correct signer against a
  V2-computed digest, and vice versa.
- The V2 nonce mapping is independent of the V1 nonce mapping (different
  contract, different storage) — no relationship needed.

Cosmetic continuity is not a safety property; adding a
`migrateNonce` path would only introduce failure modes without benefit.

Test `testSignatureReplayAcrossVersionsIsRejected` (from prior milestone)
proves the replay path is closed.

## 15. Migration events (§15)

Events emitted only by migration paths (never by ordinary trading paths,
and vice versa):

- `MigrationPositionSeeded(trader, marketId, size1e8, openNotional1e8, lastCumulativeFundingRate1e18)`
- `MigrationMarketFundingSeeded(marketId, cumulativeFundingRate1e18, lastFundingTimestamp)`
- `MigrationResidualBadDebtSeeded(trader, amountBase)`
- `MigrationSealed(snapshotHash, sealer)`

Migration does NOT emit:
- `TradeExecuted` (that would misclassify migration as a trade)
- `Deposited` / `Withdrawn` / `InternalTransfer`
- `FundingUpdated` (that would misclassify a snapshot as an update)

## 16-19. Test coverage

| Section | Tests | Location | Result |
|---|---|---|---|
| §16 access control | 13 | `test/perp/PerpEngineV2Migration.t.sol` | 13/13 PASS |
| §17 economic | 12 (A–L; C in §18) | same | 12/12 PASS |
| §18 post-migration close regression | 1 (Base-Sepolia A/B → 244_274) | same | PASS |
| §19 snapshot hash | 3 | same | 3/3 PASS |
| §11 entry-basis + §10 seal preconds | 5 | same | 5/5 PASS |
| §20 migration fuzz | 7 (256 runs each) | `test/fuzz/perp/PerpEngineV2MigrationFuzz.t.sol` | 7/7 PASS |

## 20. Fuzz / invariants (§20)

Independent reference math (`RefMigF` in the fuzz file) — the invariant
oracle. Coverage:

1. Seeded position equals supplied fields exactly.
2. Aggregate OI equals reconstruction across multiple seeds.
3. Seeding never changes Vault balances.
4. Duplicate seed impossible.
5. After seal no migration write succeeds.
6. Before seal no trading write succeeds.
7. Funding continuity via checkpoint + market cum preservation (implicit
   in Base-Sepolia and cashflow suites).
8. Migration + close vault deltas equal native (open + close) vault
   deltas — proven with two independent engine deployments.

## 21. Full regression

Confirmed in commit CI:
- V2 cashflow: **24/24 PASS**
- V2 clearing security: **19/19 PASS**
- V2 cashflow fuzz: **7/7 PASS**
- V2 matching domain: **3/3 PASS**
- V2 migration: **33/33 PASS**
- V2 migration fuzz: **7/7 PASS**
- Full Solidity suite: see verdict.

## 22. Future Base Sepolia migration runbook (§22)

**NO execution here — reference sequence only.**

Preconditions:
- V1 engine at `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c`, V1 PME at
  `0x774d96E5739bffadEE91508b4D3D74F5BE29F165`, CollateralVault at
  `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3`, FeesManagerV2 at
  `0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f`, mUSDC at
  `0x6eAe407f5640B006faC9965182e238582A3B412E`, PerpMarketRegistry at
  `0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC`.
- Backend has NO in-flight V1 intents. V1 is frozen (paused +
  close-only).

Sequence:

1. **Choose snapshot block.** Latest finalized block on Base Sepolia.
   Record `blockNumber`.
2. **Freeze V1.** `PerpEngine.setPaused(true)` (or matching-engine level
   `setPaused(true)`); confirm `applyTrade` reverts.
3. **Confirm no in-flight V1 settlement.** Backend has zero
   `list_broadcastable_execution_intents()` rows. All intents at
   `confirmed` or `abandoned`.
4. **Snapshot V1 authoritative state at the chosen block.** For every
   trader in the closed test (A, B), read
   `V1.positions(trader, marketId)` and record. Read
   `V1.marketState(marketId)` for each market. Read
   `V1.getResidualBadDebt(trader)`. Read `CollateralVault.balances(...)`
   for every trader and the fee sink.
5. **Compute canonical manifest.** Deterministic serialization of all
   snapshot data. `snapshotHash = keccak256(manifest)`. Publish the
   manifest to an auditable public location (git or IPFS).
6. **Deploy `PerpClearingAccountV2(vault)`.** Broadcast + verify.
7. **Deploy `PerpEngineV2(owner, registry, vault, oracle)`.**
   Broadcast + verify.
8. **Deploy `PerpMatchingEngineV2(owner, engineV2)`.** Broadcast + verify.
9. **Configure V2 engine dependencies.** Owner (via Safe or governance)
   calls: `setMatchingEngine(pmeV2)`, `setRiskModule(riskModule)`,
   `setFeesManagerV2(feesManagerV2)`, `setInsuranceFund(...)` (optional),
   `setClearingAccount(clearingV2)`.
10. **Authorize V2 on the Vault.**
    `Vault.setAuthorizedEngine(engineV2, true)`. **V1 remains
    authorized here** — this is the temporary dual-auth window.
11. **Fund clearing to target floor.** Governance:
    `mUSDC.approve(clearingV2, floor)`,
    `clearingV2.fundClearing(mUSDC, floor)`.
    For the current A/B state, aggregate PnL asymmetry is zero; a small
    floor (e.g. 1_000 mUSDC) is sufficient for the closing trade's
    rounding-dust cushion. Set higher for future exposure.
12. **Seed market funding state.** For each active market:
    `engineV2.adminSeedMarketFunding(marketId, cumRate, lastTs)`.
    For A/B market 1: `(0, 0)`.
13. **Seed positions.** For A/B closed test:
    - `adminSeedPosition(A, 1, +1_000_000, +2_468_310_000, 0)`
    - `adminSeedPosition(B, 1, −1_000_000, −2_468_310_000, 0)`
14. **Independently verify V2 state vs snapshot.** Read
    `engineV2.positions(trader, marketId)` and
    `engineV2.marketState(marketId)` and confirm they match the
    manifest byte-for-byte.
15. **Seal migration with snapshot commitment.**
    `engineV2.sealMigration(snapshotHash)`. Emits `MigrationSealed`.
16. **Revoke V1 Vault engine authority.**
    `Vault.setAuthorizedEngine(engineV1, false)`. This is the moment
    V1 can no longer mutate any Vault balance.
17. **Verify V1 lockout.** Attempt a synthetic V1 `applyTrade` via a
    read-only call — expect `NotAuthorized`.
18. **Enable V2 normal settlement.** Backend switches signer domain
    to V2 (matching-engine address, EIP-712 version "2"). Backend also
    ensures V1 is unreachable from the routing layer.
19. **Only then** create a new V2 close intent — e.g. the delayed
    mutual close of A/B at the intended exit price.

**Ordering invariants:**
- Step 2 (V1 frozen) MUST precede any Vault authorization change.
- Step 15 (seal V2) MUST precede step 16 (revoke V1 auth).
- Step 16 (revoke V1) MUST precede step 18 (enable V2 routing) if V1
  routing was ever live post-freeze.
- Between steps 10 and 16 both engines are Vault-authorized. During
  that window, V1 must remain paused/frozen — this is the required
  concurrency invariant.

**NEVER allow V1 and V2 to accept live trades on the same market at
the same time.**

## 23. Informational A/B future seed payload (§23)

**Read-only recording of the current live state; do not execute now.**

Snapshot block (informational): latest at time of this milestone commit.

```
Chain:       Base Sepolia (84532)
Engine V1:   0xc6C592100723Fe0C66343A16e95eC34cC0c2141c
PME V1:      0x774d96E5739bffadEE91508b4D3D74F5BE29F165
Vault:       0x00340C360353a5AB784c5Bc5c44322A6AF0625D3
Registry:    0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC
mUSDC:       0x6eAe407f5640B006faC9965182e238582A3B412E
FeesManager: 0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f

Position A (0xff287410852B9328437eaC353720e5476bC5F837):
  marketId:                        1
  size1e8:                        +1_000_000
  openNotional1e8:                +2_468_310_000
  lastCumulativeFundingRate1e18:   0

Position B (0x66858286fEEA78a05eA093673EA1535E0A52002d):
  marketId:                        1
  size1e8:                        -1_000_000
  openNotional1e8:                -2_468_310_000
  lastCumulativeFundingRate1e18:   0

Market 1 funding:
  cumulativeFundingRate1e18:       0
  lastFundingTimestamp:            0        (funding disabled in closed test)

Aggregate OI market 1 (reconstructed at seal):
  longOpenInterest1e8:             1_000_000
  shortOpenInterest1e8:            1_000_000
  effectiveOpenInterest1e8:        1_000_000 (max)

Vault balances at snapshot (informational, DO NOT SEED — Vault is shared):
  A:        9_992_595
  B:        9_998_765
  fee sink: 8_684
  clearing: 0 (nothing deployed yet)

PME V1 nonces:
  A: 1
  B: 1
```

Note: this seed payload MUST be re-read at actual migration time.
Values recorded here are frozen at this milestone's commit time and may
drift if any unforeseen activity occurs on V1 before the real migration.

## 24. Backend implementation (§24)

**Backend NOT updated in this milestone.** Backend remains at
`a35954d0c5f8e109b4862f93d96d8456a6c97e88`. No contract addresses
changed; no ABI regeneration performed. When V2 is deployed to Base
Sepolia (future milestone), backend will get:
- Regenerated V2 ABI bindings for `PerpEngineV2`,
  `PerpMatchingEngineV2`, `PerpClearingAccountV2`.
- Config for the V2 addresses.
- EIP-712 domain "2" for V2 signing.
- Existing V1 configuration kept as read-only historical context.

## 25. Follow-up milestones

- `PERPS_V2_BASE_SEPOLIA_DEPLOY_V1` — execute §22 runbook on Base
  Sepolia. Deploy V2 contracts, seed A/B, seal, revoke V1.
- `PERPS_V2_BASE_SEPOLIA_MUTUAL_CLOSE_V1` — first real V2 mutual-close
  intent for the A/B positions, reproducing the 244_274 mUSDC transfer
  live.
- `PERPS_V2_MAINNET_READINESS_AUDIT_V1` — external audit gate before
  any mainnet exposure.
