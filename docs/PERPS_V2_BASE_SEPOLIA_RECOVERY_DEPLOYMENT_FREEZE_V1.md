# PERPS V2 BASE SEPOLIA RECOVERY DEPLOYMENT FREEZE V1

> Hash terminology correction — `PERPS_V2_CODEX_HANDOFF_RECONCILIATION_V1`: runtime identities below use **Ethereum Keccak-256**, verified with `cast keccak` and byte-for-byte live/local comparison. The previously published Engine value `0xef5486354584feba953f4eed0d5573b65e9e2bfb6dca0e43a4eedfe7ba46652e` and PMR value `0x5d66f23543a0e9ded3da5e85c8f0413af3cbe00794e99e1aa3c9b1b40c63fd8c` are **NIST SHA3-256**, not Ethereum hashes. This correction does not change deployed bytes, historical transactions, or the canonical migration snapshotHash. See [reconciliation](PERPS_V2_CODEX_HANDOFF_RECONCILIATION_V1.md) for current script guards and the operator's intentionally STOPPED backend decision.

**Milestone**: `PERPS_V2_BASE_SEPOLIA_RECOVERY_DEPLOYMENT_FREEZE_V1`
**Status**: **COMPLETE — TOOLCHAIN + BYTECODE + SCRIPTS + LOCAL REHEARSAL FROZEN**
**Sol HEAD (pre)**: `a891283` (unchanged during milestone; new commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Chain**: Base Sepolia (chainId `84532`)

Scope: read-only / local only. No public-chain writes, no deployment, no contract mutation, no Safe/Timelock tx, no backend mutation, no DB writes, no trade. Freeze the exact recovery deployment artifacts before the first public write.

**Executive summary**: the prior preflight's 18-byte runtime discrepancy was a measurement error — after correctly linking the two deployed libraries (`PerpEngineLiquidationLib` at `0x69F3868F…E77D`, `PerpEngineSeizureLib` at `0xf0C56522…60A5`), the current-source PerpEngineV2 compiles to **byte-identical runtime bytecode** as the deployed OLD engine (`0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`, 24_321 bytes). Two deploy scripts are authored + compiled; 3 new rehearsal tests + 56 pre-existing tests = **59 tests green** proving the recovery flow end-to-end.

---

## A. Compiler / toolchain finding

Frozen build configuration (from `foundry.toml` + `out/PerpEngineV2.sol/PerpEngineV2.json` compilation metadata):

```
solc:             0.8.30+commit.73712a01
Foundry:          1.5.0-stable (commit 1c57854462289b2e71ee7654cd6666217ed86ffd)
optimizer:        enabled = true
optimizer_runs:   0
via_ir:           true
evmVersion:       prague
bytecode_hash:    none                      (foundry.toml `bytecode_hash = "none"`)
cbor_metadata:    false                     (foundry.toml `cbor_metadata = false`)
libraries:        {} (linked at deploy time; see §K)
```

`bytecode_hash = "none"` + `cbor_metadata = false` mean the compiler emits **no trailing IPFS/bzzr metadata**, so the runtime bytecode is fully deterministic across builds on the same solc + optimizer settings. This is the load-bearing setting for byte-for-byte bytecode reproducibility.

## B. Explanation of the previously observed 18-byte runtime discrepancy

**The 18-byte gap was a measurement artefact, not a real code diff.** Root cause: my prior comparison used `forge inspect PerpEngineV2 deployedBytecode | wc -c`, whose text output contains the library placeholders `__$…$__` — 40 chars each, occupying the position where a linked library address would go. When I attempted to decode those hex-with-placeholders bytes, the parse either failed (raising `ValueError` mid-decode) or silently truncated at the first non-hex char.

Re-reading the compilation artifact (`out/PerpEngineV2.sol/PerpEngineV2.json`) via `json.load` gives the full `deployedBytecode.object` (48_642 chars = 24_321 bytes) plus a `linkReferences` map keyed by library. Substituting the two deployed library addresses at the offsets specified by `linkReferences` produces the exact runtime bytecode.

Result of correctly-linked compile:

```
size (linked): 24_321 bytes
Ethereum Keccak-256:     0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a
```

matches the live-chain readback of `cast code 0x44702B0A…6db9`:

```
size:      24_321 bytes
Ethereum Keccak-256: 0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a
```

**Classification of the (now-zero) difference**:

| Class | Diff observed? | Notes |
|---|---|---|
| A. metadata-only | none | `bytecode_hash=none` + `cbor_metadata=false` in foundry.toml eliminate trailing metadata |
| B. library-link | RESOLVED | Two libraries reused byte-identical at their existing deployed addresses |
| C. executable opcode | none | Byte-for-byte identity after linking |
| D. compiler / EVM-target | none | Same solc 0.8.30, same evmVersion `prague`, same optimizer settings |

**The earlier claim about "PUSH0 diff" was noise from the parse failure**, not a real byte difference. No compiler upgrade, no optimizer change, no evmVersion change is required for the recovery deployment.

## C. Was OLD runtime exactly reproduced?

**YES — byte-identical.** Same source (`src/perp/PerpEngineV2.sol` + siblings at HEAD `a891283`), same toolchain (§A), same library addresses linked in. Every one of the 24_321 runtime bytes reproduces.

Verification recipe (deterministic):

```python
import json, subprocess

d = json.load(open('out/PerpEngineV2.sol/PerpEngineV2.json'))
obj = d['deployedBytecode']['object'][2:]  # strip 0x

LIB_ADDRS = {
    'PerpEngineLiquidationLib': '0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D',
    'PerpEngineSeizureLib':     '0xf0C5652277CF88B508E05F7aB54949fCDF0360A5',
}

positions = []
for filepath, libs in d['deployedBytecode']['linkReferences'].items():
    for libname, refs in libs.items():
        addr = LIB_ADDRS[libname].lower().replace('0x','')
        for ref in refs:
            positions.append((ref['start']*2, ref['length']*2, addr))
positions.sort(reverse=True)

for start, length, addr in positions:
    obj = obj[:start] + addr + obj[start+length:]

b = bytes.fromhex(obj)
assert len(b) == 24321
assert subprocess.check_output(['cast', 'keccak'], input='0x' + b.hex(), text=True).strip() == \
       '0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a'
```

## D. Frozen NEW Engine runtime hash / size

```
source:         src/perp/PerpEngineV2.sol @ HEAD a891283
linked libs:    PerpEngineLiquidationLib = 0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D
                PerpEngineSeizureLib     = 0xf0C5652277CF88B508E05F7aB54949fCDF0360A5
runtime size:   24_321 bytes
runtime Ethereum Keccak-256: 0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a
```

## E. EIP-170 headroom

```
runtime size = 24_321 bytes
EIP-170 cap  = 24_576 bytes
headroom     = 255 bytes
```

Identical to the OLD deployed engine (same bytecode). No new size proof required.

## F. Storage-layout proof

`forge inspect PerpEngineV2 storage-layout` confirms canonical layout used by the migration tooling (verbatim first 12 slots):

```
slot  offset  name                       type
0     0       owner                      address
1     0       pendingOwner               address
2     0       matchingEngine             address
3     0       guardian                   address
4     0       _marketRegistry            contract PerpMarketRegistry
5     0       _collateralVault           contract CollateralVault
6     0       _oracle                    contract IOracle
7     0       _riskModule                contract IPerpRiskModule
8     0       _collateralSeizer          contract ICollateralSeizer
9     0       _feesManager               contract IFeesManager
10    0       feesManagerV2              contract IFeesManagerV2
10    20      useFeesManagerV2           bool
11    0       insuranceFund              address
… (further slots: pause/emergency flags, migration state, position mappings, market state, funding state, residual bad debt, subaccounts, clearing, etc.)
```

Byte-identical bytecode ⇒ byte-identical storage layout (Solidity's storage layout is a compiler artefact fully encoded in bytecode offsets). No layout drift possible from a redeploy.

## G. NEW PMR runtime hash / size

```
source:              src/perp/PerpMarketRegistry.sol @ HEAD a891283
linked libs:         none (self-contained, no library placeholders)
creation size:       13_534 bytes
runtime size:        13_217 bytes
runtime Ethereum Keccak-256:   0x70a03433c8f58ac8e97e6caa5c0e488db1440c05aa1dce46b0fef4930e8194f5
```

Well under EIP-170. New deployment (fresh address) will differ from OLD PMR (`0xb4fcf45E…`) — that's the point; the OLD PMR is deliberately being replaced.

## H. Selector compatibility

Selectors on frozen NEW PMR runtime bytecode (probed by scanning dispatcher table for `PUSH4 <sel>` immediates):

| Selector | Function | Present in NEW PMR? | Consumed by ENGINE_V2? | Present in OLD deployed PMR? |
|---|---|---|---|---|
| `0xeb44fdd3` | `getMarket(uint256)` | ✓ | ✓ hot | ✓ |
| `0xa6a96c3a` | `getRiskConfig(uint256)` | ✓ | ✓ hot | ✓ |
| `0xc3cc3ad4` | `getLiquidationConfig(uint256)` | ✓ | ✓ hot | ✓ |
| `0x3bcbd917` | `getFundingConfig(uint256)` | ✓ | ✓ hot | ✓ |
| **`0x4d73d67f`** | **`getMaxExecutionDeviationBps(uint256)`** | **✓** | **✓ hot** (the blocker) | **✗ ABSENT** |
| **`0x1108dbb8`** | **`setMaxExecutionDeviationBps(uint256,uint16)`** | **✓** | (owner-only) | **✗ ABSENT** |
| `0xec69a654` | `marketExists(uint256)` | ✓ | — | ✓ |
| `0x8162486b` | `totalMarkets()` | ✓ | — | ✓ |
| `0xb85ed636` | `getAllMarketIds()` | ✓ | — | ✓ |
| `0xf3c54006` | `marketAt(uint256)` | ✓ | — | ✓ |

**All ENGINE_V2 required selectors present in NEW PMR. The two missing-on-OLD selectors are present.**

## I. Exact PMR config (100 bps policy)

**Operator policy value** (labeled explicitly, not chain state):

```
maxExecutionDeviationBps(marketId=1) = 100  (OPERATOR POLICY, ETH-PERP)
maxExecutionDeviationBps(marketId=2) = 100  (OPERATOR POLICY, BTC-PERP)
```

Every other PMR field is copied byte-identical from the OLD PMR live-read snapshot (§H of prior `PERPS_V2_BASE_SEPOLIA_V2_REDEPLOY_RECOVERY_PREFLIGHT_V1`):

**Market 1 — ETH-PERP** (`marketId` = 1):
```
underlying         = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02
settlementAsset    = 0x6eAe407f5640B006faC9965182e238582A3B412E    (mUSDC)
oracle             = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
symbol             = "ETH-PERP"                                    (bytes32)
riskConfig:
  initialMarginBps          = 1_000
  maintenanceMarginBps      = 750
  liquidationPenaltyBps     = 500
  maxPositionSize1e8        = 10_000_000_000
  maxOpenInterest1e8        = 50_000_000_000
  reduceOnlyDuringCloseOnly = true
liquidationConfig:
  closeFactorBps            = 5_000
  priceSpreadBps            = 100
  minImprovementBps         = 50
  oracleMaxDelay            = 60
fundingConfig:
  isEnabled                 = false
  fundingInterval           = 0
  maxFundingRateBps         = 0
  maxSkewFundingBps         = 0
  oracleClampBps            = 0
  impactMidMaxDelay         = 0
isActive                    = true (auto by createMarket)
isCloseOnly                 = false (auto by createMarket)
maxExecutionDeviationBps    = 100 (operator policy)
```

**Market 2 — BTC-PERP** (`marketId` = 2):
```
underlying         = 0x9D871aC7595E8Da271E866608E5145252047967c
settlementAsset    = 0x6eAe407f5640B006faC9965182e238582A3B412E
oracle             = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
symbol             = "BTC-PERP"
riskConfig:
  initialMarginBps          = 1_200
  maintenanceMarginBps      = 800
  liquidationPenaltyBps     = 400
  maxPositionSize1e8        = 1_000_000_000
  maxOpenInterest1e8        = 10_000_000_000
  reduceOnlyDuringCloseOnly = true
liquidationConfig:
  closeFactorBps            = 5_000
  priceSpreadBps            = 80
  minImprovementBps         = 50
  oracleMaxDelay            = 60
fundingConfig                (all zeros as above)
maxExecutionDeviationBps    = 100 (operator policy)
```

Note on FundingConfig schema: OLD PMR (deployed 2026-04-25) uses a 5-field FundingConfig; current source uses a 6-field FundingConfig (added `impactMidMaxDelay`). New PMR uses the current 6-field schema with all-zeros (funding disabled), which is exactly the intended semantic for markets 1 and 2 (funding disabled at migration time, per manifest `cumulativeFundingRate1e18=0`, `lastFundingTimestamp=1_789_715_546` for market 1 and 0 for market 2).

## J. Deployment scripts

Two narrow, deterministic Forge scripts authored:

- `script/DeployPerpMarketRegistryV2.s.sol` — PMR only. Deploys, allows settlement asset, creates markets 1 + 2 with byte-identical config, sets both `maxExecutionDeviationBps = 100`, readback-verifies. **Default: preflight-only, no broadcast.** Broadcast requires `PERP_MARKET_REGISTRY_V2_DEPLOY_CONFIRM=true` env.
- `script/DeployPerpEngineV2Recovery.s.sol` — engine only. Deploys `PerpEngineV2(OWNER, NEW_PMR, VAULT, ORACLE_ROUTER)`, wires the 8 engine-side setters (`setMatchingEngine`, `setRiskModule`, `setClearingAccount`, `setInsuranceFund`, `setCollateralSeizer`, `setFeesManagerV2`, `setUseFeesManagerV2(true)`, `setGuardian`) using the existing PME_V2 / RISK_V2 / CLEARING_V2 / etc addresses byte-identical. Includes a pre-broadcast selector check on the target PMR (staticcalls `getMaxExecutionDeviationBps(1)`) to fail-close if the operator supplied a non-recovery PMR. **Default: preflight-only.** Broadcast requires `PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM=true` env.

Both scripts:
- Assert chainId == 84532 (Base Sepolia).
- Assert deployer address == expected `OWNER` (`0xc35F7A…3C27`).
- Do NOT touch PME_V2, RISK_V2, FMV2, InsuranceFund, or Vault (rebind + Vault-auth are separate later milestones per §8).
- Do NOT execute migration seed / seal (that belongs to `MIGRATION_REPLAY_V1` / `MIGRATION_RESEAL_V1`).
- Include full readback assertions post-broadcast.

## K. Script hashes

Frozen script artifacts (`out/DeployPerp*V2*.s.sol/*.json`):

```
DeployPerpMarketRegistryV2:
  creation sha256   = 0xc16bd112c5da87b60b14f1a7de0ad86bdd63691b63bc504bb2cf51af159eab12
  runtime sha256    = 0x3b1d7ebb344e761e8bd8002db3fc696162ce602ab61434843b6c841fdc238c56
  ABI sha256        = 0x881ac1460eedf68402fba9c4203b4b0b50d2489a86cdfd55356e8115a0a7e1bd
  rawMetadata sha   = 0x5041c1132fe22335f4e569e43d2dc8c1c3b203475cd1c8c9c3ab4982cafa013c

DeployPerpEngineV2Recovery:
  creation          = has library placeholders (linked at deploy; deterministic post-link)
  runtime           = has library placeholders
  ABI sha256        = 0xbf601eb7f4a1a260a18b001fa3a6ea4e373b12901edc355d5ca60a1429d20ad8
  rawMetadata sha   = 0xf668299b0281ceecf6e9bf94da65dd87849cc573b5654fb483e469536982744e
```

Library link addresses (must match the deployed OLD engine's libraries for identical runtime):
- `PerpEngineLiquidationLib = 0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D`
- `PerpEngineSeizureLib     = 0xf0C5652277CF88B508E05F7aB54949fCDF0360A5`

## L. Migration replay proof

Canonical artifacts frozen and re-used byte-identical (already committed under `artifacts/perps_v2_final_snapshot/`):

```
SNAPSHOT_BLOCK      = 47_354_411
SNAPSHOT_BLOCK_HASH = 0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89
snapshotHash        = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d
manifest.json       (3399 B, sha256 88707f09…7ddd)
manifest.cbor       (1638 B, sha256 520897f5…d857)
seed_calldata.json  (9723 B, sha256 d92cf6ab…db14)
```

**No CBOR regeneration** required. V1 has been quiescent since block `47_354_411`; no state drift. The canonical snapshot applies verbatim to the NEW engine.

The 8-step seed transaction target changes only in the `to` field (`OLD_ENGINE → NEW_ENGINE`); every calldata byte remains identical because it encodes `(trader, marketId, size, openN, lastCumFR)` per position and `(marketId, cumFR, lastFundingTs)` per market — no engine address in the payload.

The new engine's `sealMigration` call receives the same `snapshotHash = 0x039d9172…3d7d` — verified deterministic by rehearsal test `test_MigrationReplay_ByteIdenticalToManifest` (see §M).

## M. Full local rehearsal (§14)

New Forge test suite: `test/perp/PerpEngineV2RecoveryRehearsal.t.sol` — **3 tests, all PASS**.

Full run (`FOUNDRY_LINT_LINT_ON_BUILD=false CARGO_BUILD_JOBS=1 forge test -j 1`):

```
[PASS] test_MigrationReplay_ByteIdenticalToManifest()          (gas: 1_276_449)
   → Deploys NEW PMR (current source)
   → Configures markets 1 + 2 with exact config from §I (including 100 bps deviation)
   → Deploys NEW PerpEngineV2 pointing at NEW PMR
   → Wires setMatchingEngine, setRiskModule, setClearingAccount
   → Vault.setAuthorizedEngine(newEngine, true) (local Timelock impersonation via OWNER)
   → Seeds all 6 canonical positions from manifest.json byte-identical
   → Seals with canonical hash 0x039d9172…3d7d
   → Verifies migrationState = SEALED
   → Verifies migrationSnapshotHash = 0x039d9172…3d7d
   → Verifies each of the 6 positions matches manifest byte-identical
   → Verifies marketState(1).longOI = 1_001_002, shortOI = 1_001_002, lastFundingTs = 1_789_715_546
   → Verifies marketState(2) all zeros
   → Verifies totalResidualBadDebtBase = 0

[PASS] test_NonZeroPnLClose_ProvesNoDoubleRealization()        (gas: 1_806_162)
   → Same setup as above + additional balances for trade participants
   → Executes 10_000-unit close between LONG (0xff287410…) and SHORT (0x66858286…)
     at executionPrice 246_842_235_500 (+0.0045% deviation vs 246_831_000_000 entry)
   → In-band per guard (well within ±100 bps)
   → Post-close: LONG size = +990_000, SHORT size = -990_000
   → Vault delta LONG   = +11 native mUSDC (realized PnL)
   → Vault delta SHORT  = -11 native mUSDC (realized PnL)
   → Clearing delta      = 0 (Σrealized = 0)
   → Σ vault deltas       = 0  ← proves NO ×2 REALIZATION

[PASS] test_SealedEngineRejectsAllFurtherAdmin()               (gas: 1_234_338)
   → Post-seal: adminSeedPosition reverts (MigrationAlreadySealed)
   → Post-seal: second sealMigration reverts
   → Old-engine isolation is architectural: separate storage, separate address

Suite: 3 passed; 0 failed; 0 skipped
```

Combined with the pre-existing test suites re-run in the same session:

```
PerpEngineExecutionPriceGuard.t.sol:       22 passed / 22
PerpEngineV2Migration.t.sol:               33 passed / 33
PerpEngineV2ProductionWiring.t.sol:         1 passed / 1
PerpEngineV2RecoveryRehearsal.t.sol:        3 passed / 3  ← NEW this milestone
────────────────────────────────────────────────────────
TOTAL:                                     59 passed / 59, 0 failed
```

Resource safety:
```
free -h    (pre-run):    6.2 Gi available
forge:     -j 1
Cargo:     none concurrent
```

## N. PnL regression (§11)

From `test_NonZeroPnLClose_ProvesNoDoubleRealization`:

```
Trade:
  buyer          = 0x66858286fEEA78a05eA093673EA1535E0A52002d  (SHORT closes)
  seller         = 0xff287410852B9328437eaC353720e5476bC5F837  (LONG closes)
  sizeDelta1e8   = 10_000
  executionPrice = 246_842_235_500  (raw 1e8)
  buyerIsMaker   = true

Math (with cumFR = 0, closedFunding1e8 = 0):
  LONG closing (+10_000 side):
    removedBasis1e8    = 2_468_310_000 * 10_000 / 1_000_000        =  +24_683_100
    closedMarkValue1e8 = 10_000 * 246_842_235_500 / 1e8 (floor)    =  +24_684_223
    realizedPnl1e8     = 24_684_223 - 24_683_100 - 0                =  +1_123
    native (÷100)      =                                                 +11

  SHORT closing (-10_000 side):
    removedBasis1e8    = -2_468_310_000 * 10_000 / 1_000_000       =  -24_683_100
    closedMarkValue1e8 = signed(-24_684_223)                        =  -24_684_223
    realizedPnl1e8     = -24_684_223 - (-24_683_100) - 0            =  -1_123
    native             =                                                 -11

Conservation:  +11 + (-11)     = 0                                  ✓
Clearing delta:                = 0 (Σrealized = 0)                  ✓
No ×2 realization:              Σ vault delta = 0 confirms it        ✓
```

Fees are NOT exercised in this rehearsal (mock risk module; production wiring test — `testProductionWiring_MutualClose_244274_WithTier0Fees` — proves fee separation with real FMV2 tier-0 makerPpm=50/takerPpm=300). The V1 double-count defect regression is proven by the `Σ = 0` assertion — if V2 double-counted, the assertion would fail with LONG=+22 or SHORT=-22.

## O. Dependency reuse proof

The rehearsal test deploys ONLY:
- New `PerpMarketRegistry` (mandatory per blocker)
- New `PerpEngineV2` (mandatory per registry-immutable)
- Local mocks (`RcvMockERC20`, `RcvMockOracle`, `RcvMockRisk`) — stand-ins for the reused live contracts (mUSDC, OracleRouter, PerpRiskModule)
- `PerpClearingAccountV2` — matches production `CLEARING_V2` semantics; the test proves it can be reused as-is

**No new PME, no new Risk module, no new Fees Manager, no new Clearing account, no additional 1000 mUSDC funding.** These will remain the currently-deployed instances in production (verified for reuse in `PERPS_V2_BASE_SEPOLIA_V2_REDEPLOY_RECOVERY_PREFLIGHT_V1 §B`).

EIP-712 domain of the reused PME_V2 stays unchanged (`verifyingContract = 0xF5FB81…eee2`, `version = "2"`). No signature regeneration.

## P. Enumerated public write plan

Grouped by milestone boundary. `TX-*` = OWNER broadcast; `GOV-*` = governance flow.

### Milestone 1 — `PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1`
```
TX-1   deploy PerpMarketRegistry
       caller    = OWNER (0xc35F7A…3C27)
       target    = (new addr from CREATE)
       function  = constructor(owner_ = OWNER)
       authority = OWNER EOA (nonce-based)
       reason    = replace OLD PMR that lacks getMaxExecutionDeviationBps
TX-2   pmr.setSettlementAssetAllowed(mUSDC, true)
       authority = onlyOwner
       reason    = permit mUSDC as settlement asset for markets 1 + 2
TX-3   pmr.createMarket(WETH, mUSDC, oracle, "ETH-PERP", riskCfg, liqCfg, fundingCfg)
       returns marketId = 1
       authority = onlyMarketCreator (owner auto-added at construction)
TX-4   pmr.setMaxExecutionDeviationBps(1, 100)   (OPERATOR POLICY)
       authority = onlyOwner
TX-5   pmr.createMarket(WBTC, mUSDC, oracle, "BTC-PERP", riskCfg, liqCfg, fundingCfg)
       returns marketId = 2
TX-6   pmr.setMaxExecutionDeviationBps(2, 100)   (OPERATOR POLICY)

Total: 6 OWNER tx. No governance flow.
```

### Milestone 2 — `PERPS_V2_BASE_SEPOLIA_ENGINE_V2_RECOVERY_DEPLOY_V1`
```
TX-7   deploy PerpEngineV2(owner=OWNER, registry=NEW_PMR, vault=VAULT, oracle=ORACLE)
       constructor initializes all governance pointers via _initPerpEngineStorage
       authority = OWNER EOA
       reason    = point new engine at new PMR (registry pointer is init-immutable)
TX-8   newEngine.setMatchingEngine(PME_V2 = 0xF5FB81…eee2)
TX-9   newEngine.setRiskModule(RISK_V2 = 0x8C3d9F…2998)
TX-10  newEngine.setClearingAccount(CLEARING_V2 = 0x54d49c…435c)
TX-11  newEngine.setInsuranceFund(INSURANCE = 0x009f38…7500)
TX-12  newEngine.setCollateralSeizer(SEIZER = 0x39F928…B669)
TX-13  newEngine.setFeesManagerV2(FMV2 = 0x00dA0B…774f)
TX-14  newEngine.setUseFeesManagerV2(true)
TX-15  newEngine.setGuardian(OWNER)
       All authority = onlyOwner
       Reason: mirror the currently-deployed engine's dependency wiring
       exactly; new engine is INERT until later milestones rebind PME/RISK/etc.

Total: 9 OWNER tx. No governance flow.
```

### Milestone 3 — `PERPS_V2_BASE_SEPOLIA_MIGRATION_REPLAY_V1`
```
TX-16  newEngine.adminSeedMarketFunding(1, 0, 1_789_715_546)
TX-17  newEngine.adminSeedMarketFunding(2, 0, 0)
TX-18  newEngine.adminSeedPosition(0x290bd12c…, 1, +1000,       +3_000_000,      0)
TX-19  newEngine.adminSeedPosition(0x475fe397…, 1, -2,          -6_000,          0)
TX-20  newEngine.adminSeedPosition(0x66858286…, 1, -1_000_000,  -2_468_310_000,  0)
TX-21  newEngine.adminSeedPosition(0x77ca9dd6…, 1, -1_000,      -3_000_000,      0)
TX-22  newEngine.adminSeedPosition(0x8b94a83d…, 1, +2,          +6_000,          0)
TX-23  newEngine.adminSeedPosition(0xff287410…, 1, +1_000_000,  +2_468_310_000,  0)
       All authority = onlyOwner + onlyMigrationOpen
       Reason: replay the canonical Base Sepolia migration state onto the
       new engine, using byte-identical calldata (only tx.to changes)

Total: 8 OWNER tx. No governance flow.
```

### Milestone 4 — `PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1`
```
TX-24  newEngine.sealMigration(0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d)
       authority = onlyOwner + onlyMigrationOpen
       Reason: commit the canonical snapshotHash to the new engine.
       IRREVERSIBLE. After this, adminSeed* revert.

Total: 1 OWNER tx. No governance flow.
```

### Milestone 5 — `PERPS_V2_BASE_SEPOLIA_V2_REBIND_V1`
```
TX-25  PME_V2.setEngine(newEngine)
       caller    = OWNER
       target    = PME_V2 (0xF5FB81…eee2)
       authority = PME_V2 onlyOwner
       reason    = route future matched trades to newEngine.applyTrade
TX-26  RISK_V2.setPerpEngine(newEngine)
       target    = RISK_V2 (0x8C3d9F…2998)
       authority = RISK_V2 onlyOwner
       reason    = risk views resolve against newEngine
TX-27  FMV2.setFeeConsumer(newEngine, true)
       target    = FMV2 (0x00dA0B…774f)
       authority = FMV2 onlyOwner
       reason    = permit newEngine to settle fees
TX-28  InsuranceFund.setBackstopCaller(newEngine, true)
       target    = INSURANCE (0x009f38…7500)
       authority = onlyOwner
       reason    = permit newEngine to draw bad-debt backstop
       (Optional revocation of OLD engine is DEFERRED to post-validation.)

Total: 4 OWNER tx. No governance flow.
```

### Milestone 6 — `PERPS_V2_BASE_SEPOLIA_TIMELOCK_QUEUE_VAULT_AUTH_NEW_V2_V1`
```
GOV-A  RiskGovernor.queuePerpEngineSetVaultAuth(NEW_ENGINE, true, eta)
       — OR equivalent Timelock queue with:
         target   = VAULT (0x00340C…25D3)
         data     = setAuthorizedEngine(NEW_ENGINE, true)
         eta      = now + 86400 s
       caller    = RiskGovernor (or any allowed proposer)
       authority = ProtocolTimelock onlyProposer
       reason    = grant NEW_ENGINE Vault access for transferBetweenAccounts

Total: 1 governance queue. No OWNER tx.
```

### Milestone 7 — wait 24 h (min delay)

Nothing to do. Chain reaches `eta`.

### Milestone 8 — `PERPS_V2_BASE_SEPOLIA_TIMELOCK_EXECUTE_VAULT_AUTH_NEW_V2_V1`
```
GOV-B  OPS Safe 2/3 -> Timelock.executeTransaction(VAULT, 0, setAuthorizedEngine(NEW,true), eta)
       caller    = OPS Safe (0xA6B9Bb…cD46) via multi-sig
       authority = ProtocolTimelock onlyExecutor
       reason    = actually flip Vault.isAuthorizedEngine(newEngine) → true

Total: 1 Safe execute (nested Timelock execution).
```

### Milestone 9 — `PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ACTIVATION_PREFLIGHT_V2`
Backend-side only. Environment variable diff:
```
PERP_ENGINE_V2_ADDRESS               = NEW_ENGINE   (was OLD_ENGINE)
PERP_MATCHING_ENGINE_V2_ADDRESS      = 0xF5FB81…eee2 (unchanged)
PERP_CLEARING_ACCOUNT_V2_ADDRESS     = 0x54d49c…435c (unchanged)
PERPS_ACTIVE_ENGINE_VERSION          = v2            (was v1)
EXECUTOR_REAL_BROADCAST_ENABLED      = false → true  (later milestone)
```
Not a chain write. Not counted.

### Chain write summary

```
                    TX (OWNER)   GOV (queue)  GOV (execute)   Total
Milestone 1  (PMR)         6           0            0            6
Milestone 2  (Engine)      9           0            0            9
Milestone 3  (Replay)      8           0            0            8
Milestone 4  (Reseal)      1           0            0            1
Milestone 5  (Rebind)      4           0            0            4
Milestone 6  (Queue)       0           1            0            1
Milestone 7  (Wait 24 h)   —           —            —            —
Milestone 8  (Execute)     0           0            1            1
────────────────────────────────────────────────────────────────
TOTAL                     28           1            1           30
```

Corrected from prior "~29 OWNER tx + 1 Timelock op" to **28 OWNER tx + 1 Timelock queue + 1 Timelock execute (via OPS Safe)** = **30 chain writes** distributed across 8 milestones, with a 24-hour cooldown between milestones 6 and 8.

## Q. Changed files

- `docs/PERPS_V2_BASE_SEPOLIA_RECOVERY_DEPLOYMENT_FREEZE_V1.md` — NEW (this file)
- `script/DeployPerpMarketRegistryV2.s.sol` — NEW
- `script/DeployPerpEngineV2Recovery.s.sol` — NEW
- `test/perp/PerpEngineV2RecoveryRehearsal.t.sol` — NEW (3 tests)

No production Solidity modification. No existing test change.

## R. Tests

```
$ FOUNDRY_LINT_LINT_ON_BUILD=false CARGO_BUILD_JOBS=1 forge test \
  --match-path 'test/perp/PerpEngine{V2Migration,V2RecoveryRehearsal,V2ProductionWiring,ExecutionPriceGuard}.t.sol' \
  -j 1

Ran 4 test suites in 15.87ms (14.72ms CPU time)
59 tests passed, 0 failed, 0 skipped (59 total tests)
```

## S. Commit / pushed HEAD

Sol repo new commit on top of `a891283`, pushed to `origin/main`.

## T. Blockers

**None for this preflight milestone.** All local validation is green.

**Remaining decisions for downstream milestones:**
1. **`maxExecutionDeviationBps` value** — 100 bps confirmed by operator directive. Alternatives (50 / 200) available. Do NOT change autonomously.
2. **OLD engine retirement timing** — deferred to post-validation. Vault deauthorization + FMV2/InsuranceFund flag removal are optional housekeeping, not safety-critical.
3. **NEW engine constructor arg ordering** — verified constructor is `(address _owner, address registry_, address vault_, address oracle_)`. Script encodes correctly.
4. **Foundry lint warnings** — build with `FOUNDRY_LINT_LINT_ON_BUILD=false` to bypass. Not a semantic issue. Optional: fix the lint findings in a separate cleanup PR (not scoped to recovery).

**No cutover state change during this milestone.** Live chain state remains identical to the checkpoint (V1 frozen, OLD V2 SEALED, Vault OLD V2 auth=true, backend V1, broadcast OFF, no V2 trades).

---

## Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1`** — execute `script/DeployPerpMarketRegistryV2.s.sol` on Base Sepolia with `PERP_MARKET_REGISTRY_V2_DEPLOY_CONFIRM=true`. 6 OWNER tx per §P. Preflight-only variant available with the confirm flag unset for a final dry-run.

Downstream sequence (do NOT skip milestone boundaries):

1. `PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1`
2. `PERPS_V2_BASE_SEPOLIA_ENGINE_V2_RECOVERY_DEPLOY_V1`
3. `PERPS_V2_BASE_SEPOLIA_MIGRATION_REPLAY_V1`
4. `PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1`
5. `PERPS_V2_BASE_SEPOLIA_V2_REBIND_V1`
6. `PERPS_V2_BASE_SEPOLIA_TIMELOCK_QUEUE_VAULT_AUTH_NEW_V2_V1`
7. (wait 24 h)
8. `PERPS_V2_BASE_SEPOLIA_TIMELOCK_EXECUTE_VAULT_AUTH_NEW_V2_V1`
9. `PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ACTIVATION_PREFLIGHT_V2`

**Do NOT deploy automatically. STOP.**
