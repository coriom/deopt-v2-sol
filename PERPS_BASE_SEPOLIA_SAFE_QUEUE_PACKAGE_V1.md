# PERPS_BASE_SEPOLIA_SAFE_QUEUE_PACKAGE_V1

Operator package for queueing **TX-05 / TX-06 / TX-07** from
`PERPS_BASE_SEPOLIA_INFRA_BROADCAST_MANIFEST_FINAL.md` (sol `5f93e199`)
through the **OPS_MULTISIG Gnosis Safe** that owns the deployed
`ProtocolTimelock` on Base Sepolia. Supersedes the earlier
`forge script --keystore` approach for TX-05..07 only; TX-01..04
remain deployer-signed exactly as designed.

- **Scope**: Base Sepolia (chain id 84532) only.
- **Broadcast**: NONE performed during preparation. No signature
  collected. Nothing submitted to Safe Transaction Service.
- **Adjacent-product posture (unchanged)**: Public Perps OFF; Funding
  OFF; WETH / cbBTC disabled; Base mainnet untouched.

## Freeze pointers

| Component | Commit / value |
|---|---|
| Solidity (adds this doc + derivation script) | `1a297d7` (pre-write) |
| Backend | `126a857` (unchanged) |
| Frontend | `9cd8dce` (unchanged) |
| FINAL Perps infra manifest | `PERPS_BASE_SEPOLIA_INFRA_BROADCAST_MANIFEST_FINAL.md` at sol `5f93e199` |
| Broadcast scripts | `script/BroadcastPerpsInfraTx01to04.s.sol` + `script/BroadcastPerpsInfraTx05to07.s.sol` at sol `1a297d7` |
| **Package derivation script (new)** | `script/DerivePerpsInfraSafeQueuePackage.s.sol` |

---

## Part A · Governance state (VALIDATED at block 46 574 052)

Read-only checks against `https://sepolia.base.org`:

| Check | Value |
|---|---|
| chainId | `84532` |
| current block.timestamp | `1 788 916 392` |
| **Safe** `0xA6B9…cD46` | `singleton = 0x29fcB43b…C762` (SafeL2), `VERSION = "1.4.1"`, `threshold = 2`, `nonce = 4`, modules **none**, balance `0.0052 ETH` |
| Safe owners (2-of-3) | `0xb9F8dE80…6d06`, `0x0E7DcB5b…a35d`, `0xa774C46C…8dFC` |
| **ProtocolTimelock** `0xa67f…b588` | `owner == Safe`, `guardian == Safe`, `minDelay = 86 400 s`, `queuePaused = false`, `proposers[Safe] = true`, `executors[Safe] = true` |
| **MultiSendCallOnly v1.4.1** `0x9641d764…102e2` | deployed on Base Sepolia (code present) |
| **MultiSend v1.4.1** `0x38869bf6…B526` | deployed on Base Sepolia (code present) — not used in this package |

**Verdict**: `PERPS_TIMELOCK_SAFE_GOVERNANCE_STATE_VALIDATED`

---

## Part B · Two-stage operator flow

### Stage A — TX-01 → TX-04 (deployer-signed)

Unchanged from the earlier design. Run:

```
cd ~/DEOPT/deopt-v2-sol && forge script script/BroadcastPerpsInfraTx01to04.s.sol \
    --rpc-url https://sepolia.base.org \
    --broadcast \
    --sender 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 \
    --keystore /home/corio/.foundry/keystores/deopt-deployer
```

**Postcondition (verify before Stage B)**:
- 4 tx receipts status = success
- 4 addresses recorded from stdout (`CH_ETH`, `CH_BTC`, `PY_ETH`, `PY_BTC`)
- `cast code <addr> --rpc-url https://sepolia.base.org` returns non-empty for each
- Broadcast artefact: `broadcast/BroadcastPerpsInfraTx01to04.s.sol/84532/run-latest.json`

### Stage B — derive the exact Safe queue package

Run the derivation script with the 4 real addresses from Stage A:

```
CH_ETH=0x<from-stage-A> \
CH_BTC=0x<from-stage-A> \
PY_ETH=0x<from-stage-A> \
PY_BTC=0x<from-stage-A> \
forge script script/DerivePerpsInfraSafeQueuePackage.s.sol:DerivePerpsInfraSafeQueuePackage \
    --rpc-url https://sepolia.base.org --sig "run()" -vv
```

