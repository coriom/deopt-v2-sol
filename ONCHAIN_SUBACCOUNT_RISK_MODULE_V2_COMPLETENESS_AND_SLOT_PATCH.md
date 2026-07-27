# ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_COMPLETENESS_AND_SLOT_PATCH

Status: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`.
Launched: 2026-07-27.
Product-owner authorization: `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS`.
Predecessor: `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-V1` (WP-07).
Blocks: `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` (WP-08).

## Supersedes — 2026-07-27 (BOUNDEDNESS-AND-LIQUIDATION-SAFETY-PATCH)

Two Part-F/Part-J conclusions from this doc are tightened by the
subsequent
`ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-BOUNDEDNESS-AND-LIQUIDATION-SAFETY-PATCH`:

- **Part J (Single RiskModule authority)**: RM-1 is now enforced at
  the SOURCE level, not just documentation + test-only reference. The
  new abstract `src/hybrid-v2/risk/VaultRiskModuleConsumer.sol`
  provides a production consumer boundary that WP-08 MarginEngine
  MUST inherit. Its constructor takes only the Vault; the RiskModule
  is canonically sourced from `Vault.RISK_MODULE()`. Verdict:
  `SINGLE_RISKMODULE_CONSUMER_BOUNDARY_ENFORCED`.
- **Part D (Collateral completeness)**: the
  `COLLATERAL_OMISSION_PROVEN_CONSERVATIVE` verdict is affirmed for
  withdrawal / internal transfer but is INSUFFICIENT for liquidation.
  Additional verdicts:
  `COLLATERAL_OMISSION_NOT_SUFFICIENT_FOR_LIQUIDATION` and
  `LIQUIDATION_REMAINS_DISABLED_PENDING_COLLATERAL_COMPLETENESS`.
  Liquidation enforcement waits for either a bounded canonical Vault
  token enumeration (CT-2) or a deployment-fixed bounded token
  universe (CT-1).

Additionally: the WP-07 `liquidationStatus` fail-closed model
returned `ELIGIBLE_FOR_LIQUIDATION` on any hook failure, which is a
wrongful-liquidation-authority pattern. That has been corrected to
`RiskModuleUnavailable` revert (LQ-2). See the patch doc §Part G.

Full detail:
`ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_BOUNDEDNESS_AND_LIQUIDATION_SAFETY_PATCH.md`.

## Purpose

Narrow prerequisite patch before WP-08 MarginEngineV2. Resolves four
questions left implicit by WP-07:

1. Canonical Options-portfolio completeness — how the future MarginEngine
   proves a supplied series list is EXACTLY the active set (not a
   truncation, not a duplication, not a substitution).
2. Collateral-input completeness — whether omitting a token from a
   valuation set can ever inflate equity.
3. Concrete risk-formula ownership — where the formula lives (shape,
   parameters, authority).
4. Single authoritative RiskModule reference — how the Vault-side and
   the future MarginEngine-side risk decisions bind to the same module.

The rule preserved by this patch:

`FAIL CLOSED RATHER THAN ACCEPT INCOMPLETE CANONICAL INPUTS`

## Verdicts (Part K)

- Position completeness: `POSITION_PORTFOLIO_COMPLETENESS_ALREADY_PROVEN`
  (smallest additive extension: verifier view + O(1) membership check).
- Collateral completeness: `COLLATERAL_OMISSION_PROVEN_CONSERVATIVE`
  (V1 Vault has no debt / negative-equity mapping; omission monotonically
  reduces calculated equity).
- Risk formulas: `RISK_FORMULAS_RESOLVED_PARAMETERS_DEPLOYMENT_CONFIG`
  (shape frozen by legacy adoption + spec 06; parameter values deferred
  to `ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1`).
- RiskModule authority: `SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT`
  (RM-1; Vault holds the sole immutable slot; downstream consumers MUST
  source their reference from `Vault.RISK_MODULE()`).
- Backend-list dependency: `NO_BACKEND_LIST_USED_AS_CANONICAL_PORTFOLIO_PROOF`
  (backend supplies a candidate array; ledger verifies canonical).
- Patch: `RISK_MODULE_V2_COMPLETENESS_AND_SLOT_PATCH_COMPLETE`.
- Next readiness: `READY_FOR_ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1`.

## Part A / B — Preflight + baseline

- Frontend HEAD: `83e68a8` (clean; untouched).
- Backend HEAD: `4dbaf3d` (clean; untouched).
- Solidity starting HEAD: `f3fd5cf`.
- Baseline: 57 suites / 902 tests / 0 failed.
- Closing Solidity HEAD: recorded in local result doc after commit.
- Closing suite: recorded in local result doc after commit.

## Part C — Position-completeness proof

### Audit target

Can the WP-06 ledger prove that a caller-supplied `seriesIds[]` is:

1. unique;
2. composed only of active series;
3. contains every active series?

### Findings

WP-06 exposes:

- `positionOf(subKey, seriesId) view returns (OptionPosition memory)`
- `activeSeriesCount(subKey) view returns (uint32)`

The `_activeSeriesCount` counter is incremented on 0→non-zero transition
and decremented on non-zero→0 transition (per `_isPositionAllZero`,
which considers `longQuantity1e8`, `shortQuantity1e8`,
`premiumBasis1e8`, `shortPremiumRecv1e8`). A series is "active" iff its
row has any non-zero field in that set.

**Completeness proof (mathematically sound with the current storage
model)**: for a caller-supplied `seriesIds[]`, the conjunction of:

- `seriesIds.length == activeSeriesCount(subKey)` (cardinality bound),
- `seriesIds` is strictly increasing (uniqueness + canonical order),
- every element has `!_isPositionAllZero(_positions[subKey][seriesId])`
  (per-element active check)

proves set equality: the supplied array is a length-N set of distinct
active members; the active set has cardinality N; therefore the supplied
set IS the active set (no omission, no duplication, no substitution).

### Verdict

`POSITION_PORTFOLIO_COMPLETENESS_ALREADY_PROVEN`.

Smallest additive extension (pure view additions to
`IOptionsPositionsLedger` + `OptionsPositionsLedger`):

- `isActiveSeries(bytes32 subKey, uint256 seriesId) view returns (bool)`
  — O(1) canonical membership check.
- `verifyActiveSeriesArrayComplete(bytes32 subKey, uint256[] calldata seriesIds) view returns (bool)`
  — binds the three-condition completeness proof into a callable primitive.

Both are `view`; neither adds storage; neither requires a per-subaccount
maximum active-series bound. Consumers (WP-08 MarginEngine) MUST call
`verifyActiveSeriesArrayComplete` BEFORE treating any caller-supplied
series array as canonical portfolio evidence — the ledger IS the
canonical authority; the caller merely supplies a candidate.

### Latent bug surfaced + fixed

The completeness invariant surfaced a latent WP-06 bug: `applySettlement`
on a never-touched series (a state-transition-only no-op) improperly
decremented `_activeSeriesCount`. Fix: snapshot `wasActive =
!_isPositionAllZero(p)` before mutation and only call
`_maybeDecrementActive` if `wasActive`. Rationale in code comment on
`applySettlement`. Unlike `applyExercise` / `applyLiquidation` (which
revert on zero side and therefore guarantee `wasActive == true`),
`applySettlement` accepts a clean row, so this guard is required.

### Non-verdicts (not returned)

- `POSITION_PORTFOLIO_COMPLETENESS_REQUIRES_BOUNDED_ACTIVE_SET` was
  considered. It would require an explicit maximum active-series count,
  which is NOT frozen in the approved design (D-C-25 caps subaccounts
  per owner, not series per subaccount; the only bound in current specs
  is `MAX_POSITIONS_PER_BATCH = 32` in migration design 18, which
  addresses migration batching, not a per-subaccount runtime cap).
  Because the smallest additive extension above suffices without a
  maximum, we do NOT take this path and therefore do NOT return
  `ACTIVE_SERIES_BOUND_REQUIRES_PRODUCT_DECISION`. If a maximum is
  later frozen, PC-1 becomes a clean superset improvement.
- `POSITION_PORTFOLIO_COMPLETENESS_REQUIRES_CANONICAL_COMMITMENT` was
  considered (Merkle root). The mathematically equivalent proof via
  the three-condition verifier is O(N) per verify (bounded per subKey),
  requires no additional storage, and is simpler to reason about.
- `POSITION_PORTFOLIO_COMPLETENESS_REQUIRES_INCREMENTAL_RISK_AGGREGATES`
  was considered and rejected because moving risk aggregates into the
  ledger would violate the WP-07 posture
  `NO_CANONICAL_ECONOMIC_STATE_OWNED_BY_RISK_MODULE` (the aggregates
  would land in the ledger instead, entangling the ledger with risk).

## Part D — Collateral-completeness analysis

### Audit target

Can omission of a collateral token from a supplied list ever:

- increase equity?
- reduce margin requirement?
- suppress debt?
- suppress a negative token position?
- turn an unsafe risk decision into a safe one?

### Findings

The WP-04B Vault (`CollateralVaultV2.sol` + `CollateralVaultV2Core.sol`)
stores:

- `_balanceOf[subKey][token]: uint256` — always non-negative (Solidity
  0.8.x checked math prohibits underflow; no code path can drive a
  balance below zero).
- `_totalLocked[subKey][token]: uint256` — bounded by balance
  (`CorruptedLockInvariant` reverts if `locked > balance`).
- `_tokenEnabled[token]: bool` — supported-token allowlist.

There is NO debt mapping. No negative-equity mapping. No
token-specific liability mapping. Bad debt is EVENT-only per
`BadDebtSocialized`. The V1 architecture explicitly excludes negative
balances — an over-liquidation shortfall is either recovered from the
insurance fund or emitted as `BadDebtSocialized`; neither writes
negative state.

### Proof of monotone conservative omission

For any per-token equity contribution `v_token >= 0`, aggregate equity
is `E = Σ_{t in supplied} v_t`. Omitting a token drops one non-negative
term from the sum, so `E_supplied <= E_full`. Any risk decision of the
form "safe iff `E >= threshold`" or "withdrawable iff `E - delta >=
required`" is monotonically SAFER under omission. There is no set of
tokens whose omission increases `E`, reduces `required`, or suppresses a
liability (because none exist to suppress).

### Constraint on WP-08 concrete `_computeAvailableMargin`

To preserve conservative omission, the concrete WP-08 aggregation MUST
be a monotone function of the per-token contributions. Specifically:

- `_computeAvailableMargin` MUST decompose as `Σ_t f(subKey, t)` where
  `f(subKey, t) >= 0` per supported token, OR any monotonically
  non-decreasing function of the per-token map.
- No per-token dependence on the SIZE of the token set (e.g., "haircut
  = max(0, 1 - N/K)"), which would break monotonicity under omission.

### Verdict

`COLLATERAL_OMISSION_PROVEN_CONSERVATIVE`.

The vault has ONLY positive-equity token balances in V1. Omission from
an equity sum is monotonically conservative for any downstream margin
formula that respects the constraint above.

### Non-verdicts (not returned)

- `COLLATERAL_COMPLETENESS_CANONIC_FIXED_SET` — the Vault does NOT
  expose an enumerable supported-token set (`supportedTokens` is a
  `bool`-mapping, not enumerable). The RiskModule cannot walk the
  supported-token set on-chain without an additive extension to the
  Vault. This path becomes preferable ONLY when the Vault gains
  enumerable-token support; until then, conservative omission is the
  correct posture.
- `COLLATERAL_COMPLETENESS_REQUIRES_BOUNDED_ACTIVE_SET` — not required
  because conservative omission is proven; the risk answer is safe
  even under omission.

## Part E — Risk-formula completeness

### Table (per spec 06 + `IRiskModule` ABI)

| Output | Exact formula | Inputs | Units | Rounding | Params | Params frozen? | Provider | Owner |
|---|---|---|---|---|---|---|---|---|
| `marginRequirement(subKey)` | `= _computeMarginRequirement(subKey)` (hook returns `(uint256, bool)`; abstract fails closed on `ok=false`) | `subKey` | 1e18 | (concrete) | (concrete) | Values: DEPLOYMENT-CONFIG | (concrete) | Abstract: WP-07; concrete: WP-08 |
| `availableMargin(subKey)` | `= _computeAvailableMargin(subKey)` (hook returns `(uint256, bool)`) | `subKey` | 1e18 | (concrete) | (concrete) | Values: DEPLOYMENT-CONFIG | (concrete) | Abstract: WP-07; concrete: WP-08 |
| `marginHealthy(subKey)` | `available >= required` (both via hooks) | `subKey` | bool | N/A | none | Frozen | Hooks | WP-07 |
| `marginRatio(subKey)` | `available * 1e18 / required` (or `type(uint256).max` when `required == 0`) | `subKey` | 1e18 | `Floor` (Solidity `/`) | none | Frozen | Hooks | WP-07 |
| `withdrawalAllowed(subKey, token, amount)` | `available - delta >= required && delta <= available && amount <= availableOf(subKey, token) && supportedTokens(token)` | `subKey`, `token`, `amount` | bool | conservative | none | Frozen | Hooks + Vault | WP-07 |
| `transferAllowed(sourceSubKey, token, amount)` | mirrors `withdrawalAllowed` on the source side | `sourceSubKey`, `token`, `amount` | bool | conservative | none | Frozen | Hooks + Vault | WP-07 |
| `liquidationStatus(subKey)` | `available >= required → HEALTHY`; else `_isWarnStatus() → WARN`; else `ELIGIBLE_FOR_LIQUIDATION`; fail closed on any hook failure | `subKey` | enum | conservative | WARN threshold | WARN threshold: DEPLOYMENT-CONFIG | Hooks | Abstract: WP-07; WARN threshold: WP-08 concrete |
| `productsEnabled(subKey)` | `(optionsEnabled = _optionsProductEnabled(subKey), perpsEnabled = false)` in V1 | `subKey` | bools | N/A | none | Frozen | `_optionsProductEnabled` hook | WP-07; perps=false frozen for V1 |
| `moduleVersion()` | constructor `moduleVersion_` (immutable) | none | uint16 | N/A | none | Frozen at deploy | none | WP-07 |
| `supportsCanonicalStorageVersion(v)` | `v == Versions.STORAGE_VERSION` (== 1 in V1) | `v` | bool | N/A | none | Frozen | none | WP-07 |

### Per-position risk formulas (source: legacy DeOpt V1 `src/risk/RiskModuleMargin.sol`)

The DeOpt V1 margin model is already frozen in legacy Solidity and is
inherited by V2 via porting to the per-subKey model. Model shape:

```
MM_per_contract = max(
    current intrinsic liability (base-native units),
    stressed liability (spot shock + vol shock via OptionProductRegistry.underlyingConfigs),
    base MM floor per contract (OptionProductRegistry.optionRiskConfigs)
)

