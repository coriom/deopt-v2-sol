# ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1

## Status

**CONTRACT SPECIFICATION COMPLETE** — 2026-07-24.

Not an audit sign-off. Not an implementation approval. Not a
production-readiness claim. Independent human security reviewer
status remains **PENDING**. External audit remains mandatory for
real funds and public rollout.

Companion ADR: `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`.

## Approved architecture

Option D — Hybrid Registry + Shared Ledger with Modular Execution
Engines. Variant D1 + D2 with D4 governance and module-replacement
posture. D3 dedicated per-subaccount vaults deferred as an optional
future institutional feature.

## Contract / module map

- **Immutable identity + custody + positions tier:**
  - `SubaccountRegistry` — canonical `(owner, subaccountId) →
    subKey` mapping. Non-transferable. Monotonically increasing
    per-owner IDs starting at 1. Lazy Account 1 via engine
    capability. No pause. No admin.
  - `CollateralVault` v2 — shared physical ERC-20 custody keyed
    by `subKey`. Per-engine reservations. Least-privilege
    capability model.
  - `OptionsPositionsLedger` — long / short quantities per
    `(subKey, seriesId)`. European-only V1.
  - `PerpsPositionsLedger` (future) — signed `sizeSigned1e8` per
    `(subKey, marketId)`. Interface frozen; engine ships after
    options.
- **Replaceable modules:**
  - `RiskModule` v2 (per C-01 — replaceable via timelocked
    migration with compatibility check).
  - Execution engines: `MarginEngine` v2, `OptionMatchingEngine`
    v2, `PerpMatchingEngine` v2 (future), `PerpEngine` v2
    (future).
  - Oracle module: `OracleRouter` retained.
- **Kept + rewired ownership:**
  `OptionProductRegistry`, `ProtocolTimelock`, `RiskGovernor`,
  `ProtocolFeeVault`, `InsuranceFund`, `FeesManagerV2`,
  `IYieldAdapter` + adapters.
- **Retired at cutover:** legacy address-keyed vault / margin /
  matching / perp / risk contracts.

## Canonical identity + storage

- External API identity: `(owner: address, subaccountId: uint32)`.
  Stable WITHIN a deployment version.
- Internal chain storage key:
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
- `subaccountId = 0` reserved; `subaccountId = 1` lazy default.
- Vault: `balances[subKey][token]`,
  `totalLocked[subKey][token]`,
  `lockedByEngine[subKey][token][engine]`.
- Position ledgers: `positions[subKey][seriesId|marketId]`.
- Events: indexed `subKey` + readable `owner` + `subaccountId` +
  `uint16 eventVersion = 1`.

## Registry lifecycle

- `registerNext()` — direct owner call; monotonic ID from 1.
- `registerLazyDefault(owner)` — engine-capability-gated;
  idempotent for Account 1.
- No `register(id)`, no deletion, no reuse, no deactivation in
  V1.
- Non-transferable; no ownership rewiring.

## Vault accounting

- Shared physical ERC-20 custody; balances keyed by `subKey`.
- Per-`(subKey, token)`:
  - `balance` (total).
  - `totalLocked` (aggregate reservation across engines).
  - `lockedByEngine[engine]` (per-engine reservation).
  - `available = balance - totalLocked`.
  - `withdrawable = min(available, riskModule.withdrawalAllowed)`.
- Balance-delta validation on every deposit (rejects
  fee-on-transfer / rebasing tokens).
- Allowlisted standard ERC-20 only.
- Solvency: `IERC20(token).balanceOf(vault) >= Σ balances +
  treasury + insurance`.

## Position ledgers

### Options

- Separate `long128 + short128` per `(subKey, seriesId)`.
- Multi-leg RFQ: net-premium package convention with
  equal-per-leg default allocation.
- European-only V1.
- Product identity (`optionId`) unchanged from
  `OptionProductRegistry`.

### Perps (interface frozen; engine ships later)

- Signed `sizeSigned1e8` per `(subKey, marketId)`.
- `costBasisSigned1e18` + `fundingSnapshotSigned1e18` on
  position (no global funding-index loops).