The script is **read-only** — no `vm.startBroadcast`, no state change.
It reverts if any adapter has no code (a Stage A hasn't-completed guard).

Its stdout contains:

- The frozen ETA (used across all three queue operations)
- **Layout A** — three separate Safe transactions (`Safe.to`, `Safe.value`, `Safe.operation`, `Safe.data`, expected timelock op hash)
- **Layout B** — a single MultiSendCallOnly batch (`Safe.to`, `Safe.value`, `Safe.operation`, `Safe.data`) that fires all three queue calls atomically
- Expected timelock operation hashes for post-queue verification
- Copy/paste `cast call` commands for post-queue verification

**No partial substitution. No guessed addresses.** The script fails
closed if any adapter address is missing or has no on-chain code.

---

## Part C · Safe transaction model

For each of the three underlying operations, the Safe transaction is:

| Field | Value (Layout A — separate txs) |
|---|---|
| `to` | `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` (ProtocolTimelock) |
| `value` | `0` |
| `data` | `queueTransaction(0xB416…A581, 0, <innerCalldata>, <ETA>)` — full outer bytes emitted by the derivation script |
| `operation` | `0` (CALL) |
| `safeTxGas` | `0` (Safe v1.4.1: not enforced; execution passes the entire tx gas budget to the sub-call) |
| `baseGas` | `0` (no on-chain refund flow — Safe pays its own tx gas from Safe balance) |
| `gasPrice` | `0` (same rationale — disables Safe's refund calculation) |
| `gasToken` | `0x0000…0000` (native ETH) |
| `refundReceiver` | `0x0000…0000` (no refund) |
| `nonce` | `4`, `5`, `6` for the three separate txs (Layout A) — assigned sequentially by Safe |
| inner Timelock calldata | as emitted by derivation script |
| inner Timelock target | `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` (OracleRouter) |
| ETA (unix) | frozen by derivation script (Part D) |
| expected op hash | as emitted by derivation script; verifiable via `hashOperationBytes` |

For Layout B (MultiSendCallOnly batch), the Safe transaction becomes:

| Field | Value |
|---|---|
| `to` | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` (MultiSendCallOnly v1.4.1) |
| `value` | `0` |
| `data` | `multiSend(<packed calls>)` — full bytes emitted by the derivation script |
| `operation` | `1` (**DELEGATECALL** — required by MultiSend contract semantics) |
| `safeTxGas / baseGas / gasPrice / gasToken / refundReceiver` | `0` / `0` / `0` / `0x0` / `0x0` (same as separate) |
| `nonce` | `4` (single Safe tx) |

**Safety note on `operation = 1`**: MultiSendCallOnly is delegate-called
by the Safe, but the MultiSendCallOnly contract itself performs only
`CALL` (never `DELEGATECALL`) to each sub-target — enforced at the
bytecode level. The Safe therefore behaves exactly as if it made three
consecutive `CALL`s to the Timelock, in a single transaction, atomic.

**No signatures are collected** by any part of this package. **No
submission to Safe Transaction Service** happens from this repo.

---

## Part D · ETA policy

```
ETA = block.timestamp (at Stage B derivation) + timelock.minDelay() + SAFETY_MARGIN
    = block.timestamp                          + 86 400              + 21 600
    = block.timestamp + 108 000  (~30 h from Stage B derivation moment)
```

Recommendation: **6-hour safety margin** (`21 600 s`).

**Rationale**:

- Timelock enforces `eta >= block.timestamp_at_queue_execution + minDelay`. The queue call must arrive at the timelock at some `T_queue` where `T_queue + 86 400 ≤ ETA`, i.e., `T_queue ≤ ETA - 86 400`.
- If we set `ETA = T_derivation + 86 400 + 21 600`, the Safe queue tx may land at any `T_queue` in the window `[T_derivation, T_derivation + 21 600]` (~6h) and still satisfy the timelock's `eta ≥ now + minDelay` check.
- **6 hours** is enough for a 2-of-3 signing round on a 3-person team distributed across timezones + Safe UI review + Base Sepolia block confirmation, without leaving so much slack that TX-08..10 execution waits an unnecessarily long extra window.
- The margin is **frozen at derivation time** and baked into the calldata + op hashes. If the Safe tx does not land within `T_derivation + 21 600`, the whole package must be re-derived (fresh block.timestamp → fresh ETA → fresh calldata → fresh op hashes → fresh signatures). No mid-flight recomputation.

**Consequences of a fresh re-derivation**:

- New op hashes (different ETA → different `hashOperationBytes` output).
- Previous Safe-owner signatures become invalid (they were EIP-712-signed against the old calldata + nonce).
- 2-of-3 signing must be repeated.

Practical guidance: aim to submit the Safe tx within 2 h of derivation, keeping 4 h of buffer against block-time drift, signer availability, or Safe UI operator error.

---

## Part E · Safe Wallet UI package

### E.1 Recommended UI

`https://app.safe.global/home?safe=basesep:0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`

Network chip must read **Base Sepolia**. Chain id **84532**. Address bar must display exactly `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`.

### E.2 Layout B (recommended — see Part F) via Transaction Builder

1. In the Safe UI: **New transaction → Transaction Builder**.
2. Add one **custom contract interaction** with:
   - **Contract address**: `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` (MultiSendCallOnly v1.4.1)
   - **ABI**: paste the fragment
     ```json
     [{"inputs":[{"internalType":"bytes","name":"transactions","type":"bytes"}],"name":"multiSend","outputs":[],"stateMutability":"payable","type":"function"}]
     ```
   - **Method**: `multiSend`
   - **transactions** parameter: paste the entire `Safe.data` hex from the derivation script's Layout B output (starts with `0x8d80ff0a…`, ~1.3 kB).
3. Add batch → **Create Batch** → **Send Batch**.
4. **Advanced parameters** (must set before signing):
   - `safeTxGas = 0`, `baseGas = 0`, `gasPrice = 0`, `gasToken = 0x0…0`, `refundReceiver = 0x0…0`
   - `operation` — Safe UI infers `DELEGATECALL` automatically for MultiSend calls when using "Transaction Builder". Confirm this in the "Simulate" step before signing; the operation field must show as `DELEGATECALL`.
5. **Do NOT sign yet** — first inspect the simulated calldata against the derivation-script output byte-exact.

### E.3 Layout A (fallback — 3 separate txs) via Transaction Builder

Repeat the above three times, once per TX-05 / TX-06 / TX-07:

- **Contract address**: `0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588` (ProtocolTimelock)
- **ABI fragment**:
  ```json
  [{"inputs":[{"internalType":"address","name":"target","type":"address"},{"internalType":"uint256","name":"value","type":"uint256"},{"internalType":"bytes","name":"data","type":"bytes"},{"internalType":"uint256","name":"eta","type":"uint256"}],"name":"queueTransaction","outputs":[{"internalType":"bytes32","name":"","type":"bytes32"}],"stateMutability":"nonpayable","type":"function"}]
  ```
- **Method**: `queueTransaction`
- Parameters:
  - `target = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581` (OracleRouter)
  - `value = 0`
  - `data = <inner calldata from the derivation script for the specific TX>`
  - `eta = <ETA from the derivation script — identical for all 3 txs>`
- `operation = CALL (0)`.
- Advanced params identical to E.2 above (`0 / 0 / 0 / 0x0 / 0x0`).

### E.4 Safe Transaction Service payload (optional)

If the operator prefers to prepare + review unsigned tx JSON via the Safe Transaction Service API, the shape is:

```json
{
  "safe": "0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46",
  "to": "0x9641d764fc13c8B624c04430C7356C1C7C8102e2",
  "value": "0",
  "data": "0x8d80ff0a…<from Layout B>",
  "operation": 1,
  "safeTxGas": "0",
  "baseGas": "0",
  "gasPrice": "0",
  "gasToken": "0x0000000000000000000000000000000000000000",
  "refundReceiver": "0x0000000000000000000000000000000000000000",
  "nonce": 4
}
```

Nothing in this package submits that JSON. Nothing collects signatures over it. Operator does that manually via `safe-cli propose`, Safe UI import, or the Safe Transaction Service `POST /api/v1/safes/{address}/multisig-transactions/` endpoint from a machine with the appropriate credentials.

---

## Part F · Batching decision — RECOMMENDATION

**Recommend Layout B (single MultiSendCallOnly batch) for TX-05..07.**

### Rationale

| Property | Layout A (3 separate) | Layout B (1 MultiSend) |
|---|---|---|
| Signature-collection rounds | 3 × 2-of-3 | 1 × 2-of-3 |
| Failure semantics if a call reverts | 2 of 3 land, 1 lost — messy state, partial queue | atomic all-or-nothing — clean state, easy retry |
| Coherent ETAs across the 3 ops | yes (fixed by derivation script) | yes (fixed by derivation script) |
| Safe nonce consumed | 3 sequentially (4, 5, 6) | 1 (nonce = 4) |
| Retry cost after ETA expiry | re-sign 3 times | re-sign 1 time |
| Safe UI operator error surface | 3 opportunities to enter wrong data | 1 opportunity |
| Interpretability in Safe history | 3 disparate rows | 1 clearly labelled batch |

The 3 underlying operations are independent (no state coupling between them) and target the same contract with the same authority (`onlyProposer` on ProtocolTimelock, held by the Safe). Their success/failure conditions are identical. There is no case where "partial application of 2-of-3" produces a better state than "all-or-nothing" — a partial application of TX-05..07 leaves the router in a half-configured state that TX-08..10 (execute) would then hit inconsistently.

Layout A is documented as a **fallback** for the case where the Safe UI or a specific signer's wallet has trouble with the MultiSend batch. The operations, addresses, ETAs, and inner calldata are byte-identical between the two layouts — pick one at Safe-tx-preparation time.

The three underlying ProtocolTimelock operations are **NOT changed** by the batching decision.

---

## Part G · Signer instructions (human-readable)

Give these to each of the 3 Safe co-signers. They must ALWAYS operate their own wallets. **Nothing in this package or in DeOpt tooling asks anyone for a private key.**

### Prerequisites (per signer)

- Wallet holding one of the Safe owner EOAs:
  `0xb9F8dE80…6d06`, `0x0E7DcB5b…a35d`, or `0xa774C46C…8dFC`
- Wallet supports Base Sepolia (chain id 84532)
- ≥ 0.001 ETH on Base Sepolia in the signer's EOA (to submit the execute tx; signature-only doesn't cost gas but the final executor pays)
- Access to the derivation script's output (from `Stage B`)

### Steps

1. **Open** `https://app.safe.global/home?safe=basesep:0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`
2. **Verify Safe topology in the header**: chain = *Base Sepolia*; address = `0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46`; owner set matches the 3 EOAs above; threshold = 2. If any field is off, **stop and escalate**.
3. Choose the appropriate flow:
   - **If a pending transaction is already open** (e.g., another signer prepared it), go to Transactions → Queue → find the tx → click "Confirm".
   - **If no pending tx**: use Transaction Builder to prepare it per §E.2 (Layout B) or §E.3 (Layout A).
4. **Inspect the transaction details**:
   - **To**: MultiSendCallOnly (`0x9641d764fc13…`) for Layout B, or Timelock (`0xa67f…b588`) for Layout A
   - **Value**: `0 ETH`
   - **Data**: matches the derivation-script output byte-exact
   - **Operation**: `DELEGATECALL` for Layout B, `CALL` for Layout A
   - **Simulation**: use "Simulate" or "Advanced → Estimate" — result must show no revert
5. **Sign** using your wallet (hardware wallet ritual for the mainnet-mirroring flow):
   - Ledger: open the "Ethereum" app, plug in, confirm on device screen. Signing is EIP-712; do NOT approve any "blind sign" that hides the payload.
   - Trezor: same principle — verify on the device screen that the target matches the expected Timelock or MultiSend address.
6. **Wait for the second co-signer** (2-of-3 threshold) to also confirm. Signatures accumulate in the Safe UI.
7. **Any owner may execute** once threshold is met: click "Execute", pay Base Sepolia gas (~0.0000015 ETH), wait for the tx receipt.
8. **Record the tx hash** (`0x…` from the receipt) and paste it in the operator log alongside the Stage A tx hashes.

Do not proceed to TX-08..10 execute after TX-05..07 queue — those are gated on:

- ≥ 24 h wait past `ETA`
- A **separate** explicit second authorization directive (this package covers Phase 1B only)

---

## Part H · Post-queue verification

The derivation script emits these commands with the actual op hashes filled in.  Template:

```
cast call 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588 \
    'queuedTransactions(bytes32)(bool)' <opHash5> \
    --rpc-url https://sepolia.base.org
# expect: true

cast call 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588 \
    'queuedTransactions(bytes32)(bool)' <opHash6> \
    --rpc-url https://sepolia.base.org
# expect: true

cast call 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588 \
    'queuedTransactions(bytes32)(bool)' <opHash7> \
    --rpc-url https://sepolia.base.org
# expect: true
```

Plus (unchanged state assertions):

```
cast call 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588 'queuePaused()(bool)'        # false
cast call 0x774d96E5739bffadEE91508b4D3D74F5BE29F165 \
    'isExecutor(address)(bool)' \
    0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8                                     # false
cast call 0x774d96E5739bffadEE91508b4D3D74F5BE29F165 \
    'isExecutor(address)(bool)' \
    0xc35F7A8A103A9A4464adfaa76B9B514093D23C27                                     # true
```

Public-Perps route + Funding route remain unchanged — verified by no state
transition in `PerpMatchingEngine.paused`, `MarginEngineV2` per-market flags,
or any other product-live gate. TX-11/12 remain unexecuted (executor-rotation
state above proves it).

### Earliest legal execute time for TX-08..10

`earliest = ETA` (exact — the ProtocolTimelock requires `block.timestamp >= eta`).

The derivation script prints this in its final line. Concretely, at derivation
time `T`, TX-08..10 may first legally execute at `T + 108 000 s` (`T + 30 h`).

A **separate** second authorization directive is required to actually broadcast
TX-08..10 — this package covers Phase 1B (queue) only.

---

## FINAL PACKAGE

`PERPS_BASE_SEPOLIA_SAFE_QUEUE_PACKAGE_READY`

Artefacts:

- `script/DerivePerpsInfraSafeQueuePackage.s.sol` — read-only Stage B derivation script (Foundry, compiles clean).
- `PERPS_BASE_SEPOLIA_SAFE_QUEUE_PACKAGE_V1.md` — this document.

Operator command summary (nothing broadcasts by default):

```
# Stage A (deployer-signed): TX-01..04
forge script script/BroadcastPerpsInfraTx01to04.s.sol \
    --rpc-url https://sepolia.base.org --broadcast \
    --sender 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 \
    --keystore /home/corio/.foundry/keystores/deopt-deployer

# Stage B (READ-ONLY): derive the Safe queue package
CH_ETH=... CH_BTC=... PY_ETH=... PY_BTC=... \
    forge script script/DerivePerpsInfraSafeQueuePackage.s.sol:DerivePerpsInfraSafeQueuePackage \
    --rpc-url https://sepolia.base.org --sig "run()" -vv

# Stage B (human, Safe UI): paste derivation output into
#   https://app.safe.global (Base Sepolia, safe 0xA6B9…cD46)
#   → Transaction Builder → Layout B (recommended)
#   → collect 2-of-3 signatures → execute
```

## Explicit non-authorization list

- **Do NOT broadcast**. This package prepares payloads only.
- **Do NOT submit** any payload to Safe Transaction Service, safe-cli, or any signature-collection infrastructure from this repo's tooling.
- **Do NOT collect signatures** from any signer via any DeOpt tool.
- **Do NOT export**, request, or otherwise touch any Safe owner private key.
- **Do NOT modify** the Safe's owners, threshold, or modules.
- **Do NOT execute** TX-08..12 — those require a separate second authorization directive after ETA + verification.
- **Do NOT broadcast** anything on Base mainnet.
- **Do NOT touch** WETH, cbBTC, public Perps, Funding — all disabled.

## Follow-on authorization sentence (for a future directive)

Once the Safe tx has landed, the operator may report a completion tuple:

```
PERPS_BASE_SEPOLIA_INFRA_PHASE1B_SAFE_QUEUE_COMPLETE
  safe_tx_hash: 0x<from Safe execute receipt>
  timelock_op_hashes: [0x<opHash5>, 0x<opHash6>, 0x<opHash7>]
  eta:          <unix seconds>
  earliest_execute: <unix seconds, == eta>
  post-state:   queuedTransactions(all 3) == true; PME executor unchanged
```

That report unblocks preparation for TX-08..10 (execute) via a **new**
Safe queue package + second explicit authorization from the user.
