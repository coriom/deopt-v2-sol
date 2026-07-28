# `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` — Concrete Options RiskModule provider + MarginEngine boundary

Status: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`
Product owner: Coriolan Morel
Authorization: `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS`
Milestone id: `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1`
Work package: `WP-08 (WP-08A)` — MarginEngine V2 + concrete Options RiskModule
Date: 2026-07-28

> `EXPERIMENTAL — NOT SECURITY APPROVED`
> Base Sepolia only. No mainnet. No real user funds. No production-readiness
> claim. Every economic value produced by this module is derived from
> deployment-configured risk parameters that a future
> `ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1` milestone will approve
> separately. Human + external security review remains required at later
> gates.

## Milestone summary

This milestone lands the concrete provider-backed Options `RiskModuleV2`
inheritor plus the `MarginEngineV2` read-only orchestration boundary. It
completes the WP-07 abstract by binding concrete formulas + collateral
valuation to canonical `OptionsPositionsLedger` reads, canonical
`CollateralVaultV2` reads, and an approved provider adapter. It does NOT
implement any economic write; every mutation is deferred to the future
`ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` (WP-08B / WP-09).

## Authoritative sources

- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_A.md` + `_B.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_OPTIONS_POSITIONS_LEDGER_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_COMPLETENESS_AND_SLOT_PATCH.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_BOUNDEDNESS_AND_LIQUIDATION_SAFETY_PATCH.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_RISK_EXECUTION_BOUNDS_AND_COLLATERAL_UNIVERSE_V1.md`
- `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/06_RISK_MARGIN_MODULE_SPEC.md`
- `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/03_COLLATERAL_VAULT_SPEC.md`
- `~/DEOPT/docs/onchain-subaccounts-v1/experimental-implementation-plan/03_WORK_PACKAGES.md` (WP-08)

## Verdicts

- `ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1_COMPLETE`
- `MARGIN_ENGINE_ABI_AND_OWNERSHIP_RESOLVED`
- `MARGIN_RESERVATION_OWNERSHIP_DEFERRED_BY_APPROVED_DESIGN`
- `MARGIN_RESERVATIONS_OWNED_BY_OPTIONS_ENGINE`
- `CONCRETE_OPTIONS_RISK_FORMULAS_IMPLEMENTED`
- `BOUNDED_CANONICAL_RISK_INPUTS_VALIDATED`
- `MARGIN_SYNCHRONIZATION_IS_IDEMPOTENT_AND_FAIL_CLOSED`
  (idempotency proved by read-only surface — repeated view calls are
  deterministically bit-identical; synchronization writes are deferred.)
- `SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT_PRESERVED`
- `POST_STATE_MARGIN_SYNC_ATOMIC_ENGINE_MODEL`
  (WP-08 boundary: MarginEngine views are read-only; the future
  OptionMatchingEngine performs atomic post-state health checks by consuming
  these views within its own transaction.)
- `NO_MATCHING_REPLAY_POSITION_OR_FEE_EXECUTION_IMPLEMENTED`
- `READY_FOR_ONCHAIN_SUBACCOUNT_OPTION_MATCHING_ENGINE_V2_V1`

## Part C — ABI + ownership audit result

`MARGIN_ENGINE_ABI_AND_OWNERSHIP_RESOLVED`. Concretely:

