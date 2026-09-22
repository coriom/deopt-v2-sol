# PERPS V2 BASE SEPOLIA DEPLOYMENT RESULT V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_DEPLOY_V2_ONLY_V1`
**Status**: **COMPLETE — PRE-STAGE deployed and readback green**
**Chain**: Base Sepolia (chainId 84532)
**Sol HEAD**: `d36699377244716a8b594d39d7754b511ef43d9a`
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged)
**Deployer**: `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (keystore `~/.foundry/keystores/deopt-deployer` — verified match via password-file workflow; password file deleted after PRE-STAGE)
**Deployer nonce**: 753 → 768 (Δ 15, matches 6 deploys + 9 config txs)
**Total ETH spent**: 0.00008164 ETH (81,635,186,767,240 wei @ 6 gwei effective gas price)
**Block range**: 47_147_669 → 47_147_923

## Deployed contracts

| # | Contract | Address | Ctor / linkage | Runtime B | Artifact-normalized SHA-256 match |
|---:|---|---|---|---:|---|
| A01 | PerpEngineSeizureLib | `0xf0C5652277CF88B508E05F7aB54949fCDF0360A5` | (no ctor) | 3_628 | ✓ |
| A02 | PerpEngineLiquidationLib | `0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D` | linked→SeizureLib | 6_148 | ✓ |
| A03 | PerpEngineV2 | `0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9` | (OWNER, REGISTRY, VAULT, ORACLE); linked→Seize+Liq | **24_321** | ✓ |
| A04 | PerpMatchingEngineV2 | `0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2` | (OWNER, ENGINE_V2) | 10_441 | (unlinked exact) |
| A05 | PerpRiskModule V2 | `0x8C3d9F71cA59B908Fa200546A63ea62F9C932998` | (OWNER, VAULT, ENGINE_V2, ORACLE, mUSDC) | 9_894 | (unlinked exact) |
| A06 | PerpClearingAccountV2 | `0x54d49c088DD27cFc82685b867c182b4bB4aC435c` | (VAULT) | 1_159 | (unlinked exact) |

**EIP-170 gate**: PerpEngineV2 runtime = 24,321 bytes < 24,576. Margin **255 bytes**. ✓

## Transaction journal

All 15 Base Sepolia transactions:

| # | Action | Tx | Block | Gas used | Target | Sig |
|---:|---|---|---:|---:|---|---|
| A01 | deploy SeizureLib          | `0x887cde2a15ac7c4acce6f501c85af2bb15b2f02f8b3d0d7ec79e087f0109ffe5` | 47_147_669 | 837_180   | CREATE | — |
| A02 | deploy LiquidationLib      | `0xdf4c5bb645c776e8d852fe28332ef63bc61cedd14a919f360b90e5c84122f87f` | 47_147_703 | 1_382_584 | CREATE | — |
| A03 | deploy EngineV2 (linked)   | `0x824152c908333d4d74c69d3e6137c4434bc9588858529309df27f7728b032855` | 47_147_740 | 5_581_032 | CREATE | — |
| A04 | deploy PME_V2              | `0x6275f353337f4a4b1ea4f018e56e9d947b3364f9e665e8d4e788d4c61b6fa07f` | 47_147_788 | 2_426_457 | CREATE | — |
| A05 | deploy RiskModule V2       | `0x702ab0a6ac4f85adf58f0964b27fb7de33ebf61c5319e4e11ca5031633818388` | 47_147_814 | 2_325_054 | CREATE | — |
| A06 | deploy ClearingAccount V2  | `0xe2b1a0128b01295d8fa78fc6ce42c22b9d5db26c96d343f00d3fac7adeb41aa7` | 47_147_818 | 305_979   | CREATE | — |
| A07 | setMatchingEngine          | `0x15f487e311c3c0e0dcd06771b6fd5c81e5d19b52710258a477f1f67a3c7299c0` | 47_147_844 | 48_401    | ENGINE_V2 | `setMatchingEngine(PME_V2)` |
| A08 | setRiskModule              | `0xb28edd4b1c15926ed2e09c182a02d959757dedc5d8ee78026a0535b21cf15f98` | 47_147_846 | 47_119    | ENGINE_V2 | `setRiskModule(RISK_V2)` |
| A09 | setClearingAccount         | `0xc1bc4856daf0a2a9b36851668d906142cff65130ce2c4bfb1a52c49304f409a2` | 47_147_848 | 54_983    | ENGINE_V2 | `setClearingAccount(CLEARING_V2)` |
| A10 | setInsuranceFund           | `0x177d9393973b3ca3e85530fd7fe5b17269a228700a04778aa31e79700d812893` | 47_147_849 | 48_732    | ENGINE_V2 | `setInsuranceFund(0x009f…7500)` |
| A11 | setCollateralSeizer        | `0x7553c397ca3dd9dfca41e5fdd0d766052cc3f29b0aa116947af7c8cae7bcf444` | 47_147_851 | 48_763    | ENGINE_V2 | `setCollateralSeizer(0x39F9…8669)` |
| A12 | setGuardian                | `0x50b5be6757654c2260c49f719b873a3b43dfb2eb5b48a1048eb2d308e919facf` | 47_147_853 | 28_570    | ENGINE_V2 | `setGuardian(OWNER)` |
| A13 | setFeesManagerV2           | `0x616727e1694dd02b9645df25798b1945d59c5ebd546d67b94db656acf01f1317` | 47_147_855 | 47_993    | ENGINE_V2 | `setFeesManagerV2(0x00dA…774f)` |
| A14 | setFeeConsumer             | `0x75d2fd2bf1cb607353a03740ea511074ee518b38a2676db59c050e89d898e054` | 47_147_920 | 47_925    | FMV2      | `setFeeConsumer(ENGINE_V2, true)` |
| A15 | setUseFeesManagerV2        | `0x862cc9097227db673ebb46044e32cfac357bb4484364209d4ab199ac56c5f5f1` | 47_147_923 | 30_587    | ENGINE_V2 | `setUseFeesManagerV2(true)` |

## §S 24-item readback — ALL GREEN

```
[✓]  1  SEIZE code.length              = 3628
[✓]  2  LIQ code.length                = 6148
[✓]  3  ENGINE_V2 code.length          = 24321   ← EIP-170 gate
[✓]  4  PME_V2 code.length             = 10441
[✓]  5  RISK_V2 code.length            = 9894
[✓]  6  CLEARING_V2 code.length        = 1159
[✓]  7  ENGINE_V2.owner                = 0xc35F7A8A…
[✓]  8  ENGINE_V2.guardian             = 0xc35F7A8A…
[✓]  9  ENGINE_V2.marketRegistry       = 0xb4fc…7eC
[✓] 10  ENGINE_V2.collateralVault      = 0x0034…5D3
[✓] 11  ENGINE_V2.oracle               = 0xB416…581
[✓] 12  ENGINE_V2.riskModule           = RISK_V2
[✓] 13  ENGINE_V2.matchingEngine       = PME_V2
[✓] 14  ENGINE_V2.clearingAccount      = CLEARING_V2
[✓] 15  ENGINE_V2.insuranceFund        = 0x009f…7500
[✓] 16  ENGINE_V2.collateralSeizer     = 0x39F9…8669
[✓] 17  ENGINE_V2.feesManagerV2        = 0x00dA…774f
[✓] 18  ENGINE_V2.useFeesManagerV2     = true
[✓] 19  FMV2.isFeeConsumer(ENGINE_V2)  = true
[✓] 20  ENGINE_V2.migrationState=OPEN  = 0
[✓] 21  ENGINE_V2.migrationSnapshotHash= 0x0
[✓] 22  Vault.isAuthorizedEngine(V2)   = false   ← V2 NOT vault-authorized (CUTOVER only)
[✓] 23  Vault.isAuthorizedEngine(V1)   = true    ← V1 UNCHANGED
[✓] 24  V1 non-interference: owner / matchingEngine / riskModule / useFeesManagerV2 / tradingPaused all identical to pre-milestone snapshot
```

Additional post-checks:
- `PME_V2.eip712Domain()` → name `"DeOptV2-PerpMatchingEngine"`, version `"2"`, chainId `84532`, verifyingContract `PME_V2` ✓
- `PME_V2.perpEngine()` → `ENGINE_V2` ✓
- `PME_V2.owner()` → `OWNER` ✓, `PME_V2.paused()` → `false` ✓

## §19 Migration fail-closed proof

`eth_call` simulation of `ENGINE_V2.applyTrade(...)` with dummy inputs reverts with selector `0x9aec415e` (migration-not-sealed guard). No transaction sent. Engine is fail-closed while `migrationState == OPEN`. ✓

## §17 V1 non-interference

V1 engine `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` state at milestone end matches pre-milestone snapshot exactly:
- owner, guardian, matchingEngine, oracle, riskModule, collateralVault, marketRegistry, collateralSeizer, insuranceFund, feesManager, feesManagerV2, useFeesManagerV2 — all identical
- tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused — all `false` (unchanged)
- `Vault.isAuthorizedEngine(V1) == true` (unchanged)
- V1 PME `0x774d96…9F165`, V1 RiskModule `0xf1b46040…7FEe5` — bindings unchanged

## §18 Vault authorization

- `Vault.isAuthorizedEngine(0xc6C5…41c)` (V1) = **true**
- `Vault.isAuthorizedEngine(0x4470…6db9)` (V2) = **false**   ← CUTOVER action, not authorized here

## §20 Backend

- HEAD unchanged: `ad8dd7466aeba6963d28687e825fe4df58ef32ee`
- Worktree clean
- `PERPS_ACTIVE_ENGINE_VERSION` unchanged (remains v1)
- Zero backend restart, zero config edit

## §16 Prohibitions honored

Explicitly NOT executed during PRE-STAGE:
- `CollateralVault.setAuthorizedEngine(V2, true)` — deferred to CUTOVER (Timelock+Safe)
- Any Timelock function / Safe execution
- `adminSeedMarketFunding` / `adminSeedPosition` / `adminSeedResidualBadDebt`
- `sealMigration`
- Clearing funding
- Backend V2 activation
- Any V1 freeze/pause mutation
- Any trade / prepare / sign / send
- Any executor-key transaction

## §24 Explorer verification

Deferred. On-chain runtime lengths + normalized SHA-256 hashes match artifact for all deployed contracts. Explorer verification (BaseScan) can be performed post-hoc using `forge verify-contract` with exact Sol HEAD `d366993`, compiler `0.8.30`, `optimizer_runs=0`, `via_ir=true`, `bytecode_hash=none`, `cbor_metadata=false`, and the recorded constructor arguments + library addresses. Not required for correctness proof.

## §21 EIP-170 hard gate

Final `eth_getCode(ENGINE_V2).length` = **24,321 bytes** exactly. Matches expected linked runtime. Zero drift. Below EIP-170 cap with 255-byte margin.

## §22 Signer hygiene

- Keystore `~/.foundry/keystores/deopt-deployer` verified via `cast wallet address --password-file /run/user/1000/deopt-deployer.pw` → resolved to `0xc35F7A8A…` (matches target signer) before any write
- Password file written interactively by operator into `/run/user/$(id -u)/deopt-deployer.pw` mode `0600`
- Password file deleted (`shred -u`) after final write
- Zero private key / password appeared in argv / shell history / journal

## §29 Remaining blockers

**CUTOVER blockers** (unchanged from PRE-STAGE preflight §W):
- Determine effective Timelock `minDelay` (Q)
- **OPERATOR_DECISION_REQUIRED** — V2 PerpRiskModule oracle-freshness policy (RISK_V2 currently at constructor default; A16 mirror-V1 deferred here to CUTOVER per §I)
- V1 quiescence gate
- Snapshot manifest generation + hash
- Clearing funding sizing at snapshot time

**FIRST V2 TRADE blockers**:
- All CUTOVER blockers +
- Vault auth flip via Timelock (Safe 2/3 → schedule → GRACE_PERIOD 14 d or effective minDelay → execute)
- Backend V2 activation flip

**NON-BLOCKING follow-ups**:
- Executor EOA `0x58Ad…52B8` balance 0.001951 ETH — top up before broadcast worker will need to send
- BaseScan verification of the 6 fresh contracts (optional)
- PME V2 executor authorization on `0x58Ad…52B8` (small config tx; can happen at CUTOVER since migration OPEN keeps V2 fail-closed regardless)

## Address summary (for backend `.env.base-sepolia` at future CUTOVER — DO NOT ACTIVATE YET)

```
PERP_ENGINE_V2_ADDRESS=0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9
PERP_MATCHING_ENGINE_V2_ADDRESS=0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2
PERP_RISK_MODULE_V2_ADDRESS=0x8C3d9F71cA59B908Fa200546A63ea62F9C932998
PERP_CLEARING_ACCOUNT_V2_ADDRESS=0x54d49c088DD27cFc82685b867c182b4bB4aC435c
PERP_ENGINE_SEIZURE_LIB_ADDRESS=0xf0C5652277CF88B508E05F7aB54949fCDF0360A5
PERP_ENGINE_LIQUIDATION_LIB_ADDRESS=0x69F3868Ff47C8bCcC45211B787a6e15D0282E77D
FEES_MANAGER_V2_ADDRESS=0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f
```

## Next milestone

**`PERPS_V2_BASE_SEPOLIA_CUTOVER_PREFLIGHT_V1`** — determine effective Timelock minDelay, resolve V2 RiskModule oracle-freshness policy (OPERATOR_DECISION), draft snapshot manifest generator + hash script, size clearing funding at a candidate snapshot block, produce the Safe-scheduled Timelock queue payload for `CollateralVault.setAuthorizedEngine(ENGINE_V2, true)`. No writes; produces the CUTOVER DAG.
