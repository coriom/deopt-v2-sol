# ONCHAIN_SUBACCOUNT_REPLAY_AND_EPOCH_FOUNDATION_V1

## Status

`IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL` — 2026-07-26. Product owner: Coriolan Morel.

Landed at `deopt-v2-sol` commit `816e288`
(`feat(subaccounts): add replay and epoch foundation`, +3055 lines,
12 files, from base `b6b2eb6`). Push: `b6b2eb6..816e288  main -> main`.

`EXPERIMENTAL — NOT SECURITY APPROVED`.

Not an audit sign-off. Not a security-reviewer sign-off. Not a deployment
approval. Not a production-readiness claim. Not authorized for Base
mainnet or real user funds. Independent human internal reviewer status
remains `PENDING_INTERNAL_REVIEWER_ACKNOWLEDGEMENT`. External audit
remains `PENDING_EXTERNAL_REVIEW`.

## Purpose

Freeze the canonical replay-protection and recovery-epoch foundation
consumed by every future DeOpt V2 matching engine (WP-08 Options, future
perps) and by the escape controller (WP-10). No engine or economic
execution behavior lands in this milestone.

## Authoritative sources

Precedence (highest first):

1. Product-owner authorization for
   `ONCHAIN-SUBACCOUNT-REPLAY-AND-EPOCH-FOUNDATION-V1` (2026-07-26) +
   its non-blocking conditions.
2. Tracked designs in `deopt-v2-sol/`:
   - `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
   - `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
   - `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md`
   - `ONCHAIN_SUBACCOUNT_REGISTRY_V1.md`
   - `ONCHAIN_SUBACCOUNT_CAPABILITY_CONTROLLER_V1.md`
   - `ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_A.md`
   - `ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_B.md`
   - `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md`
   - `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1.md`
   - `SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_V1.md`
   - `ONCHAIN_SUBACCOUNT_EXPERIMENTAL_IMPLEMENTATION_PLAN_V1.md`
3. Detailed contract specification:
   `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/` — especially
   `08_SIGNATURES_AND_REPLAY_SPEC.md`, `09_DELEGATION_AND_SMART_WALLETS.md`,
   `13_EVENTS_AND_RECONSTRUCTION.md`, `14_STATE_MACHINES.md`,
   `15_SOLIDITY_INTERFACES.md`, `16_ERRORS_AND_EVENTS_CATALOGUE.md`,
   `17_SECURITY_INVARIANT_MAPPING.md`, `18_TEST_SPECIFICATION.md`,
   `21_DECISION_REGISTER.md`.
4. Detailed experimental-implementation-plan package —
   `03_WORK_PACKAGES.md`, `04_DEPENDENCY_GRAPH.md`,
   `05_REPOSITORY_FILE_PLAN.md`, `08_THREAT_TO_WORK_PACKAGE_MATRIX.md`,
   `09_INVARIANT_TRACEABILITY.md`, `10_TEST_EXECUTION_STRATEGY.md`,
   `18_ORDERED_IMPLEMENTATION_MILESTONES.md`.
5. Validated WP-01, WP-02, WP-03, WP-04A, WP-04B implementations at
   `b6b2eb6`.
6. Current repository conventions.

## D.1 / D.2 boundary (frozen)

**D.1** = off-chain coordination or intent creation (order submission,
RFQ create/quote/accept/cancel, TWAP scheduling, API challenges). MAY
use bounded deadline + chain-side cancellation + persistent off-chain
replay state for API-level duplication. `RESTART_EMPTY` on backend DB
loss for actions with no economic effect.

**D.2** = canonical on-chain action consumption. MUST use durable
chain-side replay barrier that survives PostgreSQL loss.

This milestone implements only the D.2 foundation. Zero D.1 storage
lands in Solidity.

## Signed-domain decision (Part C verdict)

Verdict: `DEPLOYMENT_VERSION_IS_MANIFEST_ONLY_WITH_VERIFYING_CONTRACT_DOMAIN`.

Evidence:
- Spec 08 EIP-712 domain uses the four standard fields
  `{name, version, chainId, verifyingContract}`. No non-standard
  domain fields.
