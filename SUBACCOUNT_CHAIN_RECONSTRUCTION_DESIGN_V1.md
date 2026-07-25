# SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1

## Status

**DESIGN COMPLETE** — 2026-07-24. Product owner: Coriolan Morel.

Not an audit sign-off. Not an implementation approval. Not a
production-readiness claim. Independent human security reviewer
status remains **PENDING**. External audit remains mandatory for
real funds and public rollout.

Companion documents:

- `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
- `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
- `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md`
- `SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_V1.md`

Migration interaction (added 2026-07-24 by
`SUBACCOUNTS-ONCHAIN-MIGRATION-DESIGN-V1`): the migration design
consumes the reserved event interface + multi-manifest
reconstruction rules from this document. Reconstruction across a
migration boundary uses namespaced projections per
`deployment_version` per D-MIG-11. `migration_mappings`
projection joins source and destination via
`SubaccountMigrationRegistered` + `MigrationClaimed` events. No
private operator DB mapping required (D-MIG-12).

## Purpose

Freeze the deterministic, reorg-safe, version-aware
chain-reconstruction system for DeOpt V2 economic subaccounts. Prove
that after total loss or corruption of PostgreSQL / backend /
indexer state / caches / frontend, DeOpt rebuilds every canonical
economic entitlement from known deployment metadata + contract
state + canonical chain logs + versioned migration metadata +
network finality policy. Authorizes the docs-only
`SUBACCOUNTS-ONCHAIN-MIGRATION-DESIGN-V1` milestone.

## Product-owner approval recorded

- Approval date: 2026-07-24.
- Approves the escape-hatch design (retroactively formalized)
  and integrates three new invariants:
  - **INV-ESC-07** recovery activation idempotency.
  - **INV-REC-07** recovery epochs survive reorg beyond
    `min_confirmation_depth`.
  - **INV-OPS-07** recovery pause hard-cap.
- Invariant count: **63 → 66**.

## Canonical source hierarchy

7-tier hierarchy freezes precedence:

1. Current canonical contract state.
2. Finalized canonical chain logs.
3. Versioned deployment + migration metadata (manifest).
4. Reconstructed DB projections.
5. Provisional event projections.
6. Off-chain coordination state.
7. Frontend / cache state.

Contract state wins conflicts. Coordination state (D.1) is
NEVER economic truth. Frontend / cache state is NEVER economic
truth.

## Deployment manifest

Public, git-tracked, signed JSON manifest per
`docs/onchain-subaccounts-v1/chain-reconstruction/04`:

- Chain, environment, architecture / deployment versions.
- All contract addresses + code hashes + ABI hashes.
- Event schema versions + history.
- Confirmation policy (per environment).
- Predecessor / successor for migration composability.
- Optional on-chain manifest-hash publication for public
  testnet+.

## Raw event journal

Immutable per-log raw bytes storage. Decoded columns re-decodable
via decoder registry. Retention: FOREVER for dev/testnet, ≥ 5
years for public+. Journal-only reconstruction MUST work.

## Event identity

`(chainId, blockHash, transactionHash, logIndex)` frozen as
canonical event identity. Provisional vs canonical distinguished
via block hash. DB secondary key
`(chainId, contract, txHash, logIndex)` for ergonomic filtering.

## Finality / reorg policy (INV-REC-06 alignment)

- Event lifecycle: 6 states
  (`OBSERVED, PROVISIONAL, CONFIRMED, SETTLED_INDEXED, ORPHANED,
  SUPERSEDED`).
- `min_confirmation_depth` is environment-defined (INV-REC-06);
  Base Sepolia dev default proposed 20 blocks.
- Public testnet + mainnet values deferred to
  `SECURITY-REVIEW-PREP`.
- Deterministic reorg algorithm: parent-hash check + common
  ancestor + orphan-mark + projection rollback.
- Deep reorg (> depth) triggers `CriticalReorgAlert` +
  readiness `DEGRADED_READ_ONLY`.

## Empty-DB reconstruction (6 phases)

- **Phase 0** manifest validation (chain id + codehash +
  event schema).
- **Phase 1** raw log ingestion (bounded ranges, block-hash
  verification, multi-provider).
- **Phase 2** decode + version routing (per manifest schema
  history).
- **Phase 3** canonical projection (build every projection per
  `chain-reconstruction/09`).
- **Phase 4** state validation (chain views vs projection
  samples; 100% for CRITICAL).
- **Phase 5** reconciliation (auto-repair loop; fail closed on
  divergence).
- **Phase 6** API promotion (readiness gate flip to
  `READY_SETTLED`).

