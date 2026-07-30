# `ONCHAIN-SUBACCOUNT-EVENT-SURFACE-AND-DEPLOYMENT-MANIFEST-V1`

**Work package**: WP-11 — Canonical event surface, reconstruction contract and
immutable deployment manifest.

**Status**: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`
**Safety posture**: `EXPERIMENTAL — NOT SECURITY APPROVED`
**Product owner**: Coriolan Morel
**Date**: 2026-07-30

> This milestone is EXPERIMENTAL. Do NOT deploy the manifest to Base
> mainnet; the on-chain constructor rejects `chainId == 8453` outright.
> Every code path listed here has passed the local `forge test` suite,
> but no external security review has been performed.

---

## 1 · Scope

Close the protocol-wide observability and deployment-wiring surface for
Hybrid V2:

1. one complete canonical event catalogue with unambiguous ownership;
2. deterministic correlation between cross-contract economic mutations;
3. full DB-loss reconstruction from chain events + manifest identity;
4. a machine-readable immutable deployment manifest;
5. deterministic module wiring + deployment ordering;
6. architecture / version / configuration compatibility proofs;
7. no omitted module, capability, protocol subaccount, or critical limit;
8. a stable boundary for backend indexing and future deployment prep.

**Explicit non-goals** (frozen):

- No deployment broadcast, no `cast send`, no `forge script --broadcast`.
- No Base mainnet authorization (rejected by manifest constructor).
- No backend / frontend changes; no DB migrations.
- No economic-behavior changes; no fee / risk / matching / recovery
  policy changes; no forced settlement or liquidation execution.
- No Perps implementation.
- No proxy pattern, no upgrade admin, no mutable authority in the manifest.
- No secret, RPC URL, or off-chain endpoint stored on-chain.
- No `ModuleReplaced` event: V1 core modules are IMMUTABLE per D-C-12.
  Module replacement, when specified in a later milestone, deploys a
  fresh manifest instance rather than mutating an existing one.

## 2 · Complete module inventory

| Slot | Module | Source | Canonical role | Immutable deps | Mutable authority |
|---:|---|---|---|---|---|
| 0 | `SubaccountRegistry` | `src/hybrid-v2/registry/SubaccountRegistry.sol` | Owner ↔ subaccount id ↔ subKey; deployment identity | `capabilityAuthority` (vault) | — |
| 1 | `CollateralVaultV2` | `src/hybrid-v2/vault/CollateralVaultV2.sol` (via `RiskAwareVaultHarness` for tests) | Custody, reservations, capability boundary, protocol subaccount custody | `REGISTRY`, `RISK_MODULE` | `governance`, `_guardian` |
| 2 | `OptionsPositionsLedger` | `src/hybrid-v2/positions/OptionsPositionsLedger.sol` | Canonical Options position state per (subKey, seriesId) | `REGISTRY`, `CAPABILITY_AUTHORITY` (vault) | — |
| 3 | `OptionsRiskModuleV2` | `src/hybrid-v2/risk/OptionsRiskModuleV2.sol` | Margin math, health / withdrawal / transfer allowance | `REGISTRY`, `VAULT`, `OPTIONS_LEDGER`, `RISK_PROVIDER`, `ORACLE`, `QUOTE_TOKEN` | `governance` (params) |
| 4 | `MarginEngineV2` | `src/hybrid-v2/margin/MarginEngineV2.sol` | Portfolio-walk margin orchestration (read-only) | `VAULT`, `RISK_MODULE`, `OPTIONS_LEDGER`, `RISK_PROVIDER`, `ORACLE`, `QUOTE_TOKEN` | — |
| 5 | `OptionMatchingEngineV2` | `src/hybrid-v2/options/OptionMatchingEngineV2.sol` | Atomic buyer/seller execution + reservation + fee/rebate composition | `VAULT`, `RISK_MODULE`, `OPTIONS_LEDGER`, `MARGIN_ENGINE`, `RISK_PROVIDER`, `QUOTE_TOKEN`, `FEE_HOOK` | `governance` (pause, future) |
| 6 | `EscapeControllerV1` | `src/hybrid-v2/recovery/EscapeControllerV1.sol` | Recovery state machine head + owner-controlled activation | `REGISTRY`, `GOVERNANCE`, `_recoveryFinalizer` (post-init) | `governance` (pause) |
| 7 | `RecoveryFinalizerV1` | `src/hybrid-v2/recovery/RecoveryFinalizerV1.sol` | Objective finalization + atomic canonical-universe withdrawal | `REGISTRY`, `VAULT`, `ESCAPE_CONTROLLER`, `POSITIONS_LEDGER` | — |
| 8 | Oracle adapter | external | Spot price feed | — | external |
| 9 | Options risk provider | external | Series + underlying risk config | — | external |
| 10 | Quote token | external | ERC-20 numeraire (USDC in V1) | — | — |
| 11 | FeesManager V2 | optional | Fee schedule authority (used by adapter) | — | governance |
| 12 | OptionExecutionFeeAdapterV2 | `src/hybrid-v2/fees/OptionExecutionFeeAdapterV2.sol` | Fee/rebate quote for the Options engine | vault, feesManager | governance |
| 13 | ProtocolTimelock | optional | Governance action scheduling | — | — |
| 14 | Governance | address only | Least-privilege setter caller | — | — |
| 15 | Guardian | address only | Emergency revocation caller | — | — |

**Version block** (frozen for V1): `architectureVersion = 1`,
`storageVersion = 1`, `eventVersion = 1`, `manifestSchemaVersion = 1`.

**Bounded constants**: `MAX_COLLATERAL_TOKENS = 8`,
`MAX_ACTIVE_SERIES_PER_SUBACCOUNT = 32`,
`ALL_CAPABILITIES = (1 << 16) - 1`, `HIGHEST_ASSIGNED_BIT = 15`.
Raising any of these requires a NEW deployment; there is no governance
setter.

## 3 · Event surface audit

Every canonical state mutation emits exactly one canonical event whose
data is sufficient to reconstruct + verify the mutation without a
database. Every event carries `uint16 eventVersion = 1` per D-C-13.
Ownership follows contract-spec/13 (see
`deployment-manifest/event-topics-v1.json` for the concrete topic-hash
snapshot):

| Owner | Events (canonical) |
|---|---|
| `SubaccountRegistry` | `SubaccountCreated`, `SubaccountLazyRegistered` |
| `CollateralVaultV2Core` | `Deposit`, `SupportedTokenAdded`, `SupportedTokenRemoved`, `CollateralTokenEnteredUniverse`, `ProtocolSubaccountsInitialized`, `EscapeControllerInitialized`, `RecoveryFinalizerInitialized` |
| `CollateralVaultV2` | `Withdraw`, `InternalTransfer`, `CollateralLocked`, `CollateralUnlocked`, `OptionPremiumTransferred`, `OptionFeeCharged`, `OptionRebatePaid`, `RecoveryFinalizationWithdrawn`, `PauseFlagChanged`, `OrphanedLockReleased`, `BadDebtSocialized` |
| `VaultCapabilityController` | `EngineCapabilityChanged`, `EngineGuardianRevoked`, `GuardianChanged` |
| `OptionsPositionsLedger` | `OptionPositionOpened`, `OptionPositionModified`, `OptionPositionClosed`, `OptionExercised`, `OptionSettled`, `OptionPositionLiquidated` |
| `OptionMatchingEngineV2` | `OptionOrderPairExecuted`, `OptionOrderFilled`, `OptionOrderCancelled`, `OptionSubaccountMinValidOrderNonceAdvanced` |
| `EscapeControllerV1` | `RecoveryRequested`, `RecoveryActivated`, `RecoveryCancelled`, `RecoveryEpochIncremented`, `RecoveryPauseSet` |
| `RecoveryFinalizerV1` | `RecoveryFinalized` (subKey, owner, subaccountId, epochAtFinalization, timestamp, tokensWithdrawn, caller, eventVersion) |
| `ReplayAndEpochController` | `IntentConsumed`, `NonceCancelled`, `OwnerRecoveryEpochAdvanced`, `SubaccountRecoveryEpochAdvanced` |
| `IRiskModule` (concrete) | `RiskParamsSet`, `RiskModuleActivated`, `LiquidationTriggered` |
| `DeploymentManifestV1` | `DeploymentManifestDeclared` |

**No additive corrections were needed.** WP-08B / WP-09 / WP-10 already
landed every canonical event required for reconstruction. The surface
was audited in Parts D–G and found complete and unambiguous; the only
new event this milestone introduces is `DeploymentManifestDeclared`,
emitted once at manifest construction.

**Superseding notes** (dated):

- 2026-07-30: `AuthorizedEngineSet(address,bool,uint16)` is retired.
  Capability-bit deltas are canonical via `EngineCapabilityChanged`;
  see contract-spec/16 for the retired listing that remains in the
  historical spec table for context.

## 4 · Canonical event ownership (unambiguous)

For every economic fact there is exactly one canonical owner:

| Fact | Canonical owner |
|---|---|
| Registry subaccount identity | `SubaccountRegistry` |
| Vault balance mutation | `CollateralVaultV2` (`Deposit`, `Withdraw`, `InternalTransfer`, `RecoveryFinalizationWithdrawn`) |
| Reservation delta | `CollateralLocked` / `CollateralUnlocked` |
| Options premium movement | `OptionPremiumTransferred` (vault-scope) — engine-scope re-emit **not permitted** |
| Options fee / rebate | `OptionFeeCharged` / `OptionRebatePaid` (vault) — the engine's `OptionOrderPairExecuted.buyerFee` / `.sellerFee` is a correlation aid, not the source of truth |
| Options position quantity | `OptionsPositionsLedger` (`OptionPositionOpened` / `Modified` / `Closed`) — the engine's `OptionOrderPairExecuted.filledQuantity1e8` is a per-execution slice, not the aggregate |
| Options execution economics | `OptionMatchingEngineV2.OptionOrderPairExecuted` (canonical execution ID) |
| Order lifecycle | `OptionMatchingEngineV2.OptionOrderFilled` / `OptionOrderCancelled` / `MinValidOrderNonceAdvanced` |
| Recovery state | `EscapeControllerV1` (`Requested`, `Activated`, `Cancelled`, `RecoveryFinalized` is the finalizer's) |
| Recovery epoch (owner + subaccount) | `EscapeControllerV1.RecoveryEpochIncremented` + `ReplayAndEpochController.OwnerRecoveryEpochAdvanced` / `SubaccountRecoveryEpochAdvanced` (post-finalization / invalidation) |

## 5 · Cross-contract correlation

An `executeMatch(...)` transaction produces one atomic bundle:

- Engine: `OptionOrderPairExecuted(executionId, buyerOrderId, sellerOrderId, ...)`
- Engine: `OptionOrderFilled(orderId, ...)` × 2 (one per side)
- Vault: `CollateralLocked` / `CollateralUnlocked` (engine reservations)
- Vault: `OptionPremiumTransferred(payer, receiver, token, amount, engine)`
- Vault: `OptionFeeCharged` / `OptionRebatePaid` (per side, when applicable)
- Ledger: `OptionPositionOpened` / `Modified` (per side)

The canonical **execution ID** binds them:

- `executionId` is deterministic (buyer + seller intent hashes bind it);
- indexed in the engine event; every other bundle event is either
  indexed by the same `orderId` / `subKey` (correlation from txhash +
  log ordering) or explicitly carries the actor `engine` address.

Failed transactions produce **zero** surviving events (whole tx reverts).

## 6 · Event / architecture / storage / deployment versioning

Frozen for V1 via `Versions.sol`:

- `EVENT_VERSION = 1` (bumped on schema change);
- `ARCHITECTURE_VERSION = 1` (bound in every EIP-712 payload);
- `STORAGE_VERSION = 1` (compatibility identifier for replaceable modules);
- `deploymentVersion` — per-deployment `uint256` immutable; passed at
  construction, bumped monotonically per (chainId, environment).

`eventVersion` is **never** included in signed order data (per D-C-13
rationale — event schema is an observability contract, not a signing
concern).

**ABI drift detector**: `test/hybrid-v2/deployment/EventTopicSnapshotV1.t.sol`
locks 40 canonical event topic hashes and 12 manifest error selectors
via inline `keccak256(bytes(sig))` assertions. Any accidental signature
mutation fails a test.

## 7 · Snapshots (machine-readable)

- `deployment-manifest/schema-v1.json` — JSON Schema for the manifest;
- `deployment-manifest/base-sepolia-template-v1.json` — placeholder-only
  template (chainId 84532, `activationStatus: NOT_DEPLOYED`);
- `deployment-manifest/event-topics-v1.json` — canonical event topic hashes;
- `deployment-manifest/error-selectors-v1.json` — manifest error selectors;
- `deployment-manifest/abi-surface-v1.json` — module → source / interface index.

No fake live-network addresses in any of these files; no secrets; no RPC.

## 8 · DB-loss reconstruction

`test/hybrid-v2/deployment/HybridV2DbLossReconstruction.t.sol` walks a
bounded protocol sequence (owner + subaccount creation, multi-token
deposits + depositFor + withdraw, recovery request / cancel / re-request)
under `vm.recordLogs`, discards the on-chain view snapshot, rebuilds the
canonical projections from the event stream **alone**, and asserts:

- reconstructed `balanceOf(subKey, token)` == `vault.balanceOf(...)` for
  every `(subKey, token)` touched;
- reconstructed `owner(subKey)` == `registry.ownerOf(subKey)`;
- reconstructed `subaccountId(subKey)` == `registry.subaccountIdOf(...)`;
- reconstructed collateral-universe additions match new-token entries;
- reconstructed recovery state matches `escape.recoveryStateOf(subKey)`.

`test_replayingSameEventsIsIdempotent` re-applies the same log stream
after clearing the projection and asserts convergence to the identical
value — idempotent replay per INV-REC / D-CR-07.

Not covered here (owned by module-scoped suites): Options fills / positions
(`OptionMatchingEngineV2Reconstruction.t.sol`); recovery finalization
(`RecoveryFinalizerV1.t.sol`); reservation / release
(`CollateralVaultV2Invariant.t.sol`).

## 9 · Reconstruction trust boundary

- **Event-reconstructible**: balances, positions, reservations, filled
  quantities, cancellations, min-valid nonces, capability grants /
  revocations, recovery epochs, protocol subaccount identities, escape
  states, finalizations.
- **Canonical-view-verifiable**: aggregates (`activeSeriesCount`,
  `collateralTokenCount`, `_totalAccounted`) — checked by the reconciler
  against reconstructed sums.
- **Manifest-provided immutable**: chain ID, module addresses, protocol
  subKeys, frozen bounds, canonical hashes, deployment block.
- **Derived projection**: `available = balance − locked` (not emitted;
  computed).
- **Intentionally unavailable on-chain**: RPC endpoints, DB URLs,
  operator keys, indexer cursor — not part of any protocol invariant.

**Reorg handling**: recorded per `13_EVENTS_AND_RECONSTRUCTION.md` §"Reorg
rollback". Provisional-tier rows may flip `is_reverted`; settled-tier rows
never revert. Backend responsibility, not manifest.

## 10 · Manifest model

`DeploymentManifestV1` at `src/hybrid-v2/deployment/DeploymentManifestV1.sol`.

- Deployed LAST, after every core module is live and every one-shot init
  (`initializeProtocolSubaccounts`, `initializeEscapeController`,
  `initializeRecoveryFinalizer`, `EscapeController.initializeRecoveryFinalizer`)
  has run.
- Core modules NEVER depend on the manifest — it observes the completed
  wiring, does not participate in it.
- No setter, no governance action, no upgrade path; every stored field
  is `immutable`.
- Any critical-field change requires a NEW manifest deployment (a
  distinct address + a distinct `MANIFEST_HASH`).

## 11 · Manifest content

- Chain identity: `CHAIN_ID`, `ENVIRONMENT_TAG`, `DEPLOYMENT_VERSION`,
  `MANIFEST_SCHEMA_VERSION`, `DEPLOYMENT_BLOCK`, `DEPLOYMENT_TIMESTAMP`,
  `DEPLOYER`.
- Version block: `ARCHITECTURE_VERSION`, `STORAGE_VERSION`, `EVENT_VERSION`.
- Core module addresses: 8 required + 3 external + 5 optional = 16 slots.
- Protocol identities: `PROTOCOL_FEE_SUBKEY`, `REBATE_BUDGET_SUBKEY`,
  `INSURANCE_FUND_SUBKEY` (snapshotted from `vault.*SubKey()` views).
- Frozen bounds: `MAX_COLLATERAL_TOKENS_SNAPSHOT = 8`,
  `MAX_ACTIVE_SERIES_PER_SUBACCOUNT_SNAPSHOT = 32`,
  `ALL_CAPABILITIES_SNAPSHOT`, `RECOVERY_ACTIVATION_DELAY_SECONDS`,
  `RECOVERY_PAUSE_MAX_DURATION_BLOCKS`.
- Canonical hashes: `MODULE_ADDRESSES_HASH`, `CRITICAL_CONFIG_HASH`,
  `MANIFEST_HASH`.
- Event: `DeploymentManifestDeclared(...)` emitted once at construction.

No RPC URL, no private key, no signature, no mutable authority stored.

## 12 · Manifest hashing

Three canonical hashes, each `abi.encode` (never packed) with an
explicit type tag as the first argument:

- `MODULE_ADDRESSES_HASH = keccak256(abi.encode(MODULE_ADDRESSES_TYPE_HASH, /* 16 addresses */))`
- `CRITICAL_CONFIG_HASH = keccak256(abi.encode(CRITICAL_CONFIG_TYPE_HASH, chainId, arch, storage, event, deploymentVersion, schemaVersion, protoFeeSK, rebateSK, insuranceSK, maxTokens, maxSeries, allCaps, recoveryDelay, recoveryPauseMax))`
- `MANIFEST_HASH = keccak256(abi.encode(MANIFEST_TYPE_HASH, environmentTag, MODULE_ADDRESSES_HASH, CRITICAL_CONFIG_HASH, deploymentBlock, deploymentTimestamp))`

- Deterministic: recompute via `recomputeManifestHash()` — every unit
  test asserts equality with the stored `MANIFEST_HASH`.
- Any critical-field mutation flips the hash (asserted in
  `test_hash_changesWhen*`).
- No user-supplied hash accepted — the manifest computes and freezes
  its own.

## 13 · Wiring validation

At construction, the manifest calls every module's public immutable
getter and asserts:

- `Registry.capabilityAuthority == Vault`;
- `Registry.deploymentChainId == block.chainid`;
- `Vault.protocolSubaccountsInitialized() && escapeControllerInitialized() && recoveryFinalizerInitialized()`;
- `Vault.escapeController() == params.escapeController`;
- `Vault.recoveryFinalizer() == params.recoveryFinalizer`;
- `Vault.maxCollateralTokens() == 8`;
- `Vault.protocolFeeVaultSubKey() != 0` and same for rebate + insurance;
- `Ledger.REGISTRY == Registry && Ledger.CAPABILITY_AUTHORITY == Vault`;
- `Ledger.maxActiveSeriesPerSubaccount() == 32`;
- OptionsRiskModuleV2: `REGISTRY / VAULT / OPTIONS_LEDGER / RISK_PROVIDER / ORACLE / QUOTE_TOKEN / ARCHITECTURE_VERSION / SUPPORTED_STORAGE_VERSION` all match;
- MarginEngineV2: `REGISTRY / OPTIONS_LEDGER / RISK_PROVIDER / ORACLE / QUOTE_TOKEN / vault() / riskModule()` all match;
- OptionMatchingEngineV2: `VAULT / RISK_MODULE / OPTIONS_LEDGER / MARGIN_ENGINE / RISK_PROVIDER / QUOTE_TOKEN` all match;
- EscapeController: `REGISTRY / recoveryFinalizer()` match;
- RecoveryFinalizer: `REGISTRY / VAULT / ESCAPE_CONTROLLER / POSITIONS_LEDGER` match.

Duplicate required-module addresses are also rejected.

## 14 · Deployment graph

Directed acyclic. Cycles resolved via `vm.computeCreateAddress` in tests
and by predicted-address deployment in production scripts.

```
    ┌───────────────────────────────────────────────────────────────┐
    │                    OptionsRiskModuleV2 (0)                     │
    │  needs predicted: Vault, Registry, Ledger                      │
    └──┬────────────────────────────────────────────────────────────┘
       │
       ▼
    CollateralVaultV2 (1)   needs predicted Registry
       │
       ▼
    SubaccountRegistry (2)  binds capabilityAuthority = Vault
       │
       ▼
    OptionsPositionsLedger (3)   binds Registry + Vault
       │
       ▼
    EscapeControllerV1 (4)   binds Registry + governance
       │
       ▼
    RecoveryFinalizerV1 (5)  binds Registry + Vault + Escape + Ledger
       │
       ▼
    MarginEngineV2 (6)       binds Vault (reads RiskModule via Vault)
       │
       ▼
    OptionMatchingEngineV2 (7)  binds Vault + Margin + FeeHook + gov/guardian
       │
       ▼
    Governance initialisation (async, non-cyclic):
       - vault.addSupportedToken(usdc)
       - vault.initializeProtocolSubaccounts(...)
       - vault.initializeEscapeController(escape)
       - vault.initializeRecoveryFinalizer(finalizer)
       - escape.initializeRecoveryFinalizer(finalizer)
       │
       ▼
    DeploymentManifestV1 (8) — reads every wire, freezes, emits `DeploymentManifestDeclared`.