- Spec 08 typed struct examples (OptionOrder, PerpOrder,
  RfqAcceptance, MultiLegRfqAcceptance) bind
  `architectureVersion: uint256` in every payload — D-C-26 FROZEN.
- No spec 08 typed struct binds `deploymentVersion`.
- `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md` D-STI-09
  FROZEN: `deploymentVersion` is a per-deployment `uint256` immutable
  supplied at deploy time; NOT a compile-time global; belongs to
  manifests + migration events (`MigrationRootPublished.deploymentVersion`).
- Cross-deployment signature separation is provided by
  `verifyingContract` in the EIP-712 domain PLUS the deployment-scoped
  registry address encoded into `subKey`.
- The WP-05 plan-doc phrase "architectureVersion + deploymentVersion
  binding" is resolved by the higher-precedence FROZEN decisions to:
  architectureVersion goes into the signed payload; deploymentVersion
  goes only into the domain (implicitly via `verifyingContract`) plus
  manifests + events.

Consequence:
- `ARCHITECTURE_VERSION` (uint256) is bound in every signed envelope
  processed by `ReplayAndEpochController`.
- Deployment-version binding is achieved automatically by OZ EIP-712's
  cached domain separator (which mixes in `verifyingContract`).
- Two deployments of the same engine on the same chain produce
  distinct domain separators simply by being at distinct addresses.

## Replay model audit (Part D verdict)

Verdict: `REPLAY_STORAGE_MODEL_RESOLVED`.

| Concept | Canonical key | Storage owner | Sequential / Unordered | Mutation authority | Event | Reconstruction | Owning future engine | Implemented in WP-05? |
|---|---|---|---|---|---|---|---|---|
| Per-signer sequential nonce | `signer` | inheritor of `ReplayAndEpochController` (per-engine) | Sequential | `_consumeNonce(signer, expected)`; owner via `cancelNextNonce` / `cancelNoncesUpTo` | `NonceCancelled` | events + `nonces(signer)` view | WP-08 Options / future perps engine | YES (foundation) |
| Consumed intent hash | intent digest `bytes32` | inheritor | Unordered | `_consumeIntent(intentHash, signer, action)` — invoked by inheriting engine post-precondition, pre-external-call | `IntentConsumed` | events + `isIntentConsumed(intentHash)` view | WP-08 / future perps / WP-10 escape actions | YES |
| Per-subaccount recovery epoch | `subKey` | inheritor | Monotonic | owner via `advanceMySubaccountRecoveryEpoch`; authority via `_advanceSubaccountRecoveryEpoch` (WP-10) | `SubaccountRecoveryEpochAdvanced` | events + `subaccountRecoveryEpoch(subKey)` view | WP-10 escape controller | YES (owner path + internal primitive) |
| Owner-wide recovery epoch | `owner` | inheritor | Monotonic | owner via `advanceMyOwnerRecoveryEpoch`; authority via `_advanceOwnerRecoveryEpoch` (WP-10) | `OwnerRecoveryEpochAdvanced` | events + `ownerRecoveryEpoch(owner)` view | WP-10 escape controller | YES |
| Deadline | payload field | in signed struct only | N/A | validated on execution via `_requireDeadlineNotExpired` | N/A | derived from payload | product engines | YES (foundation helper) |
| `architectureVersion` | payload field + immutable | in signed struct + `ARCHITECTURE_VERSION` immutable | N/A | validated on execution via `_requireEnvelopeBindingValid` | derived from envelope | derived | product engines | YES |
| `engine` binding | payload field | in signed struct only | N/A | validated on execution vs `address(this)` | derived | derived | product engines | YES |
| D.1 coordination nonce | backend PK | Postgres — off-chain only | Sequential | backend service | N/A | N/A | backend | NO |
| Registry existence | `subKey` | Registry (WP-02) | Monotonic id per owner | owner via `registerNext`; capability-holder via `registerLazyDefault` | `SubaccountCreated` / `SubaccountLazyRegistered` | events + views | N/A | NO (already implemented) |
| Vault balance mutation | `(subKey, token)` | Vault (WP-04) | Debit/credit | owner / capability-holding engines | `Deposit` / `Withdraw` / `InternalTransfer` / etc. | events + views | N/A | NO |