IM_per_contract = ceil(MM_per_contract * imFactorBps / 10000)

Fallback (oracle down):
    MM_per_contract = ceil(baseMmFloor * oracleDownMmMultiplierBps / 10000)
```

Aggregation:

```
optionsMarginRequirement(subKey)
    = Σ_{seriesId in active} shortQuantity1e8 * MM_per_contract(seriesId) / 1e8

perpsMarginRequirement(subKey) = 0                          // V1: perps disabled
crossOffset(subKey)            = 0                          // V1: no cross-product offset
marginRequirement(subKey)      = optionsMarginRequirement(subKey)
```

The `active` set is proven via `verifyActiveSeriesArrayComplete`
(Part C). The per-series MM is computed via oracle price +
OptionProductRegistry metadata; concrete parameters
(`baseMmFloorPerContract`, `imFactorBps`, `oracleDownMmMultiplierBps`,
`spotShockUpBps`, `spotShockDownBps`, `volShockUpBps`) are frozen
per-underlying by `OptionProductRegistry.optionRiskConfigs` at admin
time and are the DEPLOYMENT-CONFIG values deferred to
`ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1` per spec 06 § "What this
spec does NOT decide".

### Verdict

`RISK_FORMULAS_RESOLVED_PARAMETERS_DEPLOYMENT_CONFIG`.

Formula shape + units + conservative bounds + authority are all frozen
(via legacy inheritance + spec 06 + `OptionProductRegistry`). Parameter
values are deployment-configurable per approved governance timelock
(D-C-11) and are the deferred set for SECURITY-REVIEW-PREP. This is the
"secure interpretation" the prompt permits: "deployment-configurable
values are acceptable only when formulas, units, conservative bounds
and authority are already frozen."

### Non-verdicts (not returned)

- `RISK_FORMULAS_REQUIRE_PRODUCT_RISK_DECISION` — not returned because
  formulas ARE resolved (via legacy adoption).
- `RISK_FORMULA_SPEC_CONFLICT` — not returned because there is no
  conflict; the legacy model is well-defined and aligned with spec 06's
  aggregate shape.

## Part F — Single RiskModule authority

### Consumers audited

| Consumer | Decision path | Current source | Immutability | Replacement authority | Compatibility validation | Can diverge from other consumers? |
|---|---|---|---|---|---|---|
| `CollateralVaultV2RiskIntegrated` (production Vault base) | `_requireWithdrawalAllowed` / `_requireInternalTransferAllowed` → `withdrawalAllowed` / `transferAllowed` | `RISK_MODULE` immutable, set in constructor | Immutable per Vault | Full Vault redeploy (spec 06 §C-01) | Registry match + `ARCHITECTURE_VERSION` match + `supportsCanonicalStorageVersion` returns true | NO |
| `RiskModuleV2` (abstract module) | Owns its own logic; abstract views only | Not applicable | Immutable references to Registry / Vault / Ledger | New module deploy = new Vault deploy | Constructor: non-zero args + Registry inherited from cross-checks in Vault | NO |
| WP-08 `MarginEngineV2` (future) | Consumes Vault's risk answers; also may call `marginRequirement` directly | MUST source from `Vault.RISK_MODULE()` — never accept an independent arg | Immutable per MarginEngine deploy | Full MarginEngine redeploy (bound to the same Vault or a new Vault) | Constructor: `RISK_MODULE = CollateralVaultV2RiskIntegrated(vault_).RISK_MODULE()` | NO |
| WP-10 `EscapeController` (future) | Same pattern | Same | Same | Same | Same | NO |

### Verdict

`SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT` (RM-1).

The Vault holds the sole immutable slot. Downstream consumers MUST
source their reference from `Vault.RISK_MODULE()`. This pattern is
tested via `DownstreamConsumerCorrect` in
`test/hybrid-v2/risk/RiskModuleV2SlotAuthority.t.sol`. The counter-
example `DownstreamConsumerDivergent` is included ONLY to document what
MUST NOT be built — the tracked doc is the enforcement mechanism until
a MarginEngine actually ships.

### Non-verdicts (not returned)

- `SHARED_TIMELOCKED_RISK_MODULE_SLOT` (RM-2) — deferred to WP-08 or
  later. RM-1 is the strictly stronger posture for V1: no in-place
  rotation surface at all. If governance later needs live rotation,
  RM-2 becomes an additive design.
- `SEPARATE_RISK_MODULES_EXPLICITLY_JUSTIFIED` (RM-3) — no separate
  module kinds exist; every overlapping economic decision path binds
  the SAME `IRiskModule`.
- `RISK_MODULE_AUTHORITY_MODEL_CONFLICT` — no conflict; every consumer
  binds via the canonical pattern.

## Part G — Required corrections implemented

- `src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol` — add
  `isActiveSeries` + `verifyActiveSeriesArrayComplete` view functions to
  the interface with full NatSpec explaining the completeness proof.
- `src/hybrid-v2/positions/OptionsPositionsLedger.sol` — implement both
  new views. Fix latent WP-06 bug in `applySettlement`
  (`wasActive` snapshot guard on `_maybeDecrementActive`) — required
  by the new invariant `RISK-COMP-I2` (count equals |active set|).

Explicitly NOT implemented (out of scope for this milestone per
authorization):

- No MarginEngine.
- No matching, no fees, no premium transfer, no liquidation execution.
- No new admin surface on the RiskModule.
- No placeholder margin formulas.
- No enumerable-token extension to the Vault (would open a design
  surface + require a governance decision on canonical token ordering).
- No shared timelocked RiskModule slot / router.

## Part H + I — Tests + invariants

### New test files

1. `test/hybrid-v2/positions/OptionsPositionsLedgerCompleteness.t.sol` —
   28 unit + fuzz tests for the verifier + membership primitives
   covering: empty account, single series, missing / extra / duplicate /
   substituted / out-of-order / zero-input cases, sibling isolation
   (across owners AND across a single owner's siblings), lifecycle
   stability (settle / exercise / liquidation), reconstruction-from-events
   pattern, and three fuzz sweeps.
2. `test/hybrid-v2/positions/OptionsPositionsLedgerCompletenessInvariant.t.sol`
   — 4 invariants at 64 × 64 handler calls each:
   - `invariant_COMP_I2_countMatchesMembership` — count equals
     Σ `isActiveSeries` over the handler's series pool.
   - `invariant_COMP_I1_omissionRejected` — any strict subset of the
     canonical active set is rejected by `verifyActiveSeriesArrayComplete`.
   - `invariant_COMP_I5_siblingIsolation` — one subKey's canonical
     array never verifies for a sibling with a different count.
   - `invariant_COMP_I2_canonicalArrayVerifies` — the canonical
     reconstruction always verifies (positive direction).
3. `test/hybrid-v2/risk/RiskModuleV2SlotAuthority.t.sol` — 9 tests for
   the RM-1 slot pattern: canonical consumer binds Vault's module,
   consumers agree across instances, module reference is immutable,
   incompatible module rejected at Vault construction, module has no
   admin setter for canonical state, replacement requires fresh Vault
   redeploy, and documented divergent-pattern counter-example.

### Invariants asserted (this milestone)

- `RISK-COMP-I1` — no affirmative completeness under omission (unit + invariant).
- `RISK-COMP-I2` — count equals |active set| (invariant + unit).
- `RISK-COMP-I3` — 0 → non-zero adds one to count (covered by RISK-COMP-I2 + WP-06 tests).
- `RISK-COMP-I4` — non-zero → 0 removes one (covered by RISK-COMP-I2 + `wasActive` fix in `applySettlement`).
- `RISK-COMP-I5` — sibling isolation (invariant + unit).
- `RISK-COMP-I6` — collateral omission cannot improve risk (proven mathematically; test in RiskModule integration suite already covers "donation does not improve equity"; not restated).
- `RISK-SLOT-I1` — every overlapping consumer binds the same module (canonical consumer test + immutability test).
- `RISK-SLOT-I2` — incompatible module cannot bind (Vault constructor gate test).
- `RISK-SLOT-I3` — module config does not mutate canonical state
  (`test_moduleHasNoAdminSetterForCanonState` + existing WP-07
  RISK-I1).

### Reconstruction

`test_verify_reconstructionFromEvents` demonstrates the DB-loss
runbook: an off-chain indexer that observed
`OptionPositionOpened(subKey, seriesId, ...)` events can reconstruct
the historical series set, filter by current `isActiveSeries`, sort in
canonical order, and pass the result to
`verifyActiveSeriesArrayComplete` for canonical validation. No trust in
the indexer; the ledger is the sole authority.

## Part J — Documentation

- This tracked doc (new).
- `ONCHAIN_SUBACCOUNT_OPTIONS_POSITIONS_LEDGER_V1.md` — dated superseding
  note recording (a) the new verifier + membership views, (b) the
  `wasActive` fix in `applySettlement`.
- `ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_V1.md` — dated superseding note
  recording (a) that the RiskModule interface used by production Vault
  is now bound to the Vault-side `RISK_MODULE` immutable per RM-1,
  (b) that MarginEngine (WP-08) MUST source its module from
  `Vault.RISK_MODULE()`, (c) that Part C's "backend-provided arrays"
  concern is resolved by ledger-side verification of caller-supplied
  arrays.
- Local (`~/DEOPT/docs/`) result doc.
- `RUN_STATE.md` — new dated section prepended.

## Part K — Verdict summary

- `POSITION_PORTFOLIO_COMPLETENESS_ALREADY_PROVEN`
- `COLLATERAL_OMISSION_PROVEN_CONSERVATIVE`
- `RISK_FORMULAS_RESOLVED_PARAMETERS_DEPLOYMENT_CONFIG`
- `SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT`
- `NO_BACKEND_LIST_USED_AS_CANONICAL_PORTFOLIO_PROOF`
- `RISK_MODULE_V2_COMPLETENESS_AND_SLOT_PATCH_COMPLETE`
- `READY_FOR_ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1`

## Part L — Validation summary

Recorded in the local result doc after commit.

## Deviations / blockers

None.

## Safety posture

- Deployment: NO.
- Broadcast: NO.
- Base mainnet touched: NO.
- Backend / frontend touched: NO.
- Database migrations: NO.
- Secrets exposed: NO.
- All repositories clean at close: recorded in local result doc.

## Exact next milestone

`ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` (WP-08) — requires separate
product-owner launch prompt.
