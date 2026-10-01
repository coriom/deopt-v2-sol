# PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1

Status: **PERPS_V2_BASE_SEPOLIA_RECOVERY_MAINTENANCE_LOCK_V1_PARTIAL**.

Stage B stopped before the fourth transaction when its per-step OP L1-fee
upper-bound check exceeded the exact reviewed allowance. The successful prefix
(PME_V2, NEW_ENGINE, OLD_ENGINE) remains applied. V1_ENGINE was not sent a
maintenance transaction. This is not a complete maintenance lock. See the
Stage-B partial-execution section below and the immutable transaction receipts.

Stage A was read-only and used no keystore. The operator subsequently approved
Stage B for the exact package hash below. No transaction outside its first three
entries was submitted. Earlier approvals do not apply to any continuation.

## Preserved checkpoint

- Solidity HEAD: `fe5a7e4588504fdaf50db2ea940943c75442a8e7`.
- Backend HEAD: `ad8dd7466aeba6963d28687e825fe4df58ef32ee`, clean.
- The original BLOCKED rebind report, helper and four JSON evidence files remain
  unchanged. Their six SHA-256 digests are in
  `artifacts/perps_v2_recovery_maintenance_lock/entry_inventory.json`.
- Production Solidity, backend configuration, canonical migration artifacts and
  historical reports are unchanged. New files belong only to this milestone.
- Memory at entry: 7.6 GiB total, 6.4 GiB available; no builds or memory-setting
  changes. Local Anvil uses one thread, zero generated accounts, actual forked
  balances/code, and no storage overrides. No Forge/Cargo suite was run.

## Exact scope and authority

OWNER: `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`.
Network: Base Sepolia, chain ID 84532.

| Order | Target | Function | Selector | Intended controls |
|---|---|---|---|---|
| 1 | PME_V2 `0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2` | `pause()` | `0x8456cb59` | `paused=true` |
| 2 | NEW `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15` | `setEmergencyModes(bool,bool,bool,bool)` | `0xf64e345d` | all four true |
| 3 | OLD `0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9` | same | `0xf64e345d` | all four true |
| 4 | V1 `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` | same | `0xf64e345d` | all four true |

Engine parameter order, from the ABI and implementation:
**tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused**.
All values submitted are true, ETH value zero. Entirely satisfied operations
are omitted; a partially satisfied Engine call preserves its existing true flags.

All four deployed contracts have OWNER as owner. Engine guardians are OWNER;
PME_V2 guardian is zero. Each exact call succeeds in OWNER-context public
`eth_call`. Both pause entrypoints use owner-or-guardian authorization.

The Engine setter changes the four packed pause booleans, emits a per-flag
event only for each changed flag, then `EmergencyModeUpdated(true,true,true,true)`.
PME emits `Paused(OWNER)`. These functions make no external calls. The local
receipt, call trace and storage-diff checks verify those deployed effects.

V1 is **not assumed equal to current source**: its actual runtime is 23,794 bytes;
the current V1 artifact is 24,679 bytes. Its deployed selectors were extracted
without a signature-resolution service; all 74 map to known ABI signatures.
The exact maintenance selector is present and directly exercised on deployed code.
V1 lacks `updateImpactMid`; no fallback call or invented interface is used.
NEW/OLD use the frozen 24,321-byte V2 runtime, Ethereum Keccak-256
`0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`.
PME runtime matches its artifact outside compiler-declared immutable fields;
its live EIP-712 domain is separately recorded and preserved.

## Canonical baseline and exposure

The pinned comparison and fresh final comparison are recorded in `preflight.json`.
Full comparisons include 114 economic/dependency gates, all six full position
tuples, both market states, OI, funding checkpoints, per-trader exposure/indexes,
seed flags, residual debt, Vault balances and six PME nonces.