## Engine capabilities

14 bits of least-privilege capabilities on the vault +
ledgers:

`CAP_REGISTER_DEFAULT_ACCOUNT`, `CAP_CREDIT_COLLATERAL`,
`CAP_WITHDRAW_FOR`, `CAP_LOCK_COLLATERAL`,
`CAP_UNLOCK_OWN_RESERVATION`, `CAP_APPLY_OPTIONS_POSITION_DELTA`,
`CAP_APPLY_PERP_POSITION_DELTA`, `CAP_APPLY_FEE`,
`CAP_APPLY_REBATE`, `CAP_SETTLE_OPTION`, `CAP_LIQUIDATE_OPTIONS`,
`CAP_LIQUIDATE_PERPS`, `CAP_EXECUTE_INTERNAL_TRANSFER`,
`CAP_CONSUME_REPLAY_NONCE`.

- Grants: timelocked via `ProtocolTimelock` (≥ 48h default).
- Immediate guardian revocation: `guardianRevokeEngine`.
- `applyUnlock` decrements ONLY caller's own reservation.
- Orphaned reservations require timelocked
  `governanceReleaseOrphanedLock`.

## Risk-module boundary

- Interface: `marginRequirement(subKey)`,
  `marginHealthy(subKey)`, `withdrawalAllowed`,
  `transferAllowed`, `liquidationStatus`, `productsEnabled`.
- Replaceable per C-01: multisig + `ProtocolTimelock` + ≥ 48h
  delay + compatibility check + migration tests + user exit
  window.
- Historical balances + ownership MUST NOT be rewritten.
- Fails closed (revert = false) for withdrawals when
  unavailable.

## EIP-712 + replay

- Domain: `(name, version, chainId, verifyingContract)`.
- Signed struct binds `(owner, subaccountId, action, product,
  nonce, deadline, architectureVersion, ...action fields)`.
- **D.1** (off-chain coordination / intent creation): bounded
  deadline + chain-side cancellation / nonce backstop where
  stale execution is possible. Includes order / RFQ / TWAP /
  conditional / signature submissions + cosmetic rename.
- **D.2** (canonical economic mutation): durable chain-side
  replay barrier surviving total Postgres loss. Includes
  `SubaccountCreate` + every chain-execution counterpart of
  D.1 submissions + all future canonical mutations
  (deposit / withdraw / transfer / exercise / settle /
  liquidation / delegation / recovery).
- Per-signer per-engine chain nonce mapping retained. Intent-hash
  consumption added for D.2 without a matching-engine path.
- Per-subaccount nonces NOT adopted; subaccountId bound in
  payload.

## Internal transfers

- Same-owner required (chain-verified).
- Distinct source / destination.
- Same token.
- Atomic paired debit + credit.
- Post-transfer margin re-check on SOURCE.
- No caps in V1.
- Chain-observable event with `subKey` attribution.

## Events + reconstruction

- Every economic event carries indexed `subKey` + readable
  `(owner, subaccountId)` + `eventVersion = 1` + domain fields.
- Provisional / settled tiers per environment-defined
  confirmation depth (INV-REC-06). 20 blocks is the current
  proposed Base Sepolia development default only.
- Reconstruction: chain events + view functions + deployment
  metadata (`deployments/base-sepolia/subaccount-v1/`).
- Reconciler drill part of `SUBACCOUNT-CHAIN-RECONSTRUCTION-DESIGN-V1`.

## Pause + governance

- Per-operation pause flags (deposit / withdraw / internal
  transfer / yield ops / matching / etc.).
- Registry has NO pause.
- Guardian OR Owner immediate pause. Owner-only unpause (≥ 24h
  timelock recommended).
- Reserved `withdrawPauseAutoClearBlock` slot for escape-hatch
  design.
- Every sensitive setter through `ProtocolTimelock` (≥ 48h
  default delay).
- Guardian revoke engine capabilities immediate; re-grant only
  via timelock.