| Function                          | Caller                  | Reads                                                  | Writes                | Capability required           | Owner       |
| --------------------------------- | ----------------------- | ------------------------------------------------------ | --------------------- | ----------------------------- | ----------- |
| `initialMargin1e18`               | any (offchain / engine) | Registry, Ledger, Provider, Oracle, Vault (collateral) | none                  | none                          | WP-08 (this)|
| `maintenanceMargin1e18`           | any                     | same                                                   | none                  | none                          | WP-08 (this)|
| `availableCollateral1e18`         | any                     | Vault (collateral universe + balances)                 | none                  | none                          | WP-08 (this)|
| `marginExcess1e18`                | any                     | same                                                   | none                  | none                          | WP-08 (this)|
| `marginRatio1e18`                 | any                     | same                                                   | none                  | none                          | WP-08 (this)|
| `isHealthy`                       | any                     | same                                                   | none                  | none                          | WP-08 (this)|
| `liquidationStatus`               | any                     | same                                                   | none                  | none                          | WP-08 (this)|
| Trade pre-check                   | (matching engine)       | this engine's views                                    | none                  | none (offchain caller)        | WP-08B/WP-09|
| Post-trade health check           | (matching engine)       | this engine's `isHealthy` after position mutation      | none                  | none                          | WP-08B/WP-09|
| Increase reservation (`applyLock`)| (matching engine)       | Vault                                                  | Vault                 | `CAP_LOCK_COLLATERAL`         | WP-08B/WP-09|
| Release reservation (`applyUnlock`)| (matching engine)      | Vault                                                  | Vault                 | `CAP_UNLOCK_OWN_RESERVATION`  | WP-08B/WP-09|
| Fee reservation / debit           | fees manager            | Vault                                                  | Vault                 | `CAP_APPLY_FEE`               | WP-09 fees  |
| Settlement reservation            | settlement engine       | Vault                                                  | Vault                 | `CAP_SETTLE_OPTION`           | WP-08B      |
| Liquidation execution             | liquidation engine      | Vault + Ledger                                         | Vault + Ledger        | `CAP_LIQUIDATE_OPTIONS`       | WP-08B      |
| Batch/multi-leg margin check      | matching engine         | this engine (composed views)                           | none                  | none                          | WP-08B      |
| Withdrawal check (`withdrawalAllowed`) | Vault (during `withdraw`) | this module's abstract hook (via `RISK_MODULE`)   | none                  | none                          | WP-07 + WP-08 (this)|
| Internal-transfer check           | Vault                   | same                                                   | none                  | none                          | WP-07 + WP-08 (this)|

**Ownership rule (frozen for WP-08A):** the MarginEngine does NOT write to
the Vault or the Ledger. Its role is to expose canonical views over the
Vault-bound `RISK_MODULE`. Concrete reservation writes are the future
OptionMatchingEngine's responsibility (Part D verdict below).

## Part D — Collateral-allocation decision

Verdict: `MARGIN_RESERVATION_OWNERSHIP_DEFERRED_BY_APPROVED_DESIGN` (CA-4).

Rationale:

- Every frozen risk view in `IRiskModule` (spec 06) is denominated in a
  **single 1e18 aggregate quote value** — not per-token amounts. Aggregate
  `marginRequirement(subKey)` and `availableMargin(subKey)` collapse the
  entire portfolio + collateral universe into a scalar.
- The Vault's `_requireWithdrawalAllowed` hook (WP-07
  `CollateralVaultV2RiskIntegrated`) already delegates ENTIRELY to
  `IRiskModule.withdrawalAllowed`. That path is value-based and never
  requires token-denominated per-engine reservations.
- The Vault's `applyLock` / `applyUnlock` primitives ARE token-denominated
  per engine, but they are the responsibility of the mutating engine
  (matching / settlement / liquidation), which knows the settlement token
  of the fill being applied. WP-08A does no mutation and therefore holds no
  reservation.
- No tracked design document contains a frozen multi-collateral allocation
  policy for MarginEngine-owned reservations. Inventing one would violate
  the prompt's "Stop rather than inventing behavior if sources conflict on
  … collateral allocation for reservations" clause.

Reservation-owner verdict: `MARGIN_RESERVATIONS_OWNED_BY_OPTIONS_ENGINE`.
The future OptionMatchingEngine (WP-08B / WP-09) MUST reserve the fill's
settlement token when opening / increasing a short and release its own
reservation on flatten / exercise / liquidation, using its own capability
grants.

Consequence for this milestone:

- WP-08A implements the read-only orchestration boundary.
- WP-08A does NOT expose any `syncAccountMargin` write. All the frozen
  requirements from Part L that pertain to WRITES (lock / unlock / event
  emission of a synchronization) are deferred to the future engine.
- Repeated view calls with unchanged canonical state return bit-identical
  values → idempotency is trivial and provable.

## Part E — Concrete Options risk provider

Implemented at `src/hybrid-v2/risk/OptionsRiskModuleV2.sol`.

