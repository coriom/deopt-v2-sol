# PERPS V2 BASE SEPOLIA PMR V2 DEPLOY V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1`
**Status**: **COMPLETE — 6 authorized OWNER tx broadcast + verified**
**Sol HEAD (pre)**: `cf99f94` (`RECOVERY_DEPLOYMENT_FREEZE_V1`)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Chain**: Base Sepolia (chainId `84532`)

Scope: deploy NEW `PerpMarketRegistry` at HEAD `cf99f94` source, configure markets 1 (ETH-PERP) + 2 (BTC-PERP) byte-identical to the OLD PMR live snapshot, and set `maxExecutionDeviationBps = 100` on both markets (operator policy). NEW PMR is deployed but operationally inert (no engine/PME/Risk/FMV2/Vault/backend touched; OLD PMR unchanged).

**NEW_PMR = `0xAD8B0855d1fd649539A344AD594bf86929cf0FF7`**

---

## A. OWNER nonce / balance pre

```
OWNER              = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
nonce (pre-M1)     = 784
ETH balance (pre)  = 0.001776194206596108 ETH   (= 1_776_194_206_596_108 wei)
```

## B. Frozen PMR artifact verification

Pre-broadcast (against local out/):

```
runtime size    = 13_217 bytes                                                  ✓ matches freeze
runtime keccak  = 0x5d66f23543a0e9ded3da5e85c8f0413af3cbe00794e99e1aa3c9b1b40c63fd8c  ✓ matches freeze
```

Selectors required (all present):

```
0x4d73d67f getMaxExecutionDeviationBps(uint256)          ✓ PRESENT (missing on OLD PMR)
0x1108dbb8 setMaxExecutionDeviationBps(uint256,uint16)   ✓ PRESENT (missing on OLD PMR)
0xeb44fdd3 getMarket(uint256)                            ✓
0xa6a96c3a getRiskConfig(uint256)                        ✓
0xc3cc3ad4 getLiquidationConfig(uint256)                 ✓
0x3bcbd917 getFundingConfig(uint256)                     ✓
0xec69a654 marketExists(uint256)                         ✓
0xf849f69e isMarketActive(uint256)                       ✓
0x8162486b totalMarkets()                                ✓
0xb85ed636 getAllMarketIds()                             ✓
```

## C. Six-transaction preview (from forge script simulation pre-broadcast)

| # | txType | function | args | gas |
|---|---|---|---|---|
| 1 | CREATE | `constructor(0xc35F7A…3C27)` | OWNER | 3_883_638 (est) |
| 2 | CALL | `setSettlementAssetAllowed(mUSDC, true)` | mUSDC=0x6eAe407f…412E | 70_548 (est) |
| 3 | CALL | `createMarket(WETH, mUSDC, oracle, "ETH-PERP", risk, liq, funding)` | see §I | 477_633 (est) |
| 4 | CALL | `setMaxExecutionDeviationBps(1, 100)` | **OPERATOR POLICY** | 71_853 (est) |
| 5 | CALL | `createMarket(WBTC, mUSDC, oracle, "BTC-PERP", risk, liq, funding)` | see §J | 453_996 (est) |
| 6 | CALL | `setMaxExecutionDeviationBps(2, 100)` | **OPERATOR POLICY** | 71_853 (est) |

Estimated total gas at 0.011 gwei preview: 5_029_521 gas ≈ 0.0000553 ETH. Actual on-chain gas at 6 mwei effective: 3_817_016 gas ≈ 0.0000229 ETH.

Broadcast method: `forge script --broadcast --sender 0xc35F7A…3C27 --keystore ~/.foundry/keystores/deopt-deployer --password-file /run/user/1000/deopt-deployer.pw`. Password material never touched by the script; kept in a mode-0600 tmpfs file that was deleted immediately post-broadcast (§P.11 verified).