- Governance actions emit events; queue observable via
  `RiskGovernor`.
- Actions never available administratively: owner reassignment,
  arbitrary balance / position rewriting, debt deletion, silent
  malicious-engine authorization, migration disguised as
  confiscation.

## Solidity interface index

Non-normative — full signatures in
`docs/onchain-subaccounts-v1/contract-spec/15_SOLIDITY_INTERFACES.md`
of the companion documentation:

- `ISubaccountRegistry`
- `ICollateralVault`
- `IOptionsPositionsLedger`
- `IPerpsPositionsLedger` (future)
- `IRiskModule`
- `IReplayProtected`
- `IOptionMatchingEngine`
- `IPerpMatchingEngine` (future)
- `IProtocolFeeVault` (unchanged from V1)

## Test gates

- L1 unit + L2 integration + L4 invariant (I-1..I-9 per spec)
  required before experimental implementation merge.
- L5 differential + L6 reorg + L7 migration + L8
  recovery-compat required before closed test.
- Escape-hatch drill + reconstruction drill required before
  public testnet.
- External audit + drills on mainnet configuration required
  before real funds.

## Deferred designs

- `SUBACCOUNT-ESCAPE-HATCH-DESIGN-V1`.
- `SUBACCOUNT-CHAIN-RECONSTRUCTION-DESIGN-V1`.
- `SUBACCOUNTS-ONCHAIN-MIGRATION-DESIGN-V1`.
- `ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1` (governance
  parameter values, multisig composition, timelock delays,
  guardian scope).
- `wallet-session-keys-v1` (first-class delegation via
  `DelegateRegistry`).
- Consolidated threat-driven implementation plan.
- Explicit product-owner experimental-implementation approval.
- Independent human internal security reviewer sign-off
  (mandatory before `GATE-CLOSED-TEST`).
- External security review (mandatory before public rollout).

## Implementation status

**NOT STARTED.** No Solidity source has been written for this
spec. Experimental implementation may be authorized separately
after all deferred designs are complete AND explicit
product-owner approval is on file.

Companion ADR + this spec together define what the future
implementation MUST produce.

## Machine-checkable invariants (frozen)

- **I-1 Vault solvency (per token).**
- **I-2 Value conservation on internal transfer.**
- **I-3 Locked collateral:** `available = balance - totalLocked;
  totalLocked = Σ lockedByEngine`.
- **I-4 Isolated margin:** no code path decreases sibling
  `balances[*]` during an operation on `subKey`.
- **I-5 No sibling collateral use.**
- **I-6 Replay protection:** matching-engine nonce monotonic;
  consumed intent hashes unreachable.
- **I-7 No owner reassignment.**
- **I-8 Engine capability isolation.**
- **I-9 Cross-engine unlock impossible.**

## Documentation cross-references

- Local detailed specification (24 files):
  `docs/onchain-subaccounts-v1/contract-spec/` (in the companion
  documentation repository, not tracked in this Solidity
  repository beyond this file + the ADR).
- Architecture ADR: `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`.
- Escape-hatch design (added 2026-07-24 by
  `SUBACCOUNT-ESCAPE-HATCH-DESIGN-V1`):
  `SUBACCOUNT_ESCAPE_HATCH_DESIGN_V1.md` — defines recovery
  activation model, `SM-Rec` state machine, `recoveryWithdrawable`
  accounting, `IEscapeController` + `IRecoveryFinalizer` +
  `IFallbackOracle` + `IRecoveryView` interfaces, and the
  `recoveryEpoch` binding required in every future EIP-712
  payload. Recovery-side additions include one new engine
  capability bit (`CAP_RECOVERY_ACTIVATE`, reserved), the
  `withdrawPauseAutoClearBlock` mechanism (already reserved on
  the vault), and the `badDebt[subKey][token]` slot addition.

## No audit or production claim

This specification is a design decision only. It does not
claim:

- audit sign-off;
- security-reviewer sign-off;
- implementation approval;
- deployment approval;
- production readiness;
- suitability for real user funds.
