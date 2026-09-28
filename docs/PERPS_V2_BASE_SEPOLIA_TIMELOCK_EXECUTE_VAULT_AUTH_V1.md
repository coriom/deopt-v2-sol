# PERPS V2 BASE SEPOLIA TIMELOCK EXECUTE VAULT AUTH V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_TIMELOCK_EXECUTE_VAULT_AUTH_V1` (C5)
**Status**: **COMPLETE — 1 authorized on-chain execution (OPS Safe → ProtocolTimelock.executeTransaction → Vault.setAuthorizedEngine)**
**Sol HEAD (pre)**: `0eb089e` (unchanged during milestone; new docs commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Production Solidity bytecode**: frozen at `004bf78c32b2b5210cd7daabef2685cd461aeec7`
**Chain**: Base Sepolia (chainId 84532)

Scope: OPS Safe 2/3 signed + executed the ALREADY QUEUED Timelock operation `0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0`, flipping `Vault.isAuthorizedEngine(ENGINE_V2) : false → true`. No migration mutation, no new Timelock queue, no backend V2 activation, no V2 trade.

---

## A. Pre-C5 state (Stage A revalidation, unchanged when Safe tx broadcast)

```
chainId                             = 84532
PME_V1.paused                       = true
V1_ENGINE.liquidationPaused         = true
Vault.isAuthorizedEngine(V1)        = true
Vault.isAuthorizedEngine(V2)        = false
ENGINE_V2.migrationState            = 1 (SEALED)
ENGINE_V2.migrationSnapshotHash     = 0x039d9172…3d7d
Vault.balances(CLEARING_V2, mUSDC)  = 1_000_000_000
Timelock queuedTransactions(op)     = true
```

## B. Fresh Safe nonce (used for signing)

```
Safe nonce (pre)   = 14   (verified live pre-signing)
Safe nonce (post)  = 15   (Δ = +1 exactly, confirmed post-execution)
```

## C. Exact Safe payload

Full outer calldata to Safe:

```
Safe.to           = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588   (ProtocolTimelock)
Safe.value        = 0
Safe.operation    = 0 (CALL)
Safe.safeTxGas    = 0
Safe.baseGas      = 0
Safe.gasPrice     = 0
Safe.gasToken     = 0x0
Safe.refundReceiver = 0x0
Safe.nonce        = 14

Safe.data (outer function) = executeTransaction(address,uint256,bytes,uint256)  (selector 0x06a41d09)
  arg[0] target   = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3   (CollateralVault)
  arg[1] value    = 0
  arg[2] data     = 0x3331c56e00000000000000000000000044702b0a3c329f2cc5b5c02c2123dc9386a46db90000000000000000000000000000000000000000000000000000000000000001
                    (setAuthorizedEngine(ENGINE_V2, true))
  arg[3] eta      = 1_790_475_748

SafeTx typehash    = 0xbb8310d486368db6bd6f849402fdd73ad53d316b5a4b2644ad6efe0f941286d8
structHash         = 0x29de4e4c84f778b453329432843567774a35c50ecc47c9fabc178d9a9e5d1da6
SAFE_TX_HASH       = 0xad70070a2cc57541d273ad385103657f0d83a3ad54cde719eeb70d5de63508e0
```

The Safe's on-chain `ExecutionSuccess(bytes32 txHash, uint256 payment)` event (logIdx 0x1c) has `topic1 = 0xad70070a2cc57541d273ad385103657f0d83a3ad54cde719eeb70d5de63508e0` — byte-identical to the Stage-A-computed SAFE_TX_HASH. Independent proof the operator signed the exact payload prepared here.

## D. Operation ID recomputation

Local recomputation of `_hashOperation(target, value, data, eta) = keccak256(abi.encode(target, value, data, eta))`:

```
target = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3
value  = 0
data   = 0x3331c56e00000000000000000000000044702b0a3c329f2cc5b5c02c2123dc9386a46db90000000000000000000000000000000000000000000000000000000000000001
eta    = 1790475748
                             ↓
recomputed opId = 0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0   ← identical to on-chain queued op
```

Timelock emitted `TransactionExecuted(txHash indexed, target indexed, value, data, eta, returnData)` with `topic1 = 0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0` — byte-identical to the recomputed opId.

## E. Timelock-window proof

```
eta                = 1_790_475_748
tx block timestamp = 0x6aba24e4 = 1_790_575_332   (block 47_407_874; Δ = +99_584 s = 27.66 h past eta)
GRACE_PERIOD       = 1_209_600 s (14 d)
expiry             = 1_791_685_348
ready              = true (block.timestamp > eta)
not_expired        = true (block.timestamp < eta + GRACE_PERIOD)
```

## F. Safe tx hash

```
0x9d2e7571c0eddca457045c9758d22c4be149b24d0c96c739369b06fde68537ac
```

## G. Receipt / block

```
tx_hash             = 0x9d2e7571c0eddca457045c9758d22c4be149b24d0c96c739369b06fde68537ac
block_number        = 47_407_874
block_hash          = 0xcd2ef8d90ad317d4d789af24409de0999cbe84d60f5ead5bed915572b02941c7
status              = 1 (success)
gas_used            = 155_278
effective_gas_price = 6 mwei
transactionIndex    = 6

Outer path: DIRECT SAFE OWNER CALL (not delegation router)
outer from = 0xb9F8dE807Ff98D5730035a8BFED4bDa33E886d06   (Safe owner)
outer to   = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46   (OPS Safe)
outer input = Safe.execTransaction(...) (selector 0x6a761202)
outer nonce = 3 (owner EOA nonce; irrelevant to Safe/Timelock accounting)
```

## H. Nested Timelock execution proof

4 events emitted, in order:

```
[logIdx 0x19]  Safe:      SafeMultiSigTransaction(...)
                          topic0 = 0x66753cd2356569ee081232e3be8909b950e0a76c1f8460c3a5e3c2be32b11bed
                          (unindexed args: to=Timelock, value=0, data=outer-calldata, ..., signatures)

[logIdx 0x1a]  Vault:     AuthorizedEngineSet(address indexed engine, bool authorized)
                          topic0 = 0x4c7a654dd2ebc1b6aa76962507b2ad653e7bb37c2cffc6c57b75572103f03a6f
                          topic1 = 0x00…44702b0a3c329f2cc5b5c02c2123dc9386a46db9  (ENGINE_V2)
                          data   = 0x00…0001  (true)

[logIdx 0x1b]  Timelock:  TransactionExecuted(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta, bytes returnData)
                          topic0 = 0xbf5aad41947264cee85c734f09dc40e62b870b104a3110ba64673196b43c4096
                          topic1 = 0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0   ← opId
                          topic2 = 0x00…00340c360353a5ab784c5bc5c44322a6af0625d3   ← Vault
                          data   = 0x0000…0000 (value=0)
                                 + 0x0000…0080 (data offset)
                                 + 0x0000…6ab87de4 (eta=1_790_475_748)
                                 + 0x0000…0100 (returnData offset)
                                 + 0x0000…0044 (inner data length = 68)
                                 + inner calldata bytes
                                 + 0x0000…0000 (returnData length = 0)

[logIdx 0x1c]  Safe:      ExecutionSuccess(bytes32 txHash, uint256 payment)
                          topic0 = 0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e
                          topic1 = 0xad70070a2cc57541d273ad385103657f0d83a3ad54cde719eeb70d5de63508e0   ← SAFE_TX_HASH (matches Stage-A precompute)
                          data   = 0 payment
```

Nested call graph: **OwnerEOA → OPS_SAFE (execTransaction) → ProtocolTimelock (executeTransaction) → CollateralVault (setAuthorizedEngine)**.

## I. Vault V2 authorization proof

```
Vault.isAuthorizedEngine(0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9)  =  true
                          (was false pre-tx; flipped by inner setAuthorizedEngine call)
```

## J. Post-execution Timelock bookkeeping

Per `ProtocolTimelock.executeTransaction` (line 336): `queuedTransactions[txHash] = false` on execution.

```
Timelock.queuedTransactions(0xb42e46a90289…4fd0)  =  false   (was true pre-tx)
```

Cannot be executed twice — verified via READ-ONLY `eth_call` from OPS_SAFE:

```
eth_call(Timelock.executeTransaction(Vault, 0, innerCalldata, 1_790_475_748)) from OPS_SAFE
→ revert 0x0280b15e   (= keccak256("TransactionNotQueued()")[:4])
```

Second execution cryptographically impossible.

## K. V1 authorization / freeze proof

```
Vault.isAuthorizedEngine(V1)   = true                    ← unchanged
PME_V1.paused                  = true                    ← unchanged
V1_ENGINE.liquidationPaused    = true                    ← unchanged
```

## L. V2 SEALED / hash proof

```
ENGINE_V2.migrationState        = 1 (SEALED)             ← unchanged
ENGINE_V2.migrationSnapshotHash = 0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d   ← unchanged
```

Seeded V2 economic state byte-identical to `PERPS_V2_BASE_SEPOLIA_MIGRATION_SEAL_V1 §M`:

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

## M. Clearing balance

```
Vault.balances(CLEARING_V2, mUSDC)  =  1_000_000_000   (unchanged from CLEARING_FUND)
```

## N. Backend still V1 / broadcast-off proof

```
Backend HEAD                     = ad8dd7466 (unchanged)
Backend worktree                 = clean (unchanged)
PERPS_ACTIVE_ENGINE_VERSION      = <unset → defaults to v1>
EXECUTOR_REAL_BROADCAST_ENABLED  = false
INDEXER_ENABLED                  = false
```

## O. Safe nonce delta

```
Safe.nonce()  :  14 → 15  (Δ = +1)   ✓
```

## P. Public-chain write audit

```
Base Sepolia writes                = 1  (the Safe execTransaction that nested to Timelock and Vault)
Safe execTransaction count         = 1
Timelock executions                = 1  (matching opId 0xb42e46a9…4fd0)
Vault authorization flips          = 1  (V2: false → true)
V1 authorization changes           = 0  (still true)
Migration state changes            = 0  (still SEALED)
Migration seed writes              = 0
Backend V2 activation              = 0
V2 trades                          = 0
DB writes                          = 0

Safe nonce Δ                       = +1
OWNER nonce Δ                      = 0  (OWNER did not sign this tx)
Executor nonce Δ                   = 0
Timelock op                        = consumed (queuedTransactions[opId] = false)
```

No unrelated writes. Direct owner-EOA → Safe execTransaction path (not delegation router) — cleaner audit trail than the ARM milestone.

## Q. Changed docs

- `docs/PERPS_V2_BASE_SEPOLIA_TIMELOCK_EXECUTE_VAULT_AUTH_V1.md` — NEW (this file).

No production Solidity modification. No artifact modification.

## R. Pushed HEAD

New commit on top of `0eb089e`, pushed to `origin/main`.

## S. Remaining blockers

**None** for the next preflight milestone.

Post-C5 chain state:

```
PME_V1.paused                     = true
V1_ENGINE.liquidationPaused       = true
Vault.isAuthorizedEngine(V1)      = true
Vault.isAuthorizedEngine(V2)      = true   ← NEW
ENGINE_V2.migrationState          = 1 (SEALED)
ENGINE_V2.migrationSnapshotHash   = 0x039d9172…3d7d
Vault.balances(CLEARING_V2, mUSDC) = 1_000_000_000
Backend                            = still V1, broadcast disabled
```

V2 is now cryptographically enabled at the Vault ACL and can settle trades — subject to the backend's fail-closed `EXECUTOR_REAL_BROADCAST_ENABLED=false` gate and `PERPS_ACTIVE_ENGINE_VERSION` still defaulting to v1.

Neither `applyTrade` nor any V2 settlement can be triggered until:

1. Backend is switched to V2 (`PERPS_ACTIVE_ENGINE_VERSION=v2`) — C6.
2. Broadcast is enabled (`EXECUTOR_REAL_BROADCAST_ENABLED=true`) — C6/C7.
3. A user submits a signed V2 intent — C7.

## Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_BACKEND_V2_ACTIVATION_PREFLIGHT_V1`** (C6 preflight) — READ-ONLY preparation of the backend flip: env-diff for `PERPS_ACTIVE_ENGINE_VERSION=v2` + `EXECUTOR_REAL_BROADCAST_ENABLED=true`, verify V2 EIP-712 domain wiring on PME_V2, verify RiskModule V2 oracle route, first-close simulation against the actual first V2 counterparty. Backend V2 activation itself (env flip + service restart) is a subsequent milestone.

**Do NOT activate backend V2 automatically.** STOP.
