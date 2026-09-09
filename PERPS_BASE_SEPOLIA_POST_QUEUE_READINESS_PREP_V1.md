# PERPS_BASE_SEPOLIA_POST_QUEUE_READINESS_PREP_V1

Prepared while awaiting the Safe 2-of-3 signing flow for TX-05 / TX-06 /
TX-07. **No Base Sepolia broadcast, no Safe submission, no signature
collection.** The purpose is to make the post-queue phase operationally
ready so that once the queue lands, the remaining broadcast decisions
have clear artefacts.

## Governance model — canonical truth (Part A)

`0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46` (`OPS_MULTISIG`) is a
**Gnosis SafeL2 v1.4.1 2-of-3 multisig** — NOT an EOA:

- singleton = `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762`
- threshold = 2
- owners = `0xb9F8dE80…6d06`, `0x0E7DcB5b…a35d`, `0xa774C46C…8dFC`
- no modules
- controls `ProtocolTimelock` (owner + guardian) + Timelock proposer/executor role
- `forge --keystore` is NOT a valid governance signing path — Safe txs require Safe UI + 2-of-3 hardware-wallet signatures

### Stale-assumption cleanup

Deprecated in this milestone:

- `script/BroadcastPerpsInfraTx05to07.s.sol` — DEPRECATION BANNER added
  (retained in-tree only as historical reference; would revert on-chain
  because the `tx.origin == EXPECTED_TL_SIGNER` guard requires a
  contract-not-EOA address). Superseded by the Safe queue package
  (`script/DerivePerpsInfraSafeQueuePackage.s.sol` +
  `PERPS_BASE_SEPOLIA_SAFE_QUEUE_PACKAGE_V1.md`).

Not touched (correct under their own scope):

- `script/AcceptOwnerships.s.sol:329-330` reads
  `TIMELOCK_OWNER_PRIVATE_KEY` only when `expectedOwner == owners.timelockOwner`
  AND the env var exists. For our Safe-owned Timelock, neither branch
  fires. This script is a generic ownership-acceptance helper; leaving it
  as-is preserves compatibility with future EOA-owned timelock scenarios.

- `.env.local` / `.env.base-sepolia` local secret files contain a stale
  `TIMELOCK_OWNER_PRIVATE_KEY` line that no longer maps to
  `0xA6B9…cD46` (see prior audit). NOT MODIFIED per directive. Operator
  hygiene follow-up: the file line can be renamed (e.g. commented out
  with `# DEPRECATED — TIMELOCK is Safe 0xA6B9…cD46`) by the operator
  at their own convenience.

## TX-08..10 execution package (Part B)

New script: `script/DerivePerpsInfraSafeExecutePackage.s.sol` (READ-ONLY).

**Consumes** (via env at run time — never hard-coded):
- `CH_ETH`, `CH_BTC`, `PY_ETH`, `PY_BTC` — real deployed adapter addresses
- `FINAL_ETA` — the ETA embedded in the successfully queued Stage-B txs
  (read from the on-chain queue receipts, NOT from any current-run
  computation)

**Fails closed** if any of:
- chain id ≠ 84532
- any adapter has no code
- Safe is not a Timelock executor
- `queuePaused == true`
- any of opHash5 / opHash6 / opHash7 NOT currently queued (nothing to execute)

**Also warns (informationally)** if `block.timestamp < FINAL_ETA` — the
operator can prepare payloads early but must not collect Safe signatures
before ETA reached (execute would revert on-chain).

**Emits** — for each of TX-08 / TX-09 / TX-10, using PATH-1 (three
separate Safe CALL transactions), the exact byte-level Safe UI package:
- Safe.to = ProtocolTimelock
- Safe.value = 0
- Safe.operation = 0 (CALL) — auto-set by Safe UI, no toggle
- Safe.data = `executeTransaction(target=Router, value=0, data=inner, eta=FINAL_ETA)`
- Expected op hash (must be currently queued and cleared post-execute)
- Post-execute verification `cast call` commands