Every phase idempotent. Re-running from block 0 twice produces
byte-identical projections.

## State validation

Contract views are the validation authority. No on-chain state
commitments required in V1 (**D-CR-07 FROZEN
`NOT_REQUIRED_V1`**); `OPTIONAL_OPERATOR_OPTIMIZATION` for
public testnet; mainnet revisit with external audit input.

## Replay / security reconstruction

- D.2 replay state (matching-engine nonces, intent hashes,
  recovery epochs, delegate revocations) fully reconstructible
  from chain.
- D.1 coordination state RESTART_EMPTY safe; chain-side
  barriers (deadline + `cancelNoncesUpTo` + `recoveryEpoch`)
  hold regardless.
- Rebuilt backend MUST NEVER treat a previously consumed D.2
  action as unused.

## Recovery reconstruction

Full escape-hatch lifecycle rebuild from `IEscapeController` +
`IRecoveryFinalizer` events. Distinguishes active vs completed
vs reorged vs owner-wide vs per-subaccount. Alignment:
`RECOVERY_ACTIVATION_DELAY > min_confirmation_depth`.

## Governance / module history

`effective_module_history` per contract slot + block enables
time-travel decoding of legacy events + correct authorization
reconstruction. Timelock queue / execute / cancel + guardian
actions tracked. Pause hard-cap verified per INV-OPS-07.

## Migration-aware boundaries

Frozen inputs for `SUBACCOUNTS-ONCHAIN-MIGRATION-DESIGN-V1`:

- 6 required migration events reserved
  (`MigrationCutoverInitiated`, `MigrationSourceSpendDisabled`,
  `MigrationMapped`, `MigrationCredited`, `MigrationCompleted`,
  `MigrationAbandoned`).
- Multi-manifest reconstruction rules.
- `migration_mappings` projection.
- Duplicate-import rejection.
- Source spend-disable proof.
- Fresh Base Sepolia deployment for V1 (no migration).

## Readiness model

5-state readiness gate: `NOT_READY, RECONSTRUCTING,
RECONCILING, DEGRADED_READ_ONLY, READY_SETTLED`. Mutation paths
fail closed when not `READY_SETTLED`. Chain-direct paths
(deposit / withdraw / escapeWithdraw / activateRecovery) ALWAYS
available regardless of backend readiness.

## Disaster drills

15 disaster scenarios (DR-01..DR-15) covered. All reach at
worst `DEGRADED_BUT_RECOVERABLE`; no scenario reaches
`UNRECOVERABLE_WITHOUT_BACKUP` given RPC archive availability.

## No claim of implementation or production readiness

This design is a docs-only decision. It does not claim:

- audit sign-off;
- security-reviewer sign-off;
- implementation approval;
- deployment approval;
- production readiness;
- suitability for real user funds.

## Machine-checkable properties (frozen)

- **R-P-1** deterministic replay.
- **R-P-2** idempotent ingest.
- **R-P-3** chain-view convergence.
- **R-P-4** reorg rollback correctness.
- **R-P-5** solvency invariant preserved.
- **R-P-6** recovery epoch monotone.
- **R-P-7** no D.2 replay possible.
- **R-P-8** coordination isolation from D.2.
- **R-P-9** governance history determinism.

## Test gates

- **`GATE-EXPERIMENTAL-IMPLEMENTATION` merge:** R-P-1..R-P-9
  pass; core scenarios T-1, T-2, T-3, T-6, T-7, T-15, T-19,
  T-21 pass.
- **`GATE-CLOSED-TEST`:** all T-1..T-22 + reorg drill.
- **`GATE-PUBLIC-TESTNET`:** live reconstruction drill on Base
  Sepolia + operator succession drill + AT-35 + AT-36 + AT-37.
- **`GATE-MAINNET`:** external audit of pipeline + drills on
  production configuration + published runbook.

## Deferred implementation

- Backend implementation modules (ingestor, decoder, projection
  builder, reorg manager, validator, readiness gate,
  reconciliation worker).
- `reconstruct` CLI binary.
- Database schema migrations.
- Frontend `settlement_tier` + `readiness_state` exposure.
- Concrete parameter values (`min_confirmation_depth` per
  network, retention, timeouts).

Deferred to future implementation milestone.

## Companion detailed documentation

Local detailed package (24 files):
`docs/onchain-subaccounts-v1/chain-reconstruction/` — in the
companion documentation repository, not tracked in this
Solidity repository beyond this file.

## No audit or production claim

This design does not claim:

- audit sign-off;
- security-reviewer sign-off;
- implementation approval;
- deployment approval;
- production readiness;
- suitability for real user funds.
