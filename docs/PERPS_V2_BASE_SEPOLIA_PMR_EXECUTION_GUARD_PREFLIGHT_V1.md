# PERPS V2 BASE SEPOLIA PMR EXECUTION GUARD PREFLIGHT V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_PMR_EXECUTION_GUARD_PREFLIGHT_V1`
**Status**: **COMPLETE — READ-ONLY DESIGN/COMPATIBILITY PREFLIGHT; MAJOR REGRESSION IDENTIFIED**
**Sol HEAD (pre)**: `713088c` (unchanged during milestone; new docs commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Chain**: Base Sepolia (chainId `84532`)
**Cutover state**: V1 frozen (PME_V1.paused, V1_ENGINE.liquidationPaused, Vault.isAuthorizedEngine(V1)=true), V2 SEALED (snapshotHash=`0x039d9172…3d7d`), Vault.isAuthorizedEngine(V2)=true, Clearing=1_000_000_000 mUSDC, backend still V1, broadcast OFF. No V2 TradeExecuted since 47_407_874.

Scope: strictly read-only design/compatibility analysis. No chain writes, no deployment, no PMR mutation, no ENGINE_V2 mutation, no backend activation, no broadcast arming, no V2 trade, no Timelock/Safe tx, no DB writes. Goal: determine the exact minimal production-safe fix for the blocker identified in `BACKEND_V2_ACTIVATION_PREFLIGHT_V1 §V.1`.

---

## A. Exact blocker reproduction

**Failure**: `_marketRegistry.getMaxExecutionDeviationBps(uint256)` reverts with a bare `EvmError: Revert` because the selector is absent from the deployed PMR bytecode. Every `applyTrade` on ENGINE_V2 must call the guard, so every trade — every market, every price, every counterparty — reverts.

Live probe (block ≥ `47_407_874`):

```
cast call 0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC \
     "getMaxExecutionDeviationBps(uint256)(uint16)" 1 \
     --rpc-url $BASE_SEPOLIA
  → Error: execution reverted   (bare, no selector-encoded revert reason)

cast call 0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC \
     0x4d73d67f0000000000000000000000000000000000000000000000000000000000000001 \
     --rpc-url $BASE_SEPOLIA
  → Error: execution reverted   (raw selector 0x4d73d67f + uint256(1) — same result)
```

End-to-end applyTrade simulation from PME_V2 (structure `Trade` = `(address buyer, address seller, uint256 marketId, uint128 sizeDelta1e8, uint128 executionPrice1e8, bool buyerIsMaker)`):

```
Traces:
  [53887] ENGINE_V2::applyTrade((SHORT, LONG, 1, 10_000, 246_831_000_000, true))
    ├─ [12782] PMR::getMarket(1)                                    → OK
    ├─ [6165]  PMR::getRiskConfig(1)                                → OK
    ├─ [4306]  VAULT::getCollateralConfig(mUSDC)                    → OK
    ├─ [1398]  PMR::getMaxExecutionDeviationBps(1)                  → REVERT ← blocker
    └─ ← Revert                                                     (propagates)
Gas used: 76_295
```

Every pre-guard staticcall returned valid data. Failure isolates to a single missing selector on PMR.

## B. Missing selector

```
FUNCTION:  getMaxExecutionDeviationBps(uint256)
SELECTOR:  0x4d73d67f
RETURN:    uint16   (basis points, 0 = "unconfigured" → engine reverts)
STATE:     ABSENT from deployed PMR bytecode
```

Also missing (paired setter — same feature would need this to configure the value in a hypothetical future):

```
FUNCTION:  setMaxExecutionDeviationBps(uint256,uint16)
SELECTOR:  0x1108dbb8
STATE:     ABSENT from deployed PMR bytecode
```

Neither selector appears anywhere in the 25 045-char (12 522-byte) deployed PMR runtime bytecode. This is not a mis-encoding — the deployed contract simply does not have these functions.

## C. Frozen EngineV2 call path

From frozen source `src/perp/PerpEngineTradingV2.sol@713088c`:

```solidity
// src/perp/PerpEngineTradingV2.sol:769-793 — applyTrade (excerpt)
function applyTrade(Trade calldata t)
    external
    onlyMigrationSealed
    onlyMatchingEngine
    whenTradingNotPaused
    nonReentrant
{
    if (t.buyer == address(0) || t.seller == address(0) || t.buyer == t.seller) revert InvalidTrade();
    if (t.sizeDelta1e8 == 0) revert SizeZero();
    if (t.executionPrice1e8 == 0) revert PriceZero();
    _requireRiskModuleSet();

    PerpMarketRegistry.Market memory m = _requireMarketExists(t.marketId);
    if (!m.isActive) revert MarketInactive();

    PerpMarketRegistry.RiskConfig memory rcfg = _getRiskConfig(t.marketId);
    _requireSettlementAssetConfigured(m.settlementAsset);

    // Execution-price deviation guard.
    _enforceExecutionPriceGuard(t.marketId, uint256(t.executionPrice1e8));
    ...
}

// src/perp/PerpEngineTradingV2.sol:749-762
function _enforceExecutionPriceGuard(uint256 marketId, uint256 executionPrice1e8) internal view {
    uint16 boundBps = _marketRegistry.getMaxExecutionDeviationBps(marketId);
    if (boundBps == 0) revert ExecutionDeviationGuardNotConfigured();
    (uint256 reference1e8, bool ok) = _tryGetMarkPrice1e8(marketId);
    if (!ok || reference1e8 == 0) revert OracleUnavailableForExecutionGuard();
    uint256 diff = executionPrice1e8 > reference1e8
        ? executionPrice1e8 - reference1e8 : reference1e8 - executionPrice1e8;
    if (_mulChecked(diff, BPS) > _mulChecked(reference1e8, uint256(boundBps))) revert ExecutionPriceOutOfBand();
}
```

**Not a `try/catch`.** Direct external `staticcall`; any revert from PMR propagates. No default value, no fallback code path. Guard fires on every `applyTrade` and every `liquidate` (line 512 of `PerpEngineTrading.sol` has the same call for liquidations).

The deployed ENGINE_V2 bytecode does emit this call — confirmed live in the trace above (`[1398] PMR::getMaxExecutionDeviationBps(1)`). So the deployed engine matches the current source's guard requirement.

## D. Registry wiring mechanics

`_marketRegistry` is a plain storage variable set exactly once at construction:

```solidity
// src/perp/PerpEngineStorage.sol:77
PerpMarketRegistry internal _marketRegistry;

// src/perp/PerpEngineStorage.sol:255-262 — one-time init
function _initPerpEngineStorage(address owner_, address registry_, address vault_, address oracle_) internal {
    if (owner != address(0)) revert NotAuthorized();     // ← guards against re-init
    if (owner_ == address(0) || registry_ == address(0) || vault_ == address(0) || oracle_ == address(0)) {
        revert ZeroAddress();
    }
    owner = owner_;
    _marketRegistry = PerpMarketRegistry(registry_);     // ← the only assignment site
    _collateralVault = CollateralVault(vault_);
    _oracle = IOracle(oracle_);
    ...
}
```

Exhaustive search for a registry setter in the deployed engine source (HEAD `713088c`):

| Function searched | Where declared | Where implemented |
|---|---|---|
| `setMarketRegistry(address)` | `gouvernance/RiskGovernorInterfaces.sol:302` (**interface only**) | ❌ **NOT IMPLEMENTED** in any Perp engine contract |
| `setCollateralVault(address)` | interface + impl | ✓ implemented (`PerpEngineAdmin.sol:268`) |
| `setOracle(address)` | interface + impl | ✓ implemented (`PerpEngineAdmin.sol:183`) |
| `setRiskModule(address)` | interface + impl | ✓ implemented (`PerpEngineAdmin.sol:189`) |
| `setMatchingEngine(address)` | interface + impl | ✓ implemented (`PerpEngineAdmin.sol:162`) |
| `setInsuranceFund(address)` | interface + impl | ✓ implemented (`PerpEngineAdmin.sol:208`) |
| `setFeesManagerV2(address)` | interface + impl | ✓ implemented (`PerpEngineAdmin.sol:217`) |

`RiskGovernorQueue.queuePerpEngineSetMarketRegistry` (`gouvernance/RiskGovernorQueue.sol:1034`) exists and encodes `abi.encodeCall(IPerpEngineGov.setMarketRegistry, (registry_))`, but the target ENGINE_V2 has no matching selector — so any queued call would revert on execution.

Live verification of deployed ENGINE_V2 (`0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9`) selector inventory:

| Selector | Function | In deployed ENGINE_V2? |
|---|---|---|
| `0x68a806c4` | `setCollateralVault(address)` | ✓ PRESENT |
| `0x7adbf973` | `setOracle(address)` | ✓ PRESENT |
| `0x04f6f5b2` | `setRiskModule(address)` | ✓ PRESENT |
| `0xcaa57466` | `setMatchingEngine(address)` | ✓ PRESENT |
| `0x41590123` | `setClearingAccount(address)` | ✓ PRESENT |
| `0x81b5323a` | `setFeesManagerV2(address)` | ✓ PRESENT |
| **`0xd8579704`** | **`setMarketRegistry(address)`** | **✗ ABSENT** |

`marketRegistry()` view returns the current pointer live:

```
ENGINE_V2.marketRegistry()  = 0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC
```

**Conclusion — the registry pointer on the deployed ENGINE_V2 is init-immutable in practice.** No admin path exists to change it. `_marketRegistry` was set once at construction and cannot be updated by any external call.

## E. Complete expected-vs-deployed ABI matrix on PMR

Selectors ENGINE_V2 calls on `_marketRegistry` (grepped from `src/perp/`):

| Selector | Function | Consumed by ENGINE_V2? | In deployed PMR? |
|---|---|---|---|
| `0xeb44fdd3` | `getMarket(uint256)` | ✓ hot path (`PerpEngineStorage.sol:424`) | ✓ PRESENT |
| `0xa6a96c3a` | `getRiskConfig(uint256)` | ✓ hot path (line 429) | ✓ PRESENT |
| `0xc3cc3ad4` | `getLiquidationConfig(uint256)` | ✓ hot path (lines 437,470,479,487,496) | ✓ PRESENT |
| `0x3bcbd917` | `getFundingConfig(uint256)` | ✓ hot path (line 441) | ✓ PRESENT |
| **`0x4d73d67f`** | **`getMaxExecutionDeviationBps(uint256)`** | **✓ hot path (`PerpEngineTradingV2.sol:750`, `PerpEngineTrading.sol:512`)** | **✗ ABSENT** |

Additional selectors on the current-source PMR public surface (not called by ENGINE_V2 but verified on the deployed contract):

| Selector | Function | In deployed PMR? |
|---|---|---|
| `0x1108dbb8` | `setMaxExecutionDeviationBps(uint256,uint16)` | ✗ ABSENT |
| `0xec69a654` | `marketExists(uint256)` | ✓ PRESENT |
| `0xf849f69e` | `isMarketActive(uint256)` | ✓ PRESENT |
| `0x794b552a` | `isMarketCloseOnly(uint256)` | ✓ PRESENT |
| `0x8162486b` | `totalMarkets()` | ✓ PRESENT (returns `2`) |
| `0xf3c54006` | `marketAt(uint256)` | ✓ PRESENT |
| `0xb85ed636` | `getAllMarketIds()` | ✓ PRESENT |
| `0xc407c134` | `getMarketsByUnderlying(address)` | ✓ PRESENT |
| `0x85477fb3` | `setMarketStatus(uint256,bool,bool)` | ✓ PRESENT |
| `0xa6b7f8f2` | `setMarketOracle(uint256,address)` | ✓ PRESENT |
| `0xdd4d8a46` | `setSettlementAssetAllowed(address,bool)` | ✓ PRESENT |
| `0xd036d124` | `setMarketCreator(address,bool)` | ✓ PRESENT |
| `0x8a0dac4a` | `setGuardian(address)` | ✓ PRESENT |
| `0x8456cb59` | `pause()` | ✓ PRESENT |
| `0x3f4ba83a` | `unpause()` | ✓ PRESENT |
| `0xf2fde38b` | `transferOwnership(address)` | ✓ PRESENT |
| `0x8da5cb5b` | `owner()` = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 | ✓ PRESENT |

**Missing surface**: **exactly the two `getMaxExecutionDeviationBps` / `setMaxExecutionDeviationBps` selectors** — the deployed PMR belongs to a **generation strictly older than the execution-price-guard feature**. The remaining PMR surface is functionally intact (markets, risk config, liquidation config, funding config, oracle wiring, ownership).

This is **not a single missing getter that can be worked around**: the missing setter means there is no storage slot for the deviation value either. The deployed PMR generation predates the feature entirely.

Full PMR selector inventory (84 unique `PUSH4` immediates in dispatcher): none of them decode to `0x4d73d67f` or `0x1108dbb8`.

## F. Compatible PMR implementation in repo/history

Current source at HEAD `713088c` — `src/perp/PerpMarketRegistry.sol` (676 LOC) implements the required interface (lines 517, 654 for setter+getter). Introduced by commit **`221cef4` `feat(perps): pricing + execution safety core (V1)` (2026-09-01 16:09 +0800)**.

Deployed PMR (`0xb4fcf45E…`) was created on Base Sepolia at block `40_889_968` (2026-04-25 approx, ~4 months before the guard feature), via `broadcast/DeployCore.s.sol/84532/run-1777480640667.json` tx `0xd2dfafe8892903c3c1ea0c12d9e0…`. At that commit the PMR source did not contain the feature.

No newer PMR has been deployed to Base Sepolia at a live address. A dry-run at `broadcast/DeployPerpsE2E.s.sol/84532/run-latest.json` (commit `cdf606d`, 2026-09-20) shows PMR at `0xe890bb67…` at block `0x9` — that's an Anvil fork, not Base Sepolia (verified: `cast code 0xe890bb67…` returns empty).

Deploy scripts capable of producing a compatible PMR:
- `script/DeployCore.s.sol` — full core deploy (deploys PMR + engines + registries; NOT designed for standalone PMR redeploy)
- `script/DeployPerpsE2E.s.sol` — E2E fresh perp stack
- No standalone `DeployPerpMarketRegistryV2.s.sol` exists; a targeted redeploy script must be authored.

## G. Minimal fix classification

Evaluation of each fix class against the frozen state:

| Class | Description | Verdict | Reason |
|---|---|---|---|
| **A** | Existing PMR config only | ❌ **IMPOSSIBLE** | Deployed PMR bytecode does not implement `getMaxExecutionDeviationBps` nor its setter — no storage slot exists, no admin path can configure a value that isn't storable. |
| **B** | New compatible PMR + ENGINE rewire | ❌ **IMPOSSIBLE** | ENGINE_V2 has no `setMarketRegistry` selector (`0xd8579704` ABSENT). `_marketRegistry` is set exactly once in `_initPerpEngineStorage` and re-init is gated by `if (owner != address(0)) revert NotAuthorized();` — the engine has been initialized, so the init path is closed forever. |
| **C** | Upgrade existing PMR | ❌ **IMPOSSIBLE** | Deployed PMR is not a proxy. EIP-1967 implementation/admin/beacon slots all `0x00…00`; `proxiableUUID()`, `implementation()`, `getImplementation()`, `admin()` all revert. Bytecode is a direct implementation (25 KiB). No selfdestruct in source. Contract code is immutable at address `0xb4fcf45E…`. |
| **D** | ENGINE_V2 change required | ⚠ **ONLY REMAINING CHAIN-SIDE PATH** | Requires redeploying ENGINE_V2 (new address, new bytecode) pointing at a new PMR, then re-executing the entire migration flow (begin → seed → seal → Vault-auth Timelock → Safe execute). Voids the currently sealed migration on the abandoned ENGINE_V2 (`0x44702B0A…`), which stays frozen at `snapshotHash=0x039d9172…3d7d` forever. |
| **E** | Other | ❌ **NONE IDENTIFIED** | Considered and rejected: (E1) proxy-in-front-of-PMR — impossible, ENGINE_V2 hardcodes the pointer; (E2) never-trade V2 — defeats migration purpose; (E3) off-chain accounting override — not a real activation; (E4) selfdestruct+redeploy — PMR has no selfdestruct source, and EIP-6780 (post-Cancun, active on Base) restricts SELFDESTRUCT to the same-tx-as-creation contract anyway. |

**Chosen classification: D — ENGINE_V2 CHANGE REQUIRED (major regression).**

## H. Market configuration to preserve (live-read snapshot for D)

If a new PMR is deployed under option D, market 1 and market 2 configuration must be replicated byte-identical (otherwise position accounting on the new engine will diverge from the SEALED artifact hash).

**Market 1 — ETH-PERP**:
```
underlying         = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02          (WETH-like)
settlementAsset    = 0x6eAe407f5640B006faC9965182e238582A3B412E          (mUSDC)
oracle             = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581          (shared perp oracle)
symbol             = "ETH-PERP"     (bytes32 = 0x4554482d504552500000…)
state              = 1              (enum value; interpreted as "exists"/"active")
isActive           = true
isCloseOnly        = false

riskConfig raw     = (1000, 750, 500, 10_000_000_000, 50_000_000_000, 1)
  interpreted per src/perp/PerpMarketRegistry.sol RiskConfig at HEAD:
    initialMarginBps         = 1000  (10%)
    maintenanceMarginBps     =  750
    liquidationPenaltyBps    =  500
    maxPositionSize1e8       = 10_000_000_000
    maxOpenInterest1e8       = 50_000_000_000
    reduceOnlyDuringCloseOnly= true (1)
  NOTE: deployed PMR predates the current struct schema; field order may
  differ slightly. New PMR (current-source generation) MUST use current
  struct order — operator MUST verify by comparing selectors after redeploy.

liquidationConfig raw = (5000, 100, 50, 60)
fundingConfig raw     = (0, 0)      (funding disabled at migration time)
```

**Market 2 — BTC-PERP**:
```
underlying         = 0x9D871aC7595E8Da271E866608E5145252047967c
settlementAsset    = 0x6eAe407f5640B006faC9965182e238582A3B412E
oracle             = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
symbol             = "BTC-PERP"     (bytes32 = 0x4254432d504552500000…)
state              = 1
isActive           = true
isCloseOnly        = false

riskConfig raw     = (1200, 800, 400, 1_000_000_000, 10_000_000_000, 1)
liquidationConfig  = (5000, 80, 50, 60)
fundingConfig      = (0, 0)
```

**Additional PMR-level state to preserve**:
```
owner              = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
totalMarkets       = 2
guardian           = check live (`guardian()`) at redeploy time
paused/creationPaused/configPaused = false / false / false (informational)
```

## I. Execution-deviation bps intended value + source

Directive spec (this milestone §6 of prior BACKEND_V2_ACTIVATION_PREFLIGHT): `100 bps` (= 1 %).

Corroborating repo sources:
- `docs/PERPS_V2_BASE_SEPOLIA_FINAL_SNAPSHOT_V1.md` §I (worst-case market params): `worstPnlSwingBps=2000` — this is the RISK model swing, not the execution guard.
- `artifacts/perps_v2_final_snapshot/market_params.json` line 8: `"worstPnlSwingBps": 2000` — same.
- **No committed source or test currently pins `maxExecutionDeviationBps=100`** for market 1 or 2. The only authoritative source is the operator directive.

Recommended value for new PMR post-D redeploy:
```
setMaxExecutionDeviationBps(1, 100)   // ETH-PERP, 1%
setMaxExecutionDeviationBps(2, 100)   // BTC-PERP, 1%
```

Loose enough to accept normal execution slippage; tight enough to fail-close on obviously stale matching-engine input. Verify against `docs/PERPS_V2_SOLIDITY_FIX_AND_TESTS_V1.md` if operator wants a different value; if that doc is silent, accept the 100-bps target.

## J. Authority model (for option D writes)

Every write required under option D, with its exact caller authority:

| # | Action | Target | Function | Authority |
|---|---|---|---|---|
| 1 | Deploy new PMR (compatible ABI) | (new addr) | constructor | OWNER EOA (`0xc35F7A…3C27`) |
| 2 | Configure markets on new PMR | new PMR | `createMarket`, `setRiskConfig`, `setLiquidationConfig`, `setFundingConfig`, `setMarketMetadata`, `setMarketStatus`, `setMarketOracle`, `setSettlementAssetAllowed` | OWNER EOA (PMR `onlyOwner`) |
| 3 | Set execution deviation | new PMR | `setMaxExecutionDeviationBps(1, 100)`, `setMaxExecutionDeviationBps(2, 100)` | OWNER EOA |
| 4 | Deploy new PerpEngineV2' | (new addr) | constructor(owner, newPMR, VAULT, ORACLE) | OWNER EOA (must fit EIP-170 — see §M) |
| 5 | Deploy new PerpMatchingEngineV2' | (new addr) | constructor(new engine, chainId) | OWNER EOA |
| 6 | Wire matching engine → engine | new engine | `setMatchingEngine(newPME)` | OWNER EOA |
| 7 | Wire risk module → engine | RISK_V2 | `setPerpEngine(newEngine)` | OWNER EOA (Risk `onlyOwner`) |
| 8 | Wire clearing → engine | CLEARING_V2 | `setPerpEngine(newEngine)` (if such setter exists on ClearingV2) | OWNER EOA |
| 9 | Wire fees → engine | FMV2 | `setFeeConsumer(newEngine, true)` + `setFeeConsumer(oldEngine, false)` | OWNER EOA |
| 10 | Migration begin+seed+seal on new engine | new engine | `beginMigration()` + 8× `adminSeedMarketFunding/adminSeedPosition` + `sealMigration(newHash)` | OWNER EOA (`onlyOwner` on migration admin fns) |
| 11 | **Vault re-authorization** | VAULT | `setAuthorizedEngine(newEngine, true)` + `setAuthorizedEngine(oldEngine, false)` | **PROTOCOL_TIMELOCK** (VAULT `onlyTimelock`) — queue by RiskGovernor, execute by OPS Safe |
| 12 | Queue Timelock op | PROTOCOL_TIMELOCK | `queueTransaction(VAULT, 0, calldata, eta)` | **RiskGovernor** (Timelock `onlyProposer`) |
| 13 | Execute Timelock op after 24 h ETA | PROTOCOL_TIMELOCK | `executeTransaction(...)` | **OPS Safe** (Timelock `onlyExecutor`) |
| 14 | Backend env update | (backend) | `PERP_ENGINE_V2_ADDRESS`, `PERP_MATCHING_ENGINE_V2_ADDRESS` | operator |

Governance chain surface for the single Timelock hop: same as `TIMELOCK_EXECUTE_VAULT_AUTH_V1` — RiskGovernor queues (must be a proposer), 24-hour min delay, OPS Safe 2/3 executes. **The Timelock op that authorized V2 previously has already been executed and cannot be replayed** (returns `TransactionNotQueued()` selector `0x0280b15e`) — a fresh queue with a new opId is required for the new engine address.

Every step except 11–13 is caller = OWNER EOA. Steps 11–13 require Timelock + OPS Safe as usual.

## K. Exact writes eventually required (option D, at least 13 tx + 1 governance flow)

Not prepared, not queued — this is a **capacity plan**, not an approval:

```
TX-1   deploy PerpMarketRegistry (new impl)
TX-2   PMR.createMarket(1, ETH-PERP config)
TX-3   PMR.setRiskConfig(1, …)          // + Liquidation, Funding, Metadata, Oracle
TX-4   PMR.createMarket(2, BTC-PERP config) [+ risk/liq/funding/metadata/oracle]
TX-5   PMR.setSettlementAssetAllowed(mUSDC, true)
TX-6   PMR.setMaxExecutionDeviationBps(1, 100)
TX-7   PMR.setMaxExecutionDeviationBps(2, 100)
TX-8   deploy PerpEngineV2' (new engine, points at new PMR)
TX-9   deploy PerpMatchingEngineV2' (or reuse; verify V2 domain "verifyingContract" changes)
TX-10  new engine.setMatchingEngine(newPME)
TX-11  RISK_V2.setPerpEngine(newEngine)  + CLEARING_V2.setPerpEngine(newEngine)
TX-12  FMV2.setFeeConsumer(newEngine, true) + setFeeConsumer(oldEngine, false)
TX-13  new engine.beginMigration() + 2× adminSeedMarketFunding + 6× adminSeedPosition
TX-14  new engine.sealMigration(newSnapshotHash)   ← new hash, canonical CBOR regeneration
GOV-A  RiskGovernor.queuePerpEngineSetVaultAuth  → Timelock.queueTransaction(VAULT, setAuthorizedEngine(newEngine, true), eta=now+86400)
GOV-B  wait 24 h min delay
GOV-C  OPS Safe 2/3 → Timelock.executeTransaction(...)
BACKEND  operator flips PERP_ENGINE_V2_ADDRESS + PERP_MATCHING_ENGINE_V2_ADDRESS
```

Plus a NEW EIP-712 domain (`verifyingContract` = new PME) — every backend `PerpTradeDomain::new_v2` invocation resolves against the new address automatically, but any V2 signature signed under the OLD PME will not verify on the NEW PME. No V2 signatures have been consumed yet (nonces=0 for the first-trade pair), so this is safe.

## L. Local/fork validation results

Read-only design analysis; no local fork executed in this milestone. If operator elects to proceed with D, the compatibility test plan is:

```
Anvil fork:
  RPC          = anvil --fork-url $BASE_SEPOLIA --fork-block-number <recent>
  OWNER        = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27  (impersonate)
  OPS Safe     = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46 (impersonate)

Tests (forge test / -j 1, --test-threads=1):
  1. Fresh PMR (current-source) implements 0x4d73d67f + 0x1108dbb8         [selector inventory]
  2. PMR.setMaxExecutionDeviationBps(1, 100) succeeds under OWNER          [config path]
  3. PMR.getMaxExecutionDeviationBps(1) returns 100                        [readback]
  4. Fresh ENGINE_V2' points at new PMR after construction                 [wiring]
  5. adminSeedPosition seeds byte-identical to manifest for all 6 traders  [regression against manifest.json]
  6. sealMigration produces a new snapshotHash that CBOR-encodes to the
     same shape as 0x039d9172…3d7d if inputs are unchanged; hash differs
     due to new marketRegistry / verifyingContract if those are inside
     the canonical CBOR body (they ARE NOT — hash is over
     market state + positions, not contract addresses); expected hash
     equals 0x039d9172…3d7d                                                [canonicality]
  7. applyTrade with executionPrice within ±100 bps passes                 [in-band]
  8. applyTrade with executionPrice outside ±100 bps reverts               [out-of-band]
  9. applyTrade with unusable oracle reverts OracleUnavailableForExecutionGuard
                                                                          [oracle-degrade path]
 10. Liquidation path also passes through _enforceExecutionPriceGuard      [PerpEngineTrading.sol:512]
 11. V1 addresses untouched during entire flow                             [invariant]
 12. Vault re-authorization via Timelock succeeds; old-engine authorization revoked
                                                                          [governance]

Resource safety:
  CARGO_BUILD_JOBS=1 forge test -j 1 --match-path 'test/perp/...' --test-threads=1
  free -h before + after
  no concurrent Cargo/Forge
```

Full pass required before any Base Sepolia deployment.

## M. EngineV2 bytecode / EIP-170 impact

**The chosen fix (D) DOES require ENGINE_V2 modification** — specifically a fresh deployment of the same bytecode with a different constructor argument.

Current deployed ENGINE_V2 runtime bytecode: **24 321 bytes**, headroom **255 bytes** below the 24 576-byte EIP-170 cap. This is post-`SIZE_REDUCTION_A/B/C/D` (commits `539fb12` → `004bf78`, 2026-09-21 → 2026-09-22): "HALTED @ EIP-170" was the earlier state (commit `8ed1ad8`), so the current headroom is the minimum viable.

**If the new deployment uses the exact same source at HEAD `713088c`**, the runtime bytecode is byte-identical to the currently deployed contract (modulo the constructor-arg immutable slot for PMR address, which is a storage write, not code). **EIP-170 proof carries forward.**

**If ANY other change is made to `src/perp/PerpEngine*.sol`** as part of the fix, a new EIP-170 measurement is required:

```
forge build
forge inspect PerpEngineV2 deployedBytecode | wc -c   # divide by 2, subtract 1
# must be < 24576
```

**Recommend: do NOT touch PerpEngineV2 source. Redeploy the same bytecode.** This preserves the existing size proof and requires zero additional review.

## N. Current cutover safety state

Live confirmation at block ≥ `47_407_874` (see prior `BACKEND_V2_ACTIVATION_PREFLIGHT_V1 §0`):

```
PME_V1.paused                                    = true                                                             ✓
V1_ENGINE.liquidationPaused                      = true                                                             ✓
Vault.isAuthorizedEngine(V1)                     = true                                                             ✓
Vault.isAuthorizedEngine(V2)                     = true                                                             ✓
ENGINE_V2.migrationState                         = 1 (SEALED)                                                       ✓
ENGINE_V2.migrationSnapshotHash                  = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d ✓
Vault.balances(CLEARING_V2, mUSDC)               = 1_000_000_000                                                    ✓
ENGINE_V2 TradeExecuted (6-arg) since 47_407_874 = 0 events                                                          ✓
Timelock op 0xb42e46a9…4fd0                      = executed (queued=false); cannot be replayed                       ✓
```

**No deadline forcing the fix.** The cutover state is stable indefinitely. Operator has time to design and validate option D correctly.

**Explicit non-invalidation**: the previously queued Timelock op has already been executed and consumed (as noted in `TIMELOCK_EXECUTE_VAULT_AUTH_V1 §J`). It is NOT pending. Any future Timelock write (option D step 11–13) requires a NEW queue with a NEW opId.

## O. Changed docs/tests

- `docs/PERPS_V2_BASE_SEPOLIA_PMR_EXECUTION_GUARD_PREFLIGHT_V1.md` — NEW (this file).

No production Solidity modification. No backend modification. No test modification.

## P. Pushed HEAD

Sol repo new commit on top of `713088c`, pushed to `origin/main`.

## Q. Blockers

**No pre-conditions block this preflight itself** — it was read-only and completes with a full determination.

**Blockers for downstream execution** (option D):

1. **Operator decision required** — option D is a MAJOR REGRESSION that voids the current sealed migration on ENGINE_V2 (`0x44702B0A…`). The abandoned engine will hold `1_000_000_000` mUSDC of clearing collateral and 6 seeded positions permanently. Operator must consciously accept the write-off, or determine an off-chain accounting mechanism to record the transition.
2. **`maxExecutionDeviationBps` value** — no committed source pins the value; `100 bps` is the directive default. If operator wants a different value, document before deploying the new PMR.
3. **New EIP-712 domain awareness** — new PME_V2' has a different `verifyingContract`. Any test signature stored anywhere (backend fixture, test artifact) must be regenerated. No production signatures exist yet (nonces=0 for the first-trade pair).
4. **Backend two-address hot-swap** — during the transition window (old-engine V2 SEALED, new-engine V2 SEALED), backend must resolve which engine to route new intents to. Recommend the `PERP_ENGINE_V2_ADDRESS` env var be flipped only AFTER new-engine seal + Vault authorization are complete on-chain. Reconciler will not touch old-engine addresses because no V2 rows exist there yet.
5. **EIP-170 headroom is 255 bytes** — do NOT touch `src/perp/PerpEngine*.sol` as part of the fix; redeploy the identical bytecode. If any source change slips in, run `forge inspect PerpEngineV2 deployedBytecode | wc -c` before broadcasting.

---

## Exact next milestone

**Blocked pending operator decision on option D vs stay-frozen.** Two candidate sequences:

### If operator accepts option D:

1. `PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1` — deploy new PMR at HEAD `713088c`, configure markets 1+2 byte-identical to current PMR, set `maxExecutionDeviationBps(1)=100` and `(2)=100`, verify selector inventory.
2. `PERPS_V2_BASE_SEPOLIA_ENGINE_V2_REDEPLOY_V1` — redeploy PerpEngineV2 pointing at new PMR (same bytecode; new constructor arg); verify EIP-170 headroom; wire matching engine, risk, clearing, fees.
3. `PERPS_V2_BASE_SEPOLIA_MIGRATION_REDO_V1` — begin migration on new engine; re-run 8-step seed calldata iterator; seal with recomputed snapshotHash.
4. `PERPS_V2_BASE_SEPOLIA_ENGINE_V2_PMR_REWIRE_V1` — (redundant if 2 is used; kept as an alternate label in case the operator prefers a per-step split).
5. `PERPS_V2_BASE_SEPOLIA_TIMELOCK_EXECUTE_VAULT_AUTH_V2_V1` — queue + wait + execute Timelock op to authorize the NEW engine and revoke the OLD.
6. Then re-enter `PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ACTIVATION_PREFLIGHT_V2` with the new addresses.

### If operator elects to stay frozen:

Do nothing on-chain. Backend remains V1; V2 remains SEALED and unusable. Document the freeze in a "known-limitations" record.

**Recommended next milestone (if D is chosen)**: `PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1` — read-only design + one-shot deployment.

**Do NOT execute either automatically. STOP.**
