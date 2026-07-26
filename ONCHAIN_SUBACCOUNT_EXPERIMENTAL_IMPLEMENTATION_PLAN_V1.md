# ONCHAIN_SUBACCOUNT_EXPERIMENTAL_IMPLEMENTATION_PLAN_V1

## Status

**DESIGN COMPLETE — DOCS ONLY** — 2026-07-25. Product owner: Coriolan Morel.

`PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS` (2026-07-25). Only
the first implementation milestone
`ONCHAIN-SUBACCOUNT-SHARED-TYPES-AND-INTERFACES-V1` is launched by this
authorization. Every subsequent milestone requires its own separate
authorization. Base Sepolia + local dev only. No mainnet. No real user
funds. No production, public-testnet, or security-readiness claim. Perps
V2 remains out of scope. Human internal reviewer + external audit remain
mandatory at their later release gates.

Not an audit sign-off. Not an implementation approval. Not a
deployment approval. Not a production-readiness claim. Not a
security-review sign-off. Independent human internal reviewer status
remains **PENDING**. External audit remains mandatory for real funds
and public rollout.

Companion documents:

- `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
- `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
- `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md`
- `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1.md`
- `SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_V1.md`

## Purpose

Freeze the docs-only, dependency-ordered, threat-driven experimental
implementation plan for DeOpt V2 on-chain economic subaccounts.
Consolidate 5 approved designs into 20 bounded work packages
distributed across the Solidity, backend, and frontend repositories.
Authorize (upon separate product-owner sign-off) the launch of the
first implementation milestone
`ONCHAIN-SUBACCOUNT-SHARED-TYPES-AND-INTERFACES-V1`.

## Prerequisites (all previously satisfied)

- Architecture: `ARCHITECTURE_D_HYBRID_APPROVED_WITH_CLARIFICATIONS`.
- Contract spec: `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_COMPLETE`.
- Escape hatch: `SUBACCOUNT_ESCAPE_HATCH_DESIGN_COMPLETE`.
- Chain reconstruction: `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_COMPLETE`.
- Migration: `SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_COMPLETE`.
- Immediate deployment posture: `FRESH_BASE_SEPOLIA_DEPLOYMENT_APPROVED`.
- Normative invariant count: **70** (all owned).
- Foundational blocking decisions: **0**.

## Prerequisite remaining

- Explicit product-owner experimental-implementation approval per the
  Product-Owner Review Packet
  (`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/20_PRODUCT_OWNER_REVIEW_PACKET.md`).

## Architecture being implemented

Option D hybrid: on-chain economic subaccounts with external identity
`(owner, subaccountId: uint32)` + internal
`subKey = keccak256(chainid, registry, owner, subaccountId)`; fresh
canonical modules (Registry, CollateralVaultV2, OptionsPositionsLedger,
EscapeController, RecoveryView, FallbackOracle) + replaceable bounded
modules (RiskModuleV2, engines, RecoveryFinalizer parameters); EIP-712
domain binding `architectureVersion + verifyingContract +
deploymentVersion + subKey + recoveryEpoch`; per-signer per-engine
nonces + intent-hash consumption; recovery epoch state
(`recoveryEpoch[subKey] + ownerRecoveryEpoch[owner]`); ProtocolTimelock
governance + guardian veto.

Fresh Base Sepolia deployment. No legacy import. No mainnet.

## Work packages

20 WPs (WP-00..WP-20) defined at
`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/03_WORK_PACKAGES.md`.

Options-first. Perps interface frozen only; no perps engine
implementation in this cycle. Per session feedback
(`memory/feedback_perps_fail_closed.md`), the perps public route
disable is preserved throughout.

Critical path: WP-00 → WP-01 → WP-02 → WP-04A → WP-04B → WP-05 → WP-06
→ WP-07 → WP-08A → WP-08B → WP-09 → WP-10A → WP-10B → WP-11 → WP-12 →
WP-13 → WP-14 → WP-15 → WP-16 → WP-17 → WP-18 → (product-owner
authorization) → WP-19 → WP-20.

Full dependency graph:
`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/04_DEPENDENCY_GRAPH.md`.

## Ordered implementation milestones (first 15)

1. `ONCHAIN-SUBACCOUNT-SHARED-TYPES-AND-INTERFACES-V1`
2. `ONCHAIN-SUBACCOUNT-REGISTRY-V1`
3. `ONCHAIN-SUBACCOUNT-CAPABILITY-CONTROLLER-V1`
4. `ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-A`
5. `ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-B`
6. `ONCHAIN-SUBACCOUNT-REPLAY-AND-EPOCH-FOUNDATION-V1`
7. `ONCHAIN-SUBACCOUNT-OPTIONS-POSITIONS-LEDGER-V1`
8. `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-V1`
9. `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1`
10. `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1`
11. `ONCHAIN-SUBACCOUNT-FEES-MANAGER-V2-SUBKEY-V1`
12. `ONCHAIN-SUBACCOUNT-ESCAPE-CONTROLLER-V1-A`
13. `ONCHAIN-SUBACCOUNT-RECOVERY-FINALIZER-V1-B`
14. `ONCHAIN-SUBACCOUNT-EVENT-SURFACE-AND-MANIFEST-V1`
15. `ONCHAIN-SUBACCOUNT-FOUNDRY-INVARIANT-SUITE-V1`

