# SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1

## Status

**DESIGN COMPLETE** — 2026-07-24. Product owner: Coriolan Morel.

Not an audit sign-off. Not an implementation approval. Not a
production-readiness claim. Independent human security reviewer
status remains **PENDING**. External audit remains mandatory for
real funds and public rollout.

Companion documents:
- `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
- `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`

## Purpose

Freeze the architecture-neutral, contract-spec-compatible escape,
recovery, and fallback-finalization design for DeOpt V2 economic
subaccounts. Authorizes the docs-only
`SUBACCOUNT-CHAIN-RECONSTRUCTION-DESIGN-V1` milestone.

## Recovery goals

The user MUST be able to inspect, settle, and recover canonical
economic value when one or more DeOpt services are unavailable,
while preventing:

- withdrawal against unresolved obligations;
- escape from negative equity;
- double withdrawal;
- replayed recovery;
- oracle manipulation;
- stale-intent execution after recovery;
- sibling-subaccount collateral consumption;
- governance or operator abuse;
- recovery-path denial of service.

## Activation model

Hybrid **M5**:

- M1 owner primitives always available (activate, cancel,
  invalidate intents, escape withdraw).
- M2 + M4 permissionless activation after objective on-chain
  conditions (operator inactivity timeout, withdraw pause
  auto-clear block, primary-oracle staleness).
- M3 governance ONLY inside bounded input surfaces (fallback
  source hierarchy, delays, bounded emergency price with
  timelock + dispute window).

Activation MUST NOT depend on backend heartbeat, PostgreSQL,
discretionary operator approval, or mutable off-chain state.

## Recovery state machine (`SM-Rec`)

`NORMAL → RECOVERY_PENDING → RECOVERY_ACTIVE →
(SETTLEMENT_PENDING) → WITHDRAWAL_ELIGIBLE → RECOVERED`.

Off-normal transitions: `RECOVERY_PENDING → CANCELLED (owner
window)`; `MIGRATED` reserved for future migration.

Every transition has a named trigger, delay, precondition set,
oracle / margin / liquidation / stale-intent requirement, event,
replay barrier, and governance authority (see
`docs/onchain-subaccounts-v1/escape-hatch/04`).

No transition allows jumping from an unresolved leveraged
position directly to unrestricted withdrawal. Recovery activation
is one-way once ACTIVE.

## Safe-withdrawal rules

```
recoveryWithdrawable(subKey, token)
  = max(
      0,
      canonicalCollateral
      - canonicalLocked
      - unresolvedObligations
      - liquidationReserve
      - settlementReserve
      - protocolDebt
      - pendingRecoveryReservation
    )