WP-05 owns: rows 1–7 (sequential nonces, consumed intent hashes,
per-subaccount + owner-wide recovery epochs, deadline helper, envelope
binding validator, envelope digest primitive).

WP-05 does NOT own: signature recovery (ECDSA / ERC-1271), engine-
specific action execution, D.1 backend state, Registry / Vault
economic state, EscapeController state machine, fallback finalization.

## Implementation form

Abstract Solidity contract:

- `src/hybrid-v2/security/ReplayAndEpochController.sol` — abstract
  contract; inherits OpenZeppelin `EIP712` (v5.5.0) for the domain
  separator; introduces the four canonical storage mappings + owner-
  path externals + internal primitives.
- `src/hybrid-v2/security/IReplayAndEpochController.sol` — interface
  extending `IReplayProtected` (already frozen in WP-01) with the
  additional epoch views + owner-path mutations + events.
- `src/hybrid-v2/libraries/EIP712Types.sol` — canonical
  `SIGNED_ACTION_ENVELOPE_TYPE` string + precomputed
  `SIGNED_ACTION_ENVELOPE_TYPEHASH` constant.
- `src/hybrid-v2/libraries/IntentHash.sol` — `SignedActionEnvelope`
  struct + pure `hashEnvelope(...)` primitive.

Deployable production form: none. This milestone deploys nothing. The
abstract is inherited by concrete matching engines (WP-08 and later).
Tests exercise the abstract via a `test/hybrid-v2/security/harness/
ReplayAndEpochControllerHarness.sol` inheritor that adds a configurable
authority-driven epoch advance path so we can also verify the
integration point that WP-10 will use.

Not created:
- Any standalone `NonceOracle` or global replay contract whose
  compromise could authorize actions across unrelated engines.
- Any generic ambiguous `bytes` signing format without a frozen inner
  type hash — every envelope binds its 12 explicit fields.

## EIP-712 foundation

Domain (per spec 08, unchanged):

```
EIP712Domain = {
  string  name;              // set per inheriting engine
  string  version;           // "1" in V1
  uint256 chainId;           // block.chainid
  address verifyingContract; // this engine address
}
```

Envelope (per WP-05, frozen):

```solidity
struct SignedActionEnvelope {
    address owner;
    uint32  subaccountId;
    bytes32 subKey;
    address signer;
    address engine;
    bytes32 action;
    uint256 architectureVersion;
    uint256 nonce;
    uint256 deadline;
    uint256 ownerRecoveryEpoch;
    uint256 subaccountRecoveryEpoch;
    bytes32 payloadHash;
}
```

Type hash:

```
SignedActionEnvelope(
  address owner,uint32 subaccountId,bytes32 subKey,address signer,
  address engine,bytes32 action,uint256 architectureVersion,
  uint256 nonce,uint256 deadline,uint256 ownerRecoveryEpoch,
  uint256 subaccountRecoveryEpoch,bytes32 payloadHash
)
```

Digest computation:

```solidity
digest = _hashTypedDataV4(IntentHash.hashEnvelope(envelope));
```

Where `IntentHash.hashEnvelope` uses `abi.encode` (never
`abi.encodePacked`) so `bytes32` neighbours (`subKey`, `action`,
`payloadHash`) cannot collide across boundaries.

Product-specific fields (e.g. option order side + limit price)
compose into the envelope via `payloadHash`. Product engines compute
`payloadHash = keccak256(abi.encode(<their action struct>))` and pass
it in as a bound field.

## Signer / owner / engine / smart-wallet model

Distinctions preserved verbatim from spec 09:

- **Canonical owner** — `address` recorded in `SubaccountRegistry.
  ownerOf(subKey)`. May be an EOA, multisig, ERC-4337 smart account,
  or any contract that can sign / call.
