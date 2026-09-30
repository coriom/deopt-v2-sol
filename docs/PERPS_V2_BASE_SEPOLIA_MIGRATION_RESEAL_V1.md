# PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1

Status: **PERPS_V2_BASE_SEPOLIA_MIGRATION_RESEAL_V1_COMPLETE**.
Exactly one operator-approved seal transaction succeeded and passed full postflight.
The Stage-A sections below preserve the historical preview; completed Stage B follows.
This is the recovery Engine's first seal. OLD_ENGINE is not a transaction target.

## Checkpoints and preserved artifacts

- Solidity HEAD: `a43e66245871a6286dcc158ef08e2f0373494a6a`.
- Backend HEAD: `ad8dd7466aeba6963d28687e825fe4df58ef32ee`.
- Both worktrees clean at entry. Subsequent local additions are this report,
  `tools/perps_v2_cutover/migration_reseal_preflight.py` and the separate
  `artifacts/perps_v2_migration_reseal/` evidence directory.
- Base Sepolia chain ID **84532**.
- No production source, backend, canonical snapshot or previous replay artifact changed.
- Existing CBOR was decoded using cbor2 5.6.5 restored only under `/tmp/deopt-cbor2`.
  JSON agreement was checked with the committed canonical schema. No CBOR encoding
  or snapshot regeneration occurred. Ethereum hashing uses the existing Ethereum
  Keccak implementation; NIST SHA3 is not used.

Existing CBOR Ethereum Keccak-256: **`0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`**.
The original block **47,354,411**, hash
`0x78debf6044c4f0d1282f0b8c60d0bb41171844453118a092bca5946a9ce54c89`,
was independently read and verified.

Recovery execution package SHA-256: **`bdcc5f48b4637822316752358e3c37324cf6e3aa85f86dc406b1e0f74bee5738`**.
All original/recovery artifact file hashes are recorded in `preflight.json` and
verified unchanged at the end of Stage A. Earlier placeholder receipt observations
are preserved, with no inferred cause.

## Replay receipt inclusion

The eight committed seed hashes were re-read and verified for status 1, sender,
target, nonce, chain, zero value and exact approved calldata. Every transaction,
receipt and expected canonical block has the same nonzero block hash, and the
transaction is included in that block. No seeds were repeated.

| Step | Transaction | Block | Status |
|---|---|---:|---:|
| 1 | `0x01d0068166d12a976a3e0ed0b71a413a46c27827193000d4f4f3a1806e9ce3d0` | 47458723 | 1 |
| 2 | `0x69f5ee24443a1c9f05e879768ed125a356565e72b0eef510f76db6122d0d6075` | 47458736 | 1 |
| 3 | `0xfc3a8617aa2535ecf669db9585780f473d67a38867f963b25bf3c8e565a69e01` | 47458749 | 1 |
| 4 | `0x1f30189c1bb20423631c93b1b14f820b9784623d2751dc687a25491891a50695` | 47458766 | 1 |
| 5 | `0xdaa6e9aaf2a401d60413d4b56a0ad45947035f183627755a49fd96c8b182fbed` | 47458784 | 1 |
| 6 | `0x66c1a111198d81568ccc2a2f6604f4fb3595802a3d1d01c5f6341a5ad39a83e7` | 47458805 | 1 |
| 7 | `0x753d2a9b8c031e99280c76a61f642d440fc92271bbd42a07399af97ef813173f` | 47458822 | 1 |
| 8 | `0xd595efa3c5d997bce502cc15b1eaa114d00dd7ea2eb0b0662bbbb92b6449c8e9` | 47458840 | 1 |

RPC inclusion heads observed:

- `safe`: block **47490494**, hash `0xfc6655b382fa2f5a291bd711683c7777bc2ea5267cd71ff95d7990d597a3df2f`.
- `finalized`: block **47489736**, hash `0x1c2aa4b80ffe4a23052f225cb97b5afb781440ee8047036db152019cf0096d27`.

The tag covering all seeds used for this check is **`finalized`**.
This is a configured-RPC observation, not independent second-provider agreement.
The earlier HTTP 403 observations remain historical; no second provider is claimed.

## Full pre-seal state reconciliation

Comparison block **47490487**, hash `0xa9a85e43732baf193daba5d87f2f64b44d289e76bde2869aa96095e96b90cb2d`.
Fresh complete recheck at block **47490558**, hash `0xfb87a979c5e005b3a13d98546b13cbd20ccdce63ec6fefa887e1d38cd9b38ce9`.
Each pass checked all **114** state gates, plus raw seed bookkeeping,
position indexes and all six PME_V2 nonces. All passed.