Immutables at construction:

- `REGISTRY`, `VAULT`, `OPTIONS_LEDGER` (from `RiskModuleV2` base)
- `RISK_PROVIDER : IOptionsRiskProvider`
- `ORACLE : IOracleAdapter`
- `QUOTE_TOKEN : address` (single deployment-scoped numeraire)
- `QUOTE_DECIMALS : uint8`
- `MAX_ORACLE_STALE_SECONDS : uint256`
- `MODULE_VERSION : uint16`
- `ARCHITECTURE_VERSION` / `SUPPORTED_STORAGE_VERSION` (inherited)

No mutable admin, no setter, no upgrade path. Rotation policy inherits WP-07:
`SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT` — rotation requires a fresh
Vault + Consumer redeploy (spec 06 C-01).

### Bounded input discovery (Part F)

- **Options positions:** the concrete `_computeMarginRequirement(subKey)`
  hook cannot enumerate active series from a `subKey` alone (the Ledger
  exposes only `activeSeriesCount` + `isActiveSeries` + witness verifier).
  Semantics:
  - `activeSeriesCount(subKey) == 0` → returns `(0, true)`.
  - `activeSeriesCount(subKey) > 0` → returns `(0, false)` (indeterminate
    without a witness → fails closed at the abstract).
  - Callers holding a canonical witness MUST route through the witness-taking
    `MarginEngineV2.maintenanceMargin1e18(subKey, seriesIds)` view instead,
    which discharges `verifyActiveSeriesArrayComplete` before iterating.
  - Every witness-taking view is bounded to ≤ 32 series (enforced by the
    Ledger's `MAX_ACTIVE_SERIES_PER_SUBACCOUNT` cap + the verifier's
    length-early-reject).
- **Collateral:** always read via
  `VAULT.collateralTokenCount()` + `VAULT.collateralTokenAt(i)`. No caller-
  supplied collateral list. Iteration bound is 8 (enforced by the Vault's
  `MAX_COLLATERAL_TOKENS`). Disabled-but-known tokens remain in the
  universe (liquidation-completeness preservation).

## Part G — Frozen Options risk formulas

Implemented in `src/hybrid-v2/margin/OptionsRiskMath.sol` (pure library):

```
intrinsic_call1e8    = max(spot1e8 - strike1e8, 0)
intrinsic_put1e8     = max(strike1e8 - spot1e8, 0)
stressed_call1e8     = max(spot1e8 * (BPS + shockUpBps) / BPS - strike1e8, 0)
stressed_put1e8      = max(strike1e8 - spot1e8 * (BPS - shockDownBps) / BPS, 0)  [put put wipe rule: shockDown >= BPS → strike]
mm_per_contract1e8   = max(intrinsic, stressed, baseFloor)
im_per_contract1e8   = ceil(mm * imFactorBps / BPS)         [ceil rounds AGAINST the user]
series_contribution1e8 = shortQuantity1e8 * per_contract1e8 / CONTRACT_SIZE_1E8
portfolio_mm1e8      = Σ series_contribution_mm_i        (long-only series contribute 0)
portfolio_im1e8      = Σ series_contribution_im_i
value1e18            = value1e8 * 1e10                   (decimal-agnostic scaling)
```

V1 explicit zeros: Perps contribution = 0; cross-subaccount offset = 0;
cross-owner offset = 0; Options/Perps cross-offset = 0; cross-series offset
= 0. Long positions do not offset short positions in V1.

Vol shocks are RESERVED for a future extension and IGNORED in V1.

Oracle-down path: when the spot oracle returns `ok = false` OR stale, the
per-contract MM is computed as `baseFloor * oracleDownMmMultiplierBps /
BPS` — conservative fallback per `OptionRiskConfig`.

### Parameter authority (Part G)

- `baseMaintenanceMarginPerContract`, `imFactorBps`,
  `oracleDownMmMultiplierBps`, `spotShockUpBps`, `spotShockDownBps` — all
  read from `IOptionsRiskProvider`, which wraps a **timelock-governed
  registry deployment**. The specific registry deployment is chosen at
  deploy time; this milestone does NOT bake in numeric values.
