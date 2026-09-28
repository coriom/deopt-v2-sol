# PERPS V2 BASE SEPOLIA mUSDC OWNER BOOTSTRAP V1

**Milestone**: `PERPS_V2_BASE_SEPOLIA_MUSDC_OWNER_BOOTSTRAP_V1`
**Status**: **COMPLETE — 1 mUSDC-mint tx broadcast**
**Sol HEAD (pre)**: `dfa3bbc` (unchanged during milestone; new docs commit follows)
**Backend HEAD**: `ad8dd7466aeba6963d28687e825fe4df58ef32ee` (unchanged; worktree clean)
**Chain**: Base Sepolia (chainId 84532)

Scope: mint exactly `1_000_000_000` native mUSDC (= 1000.000000 mUSDC) to the `OWNER` EOA so the canonical `PERPS_V2_BASE_SEPOLIA_CLEARING_FUND_V1` milestone has a funder with the balance the runbook expects. Exactly one on-chain write. No approve, no fundClearing, no migration seed, no seal, no Timelock action, no backend mutation.

---

## A. Pre-balance

`mUSDC.balanceOf(OWNER)  =  0` (verified pre-broadcast; see §D preview).

## B. totalSupply (pre)

`mUSDC.totalSupply()  =  1_423_067_000_000` (= 1_423_067.000000 mUSDC).

## C. Verified mint ABI / ownership

Selector `0x40c10f19` verified present in the deployed `mUSDC` bytecode dispatcher. Signature `mint(address,uint256)`. `mUSDC.owner() = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` = OWNER (verified). `eth_call` simulation from OWNER returned no revert (result `0x`), confirming caller authority.

## D. Signer

```
FUNDING_SIGNER (== OWNER)  = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
keystore                    = ~/.foundry/keystores/deopt-deployer
keystore address readback   = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27  ✓
signer ETH balance (pre)    = 0.001787 ETH
signer nonce (pre)          = 772
```

Password provided via temporary mode-0600 file at `/run/user/1000/deopt-deployer.pw` (deleted immediately after broadcast; verified absent).

## E. Mint tx

```
from       = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
to         = 0x6eAe407f5640B006faC9965182e238582A3B412E   (mUSDC)
function   = mint(address,uint256)                          selector 0x40c10f19
args       = (0xc35F7A8A103A9A4464adfaa76B9B514093D23C27, 1_000_000_000)
calldata   = 0x40c10f19000000000000000000000000c35f7a8a103a9a4464adfaa76b9b514093d23c27000000000000000000000000000000000000000000000000000000003b9aca00
```

## F. Receipt / block

```
tx_hash                = 0xeab8d5107e94fd7c71bb6fa4c95a926aeeda16b4cf5b1c81aa2311a5e80574ff
block_number           = 47_397_624
block_timestamp        = 0x6ab9d4d0
status                 = 1 (success)
gas_used               = 53_176
effective_gas_price    = 6 mwei
gas_cost               = 319_056_000_000 wei (≈ 0.0000003191 ETH)
transactionIndex       = 12
```

Emitted event (single, at logIndex 0x28):

```
mUSDC.Transfer(from=address(0), to=OWNER, value=1_000_000_000)
  topic0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef  (ERC20 Transfer)
  topic1 = 0x0000000000000000000000000000000000000000000000000000000000000000  (mint sentinel)
  topic2 = 0x000000000000000000000000c35f7a8a103a9a4464adfaa76b9b514093d23c27  (OWNER)
  data   = 0x000000000000000000000000000000000000000000000000000000003b9aca00 (1_000_000_000)
```

## G. OWNER post-balance

`mUSDC.balanceOf(OWNER)  =  1_000_000_000` (= 1000.000000 mUSDC).

## H. totalSupply (post)

`mUSDC.totalSupply()  =  1_424_067_000_000` (= 1_424_067.000000 mUSDC).

## I. Exact supply delta

```
delta_owner_balance = 1_000_000_000 − 0             = 1_000_000_000   ✓ matches authorized amount
delta_total_supply  = 1_424_067_000_000 − 1_423_067_000_000  = 1_000_000_000   ✓ matches authorized amount
```

## J. CLEARING_V2 clearing balance remains 0

`Vault.balances(CLEARING_V2, mUSDC)  =  0` (unchanged; no fundClearing executed in this milestone).

## K. Freeze / migration / Timelock readback (post-mint)

```
PME_V1.paused                     = true                     ← unchanged
V1_ENGINE.liquidationPaused       = true                     ← unchanged
Vault.isAuthorizedEngine(V1)      = true                     ← unchanged
Vault.isAuthorizedEngine(V2)      = false                    ← unchanged
ENGINE_V2.migrationState          = 0 (OPEN)                 ← unchanged
ENGINE_V2.migrationSnapshotHash   = 0x0                      ← unchanged
Timelock.queuedTransactions(0xb42e46a9…4fd0) = true          ← still queued+ready+unexecuted
```

No positions seeded. No market funding seeded. No residual bad debt seeded. Migration lifecycle untouched.

## L. Nonce / write audit

```
Base Sepolia writes                  = 1  (mUSDC.mint(OWNER, 1_000_000_000))
Safe / Timelock ops                  = 0
Vault writes                         = 0
CLEARING_V2 writes                   = 0
Migration writes (seed/seal)         = 0
Backend V2 activation                = 0
V2 trades                            = 0

OWNER nonce delta                    = +1  (772 → 773)  ✓
Safe nonce delta                     = 0
Executor nonce delta                 = 0
```

No unexplained transaction.

## M. Docs commit / pushed HEAD

Sol repo new commit on top of `dfa3bbc`, pushed to `origin/main`.

Changed files:

- `docs/PERPS_V2_BASE_SEPOLIA_MUSDC_OWNER_BOOTSTRAP_V1.md` — NEW (this file).

Backend repo: (none).

No production Solidity modification.

## Exact next milestone

**`PERPS_V2_BASE_SEPOLIA_CLEARING_FUND_V1`** — resumes at §4 (keystore reuse) → §5 read allowance → §6 approve if needed → §7 `CLEARING_V2.fundClearing(mUSDC, 1_000_000_000)` → §8 post-fund readback.

**Do NOT execute automatically.** STOP.
