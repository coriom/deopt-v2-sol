# PERPS V2 BASE SEPOLIA DEPLOYMENT PREFLIGHT V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_DEPLOYMENT_PREFLIGHT_V1_RESUME`
**Status**: PRE-STAGE DEPLOYMENT READY
**Sol HEAD**: `004bf78c32b2b5210cd7daabef2685cd461aeec7`
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee`
**Base Sepolia chainId**: 84532 (block ≥47_143_108 at freeze time)

Prior blocker: PerpEngineV2 runtime = 28,027 bytes > EIP-170 24,576.
Milestone D (`004bf78`) reduced it to **24,321 bytes** — margin **255 bytes**.
Blocker: **CLOSED**.

---

## A. Live Base Sepolia revalidation

| Contract | Address | Runtime bytes | Owner | Notes |
|---|---|---:|---|---|
| V1 PerpEngine | `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` | 23_794 | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (EOA admin) | fully operational |
| V1 PME | `0x774d96E5739bffadEE91508b4D3D74F5BE29F165` | 7_102 | — | wired to V1 engine |
| PerpMarketRegistry | `0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC` | 12_521 | `0xc35F7A8A…` | `nextMarketId=3`; markets 1 (ETH-PERP), 2 (BTC-PERP) live |
| OracleRouter | `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` | 6_982 | — | shared |
| V1 PerpRiskModule | `0xf1b46040147632d0b46A2153cC842506b4D7fEe5` | 9_894 | — | bound to V1 engine; keep |
| CollateralVault | `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` | 15_664 | ProtocolTimelock | `isAuthorizedEngine(V1)=true` |
| mUSDC | `0x6eAe407f5640B006faC9965182e238582A3B412E` | 1_924 | — | base collateral |
| ProtocolTimelock | `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` | 4_228 | OPS Safe | `GRACE_PERIOD=1_209_600 s` (14 d); custom impl, `getMinDelay()/delay()` revert — inspect via storage / on-chain source |
| OPS Safe | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` | 171 | 3 owners, threshold 2, Safe v1.4.1 |
| Executor (EOA) | `0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8` | 0 | backend runtime signer; balance 0.00195 ETH — **top up before broadcast** |
| InsuranceFund | `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` | 9_880 | shared | reuse for V2 |
| CollateralSeizer | `0x39F928b959cF58369E7C7a3B925e6cBfFA62B669` | 6_432 | shared | reuse for V2 |
| FeesManagerV2 (deployed) | `0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f` | 6_204 | `0xc35F7A8A…` | `feeRecipient=Timelock`; `isFeeConsumer(V1)=true`; **reuse** |
| FeesManagerV1 | `0xaef73F10224712E1312963BE11662061481aA0F0` | 7_808 | — | still wired to V1 engine, but `useFeesManagerV2=true` so unused |

V1 engine emergency flags: `paused=false`, `tradingPaused=false`, `liquidationPaused=false`, `fundingPaused=false`, `collateralOpsPaused=false`.
Registry `paused=false`. `useFeesManagerV2=true` on V1 already — V2 fee path is live under V1.

Legacy V1 liquidation defaults (source-default values, no governance override applied): `closeFactor=5000` (50 %), `penalty=500` (5 %), `spread=100` (1 %), `minImprovement=50`, `oracleMaxDelay=60 s`.

## B. Closed EIP-170 blocker proof

Standard-Anvil (EIP-170 enforced) deployment of Sol `004bf78` artifacts succeeded without `--disable-code-size-limit`:

- PerpEngineSeizureLib   runtime **3_628 B** — sha256 `073213309581dbbe903ac9ac7d4f3ed4bd5dd6271de609f3dd7a55c068f283e8`
- PerpEngineLiquidationLib runtime **6_148 B** — sha256 `ef7db60ab365ba70d6cf79b480d3d96e2fa1385005cc88a360138304c1704bd4`
- PerpEngineV2 (linked)   runtime **24_321 B** — sha256 `22ab402c0b1e0a3769275a7b95ac3ef9f664ede490db3d44f6365c5ab52921ad`

EIP-170 margin: **255 bytes**.

**Invariant**: any Solidity production source change after `004bf78` automatically invalidates this preflight and requires: full `forge build --sizes` + standard-Anvil deploy + on-chain `eth_getCode` size verification + rehashing. No exception.