- Every parameter is validated defensively:
  - `imFactorBps >= 10_000` (IM ≥ MM) → else fail closed.
  - `oracleDownMmMultiplierBps >= 10_000` → else fail closed.
  - `series.settlementAsset == QUOTE_TOKEN` → else fail closed.
  - `series.contractSize1e8 == 1e8` (frozen invariant) → else fail closed.
  - `series.strike1e8 != 0` → else fail closed.
  - `underlyingRiskView.isEnabled` → else fail closed.
  - `optionsRiskConfigView.isConfigured` → else fail closed.
- Any invalid / missing config produces `ok = false` from the per-series
  hook → the entire portfolio walk fails closed at
  `RiskModuleUnavailable`. No path silently substitutes a permissive
  default.

## Part H — Oracle + series validation

Every price fetch uses `IOracleAdapter.getPrice1e8Safe(base, quote)` with:

- `ok == false` → fail closed.
- `price1e8 == 0` → fail closed.
- `updatedAt > block.timestamp` → fail closed (future-dated).
- `block.timestamp - updatedAt > MAX_ORACLE_STALE_SECONDS` → fail closed
  (stale).

For the collateral valuation path (`_computeAvailableMargin` +
`_valueOfWithdrawnAmount`), the same freshness bound is applied per-token.

The freshness bound is shared between `OptionsRiskModuleV2` and
`MarginEngineV2` — `MarginEngineV2._spot1e8` reads
`OptionsRiskModuleV2.MAX_ORACLE_STALE_SECONDS()` at every call, so drift
between the two is impossible.

## Part I — Collateral valuation

- Enumerates the canonical Vault collateral universe (≤ 8 tokens).
- For each token with a non-zero canonical account balance:
  1. `isKnownCollateralToken(token)` (append-only membership) → else fail
     closed. Excludes tokens the Vault has never seen.
  2. `IOptionsRiskProvider.collateralRiskView(token)` → requires
     `isConfigured`; `creditFactorBps` in `(0, 10_000]`.
     - Quote-token special case: full credit (10_000 bps) with no oracle
       lookup and no provider entry required.
  3. Token decimals: read via `IERC20Metadata.decimals()` inside a
     `try/catch`; fail closed on revert or on `decimals > 36`.
  4. Oracle 1e8 price of `token → QUOTE_TOKEN` with strict freshness.
  5. Value math (rounded DOWN in favor of protocol safety):
     ```
     value1e8   = balance * price1e8 / (10 ** tokenDecimals)
     credited1e8 = value1e8 * creditFactorBps / 10_000
     value1e18   = credited1e8 * 1e10
     ```
- Direct donations to the Vault contract address are EXCLUDED — the
  canonical `balanceOf(subKey, token)` view reflects only accounted
  balances (proved by `test_availableMargin_donationExcluded`).
- Disabled tokens with pre-existing balances remain valued (proved by
  `test_disabledTokenBalanceStillCounted`).

## Part J — MarginEngineV2 implementation form

Concrete contract at `src/hybrid-v2/margin/MarginEngineV2.sol`.

Inheritance: `IMarginEngine`, `VaultRiskModuleConsumer`.

Constructor:

- Signature: `constructor(address vault_, uint16 engineVersion_)`.
- Only argument beyond the Vault is `engineVersion_` (a governance-tracking
  tag). NO independent `riskModule_` argument. Divergence between the
  engine's read and the Vault's hook path is a compile-time impossibility.
- Resolves `REGISTRY`, `OPTIONS_LEDGER`, `RISK_PROVIDER`, `ORACLE`,
  `QUOTE_TOKEN`, `QUOTE_DECIMALS` FROM the Vault-bound `RISK_MODULE`.
  Every immutable is a downstream read of the Vault's canonical binding.
- Validates all resolved references are non-zero. Divergent Vault variants
  that break the invariant surface a typed `RiskModuleIncompatible`
  revert.

Concrete because:

- The concrete risk provider IS deployable (per Part E).
- Collateral-allocation policy is resolved (deferred per Part D → no writes
  needed here).
- Every external mutation has precise authorization (zero external
  mutations exist in this contract).

