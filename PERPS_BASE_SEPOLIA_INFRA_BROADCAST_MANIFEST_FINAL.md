# PERPS_BASE_SEPOLIA_INFRA_BROADCAST_MANIFEST_FINAL

Fresh, self-contained freeze of the exact 12-transaction Base Sepolia
Perps infrastructure broadcast sequence, with every placeholder from
the predecessor manifest resolved to a concrete address.

**Supersedes `BASE_SEPOLIA_INFRA_BROADCAST_V1.md`** for authorization
purposes; the V1 manifest remains byte-frozen in the repo as the
historical design record and is not edited in place.

- **Scope**: Base Sepolia (chain id **84532**) only.
- **Broadcast**: NONE performed during preparation. Broadcast is
  gated on the explicit authorization sentence at the end of this
  document.
- **Adjacent-product posture**:
  - Public Perps: **OFF** (unchanged).
  - Funding: **OFF** (unchanged).
  - WETH collateral: **DISABLED** and deferred per
    `DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_DEFERRAL_V1.md`.
  - cbBTC collateral: **DISABLED** (unchanged).
  - USDC collateral: **UNCHANGED**.
  - Base mainnet: no action of any kind.

## Change from V1

V1 froze TX-11 as `setExecutor($NEW_PERP_MATCHING_EXECUTOR, true)` —
a symbolic placeholder because the target EOA had not been chosen at
the time. This FINAL manifest resolves the placeholder to a verified,
freshly-generated, zero-code, zero-nonce EOA:

`NEW_PERP_MATCHING_EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8`