Then (deferred to a later planning refresh): WP-13 → WP-20 milestones,
including the separately authorized Base Sepolia deployment milestone.

## Repository responsibilities

- **`deopt-v2-sol`:** Solidity contracts (`src/`), tests
  (`test/hybrid-v2/`), deployment scripts (`script/hybrid-v2/`),
  manifests (`config/hybrid-v2/`). Source of truth for ABI + event
  schema + deployment manifest hash.
- **`deopt-v2-backend`:** manifest loader, indexer, raw event journal,
  projections, reorg manager, state validator, reconstruction CLI,
  readiness state machine, API integration.
- **`deopt-v2-frontend`:** typed API client, hybrid-v2 pages, hooks,
  components, deposit/withdraw/internal-transfer flows, recovery UI,
  deployment badge, testnet banner.

## Invariant ownership

All 70 invariants have implementation owner + test owner per
`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/09_INVARIANT_TRACEABILITY.md`.

**`0 UNOWNED INVARIANTS`**. Invariant count remains **70**.

## Test gates

- **`GATE-EXPERIMENTAL-IMPLEMENTATION`** merge: per-WP unit + fuzz +
  invariant + property tests; WP-12 closer loop; cross-repo local
  acceptance suite (24 scenarios) exercisable.
- **`GATE-CLOSED-TEST`:** all invariants automated; broad codebase
  pre-audit; CRITICAL/HIGH findings dispositioned; genuine human
  technical/security review; rebuild + escape-hatch drills.
- **`GATE-PUBLIC-TESTNET`:** everything at CT + live drills on Base
  Sepolia + governance/timelock live + fallback settlement live + HIGH
  findings closed.
- **`GATE-MAINNET`:** external audit + drills on production
  configuration + operator handoff.

## Commit strategy

Per
`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/11_COMMIT_AND_REVIEW_STRATEGY.md`:
one concern per commit; tests committed with behavior; every commit
leaves repository green; no cross-repository commits except cutovers;
no Claude mention; no co-author lines; no force push; no skipped
hooks; no amend of pushed commits.

## Base Sepolia posture

- Chain id **84532** only. Never Base mainnet (**8453**).
- Fresh deployment (D-MIG-19). No legacy state import.
- WP-18 dry-run only in this cycle. WP-19 broadcast is separately
  authorized under
  `ONCHAIN-SUBACCOUNT-BASE-SEPOLIA-DEPLOYMENT-V1`.

## Prohibited scope

- Base mainnet — never touched.
- Real user funds — none.
- Broadcast in this planning milestone or implementation milestones
  WP-00..WP-18 — none.
- Source-code changes in this planning milestone — none.
- Perps V2 implementation — out of scope; interface-frozen only;
  perps route continues to fail-closed at the public route boundary
  per session feedback.
- Legacy re-enable or dual-active economic path — no.
- Secrets exposure — no `.env`, keys, RPC URLs, DB URLs, tokens.

## Product-owner approval pending

The product-owner review packet
(`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/20_PRODUCT_OWNER_REVIEW_PACKET.md`)
requires a signed decision:

- `PRODUCT_OWNER_AUTHORIZES_EXPERIMENTAL_IMPLEMENTATION`
- `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS`
- `NEEDS_REVISION_BEFORE_EXPERIMENTAL_IMPLEMENTATION`
- `REJECT_EXPERIMENTAL_IMPLEMENTATION_PLAN`

with the required acknowledgement wording that implementation is
experimental, Base Sepolia only, no mainnet, no real user funds, no
production/security claim, and human/external review remains required
at later gates.

## Machine-checkable properties (frozen — inherited)

All P-* (escape), R-P-* (reconstruction), M-P-* (migration), and
INV-* properties defined in the 5 companion tracked designs remain
authoritative. The implementation-plan milestone adds no new
normative properties; it maps the existing properties to WPs and test
files per `09_INVARIANT_TRACEABILITY.md`.

## Companion detailed documentation

Local detailed package (24 files):
`~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/`
— in the companion documentation repository, not tracked in this
Solidity repository beyond this file.

## No audit or production claim

This plan is a docs-only deliverable. It does not claim:

- audit sign-off;
- security-reviewer sign-off;
- implementation approval;
- deployment approval;
- production readiness;
- suitability for real user funds.