- **Authorized signer** — declared in the envelope's `signer` field.
  MAY differ from `owner` when future delegation lands. WP-05 does
  NOT verify signer-vs-owner authorization; the inheriting engine
  performs that check plus ECDSA / ERC-1271 recovery.
- **Executing engine** — `address(this)`. Bound into the envelope
  under the `engine` field so the envelope is self-describing.
- **Smart-wallet controller** — invisible to DeOpt at the chain
  layer. Rotation is a wallet-level event and does not emit a DeOpt
  event. Any pre-rotation intent that still validates against the
  wallet's `isValidSignature` remains executable until its nonce is
  consumed or its deadline expires. Users invalidate stale intents
  via `cancelNoncesUpTo` (WP-05) OR by advancing a recovery epoch
  (WP-05).

WP-05 does NOT invent first-class delegation. The frozen
`DelegateRegistry` interface (spec 09) remains deferred to
`wallet-session-keys-v1`.

WP-05 replay storage does NOT depend on `ecrecover` output alone —
sequential nonces + intent-hash consumption live on the engine
regardless of whether the signature came from an EOA or a smart wallet.

## Durable D.2 action consumption

Hybrid model (spec 08 D-C-08 FROZEN):

- **Sequential per-signer nonce** — used by matching engines processing
  standard order execution (D.2). Consumed via `_consumeNonce(signer,
  expected)`. Owner-side cancellation via `cancelNextNonce` /
  `cancelNoncesUpTo`.
- **Consumed-intent hash** — used by D.2 actions that do NOT flow
  through a matching engine's per-signer nonce (delegate register /
  revoke, escape / recovery execution, future compound multi-leg
  intents). Consumed via `_consumeIntent(hash, signer, action)`.

Properties:

- An action can be consumed at most once. Duplicate `_consumeIntent`
  reverts `IntentReplayed`. Duplicate `_consumeNonce` reverts `BadNonce`.
- Consumption is O(1).
- No nonce rollback, no reset, no governance replay override.
- No off-chain database dependency.
- Consumed state is reconstructible from events (verified in
  `ReplayAndEpochControllerDbLoss.t.sol`).
- Namespaces isolated by engine address (via `verifyingContract` in
  domain + `engine` field in envelope), by signer (per-signer nonces),
  by action (`bytes32 action` in envelope), by subaccount (`subKey`
  in envelope).
- Failed downstream execution: consumption happens at the beginning of
  the executing engine's function body but the tx reverts atomically on
  any downstream failure, so consumption cannot outlive a failed
  execution.

Sibling subaccounts remain isolated: the engine's per-subaccount checks
(via `_requireEnvelopeBindingValid` computing the expected subKey +
`_requireEpochsFresh` checking the per-subaccount epoch) reject any
envelope that names a wrong `(owner, subaccountId)`.

## Nonce semantics

Where sequential nonces are consumed:

- **Nonce owner:** the `signer` address in the envelope.
- **Namespace composition:** `(engine == address(this), signer)`.
  Every engine has its own separate nonce space per signer.
- **Initial nonce:** `0`.
- **Expected nonce:** `_nextNonceOfSigner[signer]`.
- **Increment behavior:** `_consumeNonce(signer, expected)` requires
  `expected == _nextNonceOfSigner[signer]`; on match, increments by 1.
- **Cancellation:** `cancelNextNonce()` (owner path) increments by 1;
  `cancelNoncesUpTo(nextValid)` sets to `nextValid` if strictly
  greater than current, else reverts `NonceCancelNoOp`.
- **Overflow:** reverts `NonceOverflow` on attempt to advance past
  `type(uint256).max`.
- **Engine isolation:** each engine has its own `_nextNonceOfSigner`
  because each engine deploys its own inheritor of
  `ReplayAndEpochController`.
- **Signer isolation:** mapping keyed by `signer`.
- **Subaccount isolation:** nonces are per-signer, not per-subaccount
  (D-C-08 FROZEN); the envelope's `subKey` field enforces
  cross-subaccount separation via `_requireEnvelopeBindingValid`.