**Script signing refactor** — the freeze artifact `script/DeployPerpMarketRegistryV2.s.sol` originally read the private key from `DEPLOYER_PRIVATE_KEY` env var, which conflicted with the keystore-only signing policy (§5 of directive). One-line refactor applied in-place at broadcast time (`vm.envUint("DEPLOYER_PRIVATE_KEY") → msg.sender` and `vm.startBroadcast(deployerPk) → vm.startBroadcast(deployer)`), preserving deployed bytecode and configuration byte-identical to the freeze. Documented + committed together with this docs commit.

## D. NEW_PMR address

```
NEW_PMR = 0xAD8B0855d1fd649539A344AD594bf86929cf0FF7
```

CREATE-derived: `keccak256(rlp([OWNER, nonce=784]))[12:]` = `0xad8b0855d1fd649539a344ad594bf86929cf0ff7`.

## E. Deployment tx / block / receipt

**TX-1 CREATE PerpMarketRegistry**:

```
hash                = 0x5f3a3bc290e1f9018eb293154f679a00dfd91097d49eda51185095e8a3b0ca8c
from                = 0xc35f7a8a103a9a4464adfaa76b9b514093d23c27
to                  = (CREATE)
contractAddress     = 0xad8b0855d1fd649539a344ad594bf86929cf0ff7
blockNumber         = 47_450_189
gasUsed             = 2_987_414
effectiveGasPrice   = 6_000_000 wei (6 mwei)
gas cost            = 17_924_484_000_000 wei ≈ 0.00001792 ETH
status              = 0x1 ✓
```

## F. Configuration txs / blocks / receipts

**TX-2 setSettlementAssetAllowed(mUSDC, true)**:
```
hash    = 0x5a5de6a56bfe789a1eee8af8aef827e8ed3711d642b8e0b0e3aac663cd0823f3
block   = 47_450_191    gasUsed = 51_076    status = 0x1 ✓
```

**TX-3 createMarket(WETH, mUSDC, oracle, "ETH-PERP", risk, liq, funding) → marketId 1**:
```
hash    = 0x0032060e1d71928de9067449460c0fd75fd1128d87466b38d598750b3a51bfd4
block   = 47_450_192    gasUsed = 345_798   status = 0x1 ✓
```

**TX-4 setMaxExecutionDeviationBps(1, 100)** [OPERATOR POLICY]:
```
hash    = 0x14bb04bd79e88df3017cdc0753618126d914996bbccb07f04200e06df4ea59a2
block   = 47_450_193    gasUsed = 52_021    status = 0x1 ✓
```

**TX-5 createMarket(WBTC, mUSDC, oracle, "BTC-PERP", risk, liq, funding) → marketId 2**:
```
hash    = 0x3727202ffc645e5a31f6ac6694c8d98922dde6523f9d1a9ab60c3a5c9a4517b6
block   = 47_450_194    gasUsed = 328_686   status = 0x1 ✓
```

**TX-6 setMaxExecutionDeviationBps(2, 100)** [OPERATOR POLICY]:
```
hash    = 0xf55dc717474719dc8f80467ccc570c85c649c8f36e5687a9f9dd62d019eefc21
block   = 47_450_195    gasUsed = 52_021    status = 0x1 ✓
```

Sequential blocks 47_450_189..47_450_195 (with `--slow` between broadcasts). All 6 receipts `status = 0x1`.

## G. Runtime hash / size (live-chain readback post-deploy)

```
NEW_PMR runtime size    = 13_217 bytes                                                     ✓
NEW_PMR runtime keccak  = 0x5d66f23543a0e9ded3da5e85c8f0413af3cbe00794e99e1aa3c9b1b40c63fd8c ✓
```

Byte-identical to the frozen local compile artifact (§B).

## H. Selector compatibility (live readback via `cast call NEW_PMR …`)

