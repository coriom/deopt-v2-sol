# PERPS V2 BASE SEPOLIA MIGRATION SEAL V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_MIGRATION_SEAL_V1` (C4.5)
**Status**: **COMPLETE — 1 irreversible on-chain write (sealMigration)**
**Sol HEAD (pre)**: `d39d14a` (unchanged during milestone; new docs commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Production Solidity bytecode**: frozen at `004bf78c32b2b5210cd7daabef2685cd461aeec7`
**Chain**: Base Sepolia (chainId 84532)

Scope: irreversibly transition `ENGINE_V2.migrationState` from `OPEN → SEALED` by broadcasting `sealMigration(0x039d9172…3d7d)` from `OWNER`. No Timelock, no Vault authorization, no backend V2 activation, no V2 trade.

---

## A. Artifact snapshotHash re-verification

```
manifest.json  sha256 = 88707f092c2be05fb5e4b73454f880b84abc4a1a95199e4eeb9aeec024687ddd
manifest.cbor  sha256 = 520897f586cb275fbe81d4d5acb30ce45632be4ce2574a0577bc302b339ed857
seed_calldata  sha256 = d92cf6abae899123d7d96009f36da3f8a715c04a7ee9ac6bf5dddc9c0b1cdb14
recomputed snapshot_hash = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d   ← identical to FINAL_SNAPSHOT §L
```

Artifacts unchanged since `dfa3bbc` and `d39d14a`. Git-clean.

## B. Pre-seal full reconciliation

Live chain state pre-seal (block 47_399_005):

```
chainId                             = 84532
PME_V1.paused                       = true
V1_ENGINE.liquidationPaused         = true
Vault.isAuthorizedEngine(V1)        = true
Vault.isAuthorizedEngine(V2)        = false
ENGINE_V2.migrationState            = 0 (OPEN)
ENGINE_V2.migrationSnapshotHash     = 0x0
ENGINE_V2.clearingAccount           = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c
ENGINE_V2.matchingEngine            = 0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2
ENGINE_V2.riskModule                = 0x8C3d9F71cA59B908Fa200546A63ea62F9C932998
Vault.balances(CLEARING_V2, mUSDC)  = 1_000_000_000
Timelock queuedTransactions(op)     = true
```

V2 seeded state (verified byte-for-byte against manifest):

```
marketState(1) = (1_001_002, 1_001_002, 0, 1_789_715_546)
marketState(2) = (0, 0, 0, 0)
totalResidualBadDebtBase = 0

0x290b…9274  (+1_000,     +3_000_000,     0)   ✓
0x475f…bc0c  (−2,         −6_000,         0)   ✓
0x6685…002d  (−1_000_000, −2_468_310_000, 0)   ✓
0x77ca…0020  (−1_000,     −3_000_000,     0)   ✓
0x8b94…9a34  (+2,         +6_000,         0)   ✓
0xff28…f837  (+1_000_000, +2_468_310_000, 0)   ✓

Σ net       = 0        ✓
Σ positive  = 1_001_002 ✓
Σ |negative| = 1_001_002 ✓
```

## C. Verified seal ABI / semantics

From `src/perp/PerpEngineTradingV2.sol:325-335`:

```solidity
function sealMigration(bytes32 snapshotHash) external onlyOwner onlyMigrationOpen {
    if (snapshotHash == bytes32(0)) revert MigrationSnapshotHashZero();
    if (clearingAccount == address(0)) revert MigrationClearingNotConfigured();
    if (matchingEngine == address(0)) revert MigrationMatchingEngineNotConfigured();
    if (address(_riskModule) == address(0)) revert MigrationRiskModuleNotConfigured();
    migrationSnapshotHash = snapshotHash;
    migrationState = MigrationState.SEALED;
    emit MigrationSealed(snapshotHash, msg.sender);
}
```

- **Selector**: `0x05d5af5b`
- **Modifiers**: `onlyOwner` + `onlyMigrationOpen` (line 189-191: `if (migrationState != MigrationState.OPEN) revert MigrationAlreadySealed();`)
- **Guards**: non-zero snapshotHash + wiring (clearing/matching/risk) preconditions
- **Effects**: `migrationSnapshotHash := snapshotHash`, `migrationState := SEALED (1)`
- **Event**: `MigrationSealed(bytes32 snapshotHash, address indexed sealer)` topic0 `0xfdd70720ee4ac8df3db40d2f0ef06f3a6df16e1f981ef0d658be4ac266d788b5`
- **Irreversibility**: no un-seal function exists in the frozen source. Post-seal, `onlyMigrationOpen` fail-closes every admin seed function.

## D. OWNER nonce / balance pre

```
nonce_pre  = 783
balance_pre = 1_776_548_230_485_688 wei (0.001776548230485688 ETH)
```

## E. Exact calldata

```
0x05d5af5b039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d
```

Decoded: `sealMigration(0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d)`.

## F. Gas estimate

```
eth_call from OWNER         → success (result: 0x)
eth_estimateGas             = 57_692
gas_price                   = 6 mwei
estimated cost              = 346_152_000_000 wei ≈ 0.0000003462 ETH
headroom vs balance          = 5132.3×
```

## G. Seal tx hash

```
0xf059de47de04d56f70d00b2363a7f1f51b2a4e27edba67bed321f99967c3f78b
```

## H. Block / receipt / gas

```
block_number             = 47_399_384
block_timestamp          = 0x6ab9e290 (2026-09-28 03:57:04 UTC-ish)
status                   = 1 (success)
gas_used                 = 56_883
effective_gas_price      = 6 mwei
gas_cost                 = 341_298_000_000 wei (~0.0000003413 ETH)
transactionIndex         = 7
```

## I. Seal event

```
event  MigrationSealed(bytes32 snapshotHash, address indexed sealer)
topic0 = 0xfdd70720ee4ac8df3db40d2f0ef06f3a6df16e1f981ef0d658be4ac266d788b5
topic1 = 0x000000000000000000000000c35f7a8a103a9a4464adfaa76b9b514093d23c27   ← OWNER (indexed sealer)
data   = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d   ← snapshotHash (non-indexed)
logIndex = 0x24
```

Single event emitted from `ENGINE_V2`. No other logs.

## J. migrationState = SEALED proof

```
ENGINE_V2.migrationState()  =  1  (SEALED)      ← was 0 (OPEN) pre-tx
```

## K. On-chain migrationSnapshotHash proof

```
ENGINE_V2.migrationSnapshotHash()  =  0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d
```

Byte-identical to the canonical off-chain hash `0x039d9172…3d7d` derived from `manifest.json` + `snapshot_hash.py`. Public on-chain commitment established.

## L. Admin seed functions fail-closed proof

Three READ-ONLY `eth_call` probes from OWNER post-seal:

```
adminSeedMarketFunding(1, 0, 0)                        → revert 0x836df086 (MigrationAlreadySealed())  ✓
adminSeedPosition(0x290b…9274, 1, +1, +3_000_000, 0)   → revert 0x836df086 (MigrationAlreadySealed())  ✓
adminSeedResidualBadDebt(0x290b…9274, 0)               → revert 0x836df086 (MigrationAlreadySealed())  ✓
```

`keccak256("MigrationAlreadySealed()")[0:4] = 0x836df086` (verified). Revert path via `onlyMigrationOpen` modifier (`PerpEngineTradingV2.sol:189-191`).

Migration is provably CLOSED. All three admin seed functions cryptographically unreachable.

## M. Post-seal economic reconciliation

Byte-identical to pre-seal (seal changed migration metadata only):

```
marketState(1) = (1_001_002, 1_001_002, 0, 1_789_715_546)
marketState(2) = (0, 0, 0, 0)
totalResidualBadDebtBase = 0

0x290b…9274  (+1_000,     +3_000_000,     0)
0x475f…bc0c  (−2,         −6_000,         0)
0x6685…002d  (−1_000_000, −2_468_310_000, 0)
0x77ca…0020  (−1_000,     −3_000_000,     0)
0x8b94…9a34  (+2,         +6_000,         0)
0xff28…f837  (+1_000_000, +2_468_310_000, 0)
```

No economic drift.

## N. Clearing balance

```
Vault.balances(CLEARING_V2, mUSDC)  =  1_000_000_000  (unchanged from CLEARING_FUND)
```

## O. Vault V1=true / V2=false proof

```
Vault.isAuthorizedEngine(V1)  =  true            ← unchanged
Vault.isAuthorizedEngine(V2)  =  false           ← unchanged
```

V2 remains cryptographically blocked at the Vault ACL from any settlement mutation. Even though `migrationState` is SEALED and `applyTrade` no longer trips the migration-OPEN guard, the Vault-side authorization gate still fails-closes any settlement path until the queued Timelock op executes.

## P. Timelock queued/ready/unexecuted proof

```
Timelock op 0xb42e46a90289…4fd0:
   queuedTransactions           = true
   ready                        = true
   executed                     = false
   time_until_grace_expiry      ≈ 12.97 d
```

## Q. Backend still V1

```
Backend HEAD                    = ad8dd7466 (unchanged)
Backend worktree                = clean
PERPS_ACTIVE_ENGINE_VERSION     = <unset → defaults to v1>
EXECUTOR_REAL_BROADCAST_ENABLED = false
INDEXER_ENABLED                 = false
```

## R. OWNER nonce / balance post

```
nonce_post   = 784                 (Δ = +1)   ✓
balance_post = 1_776_194_206_596_108 wei (≈ 0.001776 ETH)
Δ balance    = −354_023_889_580 wei (~0.00000035 ETH; slightly higher than eth_estimateGas × gas_price due to L1 blob fee ≈ 12.7 gwei)
```

## S. Transaction audit

```
Base Sepolia writes             = 1  (ENGINE_V2.sealMigration only)
Safe / Timelock ops             = 0
Vault authorization writes      = 0
migration seed writes           = 0
Backend V2 activation           = 0
V2 trades                       = 0
DB writes                       = 0

OWNER nonce Δ                   = +1
Safe nonce Δ                    = 0
Executor nonce Δ                = 0
```

Password file at `/run/user/1000/deopt-deployer.pw` removed and verified absent.

## T. Changed docs

- `docs/PERPS_V2_BASE_SEPOLIA_MIGRATION_SEAL_V1.md` — NEW (this file).

No production Solidity modification. No artifact modification.

## U. Pushed HEAD

New commit on top of `d39d14a`, pushed to `origin/main`.

## V. Remaining blockers

**None** for the next milestone (`PERPS_V2_BASE_SEPOLIA_TIMELOCK_EXECUTE_VAULT_AUTH_V1`).

- migrationState SEALED ✓
- migrationSnapshotHash matches canonical ✓
- Admin seed provably fail-closed ✓
- Timelock op still queued+ready+unexecuted (~12.97 d remaining) ✓
- CLEARING balance preserved ✓
- V1 freeze intact ✓
- Executor / OWNER ETH available for later steps

## Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_TIMELOCK_EXECUTE_VAULT_AUTH_V1`** (C5) — execute the queued Timelock op `0xb42e46a90289…4fd0` to flip `Vault.setAuthorizedEngine(ENGINE_V2, true)`. Path options:

1. **Direct call** — anyone can call `ProtocolTimelock.executeTransaction(target, value, data, eta)` once ready. Cheap, permissionless.
2. **Via OPS Safe** — matching the queue-side path (via delegation router) for continuity in the ops audit trail.

Post-execute state: `Vault.isAuthorizedEngine(V2) == true`. V2 settlement path becomes callable (subject to backend broadcast policy still being fail-closed).

**Do NOT execute automatically.** STOP.