NEW_ENGINE runtime is **24321 bytes**, byte-for-byte equal to the
frozen linked artifact. Ethereum Keccak-256:
`0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`.

OWNER and all constructor/internal dependency getters match the committed M2
report, including NEW_PMR, Vault, Oracle, PME_V2, Risk, Clearing, Insurance, Seizer,
FMV2, useFeesManagerV2=true and guardian=OWNER. Both PMR markets exist and are active;
deviations are 100/100.

V1, the manifest, OLD_ENGINE and NEW_ENGINE agree on every canonical position and
market tuple. Values below are integers in the manifest's native units.

| Market | Long OI | Short OI | Cumulative funding | Funding timestamp |
|---|---:|---:|---:|---:|
| 1 | 1001002 | 1001002 | 0 | 1789715546 |
| 2 | 0 | 0 | 0 | 0 |

| Trader | Market | Size | Open notional | Last cumulative funding |
|---|---:|---:|---:|---:|
| `0x290bd12c93e467bf51c51f5273d35bddb19e9274` | 1 | 1000 | 3000000 | 0 |
| `0x475fe397fa56884952d350aa9ee1c3946964bc0c` | 1 | -2 | -6000 | 0 |
| `0x66858286feea78a05ea093673ea1535e0a52002d` | 1 | -1000000 | -2468310000 | 0 |
| `0x77ca9dd6ccce2d692fb23877a2db7178807b0020` | 1 | -1000 | -3000000 | 0 |
| `0x8b94a83d1ad3bd2337b1886e7962ca8e0bba9a34` | 1 | 2 | 6000 | 0 |
| `0xff287410852b9328437eac353720e5476bc5f837` | 1 | 1000000 | 2468310000 | 0 |

- Net size 0; positive sizes sum to 1,001,002; absolute negative sizes sum to 1,001,002.
- Market 2 positions are empty; each canonical trader has exactly market `[1]`
  indexed, index-plus-one 1, with exact long/short exposure totals.
- Both funding flags and all six position flags are set.
- All six residual-debt seed flags remain unset; per-trader and total debt are zero.
- NEW_ENGINE remains OPEN (0), with zero on-chain migrationSnapshotHash.

## Isolation and recent activity

- V1 matching paused; V1 liquidation paused. V1 economics, PME nonces and canonical
  Vault balances match the original manifest.
- OLD_ENGINE SEALED (1), canonical snapshotHash, OLD PMR pointer, economics unchanged.
- PME_V2 and RISK_V2 remain bound to OLD_ENGINE.
- NEW_ENGINE Vault, FMV2 consumer and Insurance backstop authorizations remain false.
- V1 and OLD_ENGINE Vault authorizations remain true.
- Clearing ledger remains 1,000,000,000 native mUSDC (1000.000000 mUSDC).
- All six PME_V2 trader nonces remain unchanged (zero).
- Backend runtime STOPPED; transaction emission capability NONE; no backend process
  or port 8080 listener. No backend/configuration/service/DB action performed.
- Safe nonce **15**; runtime executor nonce **1**.

The bounded activity scan covers blocks **47459090–47490558**,
starting after the committed replay postflight. All event topics were requested
only from the exact NEW/OLD/V1 Engine, PME_V1/PME_V2, Risk, Vault, NEW PMR, FMV2 and
Insurance emitters. **Zero events** were observed, including zero unexpected V2
trades or configuration events. Historical V1 activity was not rescanned.
The previously consumed OLD_ENGINE Timelock operation is not queued or executed.

## Frozen seal semantics

`src/perp/PerpEngineTradingV2.sol:325` implements
`sealMigration(bytes32)` with `onlyOwner` and `onlyMigrationOpen`.
It requires a nonzero hash and nonzero clearing, matching and risk pointers.
It writes only `migrationSnapshotHash` and `migrationState=SEALED`, and emits
`MigrationSealed(bytes32 snapshotHash, address indexed sealer)`. No external call
or dependency-side mutation is made. There is no unseal transition in this frozen
implementation; NEW_ENGINE's first seal is irreversible.