| Selector | Function | Live readback |
|---|---|---|
| `0x4d73d67f` | `getMaxExecutionDeviationBps(uint256)` | `100` (both markets) — was **absent** on OLD |
| `0x1108dbb8` | `setMaxExecutionDeviationBps(uint256,uint16)` | present — was **absent** on OLD |
| `0xeb44fdd3` | `getMarket(uint256)` | 7-field tuple returned OK |
| `0xa6a96c3a` | `getRiskConfig(uint256)` | 6-field tuple returned OK |
| `0xc3cc3ad4` | `getLiquidationConfig(uint256)` | 4-field tuple returned OK |
| `0x3bcbd917` | `getFundingConfig(uint256)` | 6-field tuple returned OK |
| `0xec69a654` | `marketExists(uint256)` | `true` |
| `0xf849f69e` | `isMarketActive(uint256)` | `true` |
| `0x794b552a` | `isMarketCloseOnly(uint256)` | `false` |
| `0x8162486b` | `totalMarkets()` | `2` |
| `0xb85ed636` | `getAllMarketIds()` | `[1, 2]` (dynamic array) |

No bare revert. Every selector ENGINE_V2 will call is live.

## I. Market 1 full reconciliation

| Field | OLD PMR (live) | Committed script | NEW PMR (live) | Match |
|---|---|---|---|---|
| underlying | `0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02` | `WETH_UNDERLYING` | `0x4DeEBc5f…D02` | ✓ |
| settlementAsset | `0x6eAe407f5640B006faC9965182e238582A3B412E` (mUSDC) | `MUSDC` | `0x6eAe407f…12E` | ✓ |
| oracle | `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` | `PERP_ORACLE` | `0xB416406F…581` | ✓ |
| symbol | `0x4554482d5045525000…` ("ETH-PERP") | `ETH_PERP_SYMBOL` | `0x4554482d…000` | ✓ |
| exists / isActive / isCloseOnly | `(uint8=1, true, false)` | `(auto, true, false)` | `(true, true, false)` | ✓ semantic equiv |
| riskCfg.initialMarginBps | 1000 | 1_000 | 1000 | ✓ |
| riskCfg.maintenanceMarginBps | 750 | 750 | 750 | ✓ |
| riskCfg.liquidationPenaltyBps | 500 | 500 | 500 | ✓ |
| riskCfg.maxPositionSize1e8 | 10_000_000_000 | 10_000_000_000 | 10_000_000_000 | ✓ |
| riskCfg.maxOpenInterest1e8 | 50_000_000_000 | 50_000_000_000 | 50_000_000_000 | ✓ |
| riskCfg.reduceOnlyDuringCloseOnly | true | true | true | ✓ |
| liqCfg.closeFactorBps | 5000 | 5_000 | 5000 | ✓ |
| liqCfg.priceSpreadBps | 100 | 100 | 100 | ✓ |
| liqCfg.minImprovementBps | 50 | 50 | 50 | ✓ |
| liqCfg.oracleMaxDelay | 60 | 60 | 60 | ✓ |
| fundingCfg (isEnabled) | false¹ | false | false | ✓ |
| fundingCfg all others | 0 | 0 | 0 | ✓ |
| **maxExecutionDeviationBps** | **N/A (selector missing)** | **100** | **100** | ✓ NEW **OPERATOR POLICY** |

¹ OLD PMR's FundingConfig schema was 5 fields (no `impactMidMaxDelay`); NEW PMR's is 6 fields (adds `impactMidMaxDelay=0`). Semantics preserved: funding disabled on both.

**Market 1 config: byte-identical shared parameters + one intentional new-policy field (`maxExecutionDeviationBps = 100`).**

## J. Market 2 full reconciliation