**Signing path** (post-ETA): same as TX-05..07 — 3 separate custom-contract
interactions in Safe Wallet Transaction Builder, 3 signing rounds, Safe
nonces will be assigned sequentially starting at current `Safe.nonce`
(expected 7 after Stage B TX-05/06/07 land at nonces 4, 5, 6).

## Fork rehearsal — full cycle (Part C)

New script: `script/RehearsePerpsInfraFullCycle.s.sol` (READ-ONLY fork).

**Rehearsal proven this session** (block 46 584 152, ts 1 788 936 592):

```
[gov] TL.owner=Safe / proposer / executor / minDelay>=24h / !queuePaused: OK
[derive] fresh ETA:       1789044592
[phase 1B] queue via vm.prank(Safe)
  queued TX-05: OK
  queued TX-06: OK
  queued TX-07: OK
[phase 1B post-check] router.maxOracleDelay still 600: OK
[warp] jumping past ETA -> block.timestamp: 1789044593
[phase 2] execute via vm.prank(Safe)
  executed TX-08 -> maxOracleDelay = 1500
  executed TX-09 -> ETH feed configured
  executed TX-10 -> BTC feed configured
[final] post-execute router state
  router.maxOracleDelay        :  1500
  router.hasActiveFeed(ETH)    :  true
  router.hasActiveFeed(BTC)    :  true
[cross-check] PME executor state unchanged (TX-11/12 not executed): OK
PERPS_BASE_SEPOLIA_INFRA_FULL_CYCLE_FORK_REHEARSAL_GREEN
```

**Documented fork artefact** (not a real-chain issue): after `vm.warp`
past ETA, on-chain Chainlink price timestamps don't advance (heartbeats
are real-chain-only), so `getPriceSafe` returns `ok=false` on the fork.
On the real chain, Chainlink posts many fresh prices during the 24 h
timelock wait, so `getPriceSafe.ok=true` post-execute.

**What the rehearsal DOES prove on-chain**:
- Governance topology correct + queue path works via Safe prank
- Fresh ETA + op-hash derivation correct
- All 3 queue → warp → execute succeed atomically per Safe call
- Router post-state: `maxOracleDelay=1500`, both feeds configured with
  the correct primary/secondary sources + policy
- Queued entries cleared post-execute (as expected)
- No unrelated state change (PME executor unchanged)

## TX-11 / TX-12 executor rotation (Part D)

**Current on-chain state (verified this session)**:
- `PerpMatchingEngine.owner()` = `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` (deployer EOA)
- `PerpMatchingEngine.paused()` = `false`
- `PerpMatchingEngine.isExecutor(0x58Ad…52B8)` = `false` (new executor, not yet enabled)
- `PerpMatchingEngine.isExecutor(0xc35F…3C27)` = `true` (deployer, will be revoked)

**Signer topology for TX-11 + TX-12**:
- Function: `setExecutor(address, bool)` — `onlyOwner` on `PerpMatchingEngine`
- Owner: still the deployer EOA (`0xc35F…3C27`)
- **Not the Safe** — TX-11/12 are ordinary `forge script --keystore` calls signed by the deployer, using the same keystore as TX-01..04
- Existing broadcast script `script/BroadcastPerpsInfraTx05to07.s.sol` is deprecated for TX-05..07 but contains the correct TX-11/12 pattern in principle. A dedicated script for TX-11/12 alone will be prepared under a future explicit directive.

**Hard sequence rule** (encoded in any future TX-11/12 script):
1. TX-11 broadcast → wait receipt
2. Verify `isExecutor(new) == true` on-chain post-TX-11
3. Only then broadcast TX-12
4. TX-12 pre-condition: `require(isExecutor(new) == true)` → refuses to run if TX-11 didn't land
5. Post-TX-12: verify `isExecutor(deployer) == false` AND `isExecutor(new) == true`

If TX-11 fails, TX-12 must NOT run — sending TX-12 first would leave the
Matching Engine with zero executors, blocking all Perps matching.

