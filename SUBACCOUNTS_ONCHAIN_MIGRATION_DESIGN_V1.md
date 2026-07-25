# SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_V1

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
- `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1.md`

## Purpose

Freeze the migration, deployment cutover, versioning and legacy
sunset posture for DeOpt V2 on-chain economic subaccounts. Covers
two contexts:

1. **Immediate V1 development migration** — Base Sepolia; no
   production users; disposable testnet state.
2. **Future production-grade migrations** — real user funds;
   reconstructible + idempotent + independently verifiable
   cutovers.

Authorizes the docs-only
`ONCHAIN-SUBACCOUNT-EXPERIMENTAL-IMPLEMENTATION-PLAN-V1`
milestone.

## Immediate Base Sepolia posture

**M1 — Fresh deployment, no state import.** Approved by product
owner on 2026-07-24
(`APPROVE_FRESH_BASE_SEPOLIA_SUBACCOUNT_DEPLOYMENT`).

- No production users; testnet state disposable.
- PostgreSQL Account 2+ identities NOT canonical; discarded.
- Address-level state drainable by user via chain-direct calls.
- Users re-register test subaccounts in V2 registry.
- V1 contracts sunset after 30-day grace period.
- V1 signatures naturally rejected by V2 (different
  `verifyingContract`).

No `IMigrationBridge` deployed in V1.

## Legacy-state classification

- **Canonical address-level economic state** on V1 Base Sepolia:
  operator + test-wallet balances only; no real user funds to
  protect.
- **PostgreSQL Account 1**: metadata; discarded.
- **PostgreSQL Account 2+**: metadata; discarded per D-MIG-05.
- **D.1 open coordination** (orders, RFQs, TWAP): RESTART_EMPTY.
- **D.2 replay barriers**: fresh in new deployment.
- **Governance / module state**: rewired for V2.

## Future production migration strategy family

**M5+M6 hybrid**: Snapshot + Merkle claim (I2) + permissionless
keeper (I3) + fallback M6 user-authorized (I4). Rejected:
M3/M4 auto-import; M7 dual-live spending; M1-alone for real
users.

## Migration state machine

`SM-Mig` with 11 states: `UNANNOUNCED, ANNOUNCED, PREPARING,
SOURCE_FROZEN, SNAPSHOT_FINALIZED, CLAIM_OR_IMPORT_OPEN,
DESTINATION_ACTIVE, SOURCE_WITHDRAW_ONLY, CUTOVER_COMPLETE,
ABORTED, SUPERSEDED`.

All transitions timelocked per D-MIG-14. No transition creates
simultaneous spendability. Guardian veto + Path A reversal
available before `DESTINATION_ACTIVE`.

## Source freeze + spend-disable proof

Composite freeze (D-MIG-01): F2 engine capability revocation +
F3 vault withdrawal-only mode + F4 per-account migration lock +
F6 domain / version invalidation + F8 source contract sunset.

Every destination credit REQUIRES chain-side proof that source
entitlement is disabled (INV-MIG-05).

Freeze MUST NOT block escape / recovery (INV-OPS-05).

## Snapshot + import model

Deterministic snapshot block + block hash + Merkle root
published on chain via `MigrationRootPublished`. Duplicate-import
protection via `migrationClaimed[sourceSubKey]`. Amount
reconciliation post-window.

Primary import: I2 Merkle claim. Supplementary: I3 permissionless
keeper. Fallback: I4 user-authorized migration.

REJECTED: I1 direct governance batch (D-MIG-03).

## Signature versioning

Automatic domain separation via `verifyingContract` +
`architectureVersion` (INV-MIG-07). Fresh nonce + intent-hash
space in each deployment. RESTART_EMPTY coordination state
(D-MIG-10). No cross-domain signature execution possible.

## Recovery interaction

Compatible with `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1`:

- Recovery remains available at source before F4 lock.
- Recovery state imported to destination per snapshot.
- Recovery epoch monotone across migration (D-MIG-13).
- Migration does not shortcut liquidation.
- Duplicate spend impossible even with escape mid-migration.

## Reconstruction interaction

Compatible with `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1`:

- Two projection namespaces per `deployment_version` (D-MIG-11).
- `migration_mappings` projection.
- Multi-manifest reconstruction during grace.
- No private DB mapping required (D-MIG-12).
- Historical continuity preserved.

## Governance

Every state transition timelocked. Destination activation
requires ≥ 48h timelock + public announcement + user exit
window. Bounded emergency powers (guardian can abort + pause;
cannot rewrite balances, reassign owner, or force-migrate).

## Failure handling

16 failure scenarios (MIG-F01..MIG-F16) all prevented OR
recoverable via design primitives. No scenario reaches
UNRECOVERABLE_WITHOUT_BACKUP.

## Future production blueprint

14-phase blueprint (P0..P13). Rehearsal-first (D-MIG-16
FROZEN). Timeline ~4-6 months for full production migration.
External audit REQUIRED before first production migration
(D-MIG-30).

## Test gates

- **`GATE-EXPERIMENTAL-IMPLEMENTATION`**: M-P-1..M-P-9 property
  tests; core scenarios T-1, T-3, T-7, T-19 pass.
- **`GATE-CLOSED-TEST`** (only for future bridge implementation):
  all T-1..T-20.
- **`GATE-PUBLIC-TESTNET`** (only for future bridge
  implementation): live rehearsal drill + abort rehearsal +
  operator succession rehearsal; INV-MIG-05..08 automated;
  AT-38..41 drills documented + tested.
- **`GATE-MAINNET`**: external audit + published migration
  playbook + full drill on production configuration.

## New invariants approved

- **INV-MIG-05** source-destination spend-disable ordering.
- **INV-MIG-06** migration idempotency + duplicate rejection.
- **INV-MIG-07** cross-domain signature separation.
- **INV-MIG-08** DB-only metadata cannot create economic state.

Total invariant count: 66 → **70**.

## New drills

- **AT-38** dual-spend prevention drill.
- **AT-39** duplicate-claim rejection drill.
- **AT-40** cross-domain signature separation drill.
- **AT-41** DB-only metadata rejection drill.

## Deferred implementation

- `IMigrationBridge` contract (future production migration
  milestone).
- `IMigrationSourceAdapter` on source (future).
- Snapshot generator + Merkle root generator (future).
- Claim CLI + frontend claim flow (future).
- Backend migration-status API + multi-manifest indexer support
  (future).
- Concrete parameter values (per `SECURITY-REVIEW-PREP`).

## Companion detailed documentation

Local detailed package (24 files):
`docs/onchain-subaccounts-v1/migration-design/` — in the
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