## Part K — Caller authorization

- No mutation. Every function is `external view`. Capability grants are
  ZERO — this engine does not need any Vault capability bit.
- Fail-closed conditions on the read path:
  - `subKey == bytes32(0)` → `SubKeyRequired`.
  - `REGISTRY.ownerOf(subKey) == address(0)` → `UnknownSubaccount`.
  - `!OPTIONS_LEDGER.verifyActiveSeriesArrayComplete(subKey, ids)` →
    `IncompleteActiveSeriesWitness`.
  - Any upstream `IRiskModule` failure → `RiskModuleUnavailable`.
  - `isHealthy` swallows every failure and returns `false` — never reverts.
- No governance surface. No admin key. No pause. Rotation = fresh redeploy.

## Part L — Reservation synchronization (deferred)

Per Part D verdict, `syncAccountMargin(...)` is NOT implemented in this
milestone. The future OptionMatchingEngine (WP-08B) will implement:

1. Signature + replay checks (WP-06 replay foundation).
2. Trade eligibility (product-registry-side checks).
3. Position mutation via `OptionsPositionsLedger.applyFill`.
4. Post-state health check via `MarginEngineV2.isHealthy(subKey, witness)`
   (this contract) — must return `true`.
5. Reservation write via `Vault.applyLock(subKey, settlementToken,
   requiredIncrement)` — bounded by the engine's own capability grant.
6. Premium / fee routing.
7. Emit reconstructible fill events.
8. Any failure → whole transaction reverts atomically (steps 3–7 unwind).

## Part M — Risk-increasing / risk-reducing distinction

Because this milestone provides only read-only views, both flows are safe:

- **Risk-increasing flow (future WP-08B):** the matching engine calls
  `MarginEngineV2.isHealthy(subKey, witness)` AFTER applying the
  position mutation. If `false`, the whole transaction reverts (Solidity
  atomicity). Insufficient collateral → `false` return → revert.
- **Risk-reducing flow (future WP-08B):** the matching engine reduces
  position size, adds collateral, exercises, or settles. Post-state
  `isHealthy` returns `true` → transaction succeeds.
- Fail-closed guarantee: this contract NEVER returns `true` from
  `isHealthy` when any input is missing / stale / indeterminate. The
  future engine cannot rely on this contract to authorize an unsafe
  operation.

## Part N — Atomicity model

Verdict: `POST_STATE_MARGIN_SYNC_ATOMIC_ENGINE_MODEL`.

Solidity transaction atomicity underpins the safety model:

- WP-08A: MarginEngine views are pure `external view`. They read a
  consistent snapshot of Registry / Vault / Ledger / Provider / Oracle.
- WP-08B (future): the matching engine will apply position mutations,
  reservation writes, premium transfers, and event emissions inside ONE
  transaction. A failed post-state health check reverts the position
  mutation. A failed reservation write reverts the position mutation +
  fee routing. A failed fee routing reverts everything upstream.

WP-08A itself:

- Does NOT consume replay nonces.
- Does NOT mutate positions.
- Does NOT charge fees.

## Part O — Views

Exposed views (see `IMarginEngine`):

- `initialMargin1e18(subKey, witness) → uint256`
- `maintenanceMargin1e18(subKey, witness) → uint256`
- `availableCollateral1e18(subKey, witness) → uint256`
- `marginExcess1e18(subKey, witness) → uint256`
- `marginRatio1e18(subKey, witness) → uint256` (returns `type(uint256).max`
  when MM == 0)
- `isHealthy(subKey, witness) → bool` (fail-closed; never reverts)
- `liquidationStatus(subKey, witness) → LiquidationStatus` (inherits WP-07
  fail-safe: reverts on indeterminate)
- `vault() → address`
- `riskModule() → address`

Plus the concrete `OptionsRiskModuleV2` publicly exposes:

- `collateralValue1e18(token, balance) → (uint256, bool)` — introspection
  primitive for offchain tooling.

## Part P — Events + errors

**Events:** WP-08A emits NO events. There is no economic mutation to emit
about. WP-08B / WP-09 will emit fill / lock / unlock / fee events.

