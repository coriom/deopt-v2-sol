# ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1

## Status

**APPROVED BY PRODUCT OWNER FOR CONTRACT SPECIFICATION** — 2026-07-24.

Product owner: Coriolan Morel.

Not an audit sign-off. Not an implementation approval. Not a
production-readiness claim. Independent human security reviewer
status remains **PENDING**.

Downstream consumers:

- `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
- `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md`
- `SUBACCOUNT_CHAIN_RECONSTRUCTION_DESIGN_V1.md`
- `SUBACCOUNTS_ONCHAIN_MIGRATION_DESIGN_V1.md`
- `ONCHAIN_SUBACCOUNT_EXPERIMENTAL_IMPLEMENTATION_PLAN_V1.md`
  (2026-07-25) — dependency-ordered implementation plan; 20 work
  packages; Options-first; fresh Base Sepolia posture preserved.

## Purpose

Concise canonical architecture decision record for the DeOpt V1
on-chain economic-subaccount design track. Authorizes the docs-only
`ONCHAIN-SUBACCOUNT-CONTRACT-SPEC-V1` milestone.

## Selected architecture

**Option D — Hybrid Registry + Shared Ledger with Modular Execution
Engines.**

Variant: **D1 + D2 with D4 governance and module-replacement
posture.**

D3 dedicated per-subaccount vaults are deferred as an optional
future institutional feature and are not part of V1.

## Rejected

- **Option B — Account-token / ERC-721:** transfer semantics
  collide with product decision P2 (non-transferable subaccounts).
  ERC-721 approval surface is unnecessary attack surface for a
  non-transferable account. No structural benefit over Option A / D.
- **Option C — Smart account / vault per subaccount:** per-account
  deployment + per-op external calls are prohibitive at scale for
  market-makers and HFT users. Governance surface amplified by N
  accounts. Physical isolation benefit preserved for a future
  institutional tier via variant D3.

## Runner-up

Option A2 — registry integrated into a central Account Manager over
a shared ledger. Very close on the weighted scorecard (7.82 vs
8.71). Fallback if the modular boundary in D proves harder than
expected during contract-spec.

## Canonical identity

- External / API identity: `(owner: address, subaccountId: uint32)`.
- `subaccountId = 0` reserved as sentinel; `subaccountId = 1` is
  the lazy default Account 1.
- `subaccountId >= 2` requires explicit registration.
- V1 subaccounts are non-transferable.

## Internal key (subKey)

Deployment-scoped storage key:

```
bytes32 subKey = keccak256(
    abi.encode(
        block.chainid,
        address(subaccountRegistry),
        owner,
        subaccountId
    )
);
```

- `(owner, subaccountId)` is the stable external identity WITHIN
  an architecture version.
- `subKey` is deployment-scoped.
- A new registry deployment creates a new internal namespace.
- Migrations MUST explicitly map old-version identity / state to
  the new deployment via chain-observable events.
- Events emit indexed `subKey` PLUS readable `owner` and
  `subaccountId`. Hash alone is insufficient for enumeration or
  human inspection.

## Module boundaries

- `SubaccountRegistry` (immutable) — canonical existence + owner /
  subaccount association; non-transferable; minimal stable surface.
- `CollateralVault` (immutable in V1) — shared physical custody;
  balances + locked amounts keyed by `subKey`; atomic internal
  transfers; isolated withdrawal rights; no sibling-subaccount
  collateral consumption.
- Product-specific position ledgers — Options positions keyed by
  `(subKey, optionId)`; Perps positions keyed by
  `(subKey, marketId)`.
- Execution engines — options matching / execution, RFQ +
  multi-leg settlement, future perps execution; authorized via
  `ProtocolTimelock`-gated allowlist; replaceable under
  governance policy.
- Risk and margin modules — REPLACEABLE via bounded, observable,
  timelocked governance with compatibility + migration tests +
  documented user exit window. **Historical balances and ownership
  MUST NOT be mutated by a risk-module replacement.**
- Settlement and oracle modules — modular but tightly permissioned;
  fallback-finalization and escape compatibility deferred to
  dedicated design milestones.

## Isolation model

Isolation is enforced by canonical chain state (per-subaccount
storage keys). Frontend / backend conventions are insufficient. One
subaccount cannot consume sibling collateral without a separately
designed future portfolio-margin mode.

## Replay and EIP-712 model

Every EIP-712 economic authorization binds:

- `chainId`;
- `verifyingContract` (deployed engine address);
- architecture / deployment version where needed;
- `owner`;
- `subaccountId` (or `subKey`);
- action type;
- relevant economic parameters;
- nonce or consumed intent identifier;
- deadline.

Bucket-D classification (corrected):

- **D.1** — off-chain coordination / intent creation (order
  submission, RFQ acceptance, TWAP scheduling, cosmetic rename).
  Bounded deadline + chain-side cancellation / nonce backstop
  where stale execution is possible.
- **D.2** — canonical economic mutation (on-chain subaccount
  registration, deposit, withdrawal, internal transfer, executed
  fill / settlement, exercise, liquidation, canonical delegation
  register / revoke, escape / recovery). Durable chain-side replay
  consumption; MUST survive total PostgreSQL loss.

An HTTP / API signature-submission is NOT automatically D.2.
`PerpOrderSubmit` and `OptionExecutionIntentSignatureSubmit` are
D.1 submissions; their eventual on-chain executions are D.2.

Per-signer chain-side nonce mapping is retained on matching
engines. Subaccount identity is bound inside the EIP-712 payload
rather than by per-subaccount nonces.

## Smart-wallet controller posture

Canonical owner is the smart-wallet contract address (may be an
EOA, a multisig, or an ERC-4337 smart account). Controller /
signer rotation of a smart-wallet owner changes wallet-level
control but does NOT change the canonical DeOpt owner and does
NOT emit a DeOpt ownership-change event. DeOpt delegation is
distinct from wallet-controller rotation. Account recovery and
controller changes are covered by AT-34.

## Recovery / reconstruction requirements

- Chain-only rebuild via registry + engine events + deployment
  metadata (fresh PostgreSQL rebuilds every canonical economic
  entitlement).
- Provisional / settled tier promotion at an environment-defined
  confirmation depth. Specific block counts are network-operational
  policy, not universal protocol invariants.
- Idempotent reprocess after reorg.
- Chain state remains the FINAL economic authority.

## Governance / upgrade posture

- No UUPS or generic proxy over the canonical identity core in V1.
- Smallest possible upgradeable / replaceable surface.
- Canonical owner and ledger state cannot be arbitrarily mutated
  by an engine or risk-module replacement.
- Engine / risk / oracle changes require multisig +
  `ProtocolTimelock`.
- Default target delay ≥ 48 hours, subject to later governance
  specification.
- Governance changes emit events.
- Users receive a meaningful exit / defensive-action window during
  the timelock delay.
- Immutable modules (identity, custody, positions) have an
  explicit versioned migration path via fresh redeployment +
  user-verifiable proof, rather than pretending they can never
  contain a defect.

## Migration posture

Fresh Base Sepolia deployment. Existing testnet balances drained
by users manually. No production users to protect.

Migration to a hypothetical future mainnet is out of scope for
this milestone. When scoped, the milestone
`SUBACCOUNTS-ONCHAIN-MIGRATION-DESIGN-V1` will:

- Publish a user-verifiable pre-cutover proof.
- Define a bounded dual-mode period.
- Ensure only one deployment side is authoritative at any time.
- Emit explicit old→new mapping events.
- Make external API identity continuity version-aware.

## Experimental implementation gates

`GATE-EXPERIMENTAL-IMPLEMENTATION` may be authorized separately
after ALL of:

- `ONCHAIN-SUBACCOUNT-CONTRACT-SPEC-V1` complete.
- `SUBACCOUNT-ESCAPE-HATCH-DESIGN-V1` complete.
- `SUBACCOUNT-CHAIN-RECONSTRUCTION-DESIGN-V1` complete.
- `SUBACCOUNTS-ONCHAIN-MIGRATION-DESIGN-V1` complete (or explicit
  fresh-deployment posture recorded).
- Threat-driven test plan complete.
- Explicit product-owner experimental-implementation approval.

Restrictions: development only, Base Sepolia / local chain, no
real user funds, tagged `EXPERIMENTAL — NOT SECURITY APPROVED`.

External review remains **mandatory for real funds and mainnet**,
and mandatory before public rollout. Internal human security
review is **mandatory before closed test**.

## Mandatory follow-up milestones

1. `ONCHAIN-SUBACCOUNT-CONTRACT-SPEC-V1` — concrete Solidity
   function / event / storage specifications.
2. `SUBACCOUNT-ESCAPE-HATCH-DESIGN-V1` — user-callable recovery
   + fallback settlement + RFQ interaction.
3. `SUBACCOUNT-CHAIN-RECONSTRUCTION-DESIGN-V1` — reconstruction
   SLA + optional state commitments + confirmation-depth policy
   per network.
4. `SUBACCOUNTS-ONCHAIN-MIGRATION-DESIGN-V1` — migration bridge
   or explicit fresh-deployment posture.
5. `ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1` — governance
   parameter values, multisig composition, timelock delays,
   guardian scope.
6. `wallet-session-keys-v1` — first-class delegation via a
   separate `DelegateRegistry` contract.
7. Independent human internal security reviewer sign-off —
   mandatory before `GATE-CLOSED-TEST`.
8. External security review — mandatory before public rollout.

## Non-normative notes

- Detailed comparison of the four architecture families +
  weighted scorecard + full clarifications live in
  `docs/onchain-subaccounts-v1/architecture-options/` and
  `docs/onchain-subaccounts-v1/architecture-approval/` in the
  companion documentation repository (not tracked in this
  Solidity repository beyond this ADR).

## Companion contract specification

`ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md` — added 2026-07-24 by
`ONCHAIN-SUBACCOUNT-CONTRACT-SPEC-V1`. Concrete function
signatures, storage layouts, event schemas, engine capabilities,
D.1/D.2 action classification, and machine-checkable invariants
(I-1..I-9). The companion spec is the authoritative reference
for the future experimental implementation milestone.

## No audit or production claim

This ADR is a design decision only. It does not claim:

- audit sign-off;
- security-reviewer sign-off;
- implementation approval;
- deployment approval;
- production readiness;
- suitability for real user funds.
