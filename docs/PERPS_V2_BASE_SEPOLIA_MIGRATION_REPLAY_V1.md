# PERPS_V2_BASE_SEPOLIA_MIGRATION_REPLAY_V1

Status: **PERPS_V2_BASE_SEPOLIA_MIGRATION_REPLAY_V1_COMPLETE**.
Exactly eight operator-approved seeds were executed and independently reconciled.
NEW_ENGINE remains OPEN with zero on-chain snapshotHash. No seal was executed.
The Stage-A sections below preserve the reviewed pre-broadcast evidence; Stage-B
execution and final live reconciliation follow them.

## Repository checkpoint and scope

- Solidity HEAD: `def2631191c0029e8d45b6e93a976bf2570dedef`.
- Backend HEAD: `ad8dd7466aeba6963d28687e825fe4df58ef32ee`.
- Both worktrees were clean at entry. Local additions are this report, separate
  replay artifacts, and helper/tests. No production or backend source changes.
- Public chain: Base Sepolia, chain ID 84532.
- Sole approved public transaction target:
  `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15` (NEW_ENGINE).
- Exactly two funding seeds and six position seeds. No residual-debt seed or seal.
- No deployment, token movement, dependency rebind, authorization, Safe/Timelock,
  backend/DB action, trader signing, trade, or mainnet interaction.

## Canonical integrity and replay scope

Snapshot block 47,354,411 and historical hash
`0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89`
were verified by live RPC.