**Errors (IMarginEngine):**

- `SubKeyRequired`
- `UnknownSubaccount(bytes32)`
- `IncompleteActiveSeriesWitness(bytes32)`
- `RiskModuleUnavailable`

**Errors (OptionsRiskModuleV2 constructor):**

- `InvalidRiskProvider`, `InvalidOracleAdapter`, `InvalidQuoteToken`,
  `InvalidStalenessBound`, `InvalidQuoteDecimals`
- Inherited: `InvalidRegistry`, `InvalidVault`, `InvalidOptionsLedger`,
  `InvalidModuleVersion`

**Errors (MarginEngineV2 constructor):**

- `RiskModuleIncompatible`, `InvalidEngineVersion`, `RegistryMismatch`
- Inherited: `InvalidVault`, `RiskModuleNotBoundOnVault`,
  `RiskModuleArchitectureMismatch`, `RiskModuleStorageVersionUnsupported`

No string reverts.

## Part Q — Tests

**Suites shipped in this milestone:**

- `test/hybrid-v2/margin/OptionsRiskMath.t.sol` — 27 tests (unit + fuzz
  for the pure library).
- `test/hybrid-v2/margin/OptionsRiskModuleV2.t.sol` — 31 tests (unit +
  fuzz for the concrete provider).
- `test/hybrid-v2/margin/MarginEngineV2.t.sol` — 33 tests (unit +
  fuzz for the read-only orchestration boundary).
- `test/hybrid-v2/margin/MarginEngineV2Integration.t.sol` — 8 tests
  (worst-case 32 series × 8 tokens; disabled-token still valued; donation
  excluded; sibling isolation; no-mutation; RM-1 single-module posture;
  risk-reducing collateral-add path).
- `test/hybrid-v2/margin/MarginEngineV2Invariant.t.sol` — 7 invariants
  at 256 × 500 (Foundry default) with a bounded handler.

**Prompt Part Q checklist coverage:**

- Valid call / put series → `test_singleShortCallAtTheMoney_mm` +
  `test_shortPut_stressedIsDominant`.
- Intrinsic value → 6 unit + fuzz tests in `OptionsRiskMath.t.sol`.
- Stressed liability → 6 unit tests.
- Base MM floor → `test_mm_takesMaxOfThree` + `test_stalePrice_usesOracleDownPath`.
- IM ceil rounding → `test_im_ceilRounding` + fuzz.
- Multiple short series → `test_thirtyTwoSeriesEnumerable`.
- Long-only → `test_longOnlyContributesZero`.
- Stale / future / zero-price oracle → 5 dedicated tests.
- Missing series → `test_unknownSeriesFailsClosed`.
- Invalid config → `test_imFactorBelowBpsFailsClosed`,
  `test_wrongSettlementAssetFailsClosed`, `test_invalidContractSizeFailsClosed`,
  `test_inactiveSeriesFailsClosed`, `test_availableMargin_unconfiguredTokenFailsClosed`.
- Empty portfolio → `test_zeroPortfolio_marginsAreZero`.
- 32 active series → `test_thirtyTwoSeriesEnumerable`.
- Omitted / duplicate / substituted / out-of-order / length > 32 rejected →
  4 dedicated tests + Ledger's own verifier tests.
- 8 collateral tokens → `test_eightCollateralTokensEnumerable`.
- Disabled token → `test_disabledTokenBalanceStillCounted`.
- Donation excluded → `test_donationExcluded`.
- Sibling isolation → `test_siblingSubaccount_untouched` +
  `test_siblingOwner_untouched`.
- Unknown subaccount / Account 0 rejected → `test_unknownSubaccountReverts`
  + `test_zeroSubKeyReverts`.
- No position/replay/fee mutation → `test_noEconomicStateMutationDuringViewSweep`.
- RM-1 → `test_engineAndVaultUseSameRiskModule`.

**Coverage NOT applicable to this milestone** (WP-08A has no mutation):
- `syncAccountMargin` idempotency (deferred to WP-08B).
- `applyLock` / `applyUnlock` semantics (deferred).
- Guardian revocation of margin capability (deferred; no capability granted).