## New executor operational readiness (Part E)

Read-only checks (this session):

| Field | Value |
|---|---|
| Address | `0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8` |
| Code | `0x` (empty — genuine EOA) |
| Nonce | `0` (never sent a transaction) |
| Balance | `0 wei` — **needs funding before first executor-signed tx** |

Gas budget at current Base Sepolia gas price (0.006 gwei):

| Scenario | Per-tx cost | Total ETH |
|---|---|---|
| Single 500 k-gas match tx | `0.000003 ETH` | — |
| 10 closed-test matches | — | `0.00003 ETH` |
| 100 closed-test matches | — | `0.0003 ETH` |
| **Recommended minimum** | — | **`0.005 ETH`** (~500 executor txs, comfortable safety margin) |
| Recommended safe funding | — | `0.01 ETH` (~1000 executor txs) |

**NOT FUNDED by this milestone.** Operator sends a small transfer from
their hot wallet or the deployer EOA to the new executor address after
TX-11 broadcasts. Fund BEFORE the first executor-signed runtime tx (any
Perps matching/settlement action).

## Post-TX10 validation matrix (Part F)

Read-only `cast call` commands to run immediately after TX-08..10 land:

### OracleRouter state
```
cast call 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581 'maxOracleDelay()(uint32)' --rpc-url https://sepolia.base.org
# expect 1500

cast call 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581 'hasActiveFeed(address,address)(bool)' 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02 0x6eAe407f5640B006faC9965182e238582A3B412E --rpc-url https://sepolia.base.org
# expect true

cast call 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581 'hasActiveFeed(address,address)(bool)' 0x9D871aC7595E8Da271E866608E5145252047967c 0x6eAe407f5640B006faC9965182e238582A3B412E --rpc-url https://sepolia.base.org
# expect true

cast call 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581 'getFeed(address,address)((address,address,uint32,uint16,bool))' 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02 0x6eAe407f5640B006faC9965182e238582A3B412E --rpc-url https://sepolia.base.org
# expect (CH_ETH, PY_ETH, 1500, 100, true)

cast call 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581 'getFeed(address,address)((address,address,uint32,uint16,bool))' 0x9D871aC7595E8Da271E866608E5145252047967c 0x6eAe407f5640B006faC9965182e238582A3B412E --rpc-url https://sepolia.base.org
# expect (CH_BTC, PY_BTC, 1500, 100, true)

cast call 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581 'getPriceSafe(address,address)(uint256,uint256,bool)' 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02 0x6eAe407f5640B006faC9965182e238582A3B412E --rpc-url https://sepolia.base.org
# expect (price, updatedAt, true) - fresh Chainlink ETH/USD price

cast call 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581 'getPriceSafe(address,address)(uint256,uint256,bool)' 0x9D871aC7595E8Da271E866608E5145252047967c 0x6eAe407f5640B006faC9965182e238582A3B412E --rpc-url https://sepolia.base.org
# expect (price, updatedAt, true) - fresh Chainlink BTC/USD price
```

### Perps / Executor state (must remain UNCHANGED post-TX10)
```
cast call 0x774d96E5739bffadEE91508b4D3D74F5BE29F165 'paused()(bool)' --rpc-url https://sepolia.base.org
# expect false (Perps route posture unchanged)

cast call 0x774d96E5739bffadEE91508b4D3D74F5BE29F165 'isExecutor(address)(bool)' 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8 --rpc-url https://sepolia.base.org
# expect false (TX-11 not yet executed)

cast call 0x774d96E5739bffadEE91508b4D3D74F5BE29F165 'isExecutor(address)(bool)' 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 --rpc-url https://sepolia.base.org
# expect true (TX-12 not yet executed)
```