```

- Monotone-decreasing; never over-estimates safe amount.
- Primary calculator routes through the replaceable
  `IRiskModule`.
- **Immutable** fallback calculator (`IRecoveryView`) uses
  deterministic worst-case reserves; always callable.
- Fails closed if any term is unbounded.
- No PnL credit, no rebate promise, no cross-subaccount offset.

## Settlement / fallback rules

- European-only options V1.
- Permissionless `exercise` + `settleAccount` unchanged.
- `IRecoveryFinalizer.requestFallbackFinalization(optionId)`
  becomes callable after
  `SETTLEMENT_FINALIZER_INACTIVITY_TIMEOUT` from expiry.
- Hierarchical fallback `F-A → F-B → F-C → F-D`; F-D bounded
  emergency price requires timelock + user challenge window +
  strict deviation corridor.
- Duplicate finalization rejected.
- Governance MUST NOT bypass the dispute window or set
  arbitrary prices.

## Stale-intent invalidation

- Every EIP-712 payload binds `recoveryEpoch`.
- Hybrid namespace: `recoveryEpoch[subKey]` +
  `ownerRecoveryEpoch[owner]`; effective = `max(...)`.
- Matching engines reject `payload.recoveryEpoch !=
  effective` with `StaleRecoveryEpoch()`.
- Recovery activation delay gives pending matched intents time
  to land before the epoch bump; no double-execution possible.

## Recovery epoch

- Bumped on `RECOVERY_PENDING → RECOVERY_ACTIVE` transition.
- Bumpable independently via `invalidateIntents(subaccountId)` or
  `invalidateAllIntents()`.
- Monotone-non-decreasing.
- Interacts with per-signer per-engine nonces (both persist).
- Complements `cancelNoncesUpTo` on individual engines.

## Liquidation / insolvency

- Recovery does NOT pause liquidation. Liquidation takes
  priority.
- Escape withdraw reverts with `LiquidationPending()` for any
  short-side token when eligible for liquidation.
- User MAY top up collateral during recovery.
- Bad debt tracked in new `badDebt[subKey][token]` slot on
  vault.
- Insurance-fund unchanged; recovery claims none in V1.

## Pause matrix (escape-aware)

- `withdrawalsPaused` — hard auto-clears at
  `withdrawPauseAutoClearBlock` (RTH-25 mitigation).
- `recoveryPaused` — hard-capped at
  `RECOVERY_PAUSE_MAX_DURATION` (proposed 7d, upper 14d).
- Registry never pauses.
- View functions never pause.
- Fallback finalization reachable under `settlementPaused`.
- INV-OPS-05 satisfied: no permanent trap possible.

## Governance boundaries

Governance MAY:

- Configure timeouts, delays, deviation bps (bounded).
- Configure fallback oracle sources and addresses (timelocked).
- Release orphaned engine reservations (timelocked + evidence).
- Queue bounded emergency prices (F-D).

Governance MAY NOT:

- Reassign owner.
- Rewrite balances or positions.
- Select arbitrary settlement prices.
- Permanently trap funds.
- Bypass replay protection.
- Seize escape-withdraw proceeds.

## Smart-wallet posture

- Canonical owner = wallet contract address (INV-ID-06).
- Controller rotation does NOT emit DeOpt event.
- Recovery activation uses `msg.sender = wallet contract`.
- Delegates require `CAP_RECOVERY_ACTIVATE` to activate; escape
  withdraw is owner-only always.
- Post-recovery hygiene: revoke stale delegates (frontend
  prompt).

## Bounded gas model

- Every recovery function O(1) or bounded by explicit constants.
- No unbounded loop over subaccounts / tokens / positions /
  orders.
- Batches capped at `MAX_BATCH_SIZE = 16`.
- Permissionless keepers assist gas-constrained users.

## Contract interfaces

New:

- `IEscapeController` — activation, cancellation, invalidation,
  escape withdraw, pause, views.
- `IRecoveryFinalizer` — fallback finalization + dispute +
  emergency queue.
- `IFallbackOracle` — fallback price + TWAP price views.
- `IRecoveryView` — immutable withdrawable calculator with
  primary + fallback paths.

Existing extensions:

- `CollateralVault` v2 — `withdrawPauseAutoClearBlock`,
  `badDebt`, `_recoveryDebit`, `governanceReleaseOrphanedLock`.
- `SubaccountRegistry` — `subaccountsOfPage`.
- `OptionsPositionsLedger` — recovery-specific events only.
- Matching engines — `recoveryEpoch` binding in every EIP-712
  payload.
- `ProtocolTimelock` — extended target list.
- `RiskGovernor` — registers new contracts.
- One new engine capability: `CAP_RECOVERY_ACTIVATE`.

Full signatures in
`docs/onchain-subaccounts-v1/escape-hatch/15_SOLIDITY_INTERFACE_SPEC.md`.

## Test gates

- **`GATE-EXPERIMENTAL-IMPLEMENTATION` merge:** L1 + L2 + L4
  (P-1..P-9) for core scenarios T-1, T-2, T-3, T-8, T-10, T-11,
  T-16, T-22.
- **`GATE-CLOSED-TEST`:** all L1..L6 + T-1..T-22 pass.
- **`GATE-PUBLIC-TESTNET`:** all L1..L8; escape-hatch drill +
  reconstruction drill executed.
- **`GATE-MAINNET`:** external audit + drills on production
  configuration required.

## Machine-checkable properties (frozen)

- **P-1** monotone `recoveryEpoch[subKey]`.
- **P-2** monotone `ownerRecoveryEpoch[owner]`.
- **P-3** escape withdraw never touches sibling balances.
- **P-4** `Σ escapeWithdraw <= initialBalance + deposits`.
- **P-5** `recoveryWithdrawable` never increases after
  activation.
- **P-6** fallback finalization respects
  `SETTLEMENT_FINALIZER_INACTIVITY_TIMEOUT +
  SETTLEMENT_DISPUTE_WINDOW`.
- **P-7** emergency price respects timelock + challenge window.
- **P-8** escape withdraw reverts on `LiquidationPending`.
- **P-9** matching engines reject stale `recoveryEpoch`.

## Proposed invariants

- **INV-ESC-07** — recovery activation idempotency under reorg.
- **INV-REC-07** — recovery epochs survive reorg beyond
  `min_confirmation_depth`.
- **INV-OPS-07** — recovery-side pause cannot indefinitely
  extend.

## Deferred implementation details

- Concrete parameter values (delays, deviations, timeouts) →
  `ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1`.
- Concrete fallback oracle addresses (Chainlink round, Uniswap V3
  pools) → `SECURITY-REVIEW-PREP`.
- Delegate authority for recovery activation
  (`CAP_RECOVERY_ACTIVATE`) → `wallet-session-keys-v1`.
- Perp-specific recovery reserve formulas → future perps design.
- Cross-chain / bridged asset recovery → out of scope for V1.

## Companion detailed documentation

Local detailed package (23 files):
`docs/onchain-subaccounts-v1/escape-hatch/` — in the companion
documentation repository, not tracked in this Solidity repository
beyond this file.

## No audit or production claim

This design is a docs-only decision. It does not claim:

- audit sign-off;
- security-reviewer sign-off;
- implementation approval;
- deployment approval;
- production readiness;
- suitability for real user funds.