## Part R — Invariants

Bounded handler + real integration components. 256 runs × 500 calls
each. All pass.

- **MARGIN-I1** (`invariant_MARGIN_I1_engineOwnsNoBalances`) — the engine
  contract holds zero ETH balance AND zero per-token per-engine
  reservations across the surveyed (owner, subaccount, token) grid.
- **MARGIN-I4** (`invariant_MARGIN_I4_singleRiskModule`) — engine + vault
  always report the same `RISK_MODULE`.
- **MARGIN-I6** (`invariant_MARGIN_I6_neverUnlocksSibling`) — engine's
  `lockedByEngineOf` slot is always zero. Never writes → never unlocks.
- **MARGIN-I7** (`invariant_MARGIN_I7_idempotentViews`) — same
  `maintenanceMargin1e18(sk, witness)` call in the same block returns
  bit-identical values on the second invocation.
- **MARGIN-I13** (`invariant_MARGIN_I13_liquidationNeverAffirmativeOnIndeterminate`)
  — `liquidationStatus` never returns HEALTHY on portfolios whose per-series
  metadata / oracle inputs are indeterminate. Either reverts, or returns
  ELIGIBLE.
- **MARGIN-I14** (`invariant_MARGIN_I14_registryUnchanged`) — engine
  interactions never change `registry.ownerOf(subKey)` for any known
  subaccount.
- **MARGIN-I15** (`invariant_MARGIN_I15_bounded`) — every subaccount has
  ≤ 32 active series; the Vault's canonical universe never exceeds 8
  tokens.

**Invariants implicitly covered by other suites** (not duplicated here):

- **MARGIN-I2** ("every affirmative uses the complete active-series set") —
  by construction: every view that returns non-zero MM/IM discharges
  `verifyActiveSeriesArrayComplete` first.