## C. Final frozen artifacts (Sol HEAD `004bf78`)

Compiler: `solc 0.8.30`, `optimizer=true`, `optimizer_runs=0`, `via_ir=true`, `bytecode_hash=none`, `cbor_metadata=false`.

| Contract | Source path | creation B | runtime B | linkReferences |
|---|---|---:|---:|---|
| PerpEngineSeizureLib | `src/perp/PerpEngineSeizureLib.sol` | 3_661 | 3_628 | — |
| PerpEngineLiquidationLib | `src/perp/PerpEngineLiquidationLib.sol` | 6_180 | 6_148 | Seize |
| PerpEngineV2 | `src/perp/PerpEngineV2.sol` | 25_061 | 24_321 | Liq + Seize |
| PerpMatchingEngineV2 | `src/matching/PerpMatchingEngineV2.sol` | 11_885 | 10_441 | — |
| PerpClearingAccountV2 | `src/perp/PerpClearingAccountV2.sol` | 1_315 | 1_159 | — |
| PerpRiskModule (fresh V2 instance) | `src/perp/PerpRiskModule.sol` | 10_537 | 9_894 | — |
| FeesManagerV2 | `src/fees/FeesManagerV2.sol` | 9_207 | 6_727 | — (source drift vs deployed 6_204 B — do not redeploy) |

**Constructor ABIs** (fresh V2 deploys only):

- `PerpEngineV2(address owner_, address registry_, address vault_, address oracle_)`
- `PerpMatchingEngineV2(address owner_, address engine_)` — EIP712 domain: name `DeOptV2-PerpMatchingEngine`, version `2`
- `PerpClearingAccountV2(address vault_)`
- `PerpRiskModule(address owner_, address vault_, address perpEngine_, address oracle_, address baseCollateralToken_)`

**Engine link-reference positions** (unlinked artifact identity):
- creation code: LiquidationLib @ [3060, 3507, 4221], SeizureLib @ [3331, 23129, 24532]
- deployed code: LiquidationLib @ [2352, 2799, 3513], SeizureLib @ [2623, 22421, 23824]

Length substitution must leave runtime = 24_321 B exactly; any drift → STOP.

## D. Library dependency / link graph

```
PerpEngineSeizureLib          (no deps)
        ↑
PerpEngineLiquidationLib      links → SeizureLib
        ↑
PerpEngineV2                  links → LiquidationLib, SeizureLib
```