Canonical snapshotHash remains
`0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.
Existing CBOR is verified using Ethereum Keccak, decoded and compared with JSON;
no snapshot artifact is regenerated. NEW and OLD remain SEALED with this hash.
Market 1 is `(1001002,1001002,0,1789715546)`; market 2 `(0,0,0,0)`.
Clearing remains 1,000,000,000 native mUSDC. PME/Risk remain bound to OLD.
NEW Vault/FMV2/Insurance permissions remain false; V1/OLD Vault permissions true.

Read-only `updateFunding(2)` calls from unrelated address
`0x0000000000000000000000000000000000000001` succeed on NEW, OLD and V1.
Each actual-code trace changes only a zero storage word to the block timestamp;
the public value remains zero. This is timestamp initialization, not funding-rate
or PnL accrual. Empty OI and disabled funding configuration do not prevent it.

## Rehearsal and validation boundaries

`fork_simulation.json` identifies the isolated loopback Anvil RPC and fork block.
It also reports chain ID 84532; that alone never identifies it as public Sepolia.
Only the proposed maintenance calls are locally submitted, using OWNER impersonation.
No real keystore, trader signature, mocked call, code replacement, storage edit or
fabricated balance is used.

After each local receipt: exact sender/target/nonce/input, exact events, pause
readback, full economic/state comparison, domain/nonces/executor permissions and
OLD fee/Insurance permissions are checked before the next step. Call traces must
show no external calls. Storage diffs must affect only the target's pause word,
with the expected count of bytes changing from zero to one. Thus other accounts,
position/fill/nonce mappings and shared dependencies are not silently mutated.

Negative probes are `eth_call` only, using configured matching-engine and impact
source contexts, OWNER as an authorized PME executor, and a non-self liquidator.
They require exact `FundingPaused()`, `TradingPaused()`, `LiquidationPaused()` or
PME `PausedError()` errors, not arbitrary reverts. Both markets' funding calls are
tested; `updateImpactMid` is tested only where deployed. If impact source is zero,
the zero-address eth_call context is a synthetic modifier-path test, not a claim
that a real keeper can originate a zero-address transaction. Empty signature
arguments on the PME probe are never validated because the authorized executor
hits its pause modifier first. No trade is submitted even on the fork.

Current PerpEngine source defines `whenCollateralOpsNotPaused` but applies it to
no external PerpEngine collateral function. The extracted V1 deployed ABI likewise
has no direct collateral deposit/withdraw entrypoint. The collateral flag's storage
and event are checked; no nonexistent gated collateral API is claimed or called.
Essential market/position/index/debt/domain/nonce reads remain available.

The first local attempt stopped at gas estimation before any local transaction:
no explicit estimator ceiling was supplied and Anvil returned insufficient funds.
The read-only preparation helper was corrected to supply a 500,000-gas estimator
ceiling; the approved per-step limit is the actual estimate plus 30 percent.
OWNER's real fork balance was preserved. That zero-transaction attempt remains
in `fork_attempt_1.json`; it is not represented as a successful rehearsal.
The second local attempt stopped at an immediate receipt assertion before a
successful step could be established. Its local hash/receipt were not retained;
this evidence limitation is recorded in `fork_attempt_2.json`, and the fork was
terminated. The helper now journals the local hash immediately and polls for a
receipt before any readback or next call. A fresh isolated rehearsal is required;
neither failed attempt is public-chain execution or success evidence.

The third rehearsal **passed all four admin calls** in Anvil OP mode, including
exact events, pause storage and all economic checks after every call. Those receipts
are preserved in `fork_attempt_3.json`. Subsequent contract-caller negative probes
encountered an Anvil OP RPC limitation: it charges the unfunded matching-engine
caller for L1 fees before executing the call, even with zero gas price and local
impersonation. `probe_rpc_diagnosis.json` and `probe_call_context_diagnosis.json`
preserve the exact RPC observations. This is not accepted as a pause-error proof.

The final rehearsal uses standard EVM execution over the same actual Base Sepolia
fork state, repeating the four exact maintenance calls and using fee-free eth_call
for negative probes. No code, storage or balance override is used. These pause
setters have no external calls, and the tested entrypoint modifiers revert before
downstream logic; their deployed storage/error behavior is exercised directly.
This complements the OP-mode four-admin-call proof. Standard-EVM local receipts
do not model OP L1 fees; the public fee budget uses the deployed OP GasPriceOracle
upper bound separately and refreshes fee caps before issuing the preview.

## Remaining mutation surfaces

This is an Engine/PME maintenance policy, not a global protocol freeze.

- Owner/guardian configuration and emergency setters remain callable under their
  own authority. `setEmergencyModes` can subsequently change controls; this
  milestone authorizes true values only. Ownership acceptance remains restricted
  to the pending owner. V1 owner debt-repair/repayment methods are not globally
  disabled by these pause flags.
- PME trader nonce-cancellation entrypoints remain callable by traders. They are
  not exercised here. Executor administration and routing remain owner-controlled.
- Shared Vault, Risk, Insurance, token contracts, PMR, governance, deposits,
  withdrawals and unrelated products are not paused by this package.
- SEALED V2 migration entrypoints remain closed independently of maintenance.
- The local backend remains stopped. Local process/port checks make no claim
  about independent external callers or globally absent transaction activity.

## Signed-order investigation remains unresolved

No pause invalidates a signature. PME domain, nonce, fill and executor state must
be preserved. This gate does not block safety-pause preparation, but must be
resolved before unpausing/trading.

`store_inventory.json` records the bounded local investigation: existing backend
configuration names and database identity fingerprints, Docker container metadata,
volume names, and SELECT-only catalog access. No PostgreSQL container was found;
the scanned non-example environment files reference one database identity. The
configured store and maintenance-catalog access were unsuccessful. No historical
store containing actual retirement/replay records has been positively identified.
Named/anonymous volumes are not proof of their contents and have not been restored.

No database/container was created or started, no backup restored, no record
deleted/terminalized, and no signature/credential printed. Follow-up must locate
the actual historical store or backup, inspect metadata read-only, and validate
record target/domain/nonce/expiry/signers against actual Base Sepolia state.
Anvil fixtures cannot be dismissed solely by prefix, age or shared chain ID.

## Corrected downstream governance plan — not execution authority

Insurance owner is ProtocolTimelock, not OWNER. The original BLOCKED rebind report
is preserved; the historical four-EOA plan must not resume.
FMV2 `setFeeConsumer`, Risk `setPerpEngine` and PME `setEngine` are OWNER-controlled
where live ownership proves it. PME routing remains last in a separately reviewed
rebind plan, subject to the separately governed Insurance prerequisite.

The deployed Timelock runtime matches its local artifact. It exposes individual
`queueTransaction(address,uint256,bytes,uint256)` and
`executeTransaction(address,uint256,bytes,uint256)`, with no queue/execute batch.
Current `minDelay=86400`, `queuePaused=false`. OPS Safe is Timelock owner and both
proposer/executor; OWNER EOA has neither role. Safe threshold is 2 of 3.

| Future operation | Target | Call | Prerequisites / execution proof |
|---|---|---|---|
| A: Insurance permission | `0x009f38440F058d095b61E0E2ee7fAbDF05BE7500` | `setBackstopCaller(NEW_ENGINE,true)` | New separately approved operation; Safe queue/execute authority and delay; exact backstop event/readback |
| B: Vault permission | `0x00340C360353a5AB784c5Bc5c44322A6AF0625D3` | `setAuthorizedEngine(NEW_ENGINE,true)` | New separately approved operation; recovery prerequisites reviewed; exact Vault ACL event/readback |

Both can be considered in the same future governance preparation window, using
separate operations and approvals. They need not have the same readiness or
execution time. Each ID is Ethereum Keccak of `abi.encode(target,value,data,eta)`;
different targets/calldata give distinct operations. No final ETA, operation ID,
queue package, Safe signature or governance transaction is created here.

Historical OLD_ENGINE operation
`0xb42e46a90289c08aa36181e0be5f8350574a68b636bc84cb9a7aa7c83fed4fd0`
was consumed and reads unqueued; it must not be reused. See the preserved historical
Timelock execution report and this milestone's separate readback.

Before later unpausing, account for `applyTrade` calling `updateFunding` internally.
Leaving funding paused will intentionally revert trading; that is not a new
protocol defect. Old signatures and OLD_ENGINE's shared RiskModule relationship
remain separate readiness issues. No automatic unpause or rebind follows this lock.

## Stage-B partial execution and stop

The operator approved package SHA-256
`41ea29ebdbcde48dd43733d6f288bd819ad8274738bd008501d03c9d528b6697`.
The keystore-derived signer was independently verified as OWNER before any send;
the temporary password file was mode 0600 on runtime tmpfs and is now absent.
The executor checked chain ID 84532, package bytes, nonce 808/808, authorities,
full canonical economics, scoped activity and the approved fee ceiling before
the first send. It submitted one transaction at a time and validated exact
receipt, event, control readback and 114 economic/dependency checks before
proceeding to the next.

| # | Nonce | Target | Transaction hash | Block | Status | Gas used | Events |
|---|---:|---|---|---:|---:|---:|---:|
| 1 | 808 | PME_V2 | `0x02fc79a153b5db07933d23df14fec1071dde098e6c1ffa2d8ed7be050269e05f` | 47494275 | 1 | 49,239 | 1 |
| 2 | 809 | NEW_ENGINE | `0xde74e08da9bfa42415f280b94e0ccae55f2ffe88ca4a20dad704c220be768505` | 47494408 | 1 | 55,175 | 5 |
| 3 | 810 | OLD_ENGINE | `0x15b337c5874da28710b3bc03b69b30324128da8763ba79b2160da21f2e14eeb7` | 47494575 | 1 | 55,175 | 5 |

The three receipts each have a nonzero canonical block hash matching their
transactions and containing block. Exact sender, target, nonce, calldata,
zero value, gas limits/caps, event topics and event data were checked. A
provisional zero-block-hash receipt for TX1 was retained, then superseded by
the matching canonical receipt; it was never treated as confirmation.
The three receipt JSON files and `execution_journal.json` preserve this evidence.

Before TX4, the executor checked the deployed OP GasPriceOracle's
`getL1FeeUpperBound(512)` at the new head. Twice the value exceeded the
approved `57,175,216,312 wei` allowance, so the strict assertion halted before
submission. The transient bound at that exact check was not recorded; no numeric
peak is inferred. At the later read-only reconciliation block it was below
the allowance. That later observation does not retroactively authorize TX4.
No automatic fee adjustment, retry, replacement, rollback or fourth send occurred.

Read-only partial postflight at block **47494795**, hash
`0x84d7e63b48eb2ceec28251bb70a5c4e00076d8b69a73009ab38210d3795bb17d`:

- OWNER confirmed/pending nonce **811/811**, exactly +3; public send invocations
  exactly 3. V1_ENGINE remains `[trading=0, liquidation=1, funding=0,
  collateralOps=0]`. PME_V2 is paused. NEW_ENGINE and OLD_ENGINE each have
  `[1,1,1,1]`.
- All 114 canonical economic/dependency checks pass. Positions, funding,
  migration hashes, clearing ledger, PME/Risk pointers, Vault/FMV2/Insurance
  permissions, owner/guardian, runtime identity, domain, trader nonces and
  executor permissions are unchanged. The scoped emitter scan sees only the
  expected 11 pause events from the three approved transactions.
- Safe nonce remains 15; runtime-executor nonce remains 1. The backend remains
  locally STOPPED. No rebind, governance, Vault, migration, trade, backend or
  database write was performed by this execution.
- OWNER balance fell from **1,706,833,527,156,533** to
  **1,705,858,283,559,396 wei**, a decrease of **975,243,597,137 wei**.
  Settled receipt execution fees total **957,534,000,000 wei** and observed
  OP L1 fees total **17,709,597,137 wei**; their sum equals that decrease.
- Password file `/run/user/1000/deopt-deployer.pw` was removed and is absent.
  This does not imply physical shredding.

Read-only negative probes after this partial lock found the exact expected
pause errors for NEW and OLD funding on markets 1 and 2, applyTrade,
liquidation and impact-mid; PME executeTrade returned `PausedError()`.
V1 liquidation returned `LiquidationPaused()`, while V1 funding 1/2 remains
callable in `eth_call` and its trading flag remains false. These simulations
did not persist state. V1's permissionless funding-timestamp exposure therefore
remains; the full four-target maintenance objective is **not** satisfied.
See `partial_negative_probes.json` and `partial_postflight.json`.

No commit or push follows this partial result. The original BLOCKED rebind
evidence remains intact. Insurance governance and signed-order inventory are
still unresolved. Any V1 continuation requires a separately reviewed package
and new explicit authorization; the previous four-transaction approval must
not be reused.

## Verified Stage-A operator preview

Comparison block **47492624**, hash `0x52b87395d043091f9ff844a05b986ff8cfc9115ddd25b84fc8481cfc712abce4`.
Fresh complete public reconciliation block **47493084**, hash `0xf00705a8e59266f2616aa2f9e6b814d75bdffbdf7b62761087144acdae1c2723`.

All 114 economic/dependency checks plus seed flags, indexes and six PME trader
nonces pass at both comparison points. Public controls remain at their pre-lock
values. The scoped all-topic scan since reseal returned zero events.

Package: `artifacts/perps_v2_recovery_maintenance_lock/execution_package.json`.
**SHA-256: `41ea29ebdbcde48dd43733d6f288bd819ad8274738bd008501d03c9d528b6697`**.

Sender is OWNER; chain ID 84532; all ETH values zero. None of the four operations
can be skipped. Before/after arrays use the documented Engine parameter order.

| # | Nonce | Target | Before → after | Gas estimate | Gas limit |
|---|---:|---|---|---:|---:|
| 1 | 808 | `0xF5FB81e447AF3A3E81951aC72D751dE3E9B8eee2` | `[0]` → `[1]` | 49,239 | 64,011 |
| 2 | 809 | `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15` | `[0, 0, 0, 0]` → `[1, 1, 1, 1]` | 55,175 | 71,728 |
| 3 | 810 | `0x44702B0A3C329f2cc5b5c02c2123Dc9386a46db9` | `[0, 0, 0, 0]` → `[1, 1, 1, 1]` | 55,175 | 71,728 |
| 4 | 811 | `0xc6C592100723Fe0C66343A16e95eC34cC0c2141c` | `[0, 1, 0, 0]` → `[1, 1, 1, 1]` | 36,905 | 47,977 |

OWNER confirmed/pending nonce **808/808**; expected after approved execution **812**.
OWNER ETH balance **0.001706833527156533**.
Total estimated gas **196,494**; aggregate gas limits **255,444** (+30% per step).
Fee cap **11000000 wei/gas**; priority cap **1000000 wei/gas**.
OP L1 allowance **57175216312 wei per transaction**, twice the live 512-byte upper bound.
Total capped budget including L1 allowance **3038584865248 wei = 0.000003038584865248 ETH**.

Exact calldata for TX1 `pause()`:
```text
0x8456cb59
```
Exact calldata for TX2–TX4 `setEmergencyModes(true,true,true,true)`:
```text
0xf64e345d0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001
```

Simulation: **4/4 admin steps** pass in OP mode and again in standard EVM mode,
with identical gas and pause-storage effects. **15/15 exact maintenance-error
probes** pass; V1 impact-mid is correctly absent. No gated direct PerpEngine
collateral deposit/withdraw API is invented. All six trader nonces, domain,
executor permissions, economics and shared authorizations remain unchanged.

Both local forks are stopped. The source helper, this report and evidence remain
uncommitted after the partial Stage-B result. The report matches an existing
ignore rule; that rule was not changed. Prior BLOCKED evidence remains
byte-identical.

This was the archived Stage-A preview subsequently approved for a single
execution attempt. That attempt stopped after the verified three-transaction
prefix above. Insurance governance and signed-order inventory remain
unresolved. No rebind, unpause or next milestone is authorized.

Final nonce/package refresh at block **47493208**, hash
`0x79aac6f4a54370843b71662954db4843f8b340fa49deeb0c5cff45ae3be3f725`:
OWNER confirmed/pending still **808/808**, package digest unchanged. This final
nonce observation does not relabel the earlier full economic comparison block.
See `final_preview_refresh.json`. Independent package decoding verified all
targets, zero values, selectors, four true booleans, and nonces 808–811.