| Field | OLD PMR (live) | Committed script | NEW PMR (live) | Match |
|---|---|---|---|---|
| underlying | `0x9D871aC7595E8Da271E866608E5145252047967c` | `WBTC_UNDERLYING` | `0x9D871a…967c` | ✓ |
| settlementAsset | mUSDC | mUSDC | mUSDC | ✓ |
| oracle | `0xB416406F…581` | `PERP_ORACLE` | `0xB416406F…581` | ✓ |
| symbol | `0x4254432d5045525000…` ("BTC-PERP") | `BTC_PERP_SYMBOL` | `0x4254432d…000` | ✓ |
| exists / isActive / isCloseOnly | `(1, true, false)` | `(auto, true, false)` | `(true, true, false)` | ✓ semantic equiv |
| riskCfg.initialMarginBps | 1200 | 1_200 | 1200 | ✓ |
| riskCfg.maintenanceMarginBps | 800 | 800 | 800 | ✓ |
| riskCfg.liquidationPenaltyBps | 400 | 400 | 400 | ✓ |
| riskCfg.maxPositionSize1e8 | 1_000_000_000 | 1_000_000_000 | 1_000_000_000 | ✓ |
| riskCfg.maxOpenInterest1e8 | 10_000_000_000 | 10_000_000_000 | 10_000_000_000 | ✓ |
| riskCfg.reduceOnlyDuringCloseOnly | true | true | true | ✓ |
| liqCfg.closeFactorBps | 5000 | 5_000 | 5000 | ✓ |
| liqCfg.priceSpreadBps | 80 | 80 | 80 | ✓ |
| liqCfg.minImprovementBps | 50 | 50 | 50 | ✓ |
| liqCfg.oracleMaxDelay | 60 | 60 | 60 | ✓ |
| fundingCfg | (false, 0, 0, 0, 0) | (false, 0, 0, 0, 0, 0) | (false, 0, 0, 0, 0, 0) | ✓ semantic equiv |
| **maxExecutionDeviationBps** | **N/A (selector missing)** | **100** | **100** | ✓ NEW **OPERATOR POLICY** |

**Market 2 config: byte-identical shared parameters + one intentional new-policy field.**

## K. 100-bps proof (live post-broadcast)

```
NEW_PMR.getMaxExecutionDeviationBps(1)   = 100  (0x0000…64)
NEW_PMR.getMaxExecutionDeviationBps(2)   = 100  (0x0000…64)
```

## L. NEW PMR ownership / admin proof

```
NEW_PMR.owner()                                          = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27  (OWNER)
NEW_PMR.totalMarkets()                                   = 2
NEW_PMR.isMarketCreator(OWNER)                           = true  (auto-added at construction)
NEW_PMR.isSettlementAssetAllowed(mUSDC)                  = true  (TX-2)
```

## M. OLD PMR unchanged proof

```
OLD_PMR (0xb4fcf45E…77eC).getMaxExecutionDeviationBps(1) → execution reverted  ← selector still absent
OLD_PMR.totalMarkets()                                    = 2                    ← unchanged
```

## N. OLD ENGINE still wired to OLD PMR

```
OLD_ENGINE_V2 (0x44702B0A…6db9).marketRegistry() = 0xb4fcf45E57b93274441dEf8f0f68bd30f6D677eC  (OLD PMR)
```

No shared-dependency rebind executed. NEW_PMR is deployed but not referenced by any live perp contract.

## O. V1 / V2 freeze state (unchanged from checkpoint)

```
PME_V1.paused                       = true                                                             ✓
V1_ENGINE.liquidationPaused         = true                                                             ✓
Vault.isAuthorizedEngine(V1)        = true                                                             ✓
Vault.isAuthorizedEngine(OLD_V2)    = true                                                             ✓
Vault.isAuthorizedEngine(NEW_PMR)   = false   ← NEW PMR is NOT a Vault-authorized engine (as intended)
OLD_ENGINE.migrationState           = 1 (SEALED)                                                       ✓
OLD_ENGINE.migrationSnapshotHash    = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d ✓
Vault.balances(CLEARING_V2, mUSDC)  = 1_000_000_000                                                    ✓
PME_V2.perpEngine()                 = 0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9  (still OLD ENGINE_V2) ✓
RISK_V2.perpEngine()                = 0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9  (still OLD ENGINE_V2) ✓
```

## P. Backend still V1 / broadcast OFF

