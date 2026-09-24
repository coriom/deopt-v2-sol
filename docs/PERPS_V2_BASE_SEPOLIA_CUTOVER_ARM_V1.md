# PERPS V2 BASE SEPOLIA CUTOVER ARM V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_CUTOVER_ARM_V1`
**Status**: **COMPLETE — PHASE C0 ARM successful**
**Sol HEAD (pre)**: `2cdacd6`
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged, worktree clean)
**Chain**: Base Sepolia (chainId 84532)

C0-01 (RISK_V2 oracle delay), C0-02 (PME_V2 executor grant) executed via deployer EOA keystore+password-file workflow. C0-03 (OPS Safe → Timelock.queueTransaction for future Vault authorization flip) executed through the OPS Safe 2/3 process; nested execution reached the Timelock and queued the expected operation. Timelock did NOT execute — Vault remains V2-unauthorized. V1 remains fully live.

---

## A. C0-01 — RISK_V2.setMaxOracleDelay(600)

| field | value |
|---|---|
| target | `0x8C3d9F71cA59B908Fa200546A63ea62F9C932998` (RISK_V2) |
| function | `setMaxOracleDelay(uint256)` |
| selector | `0xcd3b691c` |
| args | `(600)` |
| authority | deployer EOA `0xc35F7A8A…` (RISK_V2.owner) |
| tx hash | `0xd573fb9fec402ccf167ab427cec9aaa41ac538e828122018dee3be5df37a1ebf` |
| block | 47_151_195 |
| status | 0x1 |
| gas used | 47 572 |
| gas price | 6 mwei |
| readback | `RISK_V2.maxOracleDelay() = 600` ✓ |

## B. C0-02 — PME_V2.setExecutor(runtimeExecutor, true)

| field | value |
|---|---|
| target | `0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2` (PME_V2) |
| function | `setExecutor(address,bool)` |
| selector | `0x1e1bff3f` |
| args | `(0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8, true)` |
| authority | deployer EOA `0xc35F7A8A…` (PME_V2.owner) |
| tx hash | `0xfa9bd4a8e9db1dffdcb2cb8d0156830adc897783477168c109b1fd3a477f690e` |
| block | 47_151_229 |
| status | 0x1 |
| gas used | 47 740 |
| readback | `PME_V2.isExecutor(runtime EXECUTOR) = true` ✓ |
| fail-closed proof | `eth_call` of `ENGINE_V2.applyTrade(...)` still reverts `0x9aec415e` (migration OPEN) ✓ |

## C. C0-03 — OPS Safe → ProtocolTimelock.queueTransaction (Vault auth flip queue)

| field | value |
|---|---|
| authority | OPS Safe 2/3 (`0xA6B9Bb5c…`) |
| final target | ProtocolTimelock `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` |
| Safe.data.function | `queueTransaction(address,uint256,bytes,uint256)` (selector `0x8e361cdf`) |
| Safe.data.args (target) | `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` (CollateralVault) |
| Safe.data.args (value) | 0 |
| Safe.data.args (inner data) | `setAuthorizedEngine(0x44702B0A…6db9, true)` — inner selector `0x3331c56e` |
| Safe.data.args (eta) | 1_790_475_748 (2026-09-27 02:22:28 UTC) |
| Safe nonce used | 13 |
| operation ID | `0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0` |
| queue tx hash | `0x2933a720b64b7e731ebcac1391e9ea80931004889157aa040f855539be1c34f5` |
| queue block | 47_224_438 |
| receipt status | 0x1 |
| outer-tx path | `from = 0xb01c…9c2e` → `to = 0xdb9B…7DB3` ("Redeem Delegations" router). Nested logs show OPS Safe (2 events) and ProtocolTimelock (1 event) as internal emitters — the delegation router invoked the Safe, which in turn called Timelock. Legitimate Safe-owner path (e.g. Zodiac/MetaMask smart-account delegation). |

### Nested execution proof

`ProtocolTimelock.TransactionQueued(bytes32 indexed txHash, address indexed target, uint256 value, bytes data, uint256 eta)` topic0 = `0x4efebf40a8244d219085e74f928a18e8c9d17adc6b39270b8706cca0a92b648d`. Exactly **one** such event fired in tx `0x2933a720…c34f5`, with:

- indexed `txHash` (topic1) = **`0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0`** — bit-identical to our locally computed op-id ✓
- indexed `target` (topic2) = `0x00340c360353a5ab784c5bc5c44322a6af0625d3` — CollateralVault ✓

Direct storage readback confirms:

```
Timelock.queuedTransactions(0xb42e46a9…4fd0) = true
```

Timelock eligibility window:

- earliest execute: 2026-09-27 02:22:28 UTC (eta)
- expires:        2026-10-11 02:22:28 UTC (eta + 14 d GRACE_PERIOD)

## §S 24-item post-ARM readback

```
[✓] queuedTransactions[op_id]                = true                (Timelock op live)
[✓] Safe nonce                               = 14                  (advanced 13→14)
[✓] Vault.isAuthorizedEngine(V1)             = true                (unchanged)
[✓] Vault.isAuthorizedEngine(V2)             = false               (Timelock NOT executed)
[✓] ENGINE_V2.migrationState                 = 0 (OPEN)
[✓] ENGINE_V2.migrationSnapshotHash          = 0x0
[✓] RISK_V2.maxOracleDelay                   = 600
[✓] PME_V2.isExecutor(runtime EXECUTOR)      = true
[✓] V1_ENGINE.owner                          = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
[✓] V1_ENGINE.matchingEngine                 = 0x774d96E5739bffadEE91508b4D3D74F5BE29F165
[✓] V1_ENGINE.riskModule                     = 0xf1b46040147632d0b46A2153cC842506b4D7fEe5
[✓] V1_ENGINE.useFeesManagerV2               = true
[✓] V1_ENGINE.tradingPaused                  = false
[✓] V1_ENGINE.liquidationPaused              = false
[✓] V1_ENGINE.fundingPaused                  = false
[✓] V1_ENGINE.collateralOpsPaused            = false
[✓] PME_V1.paused                            = false
[✓] V1_RISK.maxOracleDelay                   = 600                 (unchanged)
[✓] Backend HEAD                             = ad8dd7466            (unchanged)
[✓] Backend worktree                         = clean
[✓] Backend PERPS_ACTIVE_ENGINE_VERSION      = v1                   (unchanged)
[✓] Sol production bytecode                  = frozen at 004bf78
[✓] Base Sepolia chain                       = 84532
[✓] Timelock queuePaused                     = false
```

## §13 transaction / nonce audit

Public-chain writes emitted in this milestone:
1. deployer → RISK_V2.setMaxOracleDelay(600)                          — tx `0xd573fb…7a1ebf`
2. deployer → PME_V2.setExecutor(runtimeExecutor, true)               — tx `0xfa9bd4…7f690e`
3. OPS Safe (via delegation router `0xdb9B…7DB3`) → ProtocolTimelock.queueTransaction(VAULT, 0, innerCalldata, eta)  — tx `0x2933a7…c34f5`

Deployer nonce delta: +2 (as expected for two EOA txs). Safe nonce delta: +1 (13 → 14, exactly one Safe tx). No unexplained transactions.

## §15 DO NOT START FREEZE (control back to operator)

**No further action authorized in this milestone.**

Do NOT:
- execute the Timelock op (V.2 of the cutover checklist)
- pause V1 PME or V1 engine liquidations
- generate the final snapshot manifest
- fund the clearing account
- seed migration
- seal migration
- activate backend v2
- broadcast any V2 trade

The Timelock op is now **maturing**. Earliest execute = 2026-09-27 02:22:28 UTC. Expiry = 2026-10-11 02:22:28 UTC (14 d GRACE_PERIOD).

## Remaining blockers (for downstream milestones)

- **BLOCKS_FREEZE (C1)**: none; awaits operator green-light
- **BLOCKS_SEAL (C4.5)**:
  - Snapshot dry-run tooling proven in `PERPS_V2_CUTOVER_TOOLING_READINESS_V1` — must re-run at the actual pinned SNAPSHOT_BLOCK once V1 quiescence is confirmed
  - Small script to iterate manifest + emit seed calldata (trivial extension of committed tools)
- **BLOCKS_FIRST_V2_TRADE**:
  - Runtime executor `0x58Ad…52B8` ETH balance (top up before C7 if < 0.01 ETH)
  - PME_V2 EIP-712 counterparty wallet signing readiness

## Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_CUTOVER_EXECUTION_PREFLIGHT_V1`** — read-only preflight to be scheduled AFTER `block.timestamp >= 1_790_475_748` (2026-09-27 02:22:28 UTC). It will:
- verify `Timelock.isOperationReady(VAULT, 0, innerCalldata, eta) == true`
- verify V1 quiescence gates
- produce the final SNAPSHOT_BLOCK candidate + manifest dry-run at that exact block
- produce the exact Safe payload for `Timelock.executeTransaction(...)` (selector `0x06a41d09`)
- do NOT execute — remains a preflight

## Changed docs

- `docs/PERPS_V2_BASE_SEPOLIA_CUTOVER_ARM_V1.md` (this file, NEW)