### Timelock queue drained
```
cast call 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588 'queuedTransactions(bytes32)(bool)' <opHash5> --rpc-url https://sepolia.base.org
cast call 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588 'queuedTransactions(bytes32)(bool)' <opHash6> --rpc-url https://sepolia.base.org
cast call 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588 'queuedTransactions(bytes32)(bool)' <opHash7> --rpc-url https://sepolia.base.org
# expect all false (execute clears the queue slot)
```

### Non-goals (must remain OFF / disabled / unchanged)
- Public Perps route: **OFF** (no state variable flipped; enforced at API boundary + PME auth)
- Funding: **OFF** (no per-market funding activation)
- WETH collateral: **DISABLED** (deferred per `DEOPT_WETH_BASE_SEPOLIA_CLOSED_TEST_DEFERRAL_V1.md`)
- cbBTC collateral: **DISABLED**
- Safe owners / threshold / modules: **UNCHANGED**
- Base mainnet: **UNTOUCHED**

## Release gates (Part G)

Each gate requires a **separate explicit authorization** from the user.
None auto-triggers the next.

| Gate | Condition | Authorization required |
|---|---|---|
| **1** | TX-05/06/07 successfully queued on-chain (all `queuedTransactions[opHash]=true`, Safe.nonce=7) | Currently underway (Safe co-signers) |
| **2** | Timelock ETA reached (`block.timestamp >= FINAL_ETA`) | Passive — time-based |
| **3** | TX-08/09/10 executed + oracle post-state matches Part F validation matrix | New GO directive for Stage-C Safe execute broadcast |
| **4** | TX-11 executed + `isExecutor(new)=true` on-chain | New GO directive for deployer-signed executor rotation (Phase 1) |
| **5** | TX-12 executed + `isExecutor(deployer)=false` + `isExecutor(new)=true` | New GO directive for deployer-signed executor rotation (Phase 2), gated on Gate 4 |

**Post-Gate-5 state = the frozen manifest's final Perps infra target**:
Timelock owns router with dual-source oracle policy on ETH+BTC markets;
new dedicated executor is the sole PME executor; deployer key is
retained for owner role only (PME.owner unchanged; TX-11/12 don't move
ownership, only rotate the executor set). No public Perps activation, no
funding, no collateral changes — those all remain OFF and require their
own separate milestone directives beyond Gate 5.

## Remaining blockers (Part H — none unresolved)

- **B1**: Human co-signers need to complete the 2-of-3 Safe signing flow for TX-05/06/07 (Stage B in progress).
- **B2**: New executor `0x58Ad…52B8` has zero Base Sepolia ETH. Fund with ≥ 0.005 ETH before first executor-signed runtime tx (deferred until after Gate 5, out of scope for Gates 1-4).
- **B3**: Backend + frontend closed-test allowlist wiring for the Perps closed-test cohort (out of scope for the on-chain infra milestone — tracked separately).

None of the above block preparation of the post-queue artefacts, which
this milestone completes.

## Final commit SHAs

- **Solidity**: `<will be set by the commit landing this doc>`
- **Backend**: `126a857` (unchanged)
- **Frontend**: `9cd8dce` (unchanged)

## Artefacts produced this milestone

- Deprecation banner: `script/BroadcastPerpsInfraTx05to07.s.sol` (marked as historical / do-not-use)
- New: `script/DerivePerpsInfraSafeExecutePackage.s.sol` (Stage-C Safe execute derivation)
- New: `script/RehearsePerpsInfraFullCycle.s.sol` (fork rehearsal — GREEN this session)
- New: this doc — `PERPS_BASE_SEPOLIA_POST_QUEUE_READINESS_PREP_V1.md`

## Confirmations

- No Base Sepolia broadcast performed by this milestone.
- No Safe submission, no Safe signature collected, no Safe UI interaction.
- No secret file read or modified. Executor keystore untouched.
- No fund transfer.
- TX-08..12 remain **NOT authorized**.
- Public Perps OFF · Funding OFF · WETH/cbBTC disabled · Base mainnet untouched.

Return: **`PERPS_BASE_SEPOLIA_POST_QUEUE_READINESS_PREP_COMPLETE`**
