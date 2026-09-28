# PERPS V2 BASE SEPOLIA MIGRATION SEED V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_MIGRATION_SEED_V1`
**Status**: **COMPLETE — 8 authorized on-chain writes (2 × adminSeedMarketFunding + 6 × adminSeedPosition)**
**Sol HEAD (pre)**: `1ed47d5` (unchanged during milestone; new docs commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Production Solidity bytecode**: frozen at `004bf78c32b2b5210cd7daabef2685cd461aeec7`
**Chain**: Base Sepolia (chainId 84532)

Scope: execute the committed 8-step seed iterator (`artifacts/perps_v2_final_snapshot/seed_calldata.json`) against `ENGINE_V2 = 0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9` while `migrationState == OPEN`, from `OWNER = 0xc35F7A8A…3C27`. No sealMigration, no Timelock, no Vault authorization, no backend V2 activation, no V2 trade.

---

## A. OWNER ETH pre/post

```
pre-seed   = 0.001785681862587161 ETH  (1_785_681_862_587_161 wei)
post-seed  = 0.001776548230485688 ETH  (1_776_548_230_485_688 wei)
delta      = -0.000009133632101473 ETH (-9_133_632_101_473 wei)
             ≈ 0.000009 ETH total gas consumed across 8 txes
```

## B. OWNER nonce pre/post

```
pre-seed   = 775
post-seed  = 783
delta      = +8   ✓
```

## C. Artifact integrity

```
manifest.json  sha256 = 88707f092c2be05fb5e4b73454f880b84abc4a1a95199e4eeb9aeec024687ddd
manifest.cbor  sha256 = 520897f586cb275fbe81d4d5acb30ce45632be4ce2574a0577bc302b339ed857
seed_calldata  sha256 = d92cf6abae899123d7d96009f36da3f8a715c04a7ee9ac6bf5dddc9c0b1cdb14
snapshot_hash (recomputed pre-seed)  = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d   ← matches FINAL_SNAPSHOT §L
snapshot_hash (recomputed post-seed) = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d   ← unchanged
seed_calldata git-clean vs 1ed47d5   = byte-identical (no diff)
```

Iterator composition (from `seedIteratorSummary`):

```
totalSteps           = 8
marketFundingSteps   = 2
positionSteps        = 6
residualBadDebtSteps = 0
engineV2 target      = 0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9
snapshotBlock        = 47_354_411
snapshotBlockHash    = 0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89
```

## D–F. Per-step iterator + tx + receipt

Every tx broadcast used the exact committed calldata bytes from `seed_calldata.json` (via `cast send --data <hex>`), NOT reconstructed arguments. Each step passed `migrationState == 0 (OPEN)` pre-check.

| # | Phase | Selector | Args (decoded) | tx_hash | block | gas_used | status |
|---|---|---|---|---|---|---|---|
| 1 | SEED_MARKET_FUNDING | 0x2c96f1bc | `(1, 0, 1_789_715_546)` | `0xd5de956c7131efc43bfb19e0695c8ed65afadd41e25e918cfd0c547b8263c7b5` | 47_398_560 | 93_608 | 1 |
| 2 | SEED_MARKET_FUNDING | 0x2c96f1bc | `(2, 0, 0)` | `0x3848b747e55e30955bf3e3873b27e6759a7993abc525cfa8bf71e4ffb9ab0ec5` | 47_398_570 | 73_660 | 1 |
| 3 | SEED_POSITION | 0x0ef3a5f7 | `(0x290b…9274, 1, +1_000, +3_000_000, 0)` | `0x090122c1a843e71295c544d2369b8934243c6002e95673df669b496e9d3eb33a` | 47_398_599 | 234_037 | 1 |
| 4 | SEED_POSITION | 0x0ef3a5f7 | `(0x475f…bc0c, 1, −2, −6_000, 0)` | `0x41fe92c69db89c31c7de3f089a6d2b85a554684d0c3142597cf24a912ca8359e` | 47_398_636 | 235_002 | 1 |
| 5 | SEED_POSITION | 0x0ef3a5f7 | `(0x6685…002d, 1, −1_000_000, −2_468_310_000, 0)` | `0xd103c560902b97fcaa55062babfa7708c2ee11341b00a2158f53307ef5d56469` | 47_398_649 | 217_890 | 1 |
| 6 | SEED_POSITION | 0x0ef3a5f7 | `(0x77ca…0020, 1, −1_000, −3_000_000, 0)` | `0x0a4744a3ebc26418df9eb0c4a16d85fc8b899e2f5dc93144e3fd92cd5e7ef8bb` | 47_398_660 | 217_890 | 1 |
| 7 | SEED_POSITION | 0x0ef3a5f7 | `(0x8b94…9a34, 1, +2, +6_000, 0)` | `0x5b30b85ae4fc1a166a620b6f8b70c0f09d1d4e16ac7c2285e60833f83c21c1cc` | 47_398_672 | 216_913 | 1 |
| 8 | SEED_POSITION | 0x0ef3a5f7 | `(0xff28…f837, 1, +1_000_000, +2_468_310_000, 0)` | `0x653c73f651e9bfac998ce282f732991c846fc61edb58da40b4c0b35c1813dc3f` | 47_398_684 | 216_961 | 1 |

Total gas used: `93_608 + 73_660 + 234_037 + 235_002 + 217_890 + 217_890 + 216_913 + 216_961 = 1_505_961` gas.

## G. Per-step readback

Every step's readback was captured live via `cast call` immediately after receipt success, and each observed value matched the manifest and shifted `marketState(1)` OI as expected:

```
after #1: marketState(1) = (longOI=0, shortOI=0, cumFR=0, lastFundingTs=1_789_715_546)
after #2: marketState(2) = (0, 0, 0, 0)
after #3: positions(0x290b…9274, 1) = (+1_000, +3_000_000, 0);    marketState(1).longOI = 1_000
after #4: positions(0x475f…bc0c, 1) = (−2, −6_000, 0);            marketState(1).shortOI = 2
after #5: positions(0x6685…002d, 1) = (−1_000_000, −2_468_310_000, 0); marketState(1).shortOI = 1_000_002
after #6: positions(0x77ca…0020, 1) = (−1_000, −3_000_000, 0);    marketState(1).shortOI = 1_001_002
after #7: positions(0x8b94…9a34, 1) = (+2, +6_000, 0);            marketState(1).longOI = 1_002
after #8: positions(0xff28…f837, 1) = (+1_000_000, +2_468_310_000, 0); marketState(1).longOI = 1_001_002
```

## H. Final market funding state (ENGINE_V2)

```
marketState(1)            = (longOI=1_001_002, shortOI=1_001_002, cumulativeFundingRate1e18=0, lastFundingTimestamp=1_789_715_546)
marketState(2)            = (0, 0, 0, 0)
```

Byte-identical to `manifest.markets[]`. ✓

## I. Final 6 positions (ENGINE_V2)

```
0x290bd12c93e467bf51c51f5273d35bddb19e9274  (+1_000,     +3_000_000,     0)
0x475fe397fa56884952d350aa9ee1c3946964bc0c  (−2,         −6_000,         0)
0x66858286feea78a05ea093673ea1535e0a52002d  (−1_000_000, −2_468_310_000, 0)
0x77ca9dd6ccce2d692fb23877a2db7178807b0020  (−1_000,     −3_000_000,     0)
0x8b94a83d1ad3bd2337b1886e7962ca8e0bba9a34  (+2,         +6_000,         0)
0xff287410852b9328437eac353720e5476bc5f837  (+1_000_000, +2_468_310_000, 0)
```

Byte-identical to `manifest.positions[]`. ✓

## J. Final basis / openN

All 6 `openNotional1e8` values match manifest exactly. Entry-basis sign invariant holds: `sign(openN) == sign(size)` for every seeded position (enforced by `adminSeedPosition` line 238-239).

## K. Residual bad debt

```
totalResidualBadDebtBase = 0   (no seeded; matches manifest.residualBadDebt = [])
```

## L. Derived OI

```
V2.marketState(1).longOI   = 1_001_002 == Σ positive positions ✓
V2.marketState(1).shortOI  = 1_001_002 == Σ |negative| positions ✓
V2.marketState(2)          = (0, 0, 0, 0) ✓
```

OI is derived automatically by `_updateMarketOpenInterest` (called by `adminSeedPosition` line 253), NOT via a separate seed call — as designed.

## M. V1 / manifest / V2 reconciliation table

| Field | V1 snapshot @ 47_354_411 | manifest | V2 post-seed | Match |
|---|---|---|---|---|
| chainId | 84532 | 84532 | 84532 | ✓ |
| marketState(1).longOI | 1_001_002 | 1_001_002 | 1_001_002 | ✓ |
| marketState(1).shortOI | 1_001_002 | 1_001_002 | 1_001_002 | ✓ |
| marketState(1).cumFR | 0 | 0 | 0 | ✓ |
| marketState(1).lastFundingTs | 1_789_715_546 | 1_789_715_546 | 1_789_715_546 | ✓ |
| marketState(2) | (0,0,0,0) | (0,0,0,0) | (0,0,0,0) | ✓ |
| totalResidualBadDebtBase | 0 | 0 | 0 | ✓ |
| 0x290b…9274 (size / openN / lastCFR) | 1000 / 3_000_000 / 0 | 1000 / 3_000_000 / 0 | 1000 / 3_000_000 / 0 | ✓ |
| 0x475f…bc0c (size / openN / lastCFR) | −2 / −6000 / 0 | −2 / −6000 / 0 | −2 / −6000 / 0 | ✓ |
| 0x6685…002d (size / openN / lastCFR) | −1_000_000 / −2_468_310_000 / 0 | −1_000_000 / −2_468_310_000 / 0 | −1_000_000 / −2_468_310_000 / 0 | ✓ |
| 0x77ca…0020 (size / openN / lastCFR) | −1000 / −3_000_000 / 0 | −1000 / −3_000_000 / 0 | −1000 / −3_000_000 / 0 | ✓ |
| 0x8b94…9a34 (size / openN / lastCFR) | 2 / 6000 / 0 | 2 / 6000 / 0 | 2 / 6000 / 0 | ✓ |
| 0xff28…f837 (size / openN / lastCFR) | 1_000_000 / 2_468_310_000 / 0 | 1_000_000 / 2_468_310_000 / 0 | 1_000_000 / 2_468_310_000 / 0 | ✓ |
| Σ net position (across 6) | 0 | 0 | 0 | ✓ |
| Σ positive position | 1_001_002 | 1_001_002 | 1_001_002 | ✓ |
| Σ |negative| position | 1_001_002 | 1_001_002 | 1_001_002 | ✓ |

**Every row matches. Full V1 ↔ manifest ↔ V2 economic equality.**

## N. Clearing balance (preserved)

```
Vault.balances(CLEARING_V2, mUSDC) = 1_000_000_000 (unchanged from PERPS_V2_BASE_SEPOLIA_CLEARING_FUND_V1)
```

## O. Migration OPEN proof

```
ENGINE_V2.migrationState        = 0 (OPEN)   ← still OPEN, seal not called
```

## P. On-chain snapshotHash still zero

```
ENGINE_V2.migrationSnapshotHash = 0x0000000000000000000000000000000000000000000000000000000000000000
```

Sealed hash will be written in the separate `PERPS_V2_BASE_SEPOLIA_MIGRATION_SEAL_V1` milestone (C4.5).

## Q. Timelock still queued/ready/unexecuted

```
Timelock op 0xb42e46a90289…4fd0:
   queuedTransactions           = true
   ready                        = true (block.timestamp > eta 1_790_475_748)
   executed                     = false
   time until GRACE_PERIOD expiry ≈ 12.97 d
```

## R. Vault V1=true / V2=false

```
Vault.isAuthorizedEngine(V1)    = true          ← unchanged
Vault.isAuthorizedEngine(V2)    = false         ← unchanged
```

V2 authorization is a separate later milestone via the queued Timelock op.

## S. Backend still V1

```
Backend HEAD                    = ad8dd7466 (unchanged)
Backend worktree                = clean (unchanged)
.env.perps_closed_test_prepare_only.local:
   PERPS_ACTIVE_ENGINE_VERSION  = <unset → defaults to v1>
   EXECUTOR_REAL_BROADCAST_ENABLED = false
   INDEXER_ENABLED              = false
```

## T. Public-chain transaction audit

```
Base Sepolia writes                = 8  (2 × adminSeedMarketFunding + 6 × adminSeedPosition)
                                      All targeting ENGINE_V2.
Safe / Timelock ops                = 0
Vault direct writes                = 0
CLEARING_V2 writes                 = 0
migration seal                     = 0
Backend V2 activation              = 0
V2 trades                          = 0
DB writes                          = 0

OWNER nonce delta                  = +8   (775 → 783) ✓
Safe nonce delta                   = 0
Executor nonce delta               = 0
Runtime broadcaster                = disabled (backend broadcast policy unchanged)
```

Password file at `/run/user/1000/deopt-deployer.pw` removed (verified absent).

## U. Changed docs

- `docs/PERPS_V2_BASE_SEPOLIA_MIGRATION_SEED_V1.md` — NEW (this file).

No production Solidity modification. No artifact modification.

## V. Pushed HEAD

New commit on top of `1ed47d5`, pushed to `origin/main`.

## W. Remaining blockers

**None** for the next milestone.

- Migration OPEN ✓
- All 8 seed steps successful ✓
- V1 ↔ manifest ↔ V2 reconcile byte-for-byte ✓
- Clearing balance ≥ MINIMUM_REQUIRED_CLEARING ✓
- OWNER ETH sufficient (0.001777 ETH; sealMigration is ~1 owner-EOA tx of ~50k gas; ample headroom)
- Snapshot artifact untouched; snapshotHash independently reproducible ✓

## Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_MIGRATION_SEAL_V1`** (C4.5) — invoke `ENGINE_V2.sealMigration(0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d)` from OWNER EOA. Preconditions enforced on-chain (`PerpEngineTradingV2.sol:325-335`):

- `migrationState == OPEN` ✓
- `snapshotHash != 0` ✓ (given canonical hash)
- `clearingAccount != 0` ✓ (already set in ARM)
- `matchingEngine != 0` ✓ (already set in DEPLOY)
- `_riskModule != 0` ✓ (already set in DEPLOY)

After seal: `migrationState = SEALED`, `migrationSnapshotHash = 0x039d9172…3d7d`, `applyTrade` becomes callable (subject to `Vault.isAuthorizedEngine(V2)` still being `false` → any V2 trade still blocks at Vault ACL until C5).

**Do NOT execute automatically.** STOP.
