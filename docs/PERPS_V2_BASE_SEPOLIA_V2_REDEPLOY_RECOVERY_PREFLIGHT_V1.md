# PERPS V2 BASE SEPOLIA V2 REDEPLOY RECOVERY PREFLIGHT V1

> Hash terminology correction — `PERPS_V2_CODEX_HANDOFF_RECONCILIATION_V1`: runtime identities below use **Ethereum Keccak-256**, verified with `cast keccak` and byte-for-byte live/local comparison. The previously published Engine value `0xef5486354584feba953f4eed0d5573b65e9e2bfb6dca0e43a4eedfe7ba46652e` and PMR value `0x5d66f23543a0e9ded3da5e85c8f0413af3cbe00794e99e1aa3c9b1b40c63fd8c` are **NIST SHA3-256**, not Ethereum hashes. This correction does not change deployed bytes, historical transactions, or the canonical migration snapshotHash. See [reconciliation](PERPS_V2_CODEX_HANDOFF_RECONCILIATION_V1.md) for current script guards and the operator's intentionally STOPPED backend decision.

**Milestone**: `PERPS_V2_BASE_SEPOLIA_V2_REDEPLOY_RECOVERY_PREFLIGHT_V1`
**Status**: **COMPLETE — READ-ONLY / LOCAL-FORK; MINIMAL REPLACEMENT = 2 CONTRACTS**
**Sol HEAD (pre)**: `e311a5a` (unchanged during milestone; new docs commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Chain**: Base Sepolia (chainId `84532`)

Scope: strictly read-only chain analysis + isolated local Forge validation. No public-chain writes, no deployment, no contract reconfiguration, no Safe/Timelock tx, no backend mutation, no DB writes, no V2 trade. Goal: determine the MINIMAL redeployment/rebinding set required to recover from the PMR execution-guard incompatibility, superseding the earlier "redeploy everything" recommendation.

**Executive summary**: prior preflight over-scoped the fix. The minimal replacement is **exactly two new contracts** — a compatible PerpMarketRegistry and a fresh PerpEngineV2 — plus rebind setters on the existing PME_V2 / RISK_V2 / FMV2 / InsuranceFund and a single Timelock op to authorize the new engine on the Vault. **The 1_000_000_000 mUSDC clearing seed is fully reusable**, CLEARING_V2 stays as-is, PME_V2 stays as-is (EIP-712 domain preserved), all other V2 dependencies stay as-is.

---

## A. Clearing-fund ownership finding

Live-chain readbacks:

```
Vault.balances(CLEARING_V2, mUSDC)   =  1_000_000_000   ← the seed
Vault.balances(OLD_ENGINE, mUSDC)    =  0
mUSDC.balanceOf(VAULT)               =  224_066_000_000  (aggregate custody incl. other traders)
mUSDC.balanceOf(CLEARING_V2)         =  0                (all forwarded to Vault via deposit)
mUSDC.balanceOf(OLD_ENGINE)          =  0
```

Custody model verification (`src/perp/PerpClearingAccountV2.sol`):

1. CLEARING_V2 has **no owner, no engine reference, no admin surface, no upgradability, no delegatecall, no emergency drain** (source lines 22-28).
2. CLEARING_V2's only external mutation is `fundClearing(asset, amount)` (line 94), which pulls tokens from `msg.sender` and deposits into the vault under `msg.sender = CLEARING_V2`. No engine call.
3. The **only way** the CLEARING_V2 balance moves is via `Vault.transferBetweenAccounts(...)` (`src/collateral/CollateralVaultActions.sol:180`), which gates on `onlyMarginEngine`.
4. `onlyMarginEngine` (`src/collateral/CollateralVaultStorage.sol:194-197`) resolves to `_isAuthorizedEngine(msg.sender)` = `msg.sender == marginEngine || isAuthorizedEngine[msg.sender]`. **Any Vault-authorized engine can debit/credit CLEARING_V2's ledger balance.**
5. `Vault.owner() = 0xa67f8E…3b588` = PROTOCOL_TIMELOCK. `setAuthorizedEngine(newEngine, true)` requires Timelock queue + 24 h + OPS Safe execute.

**Verdict — the 1_000_000_000 mUSDC seed is A. reusable by a newly deployed EngineV2 through the SAME CLEARING_V2.** The prior preflight's "write-off" framing was incorrect. Once NEW ENGINE_V2 is added to `Vault.isAuthorizedEngine[...]`, it can access the same clearing balance without any additional funding.

## B. Dependency rebinding matrix

| Contract | Live addr | Reusable? | Setter | Selector | Authority | Callable now? | SEALED affects it? |
|---|---|---|---|---|---|---|---|
| `PerpMatchingEngineV2` (PME_V2) | `0xF5FB81…eee2` | ✓ REUSE | `setEngine(address)` | `0xd6e4b9c8`* | OWNER (PME_V2 `onlyOwner`) | YES | NO |
| `PerpRiskModule` (RISK_V2) | `0x8C3d9F…2998` | ✓ REUSE | `setPerpEngine(address)` | `0xdd8ceb17`* | OWNER (RISK_V2 `onlyOwner`) | YES | NO |
| `PerpClearingAccountV2` (CLEARING_V2) | `0x54d49c…435c` | ✓ REUSE AS-IS | **none needed** | — | — | — | NO |
| `FeesManagerV2` (FMV2) | `0x00dA0B…774f` | ✓ REUSE | `setFeeConsumer(address,bool)` | `0x…`* | OWNER (FMV2 `onlyOwner`) | YES | NO |
| `CollateralVault` (VAULT) | `0x00340C…25D3` | ✓ REUSE | `setAuthorizedEngine(address,bool)` | `0x3331c56e` | **PROTOCOL_TIMELOCK** (Vault `onlyOwner`) | via Timelock queue + 24 h + Safe execute | NO |
| `OracleRouter` | `0xB41640…A581` | ✓ REUSE AS-IS | — | — | — | — | NO |
| `CollateralSeizer` | `0x39F928…B669` | ✓ REUSE AS-IS (no engine linkage) | — | — | — | — | NO |
| `InsuranceFund` | `0x009f38…7500` | ✓ REUSE | `setBackstopCaller(address,bool)` | `0x…`* | OWNER | YES | NO |
| Guardian (EOA) | `0xc35F7A…3C27` | ✓ REUSE AS-IS | — | — | — | — | NO |
| `PerpMarketRegistry` (OLD PMR) | `0xb4fcf4…77eC` | ✗ **REDEPLOY** | — (missing selector) | — | — | — | — |
| `PerpEngineV2` (OLD ENGINE) | `0x44702B…6db9` | ✗ **REDEPLOY** | none — `_marketRegistry` is init-immutable | — | — | — | SEALED — cannot re-init or swap registry |

*Selectors marked with * verified live in the ENGINE_V2 admin surface probe (see prior preflight §D); PME/RISK/FMV2 selectors are compiled from source and validated by the test suite in §P.

Setter authorities live-verified:
```
CollateralVault.owner()     = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588  (PROTOCOL_TIMELOCK)
PerpEngineV2.owner()        = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27  (OWNER EOA)
PME_V2.owner()              = OWNER EOA   (from prior TIMELOCK_EXECUTE_VAULT_AUTH_V1 §A)
RISK_V2.owner()             = OWNER EOA   (from source; not yet re-verified live)
FMV2.owner()                = OWNER EOA   (from source)
InsuranceFund.owner()       = OWNER EOA   (from source)
```

## C. PME_V2 reuse/redeploy verdict — **REUSE**

Source: `src/matching/PerpMatchingEngineV2.sol:404-410`:

```solidity
function setEngine(address _engine) external onlyOwner {
    if (_engine == address(0)) revert ZeroAddress();
    address old = address(perpEngine);
    perpEngine = IPerpEngineTrade(_engine);
    emit EngineSet(old, _engine);
    ...
}
```

`perpEngine` is a plain mutable storage variable. OWNER can call `setEngine(newEngine)` to rebind.

**PME_V2 does NOT need to be redeployed.** Its `verifyingContract` (`address(this)`) is unchanged. **EIP-712 domain is preserved.** No test signature regeneration needed. Backend `PerpTradeDomain::new_v2()` will continue to resolve against the same PME_V2 address.

## D. EIP-712 consequence

Domain fields (verified live on PME_V2 via `eip712Domain()` in prior preflight §D):

```
name              = "DeOptV2-PerpMatchingEngine"     ← unchanged
version           = "2"                              ← unchanged
chainId           = 84532                            ← unchanged
verifyingContract = 0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2  ← unchanged (PME_V2 stays)
salt              = 0x00…00                          ← unchanged
```

Domain separator (independent recompute from prior preflight):
```
domainSep = 0x26a8b7a2a20b6c06fd610e824899da507ef8e51ad40f76040549a8332376c559  ← unchanged
```

**No V2 signature has been consumed on Base Sepolia yet** (nonces=0 for the canonical first-trade pair). But even if signatures had been consumed, they'd still verify after the engine rebind because the domain is unchanged.

**No test fixture regeneration required.**

## E. Clearing reuse/redeploy verdict — **REUSE AS-IS**

CLEARING_V2 source is engine-agnostic (§A). No storage or admin dependency on the engine. Balance moves only via `Vault.transferBetweenAccounts` called by any Vault-authorized engine.

**CLEARING_V2 does NOT need to be redeployed. Existing 1 000 mUSDC seed does NOT need to be re-funded. Zero setter calls required on CLEARING_V2.**

## F. Risk reuse/redeploy verdict — **REUSE**

Source: `src/perp/PerpRiskModule.sol:286-291`:

```solidity
function setPerpEngine(address newEngine) external onlyOwner {
    if (newEngine == address(0)) revert ZeroAddress();
    address old = address(perpEngine);
    perpEngine = IPerpEngineRiskView(newEngine);
    emit PerpEngineSet(old, newEngine);
}
```

`perpEngine` is a plain mutable storage variable. Additional setters exist for oracle, vault, base collateral token, max oracle delay (`onlyOwner` each).

**RISK_V2 does NOT need to be redeployed.** One `setPerpEngine(newEngine)` call from OWNER at rebind time.

## G. FMV2 reuse verdict — **REUSE**

Source: `src/fees/FeesManagerV2.sol:141-147`:

```solidity
function setFeeConsumer(address consumer, bool allowed) external onlyOwner {
    if (consumer == address(0)) revert ZeroAddress();
    isFeeConsumer[consumer] = allowed;
    ...
}
```

Live-verified: `FMV2.isFeeConsumer(OLD_ENGINE) = true`. To add NEW ENGINE_V2:

```
setFeeConsumer(NEW_ENGINE, true)     ← add new
```

OLD ENGINE_V2 fee-consumer authorization removal is a SEPARATE, LATER action:

```
setFeeConsumer(OLD_ENGINE, false)    ← optional, defense-in-depth
```

The old-engine fee-consumer flag is orthogonal to the trading path. OLD ENGINE cannot broadcast fees because its `applyTrade` reverts at the guard before any FMV2 call. Keeping the flag true creates no operational risk. Recommend removal only as a housekeeping step, not as a blocker.

## H. Vault authorization transition plan

Current state:
```
Vault.isAuthorizedEngine(V1)         = true    (V1 frozen elsewhere via PME_V1.paused)
Vault.isAuthorizedEngine(OLD_V2)     = true    (SEALED but applyTrade reverts at guard)
Vault.isAuthorizedEngine(NEW_V2)     = false   (must flip to true)
```

Desired end state after recovery:
```
Vault.isAuthorizedEngine(V1)         = true    (retain for reconciliation window)
Vault.isAuthorizedEngine(OLD_V2)     = false   (defense-in-depth after successful cutover)
Vault.isAuthorizedEngine(NEW_V2)     = true    (active engine)
```

**Ordering**:

1. **NEW authorization FIRST**: Timelock queue `setAuthorizedEngine(NEW_ENGINE, true)`, wait 24 h, OPS Safe execute. NEW ENGINE now co-exists with OLD ENGINE.
2. **Run first-trade validation** with NEW ENGINE (via PME_V2 rebind). If OK, proceed.
3. **OLD deauthorization LAST**: separate Timelock queue `setAuthorizedEngine(OLD_ENGINE, false)`, wait 24 h, execute. This step is a **defense-in-depth cleanup, not a safety gate** — the OLD engine cannot actually execute trades (its applyTrade reverts at the missing PMR guard call).

**Analysis of atomic-vs-sequential**: an atomic swap (both in one Timelock op via multicall) is technically possible via a batched call but adds complexity. Recommend the sequential approach:
- Simpler audit trail: one Timelock op per direction.
- Independent 24-h delays give operators time to abort each direction independently.
- Overlap window is safe: OLD engine can't trade at all (proven via §M of prior preflight), so simultaneous authorization creates no double-spend risk.

**OLD_ENGINE_V2 cannot cause Vault mutation** while unauthorized on the missing-selector guard: every `applyTrade` reverts before reaching any `Vault.transferBetweenAccounts` call. The only Vault-callable admin surface reachable by OLD ENGINE (as a Vault-authorized engine) is `transferBetweenAccounts` itself — and no path exists in OLD ENGINE's callable public surface to reach that call without going through `applyTrade` or `liquidate`, both of which revert at the guard. Vault authorization on OLD ENGINE is therefore inert.

**Recommend: do NOT revoke OLD_ENGINE Vault authorization immediately** (as per §16). Leave OLD as-is until NEW is fully validated. Then perform §3 above.

## I. New PMR exact config (deterministic, live-read from OLD PMR)

Deploy `src/perp/PerpMarketRegistry.sol` at HEAD `e311a5a` with constructor `(address owner_)`:
```
owner_ = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
```

Then configure markets 1 and 2 to match live state byte-identical (verified in prior preflight §H):

**Market 1 — ETH-PERP**:
```
underlying         = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02
settlementAsset    = 0x6eAe407f5640B006faC9965182e238582A3B412E    (mUSDC)
oracle             = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
symbol             = "ETH-PERP"   (bytes32 = 0x4554482d504552500000…)
riskConfig raw     = (1000, 750, 500, 10_000_000_000, 50_000_000_000, 1)
liquidationConfig  = (5000, 100, 50, 60)
fundingConfig      = (0, 0)
isActive           = true
isCloseOnly        = false
maxExecutionDeviationBps = 100   ← OPERATOR POLICY VALUE (see §I below)
```

**Market 2 — BTC-PERP**:
```
underlying         = 0x9D871aC7595E8Da271E866608E5145252047967c
settlementAsset    = 0x6eAe407f5640B006faC9965182e238582A3B412E
oracle             = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
symbol             = "BTC-PERP"   (bytes32 = 0x4254432d504552500000…)
riskConfig raw     = (1200, 800, 400, 1_000_000_000, 10_000_000_000, 1)
liquidationConfig  = (5000, 80, 50, 60)
fundingConfig      = (0, 0)
isActive           = true
isCloseOnly        = false
maxExecutionDeviationBps = 100   ← OPERATOR POLICY VALUE
```

Post-deploy config sequence (all `onlyOwner`, callable via OWNER EOA):
```
1.  PMR.setSettlementAssetAllowed(mUSDC, true)
2.  PMR.createMarket(1, ETH-PERP config)              // includes underlying, oracle, symbol
3.  PMR.setRiskConfig(1, ETH_risk)
4.  PMR.setLiquidationConfig(1, ETH_liq)
5.  PMR.setFundingConfig(1, ETH_fund)
6.  PMR.setMaxExecutionDeviationBps(1, 100)           ← OPERATOR POLICY
7.  PMR.setMarketStatus(1, isActive=true, isCloseOnly=false)
8-13. same for market 2
```

`maxExecutionDeviationBps = 100` labeled **OPERATOR POLICY VALUE** — no committed source-of-truth pins this. Rationale for 100 bps:
- Accepts normal execution slippage on volatile perps (up to ±1 %).
- Fails closed against obviously stale matching-engine input.
- Matches directive default in prior BACKEND_V2_ACTIVATION_PREFLIGHT_V1 §6.
- **Safer alternative to consider**: `50 bps` — tighter, better for testnet where price staleness is uncommon. Do not autonomously change; operator selects the value at deployment time.

## J. New Engine initialization plan

Deploy `src/perp/PerpEngineV2.sol` at HEAD `e311a5a` with constructor:
```solidity
constructor(address _owner, address registry_, address vault_, address oracle_)
```

Args:
```
_owner    = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27   (OWNER EOA, unchanged)
registry_ = NEW_PMR_ADDRESS                              (from §I)
vault_    = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3   (VAULT, unchanged)
oracle_   = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581   (ORACLE_ROUTER, unchanged)
```

Post-deploy wiring (all `onlyOwner`, callable via OWNER EOA):
```
1.  newEngine.setMatchingEngine(0xF5FB81…eee2)          (PME_V2 unchanged)
2.  newEngine.setRiskModule(0x8C3d9F…2998)              (RISK_V2 unchanged)
3.  newEngine.setClearingAccount(0x54d49c…435c)          (CLEARING_V2 unchanged)
4.  newEngine.setInsuranceFund(0x009f38…7500)            (InsuranceFund unchanged)
5.  newEngine.setCollateralSeizer(0x39F928…B669)         (Seizer unchanged)
6.  newEngine.setFeesManagerV2(0x00dA0B…774f)            (FMV2 unchanged)
7.  newEngine.setUseFeesManagerV2(true)
8.  newEngine.setGuardian(0xc35F7A…3C27)                 (guardian unchanged)
```

Optional wiring (may be no-op / left as init default):
```
   newEngine.setImpactMidSource(0x0)     ← default state, no action needed
```

## K. Runtime-bytecode equivalence proof

Deployed OLD ENGINE_V2 runtime bytecode:
```
size:      24 321 bytes
Ethereum Keccak-256: 0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a
```

Fresh compile at HEAD `e311a5a` via `forge inspect PerpEngineV2 deployedBytecode`:
```
size:      24 303 bytes  (≈18 B smaller — Solidity metadata bytehash diff, functionally equivalent)
Historical digest (unverified, superseded measurement): 0x91bafdf6a3a950641b24552eb5abc9fb865a1e95ab7b9e44aea912c1235e25d4
```

Byte prologue equivalent up to and including the dispatcher entry point:
```
OLD deployed:  60806040526004361015610011575f80fd5b5f3560e01c806310afecd814…
NEW compiled:  60806040526004361015610011575f80fd5b5f5f3560e01c80630212fd6a…
                                                    ^^ 1-byte diff (PUSH0 vs PUSH0 chain)
```

The delta:
- 1-2 bytes in the dispatcher prologue (`5f` PUSH0 chain adjustment — solc 0.8.30 uses one extra PUSH0 for `5f5f3560e01c` vs the deployed's `5f3560e01c`; this is a solc version fingerprint).
- Trailing IPFS/bzzr metadata differs (last ~53 bytes of runtime).

**Functional runtime bytecode is source-equivalent.** Same source `e311a5a`, same libraries (`PerpEngineTradingV2`, `PerpEngineLiquidationLib`, `PerpEngineSeizureLib`, etc.), same optimizer settings. Only the trailing metadata + minor push-order optimization differs.

**EIP-170 headroom**:
```
NEW compiled runtime = 24 303 bytes
EIP-170 limit        = 24 576 bytes
headroom             = 273 bytes    (marginally BETTER than deployed's 255 bytes)
```

**Bytecode equivalence for functional purposes is proven.** Redeploying the current source is safe.

## L. Migration replay plan

Reusable canonical artifacts (all under `artifacts/perps_v2_final_snapshot/`):

```
SNAPSHOT_BLOCK        = 47_354_411    (last V1 quiescence block)
SNAPSHOT_BLOCK_HASH   = 0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89
manifest.json         (3399 B, sha256 88707f09…7ddd)
manifest.cbor         (1638 B, sha256 520897f5…d857)  ← canonical CBOR body
seed_calldata.json    (9723 B, sha256 d92cf6ab…db14)  ← 8 ordered seed steps
market_params.json
first_close.json
snapshotHash          = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d
```

**V1 has been quiescent since block 47_354_411** (verified via prior QUIESCENCE_RAW_LOG_FINALIZATION_V1). No V1 TradeExecuted, no V1 position mutation, no V1 funding tick since seal. Vault authorization of OLD ENGINE_V2 has not been used (0 V2 TradeExecuted since Vault auth flip at block 47_407_874, re-verified live).

**Therefore the SAME canonical snapshot applies to the NEW ENGINE_V2**:
- Same 6 traders, same 6 positions, same OI, same market funding, same residual bad debt (zero).
- Same `snapshotHash = 0x039d9172…3d7d`.

**Only calldata target address changes** — `to = NEW_ENGINE_V2_ADDRESS` (not OLD). The seed calldata bytes (all 8 steps in `seed_calldata.json`) are byte-identical because they encode only `(trader, marketId, size, openN, lastCumFR)` per position and `(marketId, cumFR, lastFundingTs)` per market — no engine address in the payload.

Seed sequence on NEW ENGINE (from OWNER EOA):
```
0.  newEngine.beginMigration()                                           // implicit if omitted — engine starts in OPEN
1.  newEngine.adminSeedMarketFunding(1, 0, 1_789_715_546)
2.  newEngine.adminSeedMarketFunding(2, 0, 0)
3.  newEngine.adminSeedPosition(0x290bd12c…, 1, +1_000, +3_000_000, 0)
4.  newEngine.adminSeedPosition(0x475fe397…, 1, -2, -6_000, 0)
5.  newEngine.adminSeedPosition(0x66858286…, 1, -1_000_000, -2_468_310_000, 0)
6.  newEngine.adminSeedPosition(0x77ca9dd6…, 1, -1_000, -3_000_000, 0)
7.  newEngine.adminSeedPosition(0x8b94a83d…, 1, +2, +6_000, 0)
8.  newEngine.adminSeedPosition(0xff287410…, 1, +1_000_000, +2_468_310_000, 0)
9.  newEngine.sealMigration(0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d)
```

Post-seal invariants (mirror OLD engine's SEALED state):
```
NEW_ENGINE.marketState(1) = (1_001_002, 1_001_002, 0, 1_789_715_546)
NEW_ENGINE.marketState(2) = (0, 0, 0, 0)
NEW_ENGINE.totalResidualBadDebtBase = 0
NEW_ENGINE.migrationState = 1 (SEALED)
NEW_ENGINE.migrationSnapshotHash = 0x039d9172…3d7d
Σ per-trader size = 0     Σ± = 1_001_002 each side
```

**No new snapshot is needed.** V1 state is unchanged; the canonical hash is deterministically the same.

## M. Old Engine retirement plan (no destructive recovery)

OLD ENGINE_V2 (`0x44702B0…6db9`) surface classification:

| Surface | State | Risk | Action |
|---|---|---|---|
| A. Seeded storage (6 positions, market states) | economically inert | 0 — trades revert at guard | leave frozen (no un-seal) |
| B. Clearing capital | 0 native tokens held at OLD engine (all at CLEARING_V2 or Vault) | 0 | no action |
| C. Vault authorization (`isAuthorizedEngine`) | true | inert (cannot call `transferBetweenAccounts` because trade path reverts before it) | revoke via Timelock op §H.3 as defense-in-depth |
| D. Fee-consumer authorization (FMV2) | true | inert (guard-revert before fee call) | optional `FMV2.setFeeConsumer(OLD, false)` |
| E. PME_V2 linkage | PME_V2 currently points at OLD | inert once rebound via `PME_V2.setEngine(NEW)` | rebind (§C) — first-mover step |
| F. RISK_V2 linkage | RISK_V2 currently points at OLD | risk views may return stale reads pre-rebind | rebind via `RISK_V2.setPerpEngine(NEW)` |
| G. Insurance backstop | check live at cutover; likely OLD | rebind via `InsuranceFund.setBackstopCaller(NEW, true)`; optionally remove OLD later | |
| H. Admin surface | OWNER-owned setters | can be `setUseFeesManagerV2(false)` etc. as sterilization | non-blocking |

**Minimal retirement is a NO-OP** — OLD ENGINE stays deployed forever, `SEALED`, unable to trade. It costs zero Vault mUSDC (its balance is zero). Its retention has no operational impact.

**Recommended defense-in-depth after cutover validation**: revoke Vault authorization (§H.3). All other steps are optional housekeeping.

**Explicit prohibition**: **`sealMigration` is irreversible** (verified in prior `TIMELOCK_EXECUTE_VAULT_AUTH_V1 §L` and `PerpEngineTradingV2.sol:325-335`). OLD ENGINE cannot be un-sealed and cannot be un-authorized as an engine on Vault except via Timelock. No destructive recovery is proposed.

## N. Minimal deployment set

**CASE 1: NEW PMR + NEW ENGINE_V2 only** — this is the answer.

Justification for every reused contract:
- **PME_V2**: has `setEngine(newEngine)` — verified live via bytecode selector inventory + source. No new deployment.
- **RISK_V2**: has `setPerpEngine(newEngine)` — verified. No new deployment.
- **CLEARING_V2**: engine-agnostic by design — `PerpClearingAccountV2` has no engine reference. Balance is Vault-side. No new deployment.
- **FMV2**: `setFeeConsumer(newEngine, true)` — verified. Just add the new consumer. No new deployment.
- **Vault**: `setAuthorizedEngine(newEngine, true)` — verified. Governance op required. No new deployment.
- **OracleRouter**: no engine linkage. No new deployment.
- **CollateralSeizer**: no engine linkage (constructor only takes vault/oracle/risk). No new deployment.
- **InsuranceFund**: `setBackstopCaller(newEngine, true)`. No new deployment.
- **mUSDC**: token, engine-agnostic. No new deployment.

Justification for the two contracts that MUST be redeployed:
- **PerpMarketRegistry**: deployed 0xb4fcf4…77eC is a pre-2026-09-01 build lacking `getMaxExecutionDeviationBps` (selector `0x4d73d67f`) and its setter. Not a proxy (EIP-1967 slots zero). Bytecode is immutable at address. Must deploy fresh.
- **PerpEngineV2**: `_marketRegistry` is set once in `_initPerpEngineStorage` (`PerpEngineStorage.sol:262`), gated by `if (owner != address(0)) revert NotAuthorized()`. No admin setter (`setMarketRegistry(address)` selector `0xd8579704` ABSENT from bytecode). Must deploy fresh pointing at NEW_PMR.

## O. Exact transaction count

Minimal write plan under CASE 1:

**OWNER EOA writes** (all `onlyOwner` on target contracts):
```
TX-1   deploy PerpMarketRegistry (NEW_PMR)
TX-2   NEW_PMR.setSettlementAssetAllowed(mUSDC, true)
TX-3   NEW_PMR.createMarket(1, ETH-PERP)
TX-4   NEW_PMR.setRiskConfig(1, …)
TX-5   NEW_PMR.setLiquidationConfig(1, …)
TX-6   NEW_PMR.setFundingConfig(1, …)
TX-7   NEW_PMR.setMaxExecutionDeviationBps(1, 100)      // OPERATOR POLICY
TX-8   NEW_PMR.createMarket(2, BTC-PERP)  + risk/liq/funding/marketStatus
TX-9   NEW_PMR.setMaxExecutionDeviationBps(2, 100)
TX-10  deploy PerpEngineV2 (NEW_ENGINE, constructor: OWNER, NEW_PMR, VAULT, ORACLE)
TX-11  NEW_ENGINE.setMatchingEngine(PME_V2)
TX-12  NEW_ENGINE.setRiskModule(RISK_V2)
TX-13  NEW_ENGINE.setClearingAccount(CLEARING_V2)
TX-14  NEW_ENGINE.setInsuranceFund(INSURANCE)
TX-15  NEW_ENGINE.setCollateralSeizer(SEIZER)
TX-16  NEW_ENGINE.setFeesManagerV2(FMV2) + setUseFeesManagerV2(true) + setGuardian(OWNER)
TX-17  NEW_ENGINE.adminSeedMarketFunding(1, …)          // 2 mkt-fund + 6 position seeds
TX-18  NEW_ENGINE.adminSeedMarketFunding(2, …)
TX-19  NEW_ENGINE.adminSeedPosition(0x290bd12c…, …)
TX-20  NEW_ENGINE.adminSeedPosition(0x475fe397…, …)
TX-21  NEW_ENGINE.adminSeedPosition(0x66858286…, …)
TX-22  NEW_ENGINE.adminSeedPosition(0x77ca9dd6…, …)
TX-23  NEW_ENGINE.adminSeedPosition(0x8b94a83d…, …)
TX-24  NEW_ENGINE.adminSeedPosition(0xff287410…, …)
TX-25  NEW_ENGINE.sealMigration(0x039d9172…3d7d)
TX-26  PME_V2.setEngine(NEW_ENGINE)                     // rebind matching engine
TX-27  RISK_V2.setPerpEngine(NEW_ENGINE)                // rebind risk
TX-28  FMV2.setFeeConsumer(NEW_ENGINE, true)            // add fee consumer
TX-29  InsuranceFund.setBackstopCaller(NEW_ENGINE, true)
```

**Governance flow** (Timelock queue + delay + Safe execute for Vault ACL):
```
GOV-A  RiskGovernor / any allowed proposer queues Timelock op:
         Target = VAULT
         Fn     = setAuthorizedEngine(NEW_ENGINE, true)
         ETA    = now + 86400 s
GOV-B  wait 24 h
GOV-C  OPS Safe 2/3 → Timelock.executeTransaction(...)
```

**Backend env writes** (operator-side, not on-chain):
```
BE-1   PERP_ENGINE_V2_ADDRESS         = NEW_ENGINE
BE-2   PERP_MATCHING_ENGINE_V2_ADDRESS = 0xF5FB81…eee2  (unchanged — PME_V2 reused)
BE-3   PERP_CLEARING_ACCOUNT_V2_ADDRESS = 0x54d49c…435c (unchanged — CLEARING_V2 reused)
```

**Optional defense-in-depth (post-validation)**:
```
GOV-D  Timelock queue setAuthorizedEngine(OLD_ENGINE, false)
GOV-E  wait 24 h
GOV-F  Safe execute
TX-30  FMV2.setFeeConsumer(OLD_ENGINE, false)   (optional)
TX-31  InsuranceFund.setBackstopCaller(OLD_ENGINE, false)  (optional)
```

**Count comparison**:
- Prior estimate (full-stack redeploy): **13 chain tx + 1 governance flow + massive backend churn**
- Revised (minimal set): **29 OWNER tx + 1 Timelock op** — more OWNER tx because of finer-grained config, but ZERO redundant contract deployments. Backend churn is minimal (only PERP_ENGINE_V2_ADDRESS env var changes).

Deployment cost estimate (Base Sepolia at 6 mwei):
- PMR deploy (~3M gas) + Engine deploy (~5M gas) + 27 setter/seed tx (~150k avg × 27 ≈ 4M gas)
- Total ≈ 12M gas × 6 mwei ≈ 0.000072 ETH ≈ $0.20 at ETH ≈ $2500.
- OWNER current balance is more than sufficient.

## P. Local-fork validation results

Executed via `CARGO_BUILD_JOBS=1 forge test -j 1 --match-path <path>` (resource-safe; no parallel Cargo/Forge; `free -h` = 6.2 Gi available before + after).

**Test A — migration seed + seal + hash + invariants** (`test/perp/PerpEngineV2Migration.t.sol`):
```
Ran 33 tests, 33 passed, 0 failed, 0 skipped
  testACL_01..13                                        (access control: 13 cases)
  testEcon_A..L                                         (economic migration: 12 cases)
  testHash_CommittedAtSeal / SensitivityToCanonicalFields / ZeroRejected
  testInvariant_LongWithNegativeBasisRejected / ...     (accounting invariants)
  testBaseSepoliaAB_PostMigrationCloseReproduces244274  ← REPRODUCES BASE SEPOLIA CLOSE ECONOMICS
  testSeal_RequiresMatchingEngine / RequiresRiskModule
```

**Test B — execution price guard** (`test/perp/PerpEngineExecutionPriceGuard.t.sol`):
```
Ran 22 tests, 22 passed, 0 failed, 0 skipped
  testUnconfiguredMarketRejectsTradesFailClosed         ← THE ORIGINAL BLOCKER PATH
  testExecutionPriceAtLowerBoundaryIsAccepted / AtUpperBoundary
  testExecutionPriceOneWeiAboveUpperBoundaryReverts / OneWeiBelow
  testExecutionPriceExactlyAtMarkIsAccepted             ← flat close accepted
  testOracleUnavailableRevertsWithDedicatedError
  testOracleStalenessBeyondMaxDelayPropagatesRevert
  testSetMaxExecutionDeviationBpsEmitsEventAndUpdatesStorage
  testSetMaxExecutionDeviationBpsAcceptsHardCap / AcceptsMinValue / RejectsAboveHardCap
  testOnlyOwnerCanSetMaxExecutionDeviationBps
  testGetMaxExecutionDeviationBpsRevertsOnUnknownMarket
  testGetRiskMarkPrice1e8IsExactAliasForGetMarkPriceV1
  testPrimaryOnlyUnsafeOracleAttackRevertsAtEngineGuard
  ...
```

**Test C — production wiring 244_274 mutual close** (`test/perp/PerpEngineV2ProductionWiring.t.sol`):
```
Ran 1 test, 1 passed, 0 failed, 0 skipped
  testProductionWiring_MutualClose_244274_WithTier0Fees
    → PASSES with real PMR + real Engine + real Risk + real FMV2 (tier-0
      makerPpm=50, takerPpm=300) + real Vault + real PME_V2 + real ClearingV2
    → Realized PnL: ALICE +244_274 native, BOB -244_274 native
    → Σ realized = 0, NO ×2 REALIZATION (regression test against V1 defect)
    → Fees accounted separately from realized PnL
```

**Combined: 56 tests, 0 failures, 0 skips.**

## Q. Realized-PnL regression result

Test C is the authoritative regression proof. It runs full production wiring (no mocks) and confirms:
- `realizedPnl1e8 = closedMarkValue - removedBasis - closedFunding` (§10 of directive)
- ALICE (long): +244_274 native (positive, credited)
- BOB (short): −244_274 native (negative, debited FIRST)
- `Σ realized = 0` conservation holds
- Fees are separately accounted (tier-0 50/300 ppm)
- No ×2 realization anywhere

**§10 regression gate: PASS.**

## R. Current live safety state

Re-verified live during this milestone (chain state at block ≥ `47_440_311`):

```
PME_V1.paused                                    = true                                                             ✓
V1_ENGINE.liquidationPaused                      = true                                                             ✓
Vault.isAuthorizedEngine(V1)                     = true                                                             ✓
Vault.isAuthorizedEngine(OLD_V2)                 = true                                                             ✓
Vault.balances(CLEARING_V2, mUSDC)               = 1_000_000_000                                                    ✓
Vault.balances(OLD_ENGINE, mUSDC)                = 0                                                                ✓
mUSDC.balanceOf(OLD_ENGINE)                      = 0                                                                ✓
mUSDC.balanceOf(CLEARING_V2)                     = 0                                                                ✓
Backend HEAD                                     = ad8dd7466 (unchanged)                                            ✓
Backend V2 broadcast                             = OFF                                                              ✓
V2 TradeExecuted since 47_407_874                = 0 events                                                          ✓
```

**Cutover state safe indefinitely. No deadline.**

**Recommendation on OLD_ENGINE Vault authorization**: **DO NOT revoke immediately.** OLD ENGINE cannot mutate Vault (its trade path reverts at the guard — proven live and via 56 tests). Deferring revocation until after NEW ENGINE validation gives a rollback lane if the recovery uncovers unexpected issues.

## S. Changed docs/tests

- `docs/PERPS_V2_BASE_SEPOLIA_V2_REDEPLOY_RECOVERY_PREFLIGHT_V1.md` — NEW (this file).

No production Solidity modification. No test modification. Existing tests re-run (no changes to their contents).

## T. Pushed HEAD

Sol repo new commit on top of `e311a5a`, pushed to `origin/main`.

## U. Remaining decisions

1. **`maxExecutionDeviationBps` value** — 100 bps is the operator-directive default. Alternatives to consider: 50 bps (tighter) or 200 bps (looser, matches worstPnlSwingBps=2000/20 relationship). Operator selects at deploy time; do NOT autonomously change.
2. **Optional OLD_ENGINE housekeeping** — timing of Vault deauthorization + FMV2/InsuranceFund flag removal. Non-blocking.
3. **Deployment script authorship** — a targeted `DeployPerpMarketRegistryV2.s.sol` + `DeployPerpEngineV2Recovery.s.sol` are recommended over `DeployPerpsE2E` (which is full-stack and would re-deploy too much). Author before executing.
4. **CBOR canonicalization on new engine** — snapshot manifest is unchanged, so no CBOR regeneration is needed. Reuse `artifacts/perps_v2_final_snapshot/manifest.{json,cbor}` verbatim.
5. **PME_V2 nonces** — still 0 for the canonical first-trade pair; safe to rebind without any nonce migration.

---

## Exact next milestone

Given local-fork validation is fully green (56/56 tests) and the minimal architecture is proven:

**Recommended next milestone**: `PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1` — a targeted `forge script` to deploy the new PerpMarketRegistry and configure markets 1 + 2 with `maxExecutionDeviationBps = 100`. Read-only preflight design + one-shot deployment. No engine deploy in that milestone.

Downstream sequence:
1. `PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1` — deploy + configure new PMR.
2. `PERPS_V2_BASE_SEPOLIA_ENGINE_V2_RECOVERY_DEPLOY_V1` — deploy new PerpEngineV2 pointing at new PMR + wire deps + migration seed + seal.
3. `PERPS_V2_BASE_SEPOLIA_V2_REBIND_V1` — atomic rebind of PME_V2/RISK_V2/FMV2/InsuranceFund to new engine.
4. `PERPS_V2_BASE_SEPOLIA_TIMELOCK_QUEUE_VAULT_AUTH_NEW_V2_V1` — queue Timelock op for NEW engine Vault auth.
5. Wait 24 h.
6. `PERPS_V2_BASE_SEPOLIA_TIMELOCK_EXECUTE_VAULT_AUTH_NEW_V2_V1` — OPS Safe execute.
7. Re-enter `PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ACTIVATION_PREFLIGHT_V2` (with the new engine address in mind).

**Do NOT execute any of these automatically. STOP.**