Prohibited:
- Arbitrary nonce decrement — no code path.
- Nonce reset to zero — no code path.
- Governance nonce rewrites — no admin.
- One engine consuming another engine's nonce — separate inheritors.
- Sibling-account nonce consumption — namespace enforced by
  `_requireEnvelopeBindingValid` + `_requireEpochsFresh`.

## Recovery epoch storage

Two independent monotonic scopes:

```
mapping(bytes32 => uint256) private _subaccountRecoveryEpoch;
mapping(address => uint256) private _ownerRecoveryEpoch;
```

Properties (frozen per P-1 + P-2 + escape design):

- Epochs are monotonic. Every `_advanceOwnerRecoveryEpoch` and
  `_advanceSubaccountRecoveryEpoch` increments by exactly 1.
- Epochs never decrement.
- Epochs never reset.
- Overflow reverts explicitly (`OwnerRecoveryEpochOverflow`,
  `SubaccountRecoveryEpochOverflow`).
- Per-subaccount epoch invalidates only the targeted subaccount.
- Owner-wide epoch invalidates every signed envelope binding the
  owner (via `_requireEpochsFresh` checking the current owner-wide
  epoch against the envelope's `ownerRecoveryEpoch`).
- Sibling owners are unaffected — mappings are keyed independently.
- Both epoch values are independently bound into every signed
  envelope (`ownerRecoveryEpoch`, `subaccountRecoveryEpoch`).
- Effective epoch is not computed as a single scalar. The pair is
  compared exactly; owner-wide staleness reverts
  `StaleOwnerRecoveryEpoch`; per-subaccount staleness reverts
  `StaleSubaccountRecoveryEpoch`.
- Events emit both previous + new values.

Zero PostgreSQL dependency. Epoch state lives on chain.

## Epoch mutation authority

WP-05 exposes two owner-facing externals (`msg.sender == owner`):

- `advanceMyOwnerRecoveryEpoch()`.
- `advanceMySubaccountRecoveryEpoch(uint32 subaccountId)` — requires
  `registry.existsOf(msg.sender, subaccountId) == true`.

WP-05 exposes two internal mutators:

- `_advanceOwnerRecoveryEpoch(address owner, address actor)`.
- `_advanceSubaccountRecoveryEpoch(bytes32 subKey, address owner,
  uint32 subaccountId, address actor)`.

WP-10 `EscapeController` will inherit `ReplayAndEpochController` and
expose its own authority-gated external functions that call these
internal primitives after verifying the objective on-chain conditions
for recovery activation.

Prohibited paths:

- Random third parties cannot advance epochs (verified in unit test
  `test_authorityAdvanceOwnerRecoveryEpoch_unauthorizedReverts` and
  the invariant `attemptUnauthorizedEpochAdvance` handler).
- An engine with an economic capability cannot invalidate user
  signatures — capability model is Vault-owned; WP-05 has no
  capability entrypoint.
- Governance is not automatically an owner-signature invalidator.

No broad mutable admin. No deployment cycle. WP-10 will bind the
concrete authority via its own inheritor; the deployment order is
Registry → Vault → matching engines (WP-08) inheriting the abstract
directly, then EscapeController (WP-10) inheriting a specialized
subclass — no circular reference required.

## Effective epoch validation

Every signed envelope binds BOTH epoch values readable + verifiable:

- `envelope.ownerRecoveryEpoch` (uint256).
- `envelope.subaccountRecoveryEpoch` (uint256).

Validation is exact equality:

```solidity
if (_ownerRecoveryEpoch[owner] != providedOwnerEpoch)
    revert StaleOwnerRecoveryEpoch(...);
if (_subaccountRecoveryEpoch[subKey] != providedSubaccountEpoch)
    revert StaleSubaccountRecoveryEpoch(...);
```

No `effectiveEpoch = owner + subaccount` compression — pairs
producing the same sum would collide, and overflow semantics would
be ambiguous.

Bounded views for signers building fresh envelopes:

- `ownerRecoveryEpoch(owner)` — current owner-wide epoch.
- `subaccountRecoveryEpoch(subKey)` — current per-subaccount epoch.
- `currentEpochPair(owner, subaccountId)` — returns both values in a
  single call.

## Deadline foundation

`_requireDeadlineNotExpired(uint256 deadline)`:

- Reverts `DeadlineExpired(deadline, block.timestamp)` when
  `deadline < block.timestamp`.
- Zero deadline is valid syntactically but ALWAYS expired at
  execution time (WP-05 does NOT invent a no-expiry sentinel).
- Comparison strictness: `<` (expired iff strictly before now).
- Boundary behavior: `deadline == block.timestamp` accepted.

## Events

- `IntentConsumed(bytes32 indexed intentHash, address indexed signer,
  address indexed engine, bytes32 action, uint16 eventVersion)`.
- `NonceCancelled(address indexed signer, uint256 previousNonce,
  uint256 newNonce, address actor, uint16 eventVersion)`.
- `SubaccountRecoveryEpochAdvanced(bytes32 indexed subKey, address
  indexed owner, uint32 subaccountId, uint256 previousEpoch, uint256
  newEpoch, address actor, uint16 eventVersion)`.
- `OwnerRecoveryEpochAdvanced(address indexed owner, uint256
  previousEpoch, uint256 newEpoch, address actor, uint16
  eventVersion)`.

Every event carries `eventVersion = Versions.EVENT_VERSION` (= 1).
Signer + engine + action are readable (not opaque hashes).
Signatures themselves are NEVER leaked into events.

## Errors

Precise custom errors:

- `InvalidRegistry()` — constructor arg was zero.
- `ZeroIntentHash()` — `_consumeIntent` called with `bytes32(0)`.
- `IntentReplayed(bytes32 intentHash)` — double-consume.
- `BadNonce(address signer, uint256 expected, uint256 provided)` —
  wrong sequential nonce.
- `NonceCancelNoOp(address signer, uint256 currentNextNonce, uint256
  provided)` — `cancelNoncesUpTo` target did not advance.
- `NonceOverflow(address signer, uint256 currentNextNonce)`.
- `SignerZero()` — zero signer at mutation site.
- `DeadlineExpired(uint256 deadline, uint256 blockTimestamp)`.
- `StaleOwnerRecoveryEpoch(address owner, uint256 currentEpoch,
  uint256 providedEpoch)`.
- `StaleSubaccountRecoveryEpoch(bytes32 subKey, uint256 currentEpoch,
  uint256 providedEpoch)`.
- `OwnerRecoveryEpochOverflow(address owner)`.
- `SubaccountRecoveryEpochOverflow(bytes32 subKey)`.
- `SubaccountNotFoundForOwner(address owner, uint32 subaccountId)`.
- `SubKeyMismatch(bytes32 expected, bytes32 provided)`.
- `InvalidEngineBinding(address expected, address provided)`.
- `InvalidArchitectureVersion(uint256 expected, uint256 provided)`.
- `InvalidSubaccountId()`.
- `InvalidOwnerAddress()`.
- `InvalidSubKey()`.

Selectors are distinct; no duplication with the WP-01 interface errors.

## Registry + Vault integration

Proved via `ReplayAndEpochControllerIntegration.t.sol` (9 tests):

- Registry-derived `subKey` matches `SubKey.deriveHere` — canonical
  source.
- Replay consumption never creates Registry accounts (nextId stable).
- Replay consumption never mutates Vault balances, physical custody,
  or `totalAccounted`.
- Epoch increments never mutate reservations
  (`lockedByEngine`, `totalLocked`).
- Vault capability changes never mutate replay state.
- Account 1 and Account 2 have isolated per-subaccount epoch
  namespaces.
- Owner-wide epoch invalidates BOTH accounts under the owner.
- Sibling owners unaffected.
- Smart-wallet-style owner identity remains stable across epoch
  advances.

## DB-loss reconstruction

Proved via `ReplayAndEpochControllerDbLoss.t.sol` (6 tests):

- Consumed intent remains consumed after simulated backend DB loss.
- Sequential nonce state persists after simulated backend DB loss.
- Consumed-intent set reconstructible from `IntentConsumed` events
  alone.
- Owner recovery epoch reconstructible from
  `OwnerRecoveryEpochAdvanced` events with monotonic previous/new pairs.
- Per-subaccount recovery epoch reconstructible from
  `SubaccountRecoveryEpochAdvanced` events.
- D.1 restart-empty (backend `used_nonces_v2` reseeded empty) cannot
  fabricate D.2 availability — the on-chain intent-hash + nonce
  barriers block the duplicate.

The DB-loss drill does NOT clear canonical contract storage. It models
the destruction of the backend cache only; chain state is authoritative
and untouched.

## Storage review

New mappings on `ReplayAndEpochController`:

- `mapping(address => uint256) private _nextNonceOfSigner`.
- `mapping(bytes32 => bool) private _consumedIntent`.
- `mapping(bytes32 => uint256) private _subaccountRecoveryEpoch`.
- `mapping(address => uint256) private _ownerRecoveryEpoch`.

New immutables:

- `address public immutable REGISTRY`.
- `uint256 public immutable ARCHITECTURE_VERSION`.

Verifications:

- No collision within inheritance — `ReplayAndEpochController` extends
  only OpenZeppelin `EIP712` (which uses its own immutables +
  fallback strings) plus `IReplayAndEpochController` (no storage).
- No duplicated Registry reference beyond this immutable.
- No duplicated architecture/deployment-version state —
  `ARCHITECTURE_VERSION` is bound only here.
- No off-chain cache represented as canonical storage.
- Nonce and intent-hash namespaces cannot collide — separate
  mappings on separate keys.
- Owner and subaccount epochs stored separately.
- No storage reset function.
- Future WP-08 engines can inherit or compose the abstract safely —
  the abstract only reserves the four private mappings + two
  immutables; inheritors add their own product storage without
  overlap.
- Future WP-10 EscapeController can advance epochs through the
  internal primitives without needing new storage.
- No proxy pattern.

## Tests + invariants

Test-suite summary (see focused / full results below):

- `test/hybrid-v2/security/ReplayAndEpochController.t.sol` — 56
  unit + fuzz tests (constructor, nonces, intent consumption, owner
  path, authority path, deadlines, envelope binding, epoch freshness,
  digest determinism + field separation, typehash cross-check).
- `test/hybrid-v2/security/ReplayAndEpochControllerDomain.t.sol` —
  12 cross-domain tests (domain separator changes across chainId +
  verifyingContract + name + version; digest changes across owner,
  subaccountId, signer, engine, chainId, domain version).
- `test/hybrid-v2/security/ReplayAndEpochControllerIntegration.t.sol` —
  9 Registry + Vault isolation tests.
- `test/hybrid-v2/security/ReplayAndEpochControllerDbLoss.t.sol` — 6
  DB-loss + event reconstruction tests.
- `test/hybrid-v2/security/ReplayAndEpochControllerInvariant.t.sol` —
  13 invariant tests covering REPLAY-I1 through REPLAY-I14 (with I3
  and I4 co-covered by `invariant_I3_I4_perSignerNonceMonotonic`).

Invariants:

- REPLAY-I1: consumed intents never become unconsumed.
- REPLAY-I2: same D.2 action cannot be consumed twice (ghost mirror
  matches chain).
- REPLAY-I3 + I4: engine + signer namespaces isolated (per-signer
  nonce ghost equals chain).
- REPLAY-I5: distinct subaccounts remain isolated
  (per-subaccount epoch ghost equals chain).
- REPLAY-I6: owner + subaccount recovery epochs monotonic (chain =
  ghost, ghost only ever increments by 1).
- REPLAY-I7: sibling subaccount independence.
- REPLAY-I8: owner-wide epoch invalidates every tracked subaccount
  for the owner (chain = ghost per-owner).
- REPLAY-I9: unauthorized caller cannot advance owner or subaccount
  epochs (attacker handler always reverts).
- REPLAY-I10: stale epoch pair never validates as current.
- REPLAY-I11: cross-chain / cross-verifyingContract digests separated
  (domain separator immutable for fixed chain + address).
- REPLAY-I12: replay + epoch mutations never alter Registry state.
- REPLAY-I13: event-derived ghost state matches canonical storage.
- REPLAY-I14: clearing off-chain ghost cannot make an on-chain-consumed
  action available again.

Each invariant runs at 64 × 64 = 4096 handler calls per invariant via
inline `forge-config: default.invariant.runs = 64` +
`forge-config: default.invariant.depth = 64` annotations.

## Gas / DoS

Development-only observations (see focused test output for exact gas
per operation):

- First action consumption: O(1) — one mapping write for the intent
  hash + one for the nonce.
- Duplicate consumption revert: O(1) — one mapping read.
- Sequential nonce consumption: O(1).
- Subaccount epoch advance: O(1).
- Owner epoch advance: O(1).
- Replay + epoch views: O(1).
- Digest computation: O(1).

Confirmed:

- Every storage mutation is O(1).
- No global nonce iteration.
- No owner-account iteration.
- No consumed-action enumeration on transaction paths.
- No signature-array loop (WP-05 does not process signatures).
- No unbounded cancellation loop — `cancelNoncesUpTo` is O(1) storage
  write.
- Callers pay gas.
- Storage growth is one bytes32 entry per consumed intent + one
  uint256 per new signer / subaccount / owner. Bounded per executed
  action.

No production gas cost claimed.

## Explicit non-goals (this milestone)

- No concrete matching engine (WP-08 Options / future perps).
- No engine consumption of the abstract primitives beyond the test
  harness.
- No collateral, position, fee, settlement, liquidation, or
  recovery-withdrawal state.
- No signature verification for product actions (ECDSA / ERC-1271
  recovery is inheriting engines' responsibility).
- No backend nonce persistence.
- No frontend signing integration.
- No database migrations.
- No EscapeController state machine (WP-10).
- No fallback finalization.
- No `DelegateRegistry` implementation.
- No changes to Registry, Vault, or capability model.
- No deployment scripts.
- No Base Sepolia deployment.

## Downstream ownership

| Deferred concept | Downstream milestone |
|---|---|
| Concrete matching engine consuming per-signer nonces | WP-08 |
| Concrete matching engine consuming intent hashes | WP-08 |
| Signer authorization + ECDSA / ERC-1271 recovery | WP-08 |
| EscapeController state machine + recovery-authority-driven epoch advance | WP-10 |
| Delegate + session-key model | `wallet-session-keys-v1` |
| Backend D.2 intent-hash tracker | WP-15 |

## Decision register (this milestone)

| ID | Decision | Status |
|---|---|---|
| D-REP-01 | Deployment-version binding: `MANIFEST_ONLY_WITH_VERIFYING_CONTRACT_DOMAIN` (D-STI-09 + D-C-26 upheld) | FROZEN |
| D-REP-02 | Envelope model: canonical `SignedActionEnvelope` with 12 explicit fields incl. both epoch scopes | FROZEN |
| D-REP-03 | Domain: standard 4-field EIP-712 domain via OpenZeppelin `EIP712`; per-engine `name` string | FROZEN |
| D-REP-04 | Nonce model: per-signer per-engine sequential nonces (D-C-08 upheld) | FROZEN |
| D-REP-05 | Intent-hash consumption: per-engine mapping populated via `_consumeIntent`; only zero-hash + duplicate rejected | FROZEN |
| D-REP-06 | Recovery-epoch storage: two independent mappings (`_subaccountRecoveryEpoch`, `_ownerRecoveryEpoch`); pair is checked, never sum-compressed | FROZEN |
| D-REP-07 | Epoch authority: owner path msg.sender-only; authority path via internal primitives inheritors gate | FROZEN |
| D-REP-08 | Deadline: strict `deadline >= block.timestamp`; no no-expiry sentinel; zero always expired | FROZEN |
| D-REP-09 | Abstract shape: single abstract `ReplayAndEpochController` inherits OZ `EIP712`; no separate global oracle | FROZEN |

None BLOCKING. None DEFERRED_WITH_OWNER at this milestone (downstream
owners already frozen above).

## No audit or production claim

Same disclaimer as every prior WP milestone. Not audited. Not security-
reviewed. Not authorized for real user funds.
