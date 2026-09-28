# PERPS V2 BASE SEPOLIA CLEARING FUND V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_CLEARING_FUND_V1`
**Status**: **COMPLETE — 2 authorized on-chain writes (approve + fundClearing)**
**Sol HEAD (pre)**: `af8ff3d` (unchanged during milestone; new docs commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Chain**: Base Sepolia (chainId 84532)

Scope: fund `CLEARING_V2` with exactly `1_000_000_000` native mUSDC (= 1000.000000 mUSDC) via `OWNER → mUSDC.approve(CLEARING_V2, 1_000_000_000)` + `CLEARING_V2.fundClearing(mUSDC, 1_000_000_000)`. No migration seed, no seal, no Timelock, no Vault authorization, no backend activation.

Milestone was first entered and BLOCKED because OWNER held 0 mUSDC. `PERPS_V2_BASE_SEPOLIA_MUSDC_OWNER_BOOTSTRAP_V1` minted the required 1_000_000_000 to OWNER (tx `0xeab8d5107e94fd7c71bb6fa4c95a926aeeda16b4cf5b1c81aa2311a5e80574ff`, block `47_397_624`). This milestone resumes at §4 (keystore reuse).

---

## A. Signer

```
FUNDING_SIGNER (== OWNER)  = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
keystore                    = ~/.foundry/keystores/deopt-deployer
keystore address readback   = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27  ✓
signer nonce (pre)          = 773
```

Password provided via temporary mode-0600 file at `/run/user/1000/deopt-deployer.pw` (deleted immediately after final broadcast; verified absent).

## B. OWNER pre-balance

`mUSDC.balanceOf(OWNER)  =  1_000_000_000` (= 1000.000000 mUSDC; bootstrap-provisioned).

## C. OWNER ETH balance

`0.001786841853493698 ETH` (≈ 0.001787 ETH; sufficient for 2 tx at 6 mwei ≈ 0.000001 ETH total).

## D. Allowance pre

`mUSDC.allowance(OWNER, CLEARING_V2)  =  0` → approval required.

## E. Approval tx

```
from     = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
to       = 0x6eAe407f5640B006faC9965182e238582A3B412E   (mUSDC)
function = approve(address,uint256)                     selector 0x095ea7b3
args     = (0x54d49c088DD27cFc82685b867c182b4bB4aC435c, 1_000_000_000)  (exact, not unlimited)
```

## F. Approval receipt

```
tx_hash               = 0x45f13b12199392117519d5758281ea3277ab5a5eb6646878c5e9a6351f16cf88
block_number          = 47_397_912
status                = 1 (success)
gas_used              = 45_921
effective_gas_price   = 6 mwei
gas_cost              ≈ 275_526_000_000 wei (≈ 0.0000002755 ETH)
transactionIndex      = 12
event                 = mUSDC.Approval(owner=OWNER, spender=CLEARING_V2, value=1_000_000_000)
                        topic0 = 0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925
readback allowance    = 1_000_000_000  ✓ (matches required)
```

## G. Funding delta

```
CLEARING_V2 vault mUSDC balance (immediately pre-fund)  = 0
target                                                    = 1_000_000_000
fund_delta = max(0, target - current)                     = 1_000_000_000
```

Assertion `current == 0` held; no overfund risk.

## H. fundClearing tx

```
from     = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
to       = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c   (CLEARING_V2)
function = fundClearing(address,uint256)                selector 0xcbf68546
args     = (0x6eAe407f5640B006faC9965182e238582A3B412E, 1_000_000_000)
```

## I. Funding receipt

```
tx_hash               = 0x9a684045f69480684b012df210db758bd4cb36d3879f48305bd3e430a11083c1
block_number          = 47_397_932
status                = 1 (success)
gas_used              = 144_508
effective_gas_price   = 6 mwei
gas_cost              ≈ 867_048_000_000 wei (≈ 0.0000008670 ETH)
transactionIndex      = 5
```

Emitted events (7 total, in order):

```
[logIdx 0x3f] mUSDC.Transfer(OWNER → CLEARING_V2, 1_000_000_000)
              topic0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef  (ERC20 Transfer)
[logIdx 0x40] mUSDC.Approval(CLEARING_V2 → Vault, 1_000_000_000)
              (CLEARING_V2.forceApprove(Vault, received) — scoped intra-tx allowance)
[logIdx 0x41] Vault.??(CLEARING_V2, mUSDC, 0)
              topic0 = 0xf67cd268c5cb2f9e884934944bae45c8d46cffe591c6243336b8c007ca4cf067
[logIdx 0x42] mUSDC.Transfer(CLEARING_V2 → Vault, 1_000_000_000)
[logIdx 0x43] Vault.??(CLEARING_V2, mUSDC, 1_000_000_000)
              topic0 = 0x8752a472e571a816aea92eec8dae9baf628e840f4929fbcc2d155e6233ff68a7  (Vault internal-credit)
[logIdx 0x44] mUSDC.Approval(CLEARING_V2 → Vault, 0)
              (CLEARING_V2.forceApprove(Vault, 0) — hygiene reset per contract)
[logIdx 0x45] CLEARING_V2.ClearingFunded(funder=OWNER, asset=mUSDC, amount=1_000_000_000)
              topic0 = 0x4f10b8d6d0bda2eb245f557f0edc67b25475ef91f8dbe90ac1ccb07542bcdd34
```

Trace matches `PerpClearingAccountV2.fundClearing` semantics exactly:
1. `safeTransferFrom(OWNER, CLEARING_V2, 1_000_000_000)` → OWNER→CLEARING_V2 Transfer.
2. `forceApprove(Vault, 1_000_000_000)` → CLEARING_V2 grants Vault (scoped).
3. `Vault.deposit(mUSDC, 1_000_000_000)` → CLEARING_V2→Vault Transfer + internal credit.
4. `forceApprove(Vault, 0)` → hygiene reset.
5. `ClearingFunded(OWNER, mUSDC, 1_000_000_000)`.

## J. Final clearing ledger

`Vault.balances(CLEARING_V2, mUSDC)  =  1_000_000_000` (= 1000.000000 mUSDC = target). ✓

## K. OWNER post-balance

`mUSDC.balanceOf(OWNER)  =  0`.

## L. Token / ledger conservation

```
OWNER token delta                 = 1_000_000_000 − 0 = 1_000_000_000 decrease
Vault token custody delta         = 224_066_000_000 − 223_066_000_000 = 1_000_000_000 increase
CLEARING_V2 token bal (residual)  = 0 (all forwarded to Vault via deposit)
CLEARING_V2 vault ledger increase = 0 → 1_000_000_000
mUSDC totalSupply                 = 1_424_067_000_000 (unchanged)

OWNER token↓ == Vault custody↑    = true   ✓
OWNER token↓ == CLEARING ledger↑   = true   ✓
totalSupply invariant             = held   ✓
```

No unexplained economic delta. Full conservation.

## M. Allowance post

`mUSDC.allowance(OWNER, CLEARING_V2)  =  0` (spent exactly by `safeTransferFrom` in `fundClearing`; no additional hygiene reset authorized or needed).

## N. Migration OPEN / snapshot-zero proof

```
ENGINE_V2.migrationState          = 0 (OPEN)      ← unchanged
ENGINE_V2.migrationSnapshotHash   = 0x0           ← unchanged
```

No positions seeded. No market funding seeded. No residual bad debt seeded. Migration lifecycle untouched.

## O. Vault V1=true / V2=false proof

```
Vault.isAuthorizedEngine(V1)      = true          ← unchanged
Vault.isAuthorizedEngine(V2)      = false         ← unchanged
```

## P. Timelock queued/ready/unexecuted proof

```
Timelock op 0xb42e46a90289…4fd0:
   queuedTransactions            = true
   eta (ARM)                     = 1_790_475_748  (2026-09-27 02:22:28 UTC)
   ready                         = true (block.timestamp > eta)
   executed                      = false
   grace_expiry                  = 1_791_685_348  (2026-10-11 02:22:28 UTC)
   time until expiry             = 12.98 d
```

## Q. snapshotHash re-verification

Read-only recompute against committed `artifacts/perps_v2_final_snapshot/manifest.json` via committed `tools/perps_v2_cutover/snapshot_hash.py`:

```
canonical_cbor_bytes = 1638
snapshot_hash        = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d   ← identical to FINAL_SNAPSHOT §L
```

Manifest unchanged; funding did NOT alter the migration package.

## R. OWNER nonce delta

`nonce(pre) = 773 → nonce(post) = 775`   Δ = +2 (approve + fundClearing) ✓

## S. Public-chain write audit

```
Base Sepolia writes                = 2  (mUSDC.approve + CLEARING_V2.fundClearing)
Safe / Timelock ops                = 0
Vault direct writes                = 0  (Vault credited internally via CLEARING_V2 → Vault.deposit; no operator-side Vault call)
CLEARING_V2 direct writes          = 1  (fundClearing; the two intra-tx forceApprove calls are internal)
Migration writes (seed/seal)       = 0
Backend V2 activation              = 0
V2 trades                          = 0
DB writes                          = 0

OWNER nonce delta                  = +2   (approve + fundClearing) ✓
Safe nonce delta                   = 0
Executor nonce delta               = 0
```

## T. Changed docs

- `docs/PERPS_V2_BASE_SEPOLIA_CLEARING_FUND_V1.md` — NEW (this file).

No production Solidity modification.

## U. Pushed HEAD

New commit on top of `af8ff3d`, pushed to `origin/main`.

## V. Remaining blockers

**None** for the exact next milestone (`PERPS_V2_BASE_SEPOLIA_MIGRATION_SEED_V1`):

- Clearing seeded ≥ MINIMUM_REQUIRED_CLEARING (100 mUSDC): satisfied (1000 mUSDC ≥ 100 mUSDC) ✓
- Migration state == OPEN ✓
- OWNER available as seed signer (nonce 775; ETH ≈ 0.001786 ETH — sufficient for 9 seed txes at 6 mwei × ~120k gas each ≈ 0.0000065 ETH total, but **operational recommendation: top OWNER to ≥ 0.005 ETH before proceeding** per `FINAL_SNAPSHOT §U`).

## Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_MIGRATION_SEED_V1`** — execute the 8-step seed-calldata iterator at `artifacts/perps_v2_final_snapshot/seed_calldata.json` from OWNER EOA:

```
2 × adminSeedMarketFunding(marketId, cumFR, lastFundingTs)     selector 0x2c96f1bc
6 × adminSeedPosition(trader, marketId, size, openN, lastCumFR) selector 0x0ef3a5f7
0 × adminSeedResidualBadDebt                                    (bad debt is zero)
```

then per-market/per-position on-chain reconciliation against the manifest. `sealMigration(0x039d9172…3d7d)` is a SEPARATE later milestone (C4.5).

**Do NOT execute automatically.** STOP.