```

No proxy. No post-deploy setter on the manifest. Only approved
techniques (deterministic address prediction, one-shot immutable
binding, post-deployment manifest validation).

## 15 · Base Sepolia safety

- Base mainnet (chainId 8453) is forbidden — constructor reverts with
  `BaseMainnetForbidden(8453)`. Unit-proven.
- Base Sepolia (84532) is accepted (unit-proven via `vm.chainId(84532)`).
- Template file states `activationStatus: NOT_DEPLOYED` and carries
  zero-address placeholders throughout.
- No broadcast command in this milestone; no private key; no RPC URL;
  no transaction preparation requiring secrets.

## 16 · Tests + invariants

**Total suites landing in this milestone**: 4 (unit, invariants,
reconstruction, snapshot).

- `test/hybrid-v2/deployment/DeploymentManifestV1.t.sol` — 34 unit +
  1 fuzz (`testFuzz_recomputeMatchesStored`) covering happy path,
  every wiring mismatch, every required / optional address rule, hash
  determinism + differentiation, view surface.
- `test/hybrid-v2/deployment/DeploymentManifestV1Invariant.t.sol` — 5
  invariants (`MANIFEST-I1`, `I3`, `I4`, `I6`, and `I2` via a fuzz
  handler).
- `test/hybrid-v2/deployment/HybridV2DbLossReconstruction.t.sol` — 2
  reconstruction tests (canonical sequence + idempotent replay).
- `test/hybrid-v2/deployment/EventTopicSnapshotV1.t.sol` — 9 snapshot
  tests locking 40 event topics + 12 error selectors.

`MANIFEST-I5` (Base mainnet forbidden) is structural — proven by the
dedicated unit test `test_construction_rejectsBaseMainnet`.

## 17 · Gas + DoS

- Manifest construction: bounded by 16 external `view` calls at
  construction, no loops beyond the O(16²/2) duplicate check. Well
  below any block gas concern.
- Manifest `moduleAddresses()` returns a fixed 16-element array — O(1)
  bound.
- No unbounded module array anywhere.
- No historical-event iteration on-chain (reconstruction is off-chain).
- No global account or position enumeration added.

## 18 · Storage review

`DeploymentManifestV1` uses **immutables only** for every field except
the deployer-set `ManifestParams` (calldata-only, never stored). No
mappings, no arrays in storage, no ownership state, no setter.
Attempted mutation would require deploying a different contract — the
manifest instance is immutable identity.

## 19 · Deviations / blockers

- None material. The `AuthorizedEngineSet` legacy event listed in
  contract-spec/13 has been superseded by `EngineCapabilityChanged`
  (see D-C-12); the WP-11 catalogue reflects the current unambiguous
  event set.
- `test_reconstructsCanonicalStateFromEventsAlone` intentionally omits
  `internalTransfer` — the risk module's transfer-safety hook is
  exercised in the vault suite and is orthogonal to the reconstruction
  contract.
- Governance / guardian slots accept EOAs (per common multisig
  practice). Optional contract slots (`ProtocolTimelock`,
  `FeesManagerV2`, `OptionExecutionFeeAdapter`) require code when
  non-zero.

## 20 · Exact next milestone

`ONCHAIN-SUBACCOUNT-GLOBAL-INVARIANT-SUITE-V1`, subject to product-owner
authorization.