Existing `manifest.cbor` Ethereum Keccak-256:
`0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.
Decoded existing CBOR equals the committed `snapshot_hash.canonical(manifest.json)`
object. No CBOR encoding/regeneration is performed. The schema has V1/source-block
bindings and no exclusive destination binding. The committed recovery freeze
report section L explicitly permits verbatim replay into a replacement Engine.

All three canonical files match the authoritative Git checkpoint byte-for-byte:

| Original file | SHA-256 |
|---|---|
| `manifest.json` | `88707f092c2be05fb5e4b73454f880b84abc4a1a95199e4eeb9aeec024687ddd` |
| `manifest.cbor` | `520897f586cb275fbe81d4d5acb30ce45632be4ce2574a0577bc302b339ed857` |
| `seed_calldata.json` | `d92cf6abae899123d7d96009f36da3f8a715c04a7ee9ac6bf5dddc9c0b1cdb14` |

Separate recovery package:
`artifacts/perps_v2_migration_replay/execution_package.json`.
SHA-256: **`bdcc5f48b4637822316752358e3c37324cf6e3aa85f86dc406b1e0f74bee5738`**.

Historical `engineV2`/step target is OLD_ENGINE; recovery execution target is
NEW_ENGINE. Each step retains its ordinal, function, selector, decoded arguments,
calldata and descriptive fields unchanged; explicit ETH `value=0` is added.
Top-level chain, snapshotHash, OWNER, starting nonce and original-file-hash bindings
are added. There is no global address replacement. All eight calldata strings
are byte-for-byte identical to the originals and independently decoded with Cast
against the frozen Engine ABI, then re-encoded to reject trailing/malformed bytes.

## Read-only live preflight

Comparison block: **47,457,913**, hash `0x983c481d876aba4ba76a2dad08a877794b2d5410cb22dac83dda6d6caf8f4bc8`.
Fresh full-gate recheck after local rehearsal: **47,458,185**,
hash `0xa8dce7cde4daf33432633ba3f746ca08f94153d6c1665c5b589ea1dcf020c855`.

**114 state checks passed**, plus raw seed-flag and event checks. All were
rechecked at the fresh block, including unchanged PME_V2 nonces and runtime:

- NEW_ENGINE runtime is 24,321 bytes, byte-equal to the frozen artifact;
  Ethereum Keccak-256
  `0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`.
- OWNER and every constructor/internal dependency getter match the committed
  M2 postflight evidence. NEW PMR deviations 100/100, markets existing and active.
- NEW_ENGINE is OPEN, snapshotHash zero, both market tuples zero, all canonical
  positions zero on both markets, no indexed positions/exposure, residual debt zero.
- Seed flags: both funding flags false; six position flags false; six residual-debt
  flags false. A zero-valued market tuple is not used as a substitute for this check.
- V1 is frozen. V1 and OLD_ENGINE market/position/debt states match the manifest;
  V1 PME nonces and canonical Vault balances also match. OLD remains SEALED with
  canonical snapshotHash and its OLD PMR pointer.
- Vault V1 and OLD authorization true; NEW authorization false.
- PME_V2 and RISK_V2 still point to OLD_ENGINE.
- NEW FMV2 consumer and Insurance backstop authorizations false.
- Clearing ledger unchanged at 1,000,000,000 native mUSDC.
- All six PME_V2 trader nonces are zero; these will not be copied from PME_V1.
- Backend STOPPED; no backend process or port 8080 listener; emission capability NONE.
- OWNER confirmed/pending nonce 799/799. Safe nonce 15; runtime executor nonce 1.

Emitter-scoped scans use migration event topics derived from the frozen ABI and
Engine/PME TradeExecuted topics. Emitters are NEW_ENGINE, OLD_ENGINE, V1_ENGINE,
PME_V2 and PME_V1. Zero relevant events since M2 postflight block 47,457,159,
with continuous extension through the freshness block. NEW_ENGINE additionally
has zero migration/trade events from its CREATE block through comparison block.

Internal seed flag locations were derived using Solidity 0.8.30 storage-layout-only
output with the frozen compiler settings and all 30 source hashes checked against
artifact metadata. No production bytecode recompilation or Foundry cache change:

- `_positionSeeded`: nested mapping rooted at slot 33.
- `_marketFundingSeeded`: mapping rooted at slot 34.
- `_residualBadDebtSeeded`: mapping rooted at slot 35.

The derived mapping slots and actual zero readbacks are recorded in `preflight.json`.

## Frozen seed semantics

Both seed functions are `onlyOwner` and `onlyMigrationOpen`. Duplicate per-market
funding and per-trader/market position seeds revert, even when previous values
were zero. Position seeding rejects zero trader/size and inconsistent basis signs,
sets the seeded flag, writes the exact position tuple, synchronizes market indexing
and aggregate trader exposure, and reconstructs OI from each signed size.

Funding seeding stores the supplied cumulative rate and `uint64` timestamp exactly.
There is no current-time/future-time comparison in this implementation. Historical
1789715546 and zero timestamps are retained. Neither function requires a shared
PME/Risk rebind or Vault authorization. The only external calls are read-only PMR
market lookups. Funding/position migration events are emitted; no TradeExecuted.
No Vault balance or PME nonce is copied.

## Sequential isolated-fork rehearsal

Fork source: comparison block **47,457,913** above. The local RPC is loopback
Anvil, explicitly distinguished from public Base Sepolia even though both report
chain ID 84532. Anvil used one thread, zero generated accounts, OP support and no
persistent storage cache/default CREATE2 injection. OWNER was impersonated locally;
its initial nonce and balance matched public state. No real signer was accessed.

The actual deployed code was retained. No code replacement, storage editing,
balance/nonce override or mocked return value was used. Each step estimated gas
against the evolving state, sent only to the loopback node, waited for a successful
receipt, verified its exact migration event, then checked storage before advancing.
Call traces showed only STATICCALLs to NEW_PMR outside NEW_ENGINE.

The initial local estimator needed an explicit 1,000,000-gas search ceiling, and
receipt polling was added to handle asynchronous mining. Those harness corrections
did not change chain state or contract inputs. The final clean fork run passed
all eight steps sequentially. Its instance was stopped afterward.

## Actual eight-transaction preview

All transactions: OWNER `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`,
NEW_ENGINE `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15`, ETH value zero.
Funding selector `0x2c96f1bc`; position selector `0x0ef3a5f7`.
Arguments are in frozen ABI order.

| Step | Nonce | Function | Decoded arguments | Sequential gas estimate | Gas limit (+30%) |
|---|---:|---|---|---:|---:|
| 1 | 799 | `adminSeedMarketFunding` | `1, 0, 1789715546` | 93,748 | 121,873 |
| 2 | 800 | `adminSeedMarketFunding` | `2, 0, 0` | 74,313 | 96,607 |
| 3 | 801 | `adminSeedPosition` | `0x290bd12c93e467bf51c51f5273d35bddb19e9274, 1, 1000, 3000000, 0` | 234,177 | 304,431 |
| 4 | 802 | `adminSeedPosition` | `0x475fe397fa56884952d350aa9ee1c3946964bc0c, 1, -2, -6000, 0` | 235,142 | 305,685 |
| 5 | 803 | `adminSeedPosition` | `0x66858286feea78a05ea093673ea1535e0a52002d, 1, -1000000, -2468310000, 0` | 218,030 | 283,439 |
| 6 | 804 | `adminSeedPosition` | `0x77ca9dd6ccce2d692fb23877a2db7178807b0020, 1, -1000, -3000000, 0` | 218,030 | 283,439 |
| 7 | 805 | `adminSeedPosition` | `0x8b94a83d1ad3bd2337b1886e7962ca8e0bba9a34, 1, 2, 6000, 0` | 217,053 | 282,169 |
| 8 | 806 | `adminSeedPosition` | `0xff287410852b9328437eac353720e5476bc5f837, 1, 1000000, 2468310000, 0` | 217,101 | 282,232 |

Total sequential gas estimate: **1,507,594**.
Total proposed gas limits with 30% margin: **1,959,875**.
Fee parameters refreshed at block 47,458,185: base fee 5,000,000 wei/gas,
priority 1,000,000, suggested gas price 6,000,000.
Proposed maxFeePerGas = **11,000,000 wei** (0.011 gwei).

The deployed OP GasPriceOracle `0x420000000000000000000000000000000000000F`
returned `27805369882` wei for `getL1FeeUpperBound(512)`.
512 bytes conservatively exceeds each envelope; an additional 2x allowance is used.
Total L1 allowance: **444,885,918,112 wei**.
Combined budget: **22,003,510,918,112 wei**
(**0.000022003510918112 ETH**).
OWNER balance: **0.001716274205898345 ETH** — sufficient.
These are estimates/allowances, not public receipt costs; Stage B refreshes fees.
No top-up is needed or authorized.

## Simulated resulting state and non-interference

- Market 1: `(1001002,1001002,0,1789715546)`.
- Market 2: `(0,0,0,0)`.
- Six positions equal the canonical tuples; net size 0; long/short totals 1001002 each.
- Position indexes, per-trader exposure and seed flags match each successful step.
- Per-trader and aggregate residual debt zero; residual-debt seed flags remain false.
- Migration remains **OPEN**, on-chain snapshotHash remains **zero**.
- Shared PME/Risk pointers, NEW Vault/FMV2/Insurance authorizations, clearing ledger,
  PME_V2 trader nonces and Safe/executor nonces remain unchanged on the fork.
- Local OWNER nonce advances 799 to 807; public OWNER nonce remains **799**.

Evidence: `artifact_verification.json`, `execution_package.json`, `storage_layout.json`,
`preflight.json`, and `simulation.json` under `artifacts/perps_v2_migration_replay/`.
Focused package validation tests: **11 passed**, including wrong chain/snapshot/nonce,
forbidden target, altered calldata, nonzero value, seal selector and step-count guards.
No Cargo build or broad Forge suite was run.

The artifact helper requires the documented `cbor2` dependency. For this preparation,
version 5.6.5 was installed only under `/tmp/deopt-cbor2`, used via `PYTHONPATH`.
No repository dependency, compiler setting, system memory/swap setting or backend
configuration was changed.

## Stage-A operator stop (historical checkpoint)

**Stage A stopped for operator `ready`; no public writes or keystore unlocking occurred in Stage A.**
Stage B must independently derive the keystore address with `cast wallet address`,
verify OWNER, recheck package hash, nonce and all live gates, then send exactly one
approved calldata at a time. A successful receipt, exact event and storage readback
are required before sending the next ordinal. No automatic resume or blind retry.
An ambiguous submission requires transaction/nonce reconciliation and a stop.
Successful-prefix journaling and password-file removal apply on success or halt.

The operator subsequently replied `ready`, authorizing only the reviewed package
hash. Stage B is recorded below. No seal is included; reseal is a separate milestone.

Stage-A blockers: **none**.

## Stage-B signer, freshness and execution boundary

Before any send, `cast wallet address --keystore --password-file` independently
derived OWNER `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`. The temporary
password file was a regular OWNER-controlled file with mode 0600. No secret
material was printed or committed.

All 114 live gates, raw seed flags, event checks and approved package integrity
were refreshed at block **47,458,583**, hash
`0x1f35233ea9a2482fd005735aed81cce3c7f7faf868d5c879034251c66d570612`.
OWNER confirmed/pending nonces were 799/799. The runner independently checked the
signer again and refreshed nonce, runtime, event absence and backend stop before
the first send. Each next send required the expected evolving storage state.

Executed runner SHA-256: `a6951b2af2a064cbe055a7f158286049fe84c66b1a4885097c8e9761465f8879`.
Its source is preserved unchanged. An exclusive execution marker and fsynced
successful-prefix journal prevent automatic restart. There were eight send
invocations, no retry and no resume. All used the approved calldata, zero ETH
value, OWNER nonces 799–806 and NEW_ENGINE as the sole target.

## Public receipts and per-step readbacks

Each receipt status, transaction sender/target/nonce/chain/value/input, sole expected
migration event and step storage effects passed before the next transaction.
Funding flags, position flags, indexes, per-trader exposure and evolving OI were
read at the respective receipt block. OPEN, zero snapshotHash and zero debt
were checked after every step. Canonical block inclusion was rechecked separately
in the final audit, as detailed below.

| Step | Nonce | Transaction | Block | Status | Gas used | Settled L1 fee (wei) |
|---|---:|---|---:|---:|---:|---:|
| 1 | 799 | `0x01d0068166d12a976a3e0ed0b71a413a46c27827193000d4f4f3a1806e9ce3d0` | 47458723 | 1 | 93748 | 5955858635 |
| 2 | 800 | `0x69f5ee24443a1c9f05e879768ed125a356565e72b0eef510f76db6122d0d6075` | 47458736 | 1 | 73800 | 6224600196 |
| 3 | 801 | `0xfc3a8617aa2535ecf669db9585780f473d67a38867f963b25bf3c8e565a69e01` | 47458749 | 1 | 234177 | 6736135213 |
| 4 | 802 | `0x1f30189c1bb20423631c93b1b14f820b9784623d2751dc687a25491891a50695` | 47458766 | 1 | 235142 | 6397894502 |
| 5 | 803 | `0xdaa6e9aaf2a401d60413d4b56a0ad45947035f183627755a49fd96c8b182fbed` | 47458784 | 1 | 218030 | 6384604743 |
| 6 | 804 | `0x66c1a111198d81568ccc2a2f6604f4fb3595802a3d1d01c5f6341a5ad39a83e7` | 47458805 | 1 | 218030 | 6225383141 |
| 7 | 805 | `0x753d2a9b8c031e99280c76a61f642d440fc92271bbd42a07399af97ef813173f` | 47458822 | 1 | 217053 | 6305288257 |
| 8 | 806 | `0xd595efa3c5d997bce502cc15b1eaa114d00dd7ea2eb0b0662bbbb92b6449c8e9` | 47458840 | 1 | 217101 | 6694451305 |

## Receipt observation discrepancy and reconciliation

The initial journal observations for steps **2, 3, 5 and 6** contained an all-zero
block hash. Initial L1 fee observations for steps **2, 3 and 6** differed from later
canonical receipts. The first final-audit pass stopped on this mismatch; no further
transaction was sent. The original observations remain in `execution_journal.json`;
they were not rewritten as canonical receipts.

A separate read-only reconciliation verified all eight original transaction hashes
at the same original block numbers, status 1, with matching nonzero receipt,
transaction and canonical block hashes and explicit inclusion in each block.
A later read repeated that agreement. No previously nonzero block hash changed.
This establishes the settled inclusion; it does not establish the cause of the
earlier placeholder fields. Settled receipts supply the final fee accounting.

All eight transaction blocks precede the RPC safe head **47458993**, hash `0xf615afe4a55a403f8d7f26398845ba33fbdbf26a0ddfae7bd4f59ff7a53a1b86`.
Two optional additional public-provider checks returned HTTP 403; no second-provider
confirmation is claimed. Evidence is the configured Base Sepolia RPC, repeated
canonical receipt/transaction/block agreement and safe-head observation.

## Final pinned-block reconciliation

Final comparison block: **47459089**, hash `0xb73d53d696d499768c6d06369cf5276f47cb3ff4d57205297c60e86c79d1625e`.
All **114** state checks passed, plus seed/index, nonce, event and receipt audits.

V1, the canonical manifest, OLD_ENGINE and NEW_ENGINE agree exactly:

| Market | longOI | shortOI | cumulative funding rate | last funding timestamp |
|---|---:|---:|---:|---:|
| 1 | 1001002 | 1001002 | 0 | 1789715546 |
| 2 | 0 | 0 | 0 | 0 |

| Trader | Size | Open notional | Last cumulative funding rate |
|---|---:|---:|---:|
| `0x290bd12c93e467bf51c51f5273d35bddb19e9274` | 1000 | 3000000 | 0 |
| `0x475fe397fa56884952d350aa9ee1c3946964bc0c` | -2 | -6000 | 0 |
| `0x66858286feea78a05ea093673ea1535e0a52002d` | -1000000 | -2468310000 | 0 |
| `0x77ca9dd6ccce2d692fb23877a2db7178807b0020` | -1000 | -3000000 | 0 |
| `0x8b94a83d1ad3bd2337b1886e7962ca8e0bba9a34` | 2 | 6000 | 0 |
| `0xff287410852b9328437eac353720e5476bc5f837` | 1000000 | 2468310000 | 0 |

Net position size = 0; positive size total = 1,001,002; absolute negative size total
= 1,001,002. Market 2 positions remain zero. Each canonical trader has one indexed
market `[1]`, index-plus-one = 1, correct long/short exposure and zero residual debt.
Both funding flags and all six position flags are set. All six residual-debt flags
remain unset. Aggregate residual debt is zero.

NEW_ENGINE migration remains **OPEN (0)** and its on-chain snapshotHash remains
`0x0000000000000000000000000000000000000000000000000000000000000000`.
The canonical artifact hash remains
`0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`;
it has not yet been sealed into NEW_ENGINE. All three canonical files remain
byte-for-byte identical to the authoritative checkpoint.

NEW_ENGINE runtime remains 24,321 bytes, byte-equal to the frozen linked artifact,
Ethereum Keccak-256
`0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`.
Its constructor/internal pointers remain unchanged. NEW PMR returns deviations
100/100; both markets exist and are active.

## Non-interference, nonce and fee audit

- PME_V2 and RISK_V2 still point to OLD_ENGINE.
- NEW_ENGINE Vault, FMV2 consumer and Insurance backstop authorizations remain false.
- Vault authorizations for V1 and OLD_ENGINE remain true.
- Clearing ledger remains 1,000,000,000 native mUSDC (1000.000000 mUSDC).
- PME_V1 paused and V1 liquidations paused; V1 economics, PME nonces and canonical Vault balances unchanged.
- OLD_ENGINE remains SEALED with canonical snapshotHash, OLD PMR pointer and unchanged economics.
- All six PME_V2 trader nonces remain zero.
- Backend runtime STOPPED, emission capability NONE, no backend process/8080 listener.
- Scoped migration/trade scan finds exactly two funding and six position events on NEW_ENGINE; no seal, residual-debt or trade event.
- No authorized receipt contains any token movement or other external event. No shared-dependency write, authorization, deployment, Safe/Timelock, backend or DB action was performed.

The complete OWNER transaction scan across blocks 47458712–47459089 finds exactly the eight approved hashes. OWNER confirmed/pending nonce is **807/807**, a delta of **+8** from 799. Safe nonce **15 → 15**; runtime executor nonce **1 → 1**.

OWNER ETH: **0.001716274205898345 → 0.001707180795682353**.
Total gas used: **1507081** at effective gas price **6,000,000 wei**.
Execution fees: **9042486000000 wei**. Settled L1 fees: **50924215992 wei**.
Total expenditure: **9093410215992 wei** (**0.000009093410215992 ETH**), exactly equal to the OWNER balance decrease; no unexplained expenditure.

The temporary `/run/user/1000/deopt-deployer.pw` file was removed after the eight
transactions and independently verified absent. This is deletion, not a claim of
physical erasure. The local rehearsal fork is stopped.

## Validation and evidence

- Stateful rehearsal: 8/8 steps passed before approval.
- Package/canonical integrity tests: 11/11 passed, freshly rerun after execution.
- Receipt guard exercise: one valid case plus ten altered receipt/transaction/event cases passed before broadcasting.
- Public execution: 8/8 receipts, events and step storage readbacks passed.
- Final independent read-only reconciliation: passed; original and recovery package digests remain unchanged.
- Production contracts, deployment scripts, backend source/configuration and canonical artifacts are unchanged.

Evidence under `artifacts/perps_v2_migration_replay/`: original Stage-A files plus
`prebroadcast.json`, `execution_started.json`, `execution_journal.json`,
`receipt_block_reconciliation.json` and `postflight.json`. Only ABI function
signatures and public transaction metadata appear in these artifacts; no wallet
signatures or credentials are recorded.

Blockers: **none** after settled receipt reconciliation.

Next milestone: **PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1**.
It is not authorized or executed by this milestone. Stop after normal commit/push.