The private key was created by the operator via
`scripts/create-perps-executor.sh` (Foundry keystore prompted for a
password that never touched the assistant's context) and stored under
`~/.deopt/keystores/perp-executor-base-sepolia`. Neither this file
nor any git-tracked artefact references the key.

## Freeze pointers

| Component | Commit SHA | Working tree |
|-----------|------------|--------------|
| Solidity  | `b64c0f3` (pre-freeze; this file adds one commit) | clean |
| Backend   | `126a857` | clean |
| Frontend  | `9cd8dce` | clean |

Companion Foundry preview: `script/BaseSepoliaInfraBroadcastPreview.s.sol`
(byte-identical to V1 — reads `NEW_PERP_MATCHING_EXECUTOR` env var; no
`vm.startBroadcast`; no state change; produces the transcript in
Appendix F below).

---

## 1 · EXECUTOR VALIDATION

Live checks against Base Sepolia at block **46_543_013**
(ts 1788854235):

| Check | Value |
|---|---|
| chainId (`cast chain-id`) | `84532` ✅ |
| Provided address | `0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8` |
| EIP-55 checksum matches | ✅ (input equals `cast to-check-sum-address` output) |
| `cast code <new>` | `0x` (empty — EOA) ✅ |
| `cast nonce <new>` | `0` (never signed a tx) ✅ |
| `cast balance <new>` | `0` wei (see §5 funding note) ⚠️ |
| `PerpMatchingEngine.isExecutor(new)` | `false` ✅ (pre-rotation) |
| `PerpMatchingEngine.isExecutor(deployer)` | `true` ✅ (pre-rotation) |
| `PerpMatchingEngine.owner()` | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` = deployer ✅ |
| Deployer balance | `0x006a92c56a2f5323` wei = ~1.877e15 wei (~0.00188 ETH) — sufficient for TX-11 + TX-12 gas |

**`0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8` is recorded as the
intended Base Sepolia Perps matching executor.** No key material is
written anywhere by this record.

---

## 2 · REGENERATED TX-11 / TX-12

Freshly computed via `cast calldata` with the resolved address:

### TX-11 — `setExecutor(NEW_EXECUTOR, true)`

- Target: `0x774d96E5739bffadEE91508b4D3D74F5BE29F165` (PerpMatchingEngine)
- Selector: `0x1e1bff3f` (`setExecutor(address,bool)`)
- Full calldata:
  ```
  0x1e1bff3f00000000000000000000000058ad437cb9e32b0faee810ef05810d5b
    a2ae52b800000000000000000000000000000000000000000000000000000000
    00000001
  ```
  (single line, no whitespace, 68 bytes total)
- keccak256(calldata):
  `0xbd7f4082a38a7039ba7b501f389d279813bbe95aa72cc6eb97fc9387c0cddf89`
- Required signer: `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (deployer, PME owner)
- Modifier gate: `onlyOwner` (`src/matching/PerpMatchingEngine.sol:373`)
- Event emitted: `ExecutorSet(0x58Ad…52B8, true)`
- Gas (fork sim): 24 645
- Dependency: none — direct call, no timelock. **MUST land BEFORE TX-12.**
- Postcondition: `PerpMatchingEngine.isExecutor(0x58Ad…52B8) == true`
- Rollback: `setExecutor(0x58Ad…52B8, false)` from the deployer (or
  from any current executor, per `onlyOwner`; only owner can rotate,
  so the deployer key must be retained until after TX-12 confirms
  operationally).

### TX-12 — `setExecutor(DEPLOYER, false)`

- Target: `0x774d96E5739bffadEE91508b4D3D74F5BE29F165` (PerpMatchingEngine)
- Selector: `0x1e1bff3f`
- Full calldata:
  ```
  0x1e1bff3f000000000000000000000000c35f7a8a103a9a4464adfaa76b9b5140
    93d23c270000000000000000000000000000000000000000000000000000000
    000000000
  ```
- keccak256(calldata):
  `0x905fb3f8aad76e84e11e1906d78e987536979a634b62163f2d17d96f4c7323a3`
- Required signer: `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (deployer, PME owner)
- Modifier gate: `onlyOwner`
- Event emitted: `ExecutorSet(0xc35F…3C27, false)`
- Gas (fork sim): 5 583
- **Dependency (hard)**: TX-11 MUST have landed AND the operator MUST
  have off-chain-verified `PerpMatchingEngine.isExecutor(0x58Ad…52B8) == true`
  via `cast call` before broadcasting TX-12. Sending TX-12 first would
  leave the protocol with zero authorized executors and block all
  matching-engine settlement (which is a live operational surface).
- Postcondition: `PerpMatchingEngine.isExecutor(0xc35F…3C27) == false`,
  and the deployer EOA retains **owner** privileges (owner and executor
  are separate roles; only the executor role is revoked).
- Rollback: `setExecutor(0xc35F…3C27, true)` from the deployer.

---

## 3 · FROZEN 12-TX MANIFEST (canonical sequence)

### 3.1 On-chain addresses (Base Sepolia 84532)

| Role | Address |
|---|---|
| OracleRouter | `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` |
| PerpMatchingEngine | `0x774d96E5739bffadEE91508b4D3D74F5BE29F165` |
| ProtocolTimelock | `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` |
| Timelock proposer + executor | `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` |
| PME owner (= deployer EOA) | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |
| **NEW Perps matching executor** | **`0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8`** |
| Collateral base token (mUSDC) | `0x6eAe407f5640B006faC9965182e238582A3B412E` |
| ETH base asset (mWETH) | `0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02` |
| BTC base asset (mWBTC) | `0x9D871aC7595E8Da271E866608E5145252047967c` |
| Chainlink ETH/USD proxy | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` |
| Chainlink BTC/USD proxy | `0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298` |
| Pyth core | `0x5f52e4DBEA21f5b23523B6e20d50c29ae0a4EB83` |
| Pyth ETH/USD feed id | `0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace` |
| Pyth BTC/USD feed id | `0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43` |

### 3.2 Frozen tunables

| Parameter | Value |
|---|---|
| `maxOracleDelay` (router global) | **1500 s** (Chainlink heartbeat 1200s + 300s safety) |
| Per-feed `maxDelay` | **1500 s** (mirrors global; router picks `min(nonzero)`) |
| Cross-source `maxDeviationBps` | **100 bps (1%)** |
| Timelock `minDelay` | 86 400 s (24 h) — unchanged |
| Queue ETA (fork-sim value) | ≥ `block.timestamp + 86400 + 3600` (adds 1 h safety margin) |

### 3.3 Function selectors (verified via router `abi.encodeWithSelector`)

| Selector | Signature |
|---|---|
| `0x80cea4a2` | `setMaxOracleDelay(uint32)` (router) |
| `0x36a9da37` | `setFeed(address,address,address,address,uint32,uint16,bool)` (router; observed via TX-06/07 encoding = `0x93240036` — see note below) |
| `0x8e361cdf` | `queueTransaction(address,uint256,bytes,uint256)` (timelock) |
| `0x06a41d09` | `executeTransaction(address,uint256,bytes,uint256)` (timelock) |
| `0x1e1bff3f` | `setExecutor(address,bool)` (PerpMatchingEngine) |

Note on `setFeed`: the abi-encoded selector observed in the fork sim
is `0x93240036`. This corresponds to the exact router function
signature the compiler produces; broadcast MUST use the selector the
compiler assigns (i.e., call via the router's Solidity interface, not
by hand-encoding a mismatched signature). The preview script uses
`OracleRouter.setFeed.selector`, which resolves to exactly this
value in the deployed compiler build.

### 3.4 The 12-transaction table

| # | Phase | Target | Function / Deployment | Semantic params | Signer | Timelock dep | ETA | Gas est. | Postcondition | Rollback |
|---|---|---|---|---|---|---|---|---|---|---|
| TX-01 | G1 deploy | new `ChainlinkPriceSource` | `constructor(_aggregator=0x4aDC…7cb1)` | ETH/USD Chainlink proxy | any funded EOA (deployer OK) | none | immediate | ~215 308 | address `chEth` recorded; `getLatestPrice()` returns fresh ETH/USD 8-dec | reference dropped (adapter uncalled) |
| TX-02 | G1 deploy | new `ChainlinkPriceSource` | `constructor(_aggregator=0x0FB9…4298)` | BTC/USD Chainlink proxy | any funded EOA | none | immediate | ~215 281 | address `chBtc` recorded | reference dropped |
| TX-03 | G1 deploy | new `PythPriceSource` | `constructor(_pyth=0x5f52…EB83, _priceId=0xff614…0ace)` | ETH/USD Pyth feed | any funded EOA | none | immediate | ~225 569 | address `pyEth` recorded | reference dropped |
| TX-04 | G1 deploy | new `PythPriceSource` | `constructor(_pyth=0x5f52…EB83, _priceId=0xe62df…5b43)` | BTC/USD Pyth feed | any funded EOA | none | immediate | ~225 591 | address `pyBtc` recorded | reference dropped |
| TX-05 | G2 queue | Timelock → OracleRouter | queue → `setMaxOracleDelay(1500)` | inner cd = `0x80cea4a200000000…000005dc` | `0xA6B9…cD46` (proposer) | none | eta = now+90000 | queue tx | ScheduledCall in ledger; op hash = `0x8674b872…6a4b19` | `cancelTransaction(id)` |
| TX-06 | G2 queue | Timelock → OracleRouter | queue → `setFeed(mWETH, mUSDC, chEth, pyEth, 1500, 100, true)` | inner cd = `0x93240036000000…000001` (see fork sim log) | `0xA6B9…cD46` | requires TX-01, TX-03 | eta = now+90000 | queue tx | op hash = `0x0fddea3a…4b18d79` | cancel |
| TX-07 | G2 queue | Timelock → OracleRouter | queue → `setFeed(mWBTC, mUSDC, chBtc, pyBtc, 1500, 100, true)` | inner cd = `0x93240036000000…000001` (BTC variant) | `0xA6B9…cD46` | requires TX-02, TX-04 | eta = now+90000 | queue tx | op hash = `0x50ab6990…602307b4` | cancel |
| TX-08 | G3 execute (≥T+24h) | Timelock → OracleRouter | executeTransaction matching TX-05 | matches TX-05 inner cd + eta byte-for-byte | `0xA6B9…cD46` (executor) | after TX-05 ETA | now+24h | ~5 782 | `router.maxOracleDelay() == 1500` | none needed — raising delay is safe |
| TX-09 | G3 execute (≥T+24h) | Timelock → OracleRouter | executeTransaction matching TX-06 | matches TX-06 | `0xA6B9…cD46` | after TX-06 ETA AND TX-01/03 | now+24h | ~12 590 | `router.getFeed(mWETH, mUSDC)` returns (chEth, pyEth, 1500, 100, isActive=true); `getPriceSafe(mWETH, mUSDC)` returns `ok=true` | queue+execute `setFeedStatus(mWETH, mUSDC, false)` |
| TX-10 | G3 execute (≥T+24h) | Timelock → OracleRouter | executeTransaction matching TX-07 | matches TX-07 | `0xA6B9…cD46` | after TX-07 ETA AND TX-02/04 | now+24h | ~12 581 | `router.getFeed(mWBTC, mUSDC)` returns configured; `getPriceSafe(mWBTC, mUSDC)` returns `ok=true` | queue+execute `setFeedStatus(mWBTC, mUSDC, false)` |
| TX-11 | G4 rotate | PerpMatchingEngine | `setExecutor(0x58Ad…52B8, true)` | see §2 | `0xc35F…3C27` (deployer, PME owner) | none | immediate | ~24 645 | `pme.isExecutor(0x58Ad…52B8) == true` | `setExecutor(0x58Ad…52B8, false)` from deployer |
| TX-12 | G4 rotate | PerpMatchingEngine | `setExecutor(0xc35F…3C27, false)` | see §2 | `0xc35F…3C27` (deployer, PME owner) | **MUST wait for TX-11 post-state verify** | immediate after TX-11 verify | ~5 583 | `pme.isExecutor(0xc35F…3C27) == false`; owner unchanged | `setExecutor(0xc35F…3C27, true)` from deployer |

**Total gas budget** (deployer signer): TX-01 + TX-02 + TX-03 + TX-04
+ TX-11 + TX-12 = ~1_112_000 gas. **Total gas budget** (timelock
signer): TX-05..10 = 6 queue + 3 execute (execute wraps have their own
overhead) ≈ ~350k gas across the 24h window boundary.

**No unresolved placeholders.**

### 3.5 Rollback set (documented, not to be broadcast in the same window)

- Reverting Phase B (router): `setFeedStatus(base, mUSDC, false)` for
  each feed (mWETH, mWBTC). Also `setMaxOracleDelay(600)` if the raise
  causes an unexpected regression (unlikely — the raise is strictly
  more permissive than the pre-existing 600s). Each rollback is
  timelock-queued (24h).
- Reverting Phase C: `setExecutor(0xc35F…3C27, true)` and/or
  `setExecutor(0x58Ad…52B8, false)`, both signed by the deployer
  (owner). No timelock.
- Reverting Phase A: adapters are permissionless — no rollback needed;
  simply do not wire them into the router (or `setFeedStatus(false)`).

---

## 4 · FULL BASE SEPOLIA FORK REHEARSAL

Re-run of `script/BaseSepoliaInfraBroadcastPreview.s.sol` against a
fresh Base Sepolia fork with `NEW_PERP_MATCHING_EXECUTOR=0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8`
in this session (block 46_543_036, ts 1788854360).

### 4.1 Verified post-state

| Predicate | Fork result |
|---|---|
| `block.chainid == 84532` | ✅ |
| `router.maxOracleDelay() == 1500` | ✅ |
| BTC dual-source feed active | ✅ (`primary=chBtc, secondary=pyBtc, maxDelay=1500, maxDeviationBps=100, isActive=true`) |
| ETH dual-source feed active | ✅ (`primary=chEth, secondary=pyEth, maxDelay=1500, maxDeviationBps=100, isActive=true`) |
| Oracle `maxDeviationBps` == frozen safe value | ✅ (100 bps) |
| `router.hasActiveFeed(mWETH, mUSDC)` | ✅ true |
| `router.hasActiveFeed(mWBTC, mUSDC)` | ✅ true |
| `router.getPriceSafe(mWETH, mUSDC)` | `(price=247_578_000_000, updatedAt=1788854040, ok=true)` — $2 475.78 ✅ |
| `router.getPriceSafe(mWBTC, mUSDC)` | `(price=7_841_310_825_430, updatedAt=1788854152, ok=true)` — $78 413.11 ✅ |
| Stale-Pyth handling | Pyth BTC/USD 1999s old (>1500s cap): router safely degrades to Chainlink single-source — `getPriceSafe` still returns `ok=true` (accepted CLOSED_TEST limitation, see §5 and `PYTH_STALE_FALLBACK_CLOSED_TEST_ACCEPTED_LIMITATION`) |
| `pme.isExecutor(0x58Ad…52B8)` (post TX-11) | ✅ true |
| `pme.isExecutor(0xc35F…3C27)` (post TX-12) | ✅ false |
| `pme.owner()` unchanged | ✅ `0xc35F…3C27` |
| Public Perps route open? | **NO** — no public-Perps flip in this manifest |
| Funding enabled? | **NO** — no funding flip in this manifest |

### 4.2 Simulation guarantees

- No `vm.startBroadcast` and no `vm.broadcast` anywhere in the script
  (grep verified against `script/BaseSepoliaInfraBroadcastPreview.s.sol`).
- No transaction signing; effect simulation uses `vm.startPrank` only.
- No real state change on Base Sepolia.
- Fork block advanced only by simulated txs consumed in memory.

**Verdict**: `PERPS_BASE_SEPOLIA_INFRA_FORK_REHEARSAL_GREEN`.

### 4.3 Full transcript

Attached at Appendix F.

---

## 5 · EXECUTOR FUNDING NOTE

The new executor `0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8` currently
holds **0 wei** on Base Sepolia.

**`EXECUTOR_GAS_FUNDING_REQUIRED_BEFORE_FIRST_EXECUTOR-SIGNED_BASE_SEPOLIA_TX`**

This funding is required **before** the new executor is asked to sign
its first Perps matching-engine settlement transaction on Base Sepolia.
It is **NOT required** to perform the executor rotation itself (TX-11
+ TX-12), because those two transactions are signed by the deployer
(`0xc35F…3C27`), which currently holds ~1.877e15 wei (~0.00188 ETH) —
sufficient for the two `setExecutor` calls (~30 228 gas total at any
plausible Base Sepolia gas price).

Do NOT fund the new executor as part of this task. Funding is out of
scope for the FINAL freeze. When authorization is granted, the operator
will fund the new executor separately (e.g., a small direct transfer
from a hot wallet, sized to cover N settlement operations).

---

## 6 · FINAL FREEZE — package summary

| Field | Value |
|---|---|
| Final Solidity SHA | `<will be filled by the commit that lands this file>` |
| Final Backend SHA | `126a857` (unchanged) |
| Final Frontend SHA | `9cd8dce` (unchanged) |
| New executor address | `0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8` |
| TX-05 op hash | `0x8674b8726361261aedece02de37d7a406cd8b634d252d88505932f52926a4b19` |
| TX-06 op hash | `0x0fddea3a37974c0f01cffde6bfd6040d448ceb6f489923e80bc2f0f394b18d79` |
| TX-07 op hash | `0x50ab6990e1683b184b5295066d8a04aaf6a3ce4812abf01bf4fa229b602307b4` |
| TX-11 calldata keccak | `0xbd7f4082a38a7039ba7b501f389d279813bbe95aa72cc6eb97fc9387c0cddf89` |
| TX-12 calldata keccak | `0x905fb3f8aad76e84e11e1906d78e987536979a634b62163f2d17d96f4c7323a3` |
| Fork block | 46 543 036 |
| Fork timestamp | 1788854360 |
| Fork rehearsal outcome | **PERPS_BASE_SEPOLIA_INFRA_FORK_REHEARSAL_GREEN** (Appendix F) |
| Transactions broadcast during preparation | **0** |
| Anything mutating Base Sepolia state | **NONE** |
| Anything mutating Base mainnet state | **NONE** |
| Public Perps toggled? | **NO** |
| Funding toggled? | **NO** |
| WETH activated? | **NO** (deferred per DEFERRAL_V1) |
| cbBTC activated? | **NO** |
| Second-chain activity? | **NONE** |
| Frozen `BASE_SEPOLIA_INFRA_BROADCAST_V1.md` edited in place? | **NO** (this FINAL is a separate file) |

**Milestone**: `PERPS_BASE_SEPOLIA_INFRA_BROADCAST_MANIFEST_FINAL`.

---

## Explicit non-authorization list

Landing this manifest authorizes ONLY the exact 12 transactions
enumerated in §3.4 above, on Base Sepolia (chain id 84532), signed by
the exact signers named, under the exact dependency + timing ordering
described.

It does NOT authorize:

- WETH collateral activation on any chain (deferred).
- cbBTC collateral activation on any chain.
- Public Perps activation on any chain.
- Funding rate activation.
- Any Base mainnet transaction.
- Any second-chain broadcast.
- Any unrelated protocol transaction.
- Any additional executor rotation beyond TX-11/TX-12.
- Any adapter deployment beyond TX-01..04.
- Funding of the new executor EOA (out of scope; separate operator
  action).

---

## Authorization sentence

An operator with signing authority for the deployer EOA
(`0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`) and the timelock signer
(`0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`) may proceed with
broadcast only after issuing the following sentence verbatim in a
subsequent directive:

> I explicitly authorize broadcast of TX-01 through TX-12 from FINAL
> manifest `<FINAL_SHA>` on Base Sepolia chain 84532 only. No other
> transaction, public Perps activation, Funding activation,
> WETH/cbBTC collateral activation, second-chain action, or Base
> mainnet action is authorized.

`<FINAL_SHA>` MUST be replaced with the concrete Solidity commit SHA
that lands this file (see the top-of-file table, filled in at commit
time and reported in the assistant's final message).

---

## Appendix F — Fork-simulation transcript

Re-run in this session:
`NEW_PERP_MATCHING_EXECUTOR=0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8`
`forge script script/BaseSepoliaInfraBroadcastPreview.s.sol:BaseSepoliaInfraBroadcastPreview --fork-url https://sepolia.base.org --sig "run()" -vv`

Exit code: 0. Full log stored at `/tmp/perps_fork_sim.log` during
the preparation session; key excerpts follow verbatim.

### F.1 Preflight

```
=================================================================
PERPS_BASE_SEPOLIA_INFRA_BROADCAST_V1 - preview / fork simulation
=================================================================
chain id           : 84532
block number       : 46543036
block timestamp    : 1788854360
this script BROADCASTS NOTHING. no vm.startBroadcast anywhere.

--- preflight: on-chain state ---
OracleRouter          : 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581
  owner               : 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588
  maxOracleDelay      : 600
  paused              : false
PerpMatchingEngine    : 0x774d96E5739bffadEE91508b4D3D74F5BE29F165
  owner               : 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27
  isExecutor[deployer]: true
ProtocolTimelock      : 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588
  owner               : 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46
  minDelay (s)        : 86400
  queuePaused         : false
```

### F.2 Adapter deploys (Phase A)

```
TX-01 new ChainlinkPriceSource(ETH/USD proxy)
      deployed at (sim)    : 0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3
      gas used (sim)       : 215308
TX-02 new ChainlinkPriceSource(BTC/USD proxy)
      deployed at (sim)    : 0xf13D09eD3cbdD1C930d4de74808de1f33B6b3D4f
      gas used (sim)       : 215281
TX-03 new PythPriceSource(pythCore, ETH/USD feedId)
      deployed at (sim)    : 0x5c4a3C2CD1ffE6aAfDF62b64bb3E620C696c832E
      gas used (sim)       : 225569
TX-04 new PythPriceSource(pythCore, BTC/USD feedId)
      deployed at (sim)    : 0x6AE5E129054a5dBFCeBb9Dfcb1CE1AA229fB1Ddb
      gas used (sim)       : 225591

--- phase A verify: adapter readbacks ---
chainlink ETH/USD price(1e8) : 247578000000
chainlink ETH/USD age (s)    : 320
chainlink BTC/USD price(1e8) : 7841310825430
chainlink BTC/USD age (s)    : 208
pyth ETH/USD      price(1e8) : 247600069120
pyth ETH/USD      age (s)    : 269
pyth BTC/USD      price(1e8) : 7849383518455
pyth BTC/USD      age (s)    : 1999   ← accepted CLOSED_TEST limitation
```

### F.3 Router reconfig (Phase B)

```
TX-05 op hash: 0x8674b8726361261aedece02de37d7a406cd8b634d252d88505932f52926a4b19
TX-05 inner cd: 0x80cea4a200000000000000000000000000000000000000000000000000000000000005dc

TX-06 op hash: 0x0fddea3a37974c0f01cffde6bfd6040d448ceb6f489923e80bc2f0f394b18d79
TX-06 inner cd: 0x932400360000000000000000000000004deebc5f537f3b8ba0e3393807b4d699d72bdd02
                  0000000000000000000000006eae407f5640b006fac9965182e238582a3b412e
                  0000000000000000000000005aadfb43ef8daf45dd80f4676345b7676f1d70e3
                  0000000000000000000000005c4a3c2cd1ffe6aafdf62b64bb3e620c696c832e
                  00000000000000000000000000000000000000000000000000000000000005dc
                  0000000000000000000000000000000000000000000000000000000000000064
                  0000000000000000000000000000000000000000000000000000000000000001

TX-07 op hash: 0x50ab6990e1683b184b5295066d8a04aaf6a3ce4812abf01bf4fa229b602307b4
TX-07 inner cd: 0x932400360000000000000000000000009d871ac7595e8da271e866608e5145252047967c
                  0000000000000000000000006eae407f5640b006fac9965182e238582a3b412e
                  000000000000000000000000f13d09ed3cbdd1c930d4de74808de1f33b6b3d4f
                  0000000000000000000000006ae5e129054a5dbfcebb9dfcb1ce1aa229fb1ddb
                  00000000000000000000000000000000000000000000000000000000000005dc
                  0000000000000000000000000000000000000000000000000000000000000064
                  0000000000000000000000000000000000000000000000000000000000000001

TX-08 (execute) inner gas: 5782
TX-09 (execute) inner gas: 12590
TX-10 (execute) inner gas: 12581

--- phase B verify: post-state ---
router.maxOracleDelay             : 1500
ETH feed.primary                  : 0x5aAdFB43eF8dAF45DD80F4676345b7676f1D70e3
ETH feed.secondary                : 0x5c4a3C2CD1ffE6aAfDF62b64bb3E620C696c832E
ETH feed.maxDelay                 : 1500
ETH feed.maxDeviationBps          : 100
ETH feed.isActive                 : true
router.hasActiveFeed(mWETH,mUSDC) : true
router.getPriceSafe ETH.price     : 247578000000
router.getPriceSafe ETH.ok        : true
BTC feed.isActive                 : true
router.hasActiveFeed(mWBTC,mUSDC) : true
router.getPriceSafe BTC.price     : 7841310825430
router.getPriceSafe BTC.ok        : true
```

### F.4 Executor rotation (Phase C)

```
TX-11  setExecutor(0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8, true)
       calldata:
0x1e1bff3f00000000000000000000000058ad437cb9e32b0faee810ef05810d5ba2ae52b80000000000000000000000000000000000000000000000000000000000000001
       effect gas: 24645

TX-12  setExecutor(0xc35F7A8A103A9A4464adfaa76B9B514093D23C27, false)
       calldata:
0x1e1bff3f000000000000000000000000c35f7a8a103a9a4464adfaa76b9b514093d23c270000000000000000000000000000000000000000000000000000000000000000
       effect gas: 5583

--- phase C verify ---
isExecutor[newExecutor]        : true
isExecutor[deployer]           : false
```

### F.5 Simulation-only trailer

```
=================================================================
PERPS_BASE_SEPOLIA_INFRA_BROADCAST_PACKAGE_READY (simulation only)
=================================================================
NEXT STEP: user must explicitly authorize broadcasting TX-01..TX-12
This script did NOT broadcast. No state changed.
```