Backend HEAD `ad8dd7466` unchanged. `PERPS_ACTIVE_ENGINE_VERSION = v1` (defaults). `EXECUTOR_REAL_BROADCAST_ENABLED = false` (defaults). No V2 TradeExecuted since block `47_407_874` (verified via 42_321-block log scan on OLD ENGINE_V2 topic0 `0xa73bf9fa…4ed60`, 0 events).

## Q. Nonce / write audit

```
OWNER nonce (pre-M1)   = 784
OWNER nonce (post-M1)  = 790
OWNER nonce Δ          = +6     ← exactly 6 tx (matches frozen plan)

Safe nonce Δ            = 0
Executor nonce Δ        = 0

Base Sepolia writes:
  Deploy PMR                 = 1  ✓
  PMR config tx              = 5  (setSettlementAssetAllowed + 2× createMarket + 2× setMaxExecutionDeviationBps)
  Timelock queue             = 0
  Timelock execute           = 0
  Safe execute               = 0
  Vault ACL write            = 0
  Engine deployment          = 0
  Migration write            = 0
  V2 trade                   = 0
  DB write                   = 0
  Backend restart            = 0

OWNER ETH balance:
  pre  = 0.001776194206596108 ETH
  post = 0.001752856549434849 ETH
  delta = -23_337_657_161_259 wei ≈ -0.0000234 ETH  (~3× cheaper than 0.011 gwei estimate — actual eff price was 6 mwei)
```

No unexplained transaction. No Timelock op. No Safe op. No Vault ACL change. No Engine touched.

## R. Changed docs / scripts

- `docs/PERPS_V2_BASE_SEPOLIA_PMR_V2_DEPLOY_V1.md` — NEW (this file)
- `script/DeployPerpMarketRegistryV2.s.sol` — MODIFIED (signing refactor: `vm.envUint("DEPLOYER_PRIVATE_KEY") → msg.sender`, `vm.startBroadcast(deployerPk) → vm.startBroadcast(deployer)`, plus header docstring update). No change to deployed bytecode or configuration; deployment produced byte-identical runtime keccak to the freeze artifact.

No production Solidity modification (perp/collateral/matching/gouvernance sources untouched).

## S. Pushed HEAD

Sol repo new commit on top of `cf99f94`, pushed to `origin/main`.

## T. Blockers

**None.** All 20 §7–§10 verification checks green. NEW_PMR is deployed, configured, and operationally inert — ready to receive a new PerpEngineV2 pointer in the next milestone.

**Remaining decisions for downstream** (unchanged from freeze):
1. **`maxExecutionDeviationBps`** — operator confirmed 100 bps. **APPLIED on-chain.**
2. **OLD engine housekeeping** — deferred to post-validation.
3. **Backend two-address transition** — deferred to `BACKEND_V2_ACTIVATION_PREFLIGHT_V2`.

---

## Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_ENGINE_V2_RECOVERY_DEPLOY_V1`** — execute `script/DeployPerpEngineV2Recovery.s.sol` with:
```
PERP_MARKET_REGISTRY_V2_ADDRESS=0xAD8B0855d1fd649539A344AD594bf86929cf0FF7
PERP_ENGINE_V2_RECOVERY_DEPLOY_CONFIRM=true
```
Predicted 9 OWNER tx: 1 CREATE + 8 setter wires (`setMatchingEngine`, `setRiskModule`, `setClearingAccount`, `setInsuranceFund`, `setCollateralSeizer`, `setFeesManagerV2`, `setUseFeesManagerV2`, `setGuardian`). Expected NEW_ENGINE deterministic address: `keccak256(rlp([OWNER, nonce=790]))[12:]`.

The script's pre-broadcast `staticcall(NEW_PMR, getMaxExecutionDeviationBps(1))` gate will pass (returns 100) — proving the PMR is recovery-capable before the engine deploy commits.

Backend HEAD ad8dd7466 continues to route V1. Cutover state remains safe.

**Do NOT execute automatically. STOP.**