Both libs are independently linked into `PerpEngineV2` (SeizureLib is _also_ referenced by LiquidationLib, but the engine references SeizureLib directly too, so it must appear in the engine's `--libraries` list on its own).

`forge create` invocation shape:

```
forge create src/perp/PerpEngineSeizureLib.sol:PerpEngineSeizureLib ...
forge create src/perp/PerpEngineLiquidationLib.sol:PerpEngineLiquidationLib \
    --libraries src/perp/PerpEngineSeizureLib.sol:PerpEngineSeizureLib:<SEIZE_ADDR> ...
forge create src/perp/PerpEngineV2.sol:PerpEngineV2 \
    --libraries src/perp/PerpEngineSeizureLib.sol:PerpEngineSeizureLib:<SEIZE_ADDR> \
    --libraries src/perp/PerpEngineLiquidationLib.sol:PerpEngineLiquidationLib:<LIQ_ADDR> \
    --constructor-args <OWNER> <REGISTRY> <VAULT> <ORACLE> ...
```

## E. Exact fresh-deploy graph (order-constrained)

| # | Contract | Deps | Constructor args |
|---|---|---|---|
| 1 | PerpEngineSeizureLib | — | — |
| 2 | PerpEngineLiquidationLib | (1) linked | — |
| 3 | PerpEngineV2 | (1),(2) linked | `OWNER, PerpMarketRegistry=0xb4fc…7eC, CollateralVault=0x0034…5D3, OracleRouter=0xB416…581` |
| 4 | PerpMatchingEngineV2 | (3) | `OWNER, engine=(3)` |
| 5 | PerpRiskModule (V2 dedicated) | (3) | `OWNER, vault=0x0034…5D3, perpEngine=(3), oracle=0xB416…581, baseCollateralToken=mUSDC 0x6eAe…12E` |
| 6 | PerpClearingAccountV2 | — | `vault=0x0034…5D3` |

`OWNER` = `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (EOA admin; matches V1 engine owner, matches FMV2 owner, matches Registry owner). Direct EOA ownership keeps parity with the existing testnet posture; do NOT hand engine to Timelock at construction unless operator decides to shift the entire perp control surface.

**Reused** (no fresh deploy): CollateralVault, mUSDC, PerpMarketRegistry, OracleRouter, ProtocolTimelock, OPS Safe, EXECUTOR, InsuranceFund `0x009f…7500`, CollateralSeizer `0x39F9…8669`, FeesManagerV2 `0x00dA…774f`, V1 PerpEngine, V1 PME, V1 PerpRiskModule.

## F. V2 admin ABI audit vs scripts

Milestone D removed 15 selectors from V2:
`feesManager`, `feeRecipient`, `paused`, `liquidationCloseFactorBps`, `liquidationPenaltyBps`, `liquidationPriceSpreadBps`, `minLiquidationImprovementBps`, `liquidationOracleMaxDelay`, `setFeesManager`, `setLiquidationParams(4-arg)`, `getRiskMarkPrice1e8`, `recordResidualBadDebt`, `reduceResidualBadDebt`, `clearResidualBadDebt`, `repayResidualBadDebt`.

Script sweep results:

- `script/DeployPerpsE2E.s.sol` — targets V2 (`new PerpEngineV2`); calls only V2-preserved selectors (`setMatchingEngine`, `setRiskModule`, `setClearingAccount`, `adminSeedMarketFunding`, `adminSeedPosition`, `sealMigration`). ✓ safe.
- `script/RewirePerpEngineV2.s.sol` — declares `PerpEngine` (V1 type) but semantically for a V2 rewire; only touches `useFeesManagerV2`, `feesManagerV2`, `owner`, `marketRegistry`, `marketState`, `totalResidualBadDebtBase`, `tradingPaused` — all V2-preserved. ✓ safe.
- `script/DeployPerpEngineV2.s.sol` — misleadingly named, imports **V1** `PerpEngine`. Calls `engine.setFeesManager(...)` + `engine.feesManager()` which V2 no longer exposes. This script is a V1-shape deploy path and MUST NOT be used to deploy V2. Do not modify (code freeze); the real V2 deploy will be `forge create` invocations per §D.
- `script/WireCore.s.sol` — V1-typed; `perp.setFeesManager(...)` — V1-only; not applicable to V2.
- `script/SmokeV1PerpOnNew.s.sol` — V1 smoke path; `engine.feesManager()` — V1 typed. Not for V2.

Runbook implication: **do not reuse `DeployPerpEngineV2.s.sol` / `WireCore.s.sol` / `SmokeV1PerpOnNew.s.sol` against the V2 address**. Use `forge create` + `cast send` for §L PRE-STAGE actions.

## G. Final fee configuration

FMV2 (`0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f`) is REUSED. Current live state:

- owner `0xc35F7A8A…` (EOA)
- `feeRecipient=Timelock 0xa67f…b588`
- `isFeeConsumer(V1_ENGINE)=true` — must stay true through cutover
- launch schedule (target): perp maker 50 ppm, taker 300 ppm — confirm at cutover, not now

New V2 engine must be added as a fee consumer BEFORE `setUseFeesManagerV2(true)` is called on it. Owner-authorized:

```
FMV2.setFeeConsumer(ENGINE_V2, true)
```

Then on the engine (owner-authorized):

```
ENGINE_V2.setFeesManagerV2(FMV2)
ENGINE_V2.setUseFeesManagerV2(true)
```

`ENGINE_V2.setFeesManager(...)` does not exist — do not add legacy V1 pointer wiring.

## H. FeeChargedV2 backend indexer status

**FEECHARGED_V2_INDEXER_READY** — backend HEAD `ad8dd7466` includes:

- `src/fees/onchain_summary.rs` — parses `FeeChargedV2` (positive) + `FeeRebatedV2`, extracts `productKind`, `flowKind`
- `src/fees/perp_consumer.rs` — perp-specific consumer classifier emitting `deopt_perp_fee_charged_v2_total{consumer}`
- V1/V2 fee flow already wired for options and perps

No backend milestone required before Engine V2 PRE-STAGE deployment or FIRST V2 TRADE for fee observability.

## I. Oracle-delay policy

V1 engine live values (source defaults, never overridden by governance):

- `liquidationOracleMaxDelay = 60 s` (engine-level fallback)
- Per-market registry `RiskConfig` / `LiquidationConfig` — must be checked at cutover for market 1 (ETH-PERP), market 2 (BTC-PERP) via `PerpMarketRegistry.getLiquidationConfig(marketId)`

V2 engine defaults to the same `60 s` at construction (`_liquidationOracleMaxDelay = 60`, private storage). V2 exposes NO external `setLiquidationParams(...)`; per-market overrides live on `PerpMarketRegistry` and are shared with V1 (no change).

**OPERATOR_DECISION_REQUIRED**: confirm the V2 dedicated PerpRiskModule's oracle-freshness policy (its own `setOracleMaxDelay` or equivalent). Do not blindly reuse V1 risk-module defaults — read V1 PerpRiskModule setters at cutover time and mirror them explicitly on V2 risk module.

## J. Owner / guardian matrix

| Contract | Constructor owner | Final owner (post-PRE-STAGE) | Guardian | Notes |
|---|---|---|---|---|
| PerpEngineV2 | `0xc35F7A8A…` EOA | same | `0xc35F7A8A…` (mirror V1) | matches V1 posture |
| PerpMatchingEngineV2 | `0xc35F7A8A…` | same | — | |
| PerpClearingAccountV2 | (no owner constructor; only vault) | — | — | vault-scoped |
| PerpRiskModule V2 | `0xc35F7A8A…` | same | — | |
| FMV2 (reused) | `0xc35F7A8A…` | unchanged | unchanged | |
| CollateralVault (reused) | Timelock | unchanged | — | Timelock-only ops |
| PerpMarketRegistry (reused) | `0xc35F7A8A…` | unchanged | — | |

Executor `0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8` remains the backend runtime signer. Fee consumer role on FMV2 must be granted to ENGINE_V2 explicitly (see §G).

## K. Vault authorization strategy

`CollateralVault.setAuthorizedEngine(ENGINE_V2, true)` requires `msg.sender == Timelock`. Timelock is Safe-owned (2/3). This is a **CUTOVER** action, not PRE-STAGE:

- PRE-STAGE: V2 engine deployed but not vault-authorized → cannot mutate vault balances → cannot trade. Safe.
- CUTOVER: after `sealMigration` + backend V2 arming, Safe proposes → Timelock schedules → 14-day GRACE_PERIOD (or shorter minDelay) → Timelock executes → V2 becomes vault-authorized.

**Never revoke V1 vault authorization** during V2 deployment. Both engines can coexist as authorized-vault-engines; migration seal is what enforces state isolation.

## L. PRE-STAGE DAG (Phase A — V1 stays operational)

All actions below are **read-only + fresh deploys + wiring on freshly-deployed contracts**. Nothing touches V1 economic state, nothing touches Vault/Timelock/Safe, nothing activates backend V2.

| ID | Category | Authority | Target | Function | Args | Deps | Precondition | Postcondition / readback |
|---:|---|---|---|---|---|---|---|---|
| A01 | DEPLOY | `0xc35F7A8A…` EOA | — | `create` PerpEngineSeizureLib | — | — | RPC reachable, gas price sane | `SEIZE_ADDR.code.length == 3_628` AND sha256 matches `073213…83e8` |
| A02 | DEPLOY | EOA | — | `create` PerpEngineLiquidationLib (linked to SEIZE_ADDR) | — | A01 | A01 postcondition | `LIQ_ADDR.code.length == 6_148` AND sha256 matches `ef7db6…04bd4` |
| A03 | DEPLOY | EOA | — | `create` PerpEngineV2 (linked to LIQ_ADDR + SEIZE_ADDR) | `OWNER, REGISTRY, VAULT, ORACLE` | A01, A02 | A02 postcondition | `ENGINE_V2.code.length == 24_321` AND sha256 matches `22ab40…21ad` |
| A04 | DEPLOY | EOA | — | `create` PerpMatchingEngineV2 | `OWNER, ENGINE_V2` | A03 | A03 postcondition | `PME_V2.code.length == 10_441` |
| A05 | DEPLOY | EOA | — | `create` PerpRiskModule V2 | `OWNER, VAULT, ENGINE_V2, ORACLE, mUSDC` | A03 | A03 postcondition | `RISK_V2.code.length == 9_894` |
| A06 | DEPLOY | EOA | — | `create` PerpClearingAccountV2 | `VAULT` | — | — | `CLEARING_V2.code.length == 1_159` |
| A07 | DIRECT | EOA (owner) | ENGINE_V2 | `setMatchingEngine(PME_V2)` | | A03, A04 | `ENGINE_V2.owner() == EOA` | `ENGINE_V2.matchingEngine() == PME_V2` |
| A08 | DIRECT | EOA (owner) | ENGINE_V2 | `setRiskModule(RISK_V2)` | | A03, A05 | | `ENGINE_V2.riskModule() == RISK_V2` |
| A09 | DIRECT | EOA (owner) | ENGINE_V2 | `setClearingAccount(CLEARING_V2)` | | A03, A06 | | `ENGINE_V2.clearingAccount() == CLEARING_V2` |
| A10 | DIRECT | EOA (owner) | ENGINE_V2 | `setInsuranceFund(0x009f…7500)` | | A03 | | reuses existing InsuranceFund |
| A11 | DIRECT | EOA (owner) | ENGINE_V2 | `setCollateralSeizer(0x39F9…8669)` | | A03 | | reuses existing CollateralSeizer |
| A12 | DIRECT | EOA (owner) | ENGINE_V2 | `setGuardian(0xc35F7A8A…)` | | A03 | | mirrors V1 guardian |
| A13 | DIRECT | EOA (owner) | ENGINE_V2 | `setFeesManagerV2(0x00dA…774f)` | | A03 | FMV2 owner still EOA | `ENGINE_V2.feesManagerV2() == FMV2` |
| A14 | DIRECT | EOA (FMV2 owner) | FMV2 | `setFeeConsumer(ENGINE_V2, true)` | | A03 | FMV2 owner still EOA | `FMV2.isFeeConsumer(ENGINE_V2) == true` |
| A15 | DIRECT | EOA (owner) | ENGINE_V2 | `setUseFeesManagerV2(true)` | | A13, A14 | A13 + A14 postcond | `ENGINE_V2.useFeesManagerV2() == true` |
| A16 | DIRECT | EOA (owner) | RISK_V2 | mirror V1 risk-module admin (per-market caps, oracle-max-delay, etc. — copy from V1 `0xf1b46040…`) | see §I OPERATOR_DECISION | A05 | V1 risk readable | RISK_V2 state == mirrored |
| A17 | READBACK | anyone | — | see §S readback checklist | | A07–A16 | | all rows green |

**Migration state after A01–A17**: `ENGINE_V2.migrationState() == OPEN`, `migrationSnapshotHash() == 0x0`. No V1 state touched. Vault authorization for V2 NOT yet granted. Backend still `PERPS_ACTIVE_ENGINE_VERSION=v1`.

**Do NOT set `impactMidSource` in PRE-STAGE** — Funding V2 is not yet configured on markets, and V2 keeper wiring is a separate future milestone.

## M. CUTOVER DAG (Phase B — V1 → V2 handover)

**Do NOT execute during this milestone.** Recorded here so PRE-STAGE plan is complete.

Conceptual order (exact order derives from final live state at cutover time):

1. **Freeze V1 new execution** — backend refuses new V1 intents (`PERPS_ACTIVE_ENGINE_VERSION` remains v1 but new-intent gate flipped closed via a backend-only config)
2. **Drain V1 in-flight** — reconciler + broadcast worker resolve all Prepared/Submitted V1 broadcasts to terminal state
3. **Verify V1 quiescence** — §N gate all green
4. **Pin snapshot block** — record `chainId`, `blockNumber`, `blockHash`
5. **Read V1 canonical state at snapshot** — build deterministic manifest (§O)
6. **Compute snapshot hash** — canonical CBOR-like encoding + keccak256; record
7. **Fund clearing account** — see §P
8. **Seed market funding** — `ENGINE_V2.adminSeedMarketFunding(marketId, cumRate, ts)` per market
9. **Seed live positions** — `ENGINE_V2.adminSeedPosition(trader, marketId, size, openNotional, checkpoint)` per (trader, marketId)
10. **Seed residual bad debt** — `ENGINE_V2.adminSeedResidualBadDebt(trader, amount)` per trader with non-zero residual
11. **Verify seeded state** — enumerate on-chain reads on V2 == V1 snapshot values
12. **Seal migration** — `ENGINE_V2.sealMigration(snapshotHash)` (EOA owner)
13. **Timelock schedule Vault auth flip** — Safe(2/3) → Timelock.schedule(`vault.setAuthorizedEngine(ENGINE_V2, true)`, delay)
14. **Wait Timelock delay** — GRACE_PERIOD is 14 d but minDelay unknown; determine before scheduling
15. **Timelock execute Vault auth flip** — Safe → Timelock.execute(...)
16. **Verify V1 cannot mutate migrated state** — assert `ENGINE_V2.migrationState() == SEALED` blocks V1 admin-seed paths; V1 vault ops still authorized but no economic effect on V2 positions
17. **Backend V2 activation** — flip `PERPS_ACTIVE_ENGINE_VERSION=v2`, populate V2 addresses, restart backend
18. **First V2 trade** — §U

## N. V1 quiescence gate (backend-side)

All conditions must hold at the pinned snapshot block:

- No Pending V1 intent capable of progression
- No CalldataReady V1 candidate
- No SimulationOk V1 candidate eligible for send
- No unresolved Prepared V1 broadcast
- No unresolved Submitted V1 broadcast (all → OnChainSuccess or Abandoned)
- Reconciler caught up to snapshot block
- Indexer caught up to snapshot block
- Known abandoned V1 close remains Abandoned (no accidental retry)
- No V1 trade is possible in the window between snapshot block and Timelock-execute of Vault auth flip

Ensuring this is a backend responsibility (a small readiness endpoint or gate script).

## O. Snapshot manifest (schema)

At pinned block:

```
chainId:             uint256
blockNumber:         uint256
blockHash:           bytes32
markets: [
  {
    marketId:                        uint256
    cumulativeFundingRate1e18:       int256
    lastFundingTimestamp:            uint256
    longOI1e8:                       uint256
    shortOI1e8:                      uint256
  }
]
positions: [   // one row per (trader, marketId) with size != 0
  {
    trader:                          address
    marketId:                        uint256
    size1e8:                         int256
    openNotional1e8:                 int256
    lastCumulativeFundingRate1e18:   int256
  }
]
residualBadDebt: [   // one row per trader with residual > 0
  {
    trader:                          address
    amountBase:                      uint256
  }
]
v1PmeNonces: [
  { user: address, nonce: uint256 }
]
vaultBalances: [
  { user: address, token: address, balance: uint256 }
]
```

**Canonical ordering**: strict lexicographic ASC by primary key (marketId; then trader,marketId; then trader; then user). All integers big-endian, exact-length. Encode as deterministic CBOR (no map indefinite-length, sorted keys). `snapshotHash = keccak256(cbor(manifest))`.

## P. Clearing funding methodology

Anvil used a 1_000_000 mUSDC clearing floor for local invariants; **do not blindly reuse that value on Base Sepolia**.

To determine live clearing seed:

1. Read Vault balances per (trader, mUSDC) from snapshot
2. Read `ENGINE_V2.totalAbsLongSize1e8(trader)` and `totalAbsShortSize1e8(trader)` post-seed
3. Compute max exposure that could realize as a net loss to Clearing at the current mark price
4. Add operator safety buffer (recommended: 2× worst-case loss estimate)
5. Sanity check: seed amount ≤ available treasury / OPS_SAFE mUSDC balance

Perform this arithmetic at snapshot time — cannot be determined statically now.

## Q. Timelock / Safe timing

Timelock at `0xa67f8E8E…` is a custom implementation: `getMinDelay()`, `delay()`, `MINIMUM_DELAY()` all revert; only `GRACE_PERIOD() = 1_209_600` (14 d) reads cleanly. Owner is OPS Safe (2/3).

**Before scheduling**: run a diagnostic pass to determine effective `minDelay` (inspect via source code of the deployed timelock impl, or via a scheduled no-op probe). Do not schedule Vault auth flip before minDelay is confirmed.

**Timing-aware DAG note**: only the Vault-authorization flip is on the critical Timelock path. All ENGINE_V2 / PME_V2 / RISK_V2 / CLEARING_V2 wiring is EOA-owned and executes instantly. This means PRE-STAGE is decoupled from Timelock — deploy + wire in a single session, schedule Vault flip only at cutover once quiescence is verified.

## R. Exact transaction DAG (see §L for PRE-STAGE; §M for CUTOVER)

- IDs A01–A17 = PRE-STAGE (this milestone will not execute; deployment milestone will)
- CUTOVER IDs will be assigned in a subsequent milestone once snapshot values are pinned

## S. Readback checklist (after PRE-STAGE deployment)

```
[ ] SEIZE_ADDR.code.length == 3_628 AND sha256 == 073213…83e8
[ ] LIQ_ADDR.code.length == 6_148 AND sha256 == ef7db6…04bd4
[ ] ENGINE_V2.code.length == 24_321 AND sha256 == 22ab40…21ad     (LINKED)
[ ] PME_V2.code.length == 10_441
[ ] RISK_V2.code.length == 9_894
[ ] CLEARING_V2.code.length == 1_159
[ ] ENGINE_V2.owner()           == OWNER EOA
[ ] ENGINE_V2.guardian()        == 0xc35F7A8A…
[ ] ENGINE_V2.marketRegistry()  == 0xb4fc…7eC
[ ] ENGINE_V2.collateralVault() == 0x0034…5D3
[ ] ENGINE_V2.oracle()          == 0xB416…581
[ ] ENGINE_V2.riskModule()      == RISK_V2
[ ] ENGINE_V2.matchingEngine()  == PME_V2
[ ] ENGINE_V2.clearingAccount() == CLEARING_V2
[ ] ENGINE_V2.insuranceFund()   == 0x009f…7500
[ ] ENGINE_V2.collateralSeizer()== 0x39F9…8669
[ ] ENGINE_V2.feesManagerV2()   == 0x00dA…774f
[ ] ENGINE_V2.useFeesManagerV2()== true
[ ] FMV2.isFeeConsumer(ENGINE_V2)   == true
[ ] ENGINE_V2.migrationState()  == OPEN
[ ] ENGINE_V2.migrationSnapshotHash() == 0x0
[ ] Vault.isAuthorizedEngine(ENGINE_V2)  == false     (PRE-STAGE: not yet)
[ ] Vault.isAuthorizedEngine(V1_ENGINE)  == true      (unchanged)
[ ] V1_ENGINE state unchanged (owner, matchingEngine, riskModule, useFeesManagerV2, pauses, market OI)
[ ] Backend PERPS_ACTIVE_ENGINE_VERSION == v1
```

## T. Backend config plan

`.env.base-sepolia` additions for FUTURE cutover (do not add now):

```
PERPS_ACTIVE_ENGINE_VERSION=v2                # flip at cutover
PERP_ENGINE_V2_ADDRESS=<ENGINE_V2>
PERP_MATCHING_ENGINE_V2_ADDRESS=<PME_V2>
PERP_RISK_MODULE_V2_ADDRESS=<RISK_V2>
PERP_CLEARING_ACCOUNT_V2_ADDRESS=<CLEARING_V2>
FEES_MANAGER_V2_ADDRESS=0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f    # unchanged
```

Backend refuses startup with `PERPS_ACTIVE_ENGINE_VERSION=v2` if any of the above are missing (see `src/execution/config.rs:398`).

Presence of the addresses in the env does NOT constitute activation. Activation = flipping the version flag + restart.

## U. First real V2 trade plan

- The known A/B V1 test positions (if they remain at snapshot time) will be the first V2 trade — a narrowly-scoped mutual close
- Do NOT hard-code `+244_274 / -244_274` — the Anvil golden used a specific mark price, funding, and fee schedule that will NOT match Base Sepolia state
- Re-derive expected PnL from migrated basis, funding checkpoint, actual execution price, and current market registry `RiskConfig`; separately compute expected fees from FMV2 quote surface
- Compare on-chain settlement to expected values with per-component tolerance:
  - PnL: exact match (settlement math is deterministic)
  - Fee: exact match to FMV2 quote
  - Funding: exact match to `PositionFundingSettled` log
  - Clearing: `RealizedPnlSettledV2` net delta == 0 for a symmetric mutual close

## V. Abort / recovery matrix

| Failure signal | Safe action |
|---|---|
| Library runtime hash mismatch | STOP; do not deploy engine. Investigate build determinism. |
| Engine linked runtime length ≠ 24_321 | STOP. Any drift means either lib address altered length (impossible if link substitution is correct) or artifact was rebuilt from different source. |
| Engine linked runtime sha256 ≠ expected (with real lib addresses filled) | STOP; recompute link substitution locally, compare against on-chain `eth_getCode`. |
| Unexpected owner/guardian/dep on ENGINE_V2 | STOP; do not proceed to wiring. |
| FMV2 `isFeeConsumer(ENGINE_V2)` returns false after A14 | Retry A14 (idempotent). If still false → check FMV2 owner and tx receipt. |
| V1 state drift observed at any read | STOP CUTOVER. V2 remains dormant. Investigate. |
| Snapshot hash mismatch between local computation and on-chain seal | STOP. Do not seal. Reseed if partial. |
| Seed mismatch (post-seed read ≠ snapshot value) | STOP. Do not seal. Investigate individual seed tx. |
| Clearing insufficient at first trade | Withhold trade. Top up CLEARING_V2 mUSDC balance from OPS Safe. |
| Seal preconditions not met | Investigate `MigrationSealed` event emission path; check EOA owner still owns engine. |
| Backend preflight not READY | Delay activation. PRE-STAGE deployment is fine to leave unactivated. |
| FeeChargedV2 observability missing at first trade | Backend already ready (§H). If somehow missing at cutover, abort trade — do not proceed without fee attestation. |

## W. Blockers by phase

**BLOCKS_PRESTAGE_DEPLOYMENT**: none.

**BLOCKS_CUTOVER**:
- Determine effective Timelock `minDelay` (Q)
- Determine V2 PerpRiskModule oracle-freshness policy (I — OPERATOR_DECISION_REQUIRED)
- V1 quiescence gate (N)
- Snapshot manifest generation + hash (O)
- Clearing funding sizing at snapshot time (P)

**BLOCKS_FIRST_V2_TRADE**:
- CUTOVER blockers above +
- Vault auth flip through Timelock (K)
- Backend V2 activation (T)

**NON_BLOCKING**:
- Executor EOA balance top-up (0.00195 ETH is too low for a real cutover; add before broadcast)
- Confirm launch fee schedule (perp maker 50 ppm / taker 300 ppm) at cutover
- Optional: rewrite/rename `script/DeployPerpEngineV2.s.sol` so its V1-shape does not accidentally get invoked against V2 addr (post-freeze cleanup, defer)

## X. Final readiness verdict

**`PERPS_V2_BASE_SEPOLIA_DEPLOYMENT_PREFLIGHT_READY`** for PRE-STAGE DEPLOYMENT.

CUTOVER remains gated by §W CUTOVER blockers.
FIRST V2 TRADE remains gated by §W FIRST V2 TRADE blockers.

## Y. Changed non-production files

- `docs/PERPS_V2_BASE_SEPOLIA_DEPLOYMENT_PREFLIGHT_V1.md` (this file, NEW)

No Solidity production source changed. No script changed. No backend changed.

## Z. Commit (this milestone)

To be created: doc-only commit adding this runbook. Sol production bytecode unchanged (`004bf78`).

## AA. Sol HEAD

`004bf78c32b2b5210cd7daabef2685cd461aeec7` (unchanged during this milestone).

## AB. Backend HEAD

`ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged, worktree clean).

## AC. Proof Base Sepolia unchanged

Zero transactions sent. RPC access read-only via `cast call` / `cast code` / `cast chain-id`. No `--broadcast`, no `cast send`, no Safe execution, no Timelock schedule/execute.

## AD. Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_DEPLOY_V2_ONLY_V1`** — execute PRE-STAGE DAG (§L, IDs A01–A17). Read §S readback checklist as postcondition gate. Do NOT touch Vault, do NOT touch Timelock/Safe, do NOT flip backend activation.
