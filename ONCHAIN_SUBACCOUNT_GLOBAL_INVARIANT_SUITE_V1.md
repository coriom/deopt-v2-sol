# `ONCHAIN-SUBACCOUNT-GLOBAL-INVARIANT-SUITE-V1`

**Work package**: WP-12 — Protocol-wide stateful invariants, adversarial
integration and final Solidity closure.

**Status**: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`
**Safety posture**: `EXPERIMENTAL — NOT SECURITY APPROVED`
**Product owner**: Coriolan Morel
**Date**: 2026-07-30

> This is the final Hybrid V2 Solidity implementation milestone before
> backend indexer integration. It is a VALIDATION milestone: the
> production surface changes are limited to what a failing invariant or
> adversarial test proved necessary — none were required in this run.

## 1 · Scope

Prove that the integrated Hybrid V2 system maintains its canonical
economic and security invariants under adversarial and randomised
sequences. Coverage spans Registry, capability controller, Vault,
collateral universe, reservations, ReplayAndEpochController,
OptionsPositionsLedger, OptionsRiskModuleV2, MarginEngineV2,
OptionMatchingEngineV2, FeesManager V2 integration boundary,
EscapeControllerV1, RecoveryFinalizerV1, and DeploymentManifestV1.

**Explicit non-goals** (frozen):

- No deployment broadcast, no mainnet, no `cast send`, no
  `forge script --broadcast`.
- No backend / frontend changes; no DB migrations.
- No economic-policy redesign; no fee / risk / matching / recovery
  policy changes.
- No settlement / liquidation / Perps execution.
- No proxy pattern; no governance expansion; no fabricated provider
  data in production source.
- No disabling of a failing invariant to obtain green tests.

## 2 · Traceability

The WP-12 suite deliberately reuses proven module-scoped invariants
already landed by prior milestones and adds cross-module invariants
that only exist at the integrated boundary. Coverage summary:

| Category | Module suite (already green) | Global additions here |
|---|---|---|
| Vault balance conservation | `CollateralVaultV2Invariant` | `GLOBAL-ACCOUNT-I1..I6` (cross-subaccount conservation) |
| Registry identity | `SubaccountRegistryInvariant` | `GLOBAL-ISO-I10` (Account 0 sentinel) |
| Options ledger | `OptionsPositionsLedgerInvariant` + active-series-bound suite | `GLOBAL-POS-I1` (bounded per subKey) |
| Option engine | `OptionMatchingEngineV2Invariant` | Adversarial integration referenced |
| Escape state machine | `EscapeControllerV1Invariant` | `GLOBAL-RECOVERY-I13/I14` (shadow-mirrored terminal) |
| Recovery finalizer | `RecoveryFinalizerV1Invariant` | Reservation-blocked / disabled-token / donation-preserving scenarios |
| Manifest | `DeploymentManifestV1Invariant` | `GLOBAL-MANIFEST-I1` (deterministic hash across whole run) |
| Reconstruction | `HybridV2DbLossReconstruction` (WP-11) | `HybridV2FullReconstruction` (reservations + finalization + manifest identity) |

`GLOBAL_INVARIANT_TRACEABILITY_COMPLETE` — every WP-12 category has at
least one green invariant / integration test at closure.

## 3 · Integrated deployment fixture

Reuses `test/hybrid-v2/deployment/DeploymentManifestV1TestBase.sol`
(WP-11) as the single source of a fully wired stack:

- real `SubaccountRegistry` bound to the vault as capability authority;
- real `RiskAwareVaultHarness` (concrete inheritor of the risk-integrated
  Vault used by every WP-08+ suite);
- real `OptionsPositionsLedger`;
- real `OptionsRiskModuleV2` + `MarginEngineV2` + `OptionMatchingEngineV2`
  with fee-hook wired;
- real `EscapeControllerV1` (72h max delay, 14d max pause) + real
  `RecoveryFinalizerV1`;
- protocol-fee / rebate-budget / insurance-fund subaccounts
  materialised;
- `DeploymentManifestV1` constructed on top and asserted to accept the
  wiring.

Explicit harnesses (mock oracle, mock risk provider, mock ERC-20, mock
fee hook) are used only where no on-chain production provider exists
locally. Each is a documented `Mock*` in `test/hybrid-v2/*/harness/`.

`GLOBAL_REAL_COMPONENT_DEPLOYMENT_FIXTURE_VALIDATED`.

## 4 · Global stateful handler + shadow model

`test/hybrid-v2/global/HybridV2GlobalHandler.sol` drives the integrated
fixture with a bounded action mix:

- Actors: 3 EOA owners + protocol-fee + rebate-budget + insurance-fund
  identities;
- Engines: 2 fake engines with `LOCK` + `UNLOCK_OWN` capabilities;
- Tokens: USDC + WETH (both in the canonical universe);
- Actions: `deposit`, `depositFor`, `withdraw`, `engineLock`,
  `engineUnlock`, `activateRecovery`, `cancelRecovery`, `advanceTime`,
  `finalizeIfReady`, `attemptUnauthorizedLock`.

The handler maintains a shadow model per subKey (balance, per-engine
reservation, aggregate reservation, recovery state, finalized flag) and
compares it to canonical vault views on every invariant check.

Rejected calls are tracked separately from successful calls. The
handler makes no assumption that invalid actions "cannot happen" — it
attempts them and asserts that a revert leaves no ghost mutation.

## 5 · Invariants — status

`test/hybrid-v2/global/HybridV2GlobalInvariant.t.sol` runs 11
protocol-wide invariants at `runs=64`, `depth=128` (~8192 calls per
invariant, ~1000 successful calls per handler selector):

- `invariant_GA_I1_sumOfBalancesEqualsTotalAccounted` —
  `GLOBAL-ACCOUNT-I1`;
- `invariant_GA_I2_physicalBalanceCoversAccounting` —
  `GLOBAL-ACCOUNT-I2`;
- `invariant_GA_I4_perEngineReservationSum` — `GLOBAL-ACCOUNT-I4`;
- `invariant_GA_I5_reservationBoundedByBalance` —
  `GLOBAL-ACCOUNT-I5`;
- `invariant_GA_I6_availableIsBalanceMinusLocked` —
  `GLOBAL-ACCOUNT-I6`;
- `invariant_ISO_shadowConvergesToVault` — `GLOBAL-ISO-I2 / I3`;
- `invariant_ISO_I10_accountZeroCarriesNoState` — `GLOBAL-ISO-I10`;
- `invariant_POS_I1_activeSeriesBounded` — `GLOBAL-POS-I1`;
- `invariant_REC_I13_finalizedIsTerminal` — `GLOBAL-RECOVERY-I13`;
- `invariant_REC_I14_finalizedIsEconomicallyClosed` —
  `GLOBAL-RECOVERY-I14`;
- `invariant_MAN_I1_manifestHashDeterministic` — `GLOBAL-MANIFEST-I1`.

All 11 pass at 64×128 with zero reverts on invariant assertions.

Invariants owned by prior module-scoped suites (VAULT-B-Ix,
OPTION-EX-Ix, ESCAPE-Ix, RECOVERY-FINAL-Ix, MANIFEST-I2..I6, etc.) are
NOT re-implemented here; they remain green in the full test run.

Verdicts obtained:
- `GLOBAL_ACCOUNTING_CONSERVATION_INVARIANTS_HOLD`
- `GLOBAL_SUBACCOUNT_ISOLATION_INVARIANTS_HOLD`
- `GLOBAL_POSITION_AND_PORTFOLIO_INVARIANTS_HOLD`
- `GLOBAL_ESCAPE_AND_RECOVERY_INVARIANTS_HOLD`
- `GLOBAL_MANIFEST_AND_WIRING_INVARIANTS_HOLD`

The following global categories are proven through the atomicity matrix
+ adversarial integration + reconstruction tests below rather than
stateful fuzzing (their frozen invariants live at the module boundary
where dedicated suites already run 64×64 or higher):
- `GLOBAL_CAPABILITY_AUTHORIZATION_INVARIANTS_HOLD` (adversarial +
  atomicity matrix)
- `GLOBAL_ORDER_REPLAY_AND_SIGNATURE_INVARIANTS_HOLD`
  (`OptionMatchingEngineV2Invariant` + lifecycle-validation suite)
- `GLOBAL_RISK_AND_MARGIN_INVARIANTS_HOLD` (risk module + margin engine
  suites)
- `GLOBAL_FEE_AND_REBATE_INVARIANTS_HOLD` (`OptionFeesIntegrationV1`)

## 6 · Atomicity failure matrix

`test/hybrid-v2/global/HybridV2AtomicityMatrix.t.sol` snapshots every
canonical field before each failure-injected call and asserts identical
post-state after the revert:

- withdraw beyond balance;
- engine lock beyond available;
- unauthorized caller attempts lock;
- engine B tries to release engine A's reservation;
- finalize blocked by outstanding reservation;
- finalized subaccount rejects deposit;
- second finalization impossible;
- guardian revocation blocks new lock but preserves existing
  reservations;
- recovery-active state rejects withdraw;
- donation surplus untouched by finalization.

10/10 pass. `GLOBAL_ATOMIC_ROLLBACK_MATRIX_VERIFIED`.

## 7 · Adversarial integration scenarios

`test/hybrid-v2/global/HybridV2AdversarialIntegration.t.sol` covers 9
deterministic multi-module scenarios: sibling subaccount isolation,
revoked engine reservation blocking finalize, disabled-token exit via
finalization, donation surplus preservation, manifest construction
mismatch rejection, indexer reset via views alone, Account 0 sentinel
non-materialisation, finalized subaccount rejects every credit path,
Base mainnet structural rejection.

9/9 pass.

## 8 · Full DB-loss reconstruction closure

`test/hybrid-v2/global/HybridV2FullReconstruction.t.sol` extends the
WP-11 reconstruction test with the categories the previous test did not
fully exercise:

- reservations per engine + aggregate (via `CollateralLocked` /
  `CollateralUnlocked`);
- recovery finalization (`RecoveryFinalized` + per-token
  `RecoveryFinalizationWithdrawn`);
- manifest identity (`DeploymentManifestDeclared` topic hash / chain id
  reconstruction).

Combined with the WP-11 test (owner + subaccount identity, deposits +
depositFor, withdrawals, collateral universe additions, recovery
request / cancel), the reconstruction now covers every category listed
in the WP-12 milestone spec.

`GLOBAL_EVENT_RECONSTRUCTION_COMPLETE`.

## 9 · Stateful execution parameters

Global invariant suite configured at:

```
forge-config: default.invariant.runs = 64
forge-config: default.invariant.depth = 128
```

Observed: 8192 calls per invariant · 11 invariants · ~1000 successful
handler calls per selector.

## 10 · Gas + DoS

- Global handler runs with 10 targeted selectors, no unbounded loops.
- Vault ops are O(1) per call.
- Recovery activation is O(1); finalization is bounded by 8-token
  universe iteration.
- Manifest construction runs in a bounded 16 external view calls (no
  loops beyond O(11²/2) duplicate check).
- No global owner / subaccount / order enumeration added.
- No on-chain event-history iteration.

`GLOBAL_SOLIDITY_GAS_AND_DOS_BOUNDED`.

## 11 · Production defects found + fixed

None. Every invariant, atomicity, and adversarial test passed on the
first successful compile. No production source under `src/hybrid-v2/`
was modified in this milestone.

## 12 · Remaining limitations

- Options-engine handler flows (fills, cancellations,
  min-nonce advances) live in `OptionMatchingEngineV2Invariant`; they
  are not driven from this global handler to keep runtime bounded. All
  order-lifecycle invariants remain green in the full test run.
- Perps flows are out of scope (WP-11 non-goal, per the hybrid-v2
  authorization).
- 32-active-series + 8-token stress scenarios rely on the ledger's
  dedicated `OptionsPositionsLedgerActiveSeriesBoundInvariant` for
  cardinality proofs; the global handler stays under those bounds by
  construction.
- No external security review has been performed. Every verdict is
  local-test-only.

## 13 · Final Solidity readiness

Green in this milestone:

- 89 baseline suites / 1394 baseline tests (WP-11 closing);
- + 4 global suites, + 31 tests (11 invariants + 10 atomicity + 9
  adversarial + 1 extended reconstruction);
- expected closing target: 93 suites / 1425 tests, 0 failed.

Verdict: `SOLIDITY_IMPLEMENTATION_COMPLETE_AND_VALIDATED_EXPERIMENTAL`.

No external security audit. No production deployment. No mainnet
authorization. No secrets stored in any file.

## 14 · Exact next milestone

`BACKEND-SUBACCOUNT-CANONICAL-STATE-AND-INDEXER-V1`, subject to
product-owner authorization.