**The function does not reconstruct the manifest or verify economic completeness.**
The full pre-seal reconciliation above is therefore a mandatory operator gate.
Some older NatSpec comments call the closed-state error `MigrationSealed`; the
actual frozen modifier reverts with **`MigrationAlreadySealed()`**, selector
**`0x836df086`**. Stage-B negative probes must require this exact error.
Production comments/source were not changed.

## Exact one-transaction preview

- From: `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`.
- Sole target: `0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15`.
- Chain ID: **84532**.
- ETH value: **0**.
- Nonce: **807**; current confirmed/pending readback **807/807**.
- Function: `sealMigration(bytes32)`.
- Selector: `0x05d5af5b`.
- Argument: `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.
- Full calldata:

```text
0x05d5af5b039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d
```

Preview file: `artifacts/perps_v2_migration_reseal/transaction_preview.json`.
SHA-256: **`993727c3d27fe697d28f04d2adbda4c91573e77f035a44b5ba4865e6f8a13134`**.

Exact OWNER-context `eth_call` at block **47490558** returned `0x` successfully.
No state overrides, mock responses, keystore access, local/public transaction or
signature was used. Simulation does not establish the live seal transition.

Gas estimate: **57692**. Proposed gas limit (30% margin): **75000**.
Base fee: **5000000 wei/gas**.
Priority fee: **1000000 wei/gas**.
Max fee per gas: **11000000 wei/gas**.
OP GasPriceOracle `getL1FeeUpperBound(512)` at the freshness block:
**28490599994 wei**. Twice this amount is reserved for L1 fees:
**56981199988 wei**.
Total conservative budget: **881981199988 wei = 8.81981199988E-7 ETH**.
Fresh OWNER balance: **1707180795682353 wei = 0.001707180795682353 ETH**,
matching the previous checkpoint and sufficient without a top-up.

Expected event topic 0: `0xfdd70720ee4ac8df3db40d2f0ef06f3a6df16e1f981ef0d658be4ac266d788b5`.
Indexed sealer topic: `0x000000000000000000000000c35f7a8a103a9a4464adfaa76b9b514093d23c27`.
Event data (canonical hash): `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.
Emitter must be NEW_ENGINE.

Expected transition: **OPEN → SEALED**, **zero snapshotHash → canonical hash**.
All positions, basis, funding, timestamps, OI, debt, indexes and seed flags stay
unchanged. Shared dependencies remain OLD-bound and NEW_ENGINE remains unauthorized
in Vault, FMV2 and Insurance. Sealing alone does not activate the trading route.

## Stage-A mandatory stop (historical checkpoint)

Stage-A blockers were **none**; no seal transaction had been sent at that checkpoint.
The operator subsequently replied **`ready`**, approving exactly this preview hash.
Stage B must independently derive OWNER from the existing keystore, check the
operator-owned mode-0600 password file on verified runtime tmpfs, refresh all gates,
and send at most this one transaction. No blind retry, replacement or repair.
Require settled nonzero receipt/block inclusion and the exact event before completion.

Post-seal OWNER-context eth_call probes for all three seed functions and a second
seal must return `MigrationAlreadySealed()`; none may be broadcast. Final economics,
isolation, OWNER 807→808, Safe/executor zero deltas, settled fees and password-file
cleanup remain Stage-B work. Normal commit/push follows verified completion.

Next milestone after completed sealing: **PERPS_V2_BASE_SEPOLIA_V2_REBIND_V1**.
Not executed or authorized by this Stage-A preview.

## Completed Stage B: signer, freshness and one-shot execution

The operator authorized only preview SHA-256
`993727c3d27fe697d28f04d2adbda4c91573e77f035a44b5ba4865e6f8a13134`.
Its file and exact calldata remain unchanged. Before any send, the existing
keystore was independently queried with `cast wallet address --keystore --password-file`;
the result was exactly OWNER. Neither a sender flag nor a script assertion was
used as a substitute. The temporary password was a regular file with mode 0600,
uid 1000, on the verified `/run/user/1000` tmpfs mount. No secret was printed.

The complete 114-gate economic/isolation recheck, raw seed/index checks, historical
receipt inclusion and recent event scan passed at block **47491057**, hash `0xc225d92713ec54275e5609c2872dc00ef2150f37d00007f0c9c43dfa7e45ce5f`.
Critical fields, empty event window, OWNER 807/807, current balance, fee sufficiency
and exact-call simulation were refreshed at block **47491119**, hash `0x5ff620b6725e294a4d1fd6094d5d7a83bc1478632a27a7e1ad5669dd91ab0115`.
Fresh gas estimate was **57692**; conservative fee budget was **878613700026 wei**.
The approved nonce, calldata, gas limit and fee caps were used unchanged.