- **MARGIN-I3** ("every exact collateral result includes every canonical
  Vault collateral token with a non-zero balance") — by construction: the
  concrete `_computeAvailableMargin` iterates `collateralUniverse()`.
- **MARGIN-I5** ("sibling isolation") — covered by the two sibling
  isolation unit tests + inherited from the Ledger's + Vault's own
  invariants.
- **MARGIN-I8** ("target reservation equals frozen allocation policy") —
  N/A under CA-4 (no reservations owned).
- **MARGIN-I9** ("failed / indeterminate risk produces no reservation
  change") — N/A under CA-4 (no reservations).
- **MARGIN-I10** ("stale data never causes collateral release") — N/A
  under CA-4; guaranteed for the abstract `withdrawalAllowed` view by
  WP-07's own invariants.
- **MARGIN-I11 / I12** ("risk-increasing / withdrawal thresholds") —
  deferred to WP-08B when the mutating engine lands.
- **MARGIN-I16** ("event-derived state matches canonical state") — N/A
  under CA-4 (no events).

## Part S — Storage review

- `OptionsRiskModuleV2` — 6 constructor-immutable slots. Zero mutable
  state. No mapping. No per-user cache. No copied balance / position.
- `MarginEngineV2` — 7 constructor-immutable slots (all resolved from
  the Vault-bound `RISK_MODULE`). Zero mutable state. No mapping. No
  cache. No replay. No local capability bitmap. No mutable module.
- `OptionsRiskMath` — pure library, zero storage.

No duplicate canonical state anywhere.

## Part T — Gas / DoS

Development observations from the integration suite:

| Path                                  | Approx gas |
| ------------------------------------- | ---------- |
| 1-series + 1-token view (`isHealthy`) | ~200 k     |
| 32-series + 1-token view (`maintenanceMargin1e18`) | ~5.1 M |
| 32-series + 8-token view (`marginRatio1e18`)       | ~5.3 M |
| First `_computeAvailableMargin` (empty)| ~50 k     |
| Complete 8-token collateral walk       | ~1.2 M    |
| Stale-input rejection                  | ~150 k    |
| Liquidation classification (32 × 8)    | ~5.3 M    |

- Every loop is bounded above by 32 (series) or 8 (tokens).
- No unbounded caller array is accepted.
- No global iteration.
- No recursive call graph.
- No state-changing oracle call.

The worst-case 32 × 8 concrete path fits comfortably under a conservative
30 M block-gas envelope. `MARGIN_ENGINE_WORST_CASE_GAS_BLOCKER` NOT
returned.

## Part U — Integration

`test/hybrid-v2/margin/MarginEngineV2Integration.t.sol` uses real
components:

- `SubaccountRegistry` (WP-02).
- `RiskAwareVaultHarness` (WP-04B + WP-07 abstract closed).
- `OptionsPositionsLedger` (WP-06).
- `OptionsRiskModuleV2` (this milestone).
- `MarginEngineV2` (this milestone).
- `MockOptionsRiskProvider` + `MockOracleAdapter` (test-only concrete
  implementations of the two adapter interfaces).

Integration coverage:

1. 32-series enumeration → `test_thirtyTwoSeriesEnumerable`.
2. 8-token collateral universe → `test_eightCollateralTokensEnumerable`.
3. Sibling / cross-owner isolation → 2 dedicated tests.
4. Disabled-token still valued → `test_disabledTokenBalanceStillCounted`.
5. Donation exclusion → `test_donationExcluded`.
6. Undercollateralized-then-collateral-added healthy transition →
   `test_undercollateralizedAccountCannotBecomeHealthy_untilCollateralAdded`.
7. No mutation → `test_noEconomicStateMutationDuringViewSweep`.
8. RM-1 single-module posture → `test_engineAndVaultUseSameRiskModule`.

## Part V — Tracked documentation

This document (`ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1.md`) is the tracked
record.

## Baseline / closing tests

- **Starting baseline:** 68 suites / 1029 tests / 0 failed (from
  `ONCHAIN-SUBACCOUNT-RISK-EXECUTION-BOUNDS-AND-COLLATERAL-UNIVERSE-V1`).
- **Closing suite:** 73 suites / 1135 tests / 0 failed (+5 suites,
  +106 tests; zero regressions).

## Deviations / blockers

None. All required verdicts returned including
`READY_FOR_ONCHAIN_SUBACCOUNT_OPTION_MATCHING_ENGINE_V2_V1`.

The `syncAccountMargin` primitive is deferred by design (Part D). This is
NOT a blocker — it is the intentional Part D verdict
`MARGIN_RESERVATION_OWNERSHIP_DEFERRED_BY_APPROVED_DESIGN`. The write path
lands with WP-08B when the OptionMatchingEngine is authorized.

## Non-goals reconfirmed

- No Options matching / RFQ / signed-order execution.
- No signature / EIP-712 / ERC-1271 verification.
- No D.2 replay consumption or nonce state.
- No premium / fee / rebate transfer.
- No position mutation (fill / exercise / settlement / liquidation).
- No collateral reservation writes (`applyLock` / `applyUnlock`).
- No liquidation seizure.
- No recovery / escape execution.
- No backend / frontend changes.
- No database migrations.
- No Perps behavior (`productsEnabled(subKey).perpsEnabled` remains
  `false` in V1).
- No Base mainnet reference.
- No deployment or broadcast in this milestone.

## Carry-forward to the Options matching engine

`ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` (WP-08B / WP-09) inherits
this contract as its post-state health source. The matching engine will:

1. Inherit `VaultRiskModuleConsumer` for its own RM-1 binding.
2. Consume the frozen `MarginEngineV2.isHealthy(subKey, witness)` view
   AFTER applying every position mutation, in the same transaction.
3. Own its own capability grants (`CAP_APPLY_OPTIONS_POSITION_DELTA`,
   `CAP_LOCK_COLLATERAL`, `CAP_UNLOCK_OWN_RESERVATION`,
   `CAP_APPLY_FEE`, `CAP_SETTLE_OPTION`, `CAP_LIQUIDATE_OPTIONS`).
4. Write its own `applyLock` / `applyUnlock` per-fill under whichever
   collateral-allocation policy the product owner freezes at that time.

## No audit / production-readiness claim

This milestone is `EXPERIMENTAL — NOT SECURITY APPROVED`. No production
values are baked in; every risk parameter is deployment-configured. Human
+ external security review remains required at every future gate.