The runner recorded intent durably before its only send and created an exclusive
execution marker. It permits no automatic resume, retry or replacement.
Executed runner SHA-256:
`db705384f00096885925fd6487dbbf61a14acc9090e3080d15d5645d094f8f5c`.

## Canonical transaction, receipt and event

- Transaction: `0xf4cd9b68d0b21734e2d1ab4710b52b20ca36a7458e8fcc518d01731e07b0cec2`.
- Receipt block: **47491134**, hash `0x78734583f186f0c68a5437626778e19d8bce9240d1a8bb6d0fe0e209fe5d2ac3`.
- Receipt status: **1**.
- OWNER/from, NEW_ENGINE/to, nonce **807**, chain **84532**, zero value and full calldata match the reviewed preview.
- Gas limit **75,000**, max fee **11,000,000 wei/gas**, priority cap **1,000,000 wei/gas** match the preview.
- Exactly one log: `MigrationSealed(bytes32,address)`, emitted by NEW_ENGINE.
- Event data is the canonical snapshotHash; indexed sealer is OWNER.
- Receipt/transaction/block hashes agree and are nonzero; explicit canonical block inclusion passed twice.

Event topic 0: `0xfdd70720ee4ac8df3db40d2f0ef06f3a6df16e1f981ef0d658be4ac266d788b5`.
Indexed sealer: `0x000000000000000000000000c35f7a8a103a9a4464adfaa76b9b514093d23c27`.
Event data: `0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.

The first RPC receipt observation contained an all-zero block hash. It was
preserved as a provisional observation; the runner did not accept it as canonical
inclusion. Read-only polling of the same transaction established the nonzero
canonical block hash before success was recorded. No resend occurred and no cause
is inferred. The original observations remain in `execution_journal.json`;
`canonical_receipt.json` and `settled_receipt.json` retain subsequent readbacks.

Initial L1 fee **5970525820 wei**; settled L1 fee **5970525820 wei**.

Heads observed during the independent postflight:

- `safe`: block **47491076**, hash `0x86078e07c064a57fd470603d0ca25f75184d1cf47be920d3a1b6e95a37b73212`, covers seal: **False**.
- `finalized`: block **47490494**, hash `0xfc6655b382fa2f5a291bd711683c7777bc2ea5267cd71ff95d7990d597a3df2f`, covers seal: **False**.

A safe-head observation is not described as finalized proof. No second-provider
agreement is claimed. The previous M3 placeholder observations remain unchanged.

A later bounded inclusion refresh again matched the exact receipt and canonical block.
Its `safe` head was **47491271**, hash `0x950a2da4f35f5fd3c3847a57b5fa0d4f6feb891f29598101042d250f8ffb5578`,
which **covers the seal**. Its `finalized` head was **47490683**,
hash `0x96b54af4aef5685a6a0744d691500894c70aacd3ff3ddfce870109d0a9c67a4a`, which did **not** yet cover the seal.
This is safe inclusion, not a claim of finalized inclusion for this seal.
Evidence: `inclusion_refresh.json`; earlier head observations above remain preserved.

## Post-seal metadata, economics and rejection probes

All post-seal comparisons use block **47491264**, hash `0x582ab9e02cf6b2f387319684d9eeec942049a95727f2daef79fab5a2a64d48df`.
NEW_ENGINE is **SEALED (1)** with canonical on-chain hash
`0x039d9172729b0c9621956878a453409796308a37dc8e9f8f2d3f0d7e5b8b3d7d`.

All **114** state gates passed with only the two intended NEW_ENGINE metadata
expectations changed. Every other getter value matches the prebroadcast evidence.
Both market tuples and all six position tuples exactly match the Stage-A tables
above, the canonical manifest, V1 and OLD_ENGINE. In particular:

- Market 1 `(longOI, shortOI, cumFR, timestamp)` = `(1001002, 1001002, 0, 1789715546)`.
- Market 2 = `(0, 0, 0, 0)`; its canonical trader positions remain empty.
- Net position size 0; positive-size and absolute negative-size totals 1,001,002 each.
- All basis/open-notional values and funding checkpoints unchanged.
- Both funding flags and six position flags remain set; six residual-debt flags remain unset.
- Six trader indexes remain `[1]`, index-plus-one 1, with unchanged exposure aggregates.
- Per-trader and aggregate residual bad debt remain zero.

Four **OWNER-context eth_call-only** probes returned the exact custom error
`MigrationAlreadySealed()` = **`0x836df086`**:

- `adminSeedMarketFunding` — exact expected error verified; no broadcast.
- `adminSeedPosition` — exact expected error verified; no broadcast.
- `adminSeedResidualBadDebt` — exact expected error verified; no broadcast.
- `sealMigration` — exact expected error verified; no broadcast.

These are the three seed entrypoints and a second seal. Generic revert failure
was not treated as sufficient. Their full call bytes and revert data are retained
in `postflight.json`. Only migration state/hash metadata changed.

## Non-interference, costs and cleanup

- PME_V2 and RISK_V2 still point to OLD_ENGINE.
- NEW_ENGINE Vault authorization, FMV2 consumer and Insurance backstop authorizations remain false.
- V1 and OLD_ENGINE Vault authorizations remain true.
- Clearing ledger remains **1,000,000,000 native mUSDC**.
- V1 remains frozen and its migration-relevant economics, nonces and canonical Vault balances are unchanged.
- OLD_ENGINE remains SEALED with canonical hash, OLD PMR pointer and unchanged economics.
- Six PME_V2 trader nonces remain unchanged at zero.
- NEW_ENGINE runtime remains **24,321 bytes**, byte-equal to the frozen artifact, Ethereum Keccak-256 `0xc0ac9015866a36d0c9c25920387af78cb59cc24f66170728ade1a835d1211a2a`.
- Backend runtime remains STOPPED; emission capability NONE; no backend process/8080 listener.
- No trade, seed, deployment, funding, token movement, shared-dependency rebind, Vault ACL, Safe/Timelock or DB/backend action occurred.

The bounded OWNER transaction audit over blocks **47491119–47491264**
finds exactly the seal hash above. The scoped all-topic event scan finds exactly
one seal event and no other event from the monitored emitters.

OWNER confirmed/pending nonce: **807/807 → 808/808**.
Safe nonce **15 → 15**; executor nonce **1 → 1**.
Public send invocations: **1**. No additional or unexplained OWNER transaction.

OWNER balance: **0.001707180795682353 → 0.001706833527156533 ETH**.
Gas used: **56883**; effective gas price: **6000000 wei/gas**.
Execution fees: **341298000000 wei**; settled L1 fee: **5970525820 wei**.
Total expenditure: **347268525820 wei = 0.00000034726852582 ETH**,
exactly equal to the OWNER balance decrease. No top-up or unexplained expenditure.

The temporary password file was removed after canonical seal verification and
independently verified absent during postflight. This is deletion, not a claim
of physical erasure. Canonical snapshot and historical/recovery replay files
remain byte-for-byte unchanged; their hashes are retained in the final evidence.

## Audit-tool comparison correction

The first independent postflight passed the live getter checks but stopped at
its before/after record comparison: 22 zero-argument function metadata values
were Python tuples in memory and JSON arrays in the saved baseline. This was
a representation mismatch, not a changed getter value. Only the argument
metadata was normalized to a list; no expected chain state or contract code
was changed. The full independent read-only postflight was then rerun and
passed. No additional transaction was sent. The diagnosis is retained in
`postflight_tool_reconciliation.json`.

## Validation and evidence

The offline receipt validator accepted one explicit test fixture and rejected
14 altered transaction/receipt/event cases before execution. The same cases were
persisted and rerun afterward: **2 unittest tests, 15 cases, all passed**. No Forge
or Cargo build or broad suite was required. Frozen production source is unchanged.

Evidence under `artifacts/perps_v2_migration_reseal/`:

- `canonical_receipt.json`.
- `execution_journal.json`.
- `execution_started.json`.
- `inclusion_refresh.json`.
- `postflight.json`.
- `postflight_tool_reconciliation.json`.
- `prebroadcast.json`.
- `preflight.json`.
- `settled_receipt.json`.
- `transaction_preview.json`.

All source/test additions are dedicated reseal operator helpers. No credentials,
keystore contents, private keys, passwords or transaction signatures are recorded.

Blockers: **none**. Normal commit/push records this verified result.

Exact next milestone: **PERPS_V2_BASE_SEPOLIA_V2_REBIND_V1**.
It has not been executed and requires separate authorization. Stop here.
