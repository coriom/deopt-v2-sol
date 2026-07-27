# ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_BOUNDEDNESS_AND_LIQUIDATION_SAFETY_PATCH

Status: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`.
Launched: 2026-07-27.
Product-owner authorization: `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS`.
Predecessor: `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-COMPLETENESS-AND-SLOT-PATCH`.
Blocks (unresolved): `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` (WP-08) is
BLOCKED pending an approved active-series maximum — see Part C / Part D.

## Purpose

Narrow prerequisite safety patch before WP-08 MarginEngineV2. Resolves
four questions left open by the completeness patch:

1. Gas-bounded canonical Options portfolio validation.
2. Context-correct collateral completeness (withdrawal vs liquidation).
3. Fail-safe liquidation eligibility under indeterminate risk inputs.
4. Enforceable single-RiskModule consumption by future consumers.

Rule preserved:

`FAIL CLOSED WITHOUT CREATING WRONGFUL LIQUIDATION AUTHORITY`

The meaning of fail-closed depends on the operation:
- Withdrawal / internal-transfer uncertainty → REJECT user operation.
- Liquidation uncertainty → REJECT liquidation authorization.
- Never convert missing information into permission to seize collateral.

## Verdicts (Part N)

- **Active-series boundedness (Part C):** `ACTIVE_SERIES_BOUND_REQUIRES_PRODUCT_DECISION`.
- **Collateral by operation (Part F):**
  - `COLLATERAL_OMISSION_CONSERVATIVE_FOR_USER_OUTFLOWS`
  - `COLLATERAL_OMISSION_NOT_SUFFICIENT_FOR_LIQUIDATION`
  - `COLLATERAL_LIQUIDATION_COMPLETENESS_REQUIRES_EXTENSION`
- **Liquidation-collateral model (Part I):** `LIQUIDATION_REMAINS_DISABLED_PENDING_COLLATERAL_COMPLETENESS`.
- **Liquidation fail-safe (Part G):** `INDETERMINATE_RISK_CANNOT_AUTHORIZE_LIQUIDATION` (post-fix).
- **Single-RiskModule enforcement (Part J):** `SINGLE_RISKMODULE_CONSUMER_BOUNDARY_ENFORCED` (via new `VaultRiskModuleConsumer`).
- **Formula status (Part K):** `RISK_FORMULAS_FROZEN_PROVIDER_IMPLEMENTATION_DEFERRED`.
- **Milestone:** `RISK_MODULE_V2_BOUNDEDNESS_AND_LIQUIDATION_SAFETY_PATCH_COMPLETE`
  (for the parts this patch is authorized to address).
- **WP-08 readiness:** NOT RETURNED. `READY_FOR_ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1`
  cannot be issued because the active-series maximum is a product
  decision required by WP-08 (see Exact-next-milestone).

## Part A / B — Preflight + baseline

- Frontend HEAD: `83e68a8` (clean, untouched).
- Backend HEAD: `4dbaf3d` (clean, untouched).
- Solidity starting HEAD: `1c1fe90`.
- Baseline: 60 suites / 943 tests / 0 failed (~308s).

## Part C — Active-series gas boundedness

### Audit

The completeness patch proved LOGICAL set equality between a
caller-supplied array and the canonical active set, but did NOT prove
GAS EXECUTABILITY of validating or valuing a complete portfolio.

Current storage bounds:
- `_activeSeriesCount[subKey]: uint32` — max `type(uint32).max ≈ 4.3 × 10^9`
  active series per subaccount. Overflow reverts (see `applyFill` +
  `OptionActiveSeriesOverflow`), but a max at 4.3 billion is
  functionally unbounded for on-chain gas.

Gas surface for the concrete WP-08 `_computeMarginRequirement`
(un-implemented):
- Per series: 1 SLOAD for the position row, 1 external oracle call, 1
  external `OptionProductRegistry` metadata call, ~1 SSTORE-free math
  block. Rough envelope ~5–20 k gas per series (varies wildly with
  cache + oracle vendor).
- N-series portfolios at N = 500 → ~5 M gas; N = 5000 → ~50 M gas;
  Base block gas limit is 30 M. **Portfolios of a few thousand active
  series break the block gas limit.**

Withdrawal path currently reads `activeSeriesCount` only via the
verifier + delegates aggregate computation to the abstract hooks — the
abstract itself is O(1). The DoS risk is in the CONCRETE WP-08
implementation that will walk the portfolio.

**Adversary model**: a user opens many small option positions (long or
short) to inflate their own `activeSeriesCount`. Once the count is
large enough that risk validation exceeds the block gas limit, that
subKey becomes un-liquidatable, un-withdrawable, and un-transferable —
locking the user in and creating a socialized-loss vector for the
protocol (uncollectible bad debt on the user's short positions).

### Table

| Portfolio size | Verifier gas (current) | Position-read gas | Provider calls (est.) | Total risk-check (est.) | Fits under Base 30 M? |
|---|---|---|---|---|---|
| 1  | ~20 k  | ~2 k  | 2 | ~30 k    | yes |
| 10 | ~50 k  | ~20 k | 20 | ~200 k   | yes |
| 100 | ~500 k | ~200 k | 200 | ~2 M   | yes |
| 1000 | ~5 M | ~2 M | 2000 | ~20 M | marginal |
| 10 000 | ~50 M | ~20 M | 20 000 | ~200 M | NO |
| `type(uint32).max` | ∞ | ∞ | ∞ | ∞ | NO |

The numbers are rough envelopes for reasoning only — **not** production
gas promises.

### Verdict

`ACTIVE_SERIES_BOUND_REQUIRES_PRODUCT_DECISION`.

Neither the contract spec nor any tracked design document freezes a
per-subaccount runtime maximum for active option series. The migration
design's `MAX_POSITIONS_PER_BATCH = 32` is RECOMMENDED for MIGRATION
BATCHES (per D-MIG-17 status), not a runtime cap; D-C-25 addresses
subaccounts-per-owner (also no hard cap). Per prompt instruction: "Do
not invent the numeric maximum." No source change is shipped for the
bound in this patch.

## Part D — Acceptable boundedness models (surfaced, not implemented)

- **AB-1** (frozen maximum active-series count per subaccount):
  requires an approved numeric max. Not available.
- **AB-2** (bounded canonical commitment/proof): requires a maximum
  proof size (still requires a max) and a commitment scheme. Not
  approved.
- **AB-3** (bounded incremental risk aggregates): would move economic
  risk state into the position ledger, which the WP-07 posture
  (`NO_CANONICAL_ECONOMIC_STATE_OWNED_BY_RISK_MODULE`) explicitly
  forbids without approval.

Selection is deferred to a product decision. See Exact-next-milestone.

## Part E — Gas-liveness safety (unresolved)

Under an active-series maximum M, the following invariants MUST hold
for WP-08 to be shippable (they are documented here for tracking; they
CANNOT be exercised without M):

- **RISK-BOUND-I1**: every canonical active portfolio accepted by the
  ledger is within the protocol's maximum executable risk-validation
  size (= M).
- **RISK-BOUND-I2**: when the active-series maximum M is reached, the
  risk-reducing close / exercise / settlement / liquidation-quantity-
  reduction paths remain operable when their normal preconditions hold
  (the ledger MUST NOT block a user from reducing risk when they are
  at the cap).

The completeness patch's verifier `verifyActiveSeriesArrayComplete`
already guarantees canonical set equality. Adding an M cap turns the
verifier's return-value into a proof of "the caller-supplied array is
the FULL portfolio AND its size is at most M" — a sufficient basis
for bounded gas in WP-08.

Until M is frozen, WP-08 MUST NOT liquidate. This patch enforces that
policy by:
- Fail-safe `liquidationStatus` (Part G) — refuses to authorize on
  indeterminate hooks, which every WP-08 concrete inheritor would hit
  when the portfolio walk fails.
- `LIQUIDATION_REMAINS_DISABLED_PENDING_COLLATERAL_COMPLETENESS` (Part
  I) — additional block on the concrete WP-08 turning on liquidation.

## Part F — Collateral completeness by operation

### Withdrawal + internal transfer

Omitting a non-negative collateral asset from an equity sum monotone
reduces calculated equity → the safety-negative direction. This
produces at worst a FALSE NEGATIVE (reject a safe operation), never a
false positive (permit an unsafe one). **Safe under omission.**

Verdict: `COLLATERAL_OMISSION_CONSERVATIVE_FOR_USER_OUTFLOWS`.

### Liquidation eligibility

Omitting a non-negative collateral asset can reduce calculated equity
below the maintenance threshold, flipping a HEALTHY account to
ELIGIBLE. That is a WRONGFUL AFFIRMATIVE liquidation decision. It is
NOT a safe false negative. **Not safe under omission.**

Verdict: `COLLATERAL_OMISSION_NOT_SUFFICIENT_FOR_LIQUIDATION`.

### Health display

The current abstract `marginHealthy(subKey)` returns `available >=
required` (bool), where both sides come from the concrete hooks. A
concrete WP-08 walking an incomplete collateral set would return a
LOWER-BOUND health value. There is no ABI mechanism to surface
"lower-bound vs exact"; the boolean IS interpreted as exact.

Because the current Vault does not expose a canonical enumerable
supported-token set (`supportedTokens` is a `bool` mapping, not
enumerable), concrete WP-08 implementations of
`_computeAvailableMargin` MUST rely on a caller-supplied token list.
For withdrawal/transfer this is safe (conservative omission); for
liquidation it is NOT safe.

Verdict: `COLLATERAL_LIQUIDATION_COMPLETENESS_REQUIRES_EXTENSION` —
until either the Vault gains enumerable supported-token support (CT-2)
or a deployment-fixed bounded token universe is approved (CT-1),
liquidation eligibility on the concrete WP-08 MUST NOT be affirmative.

## Part G — Liquidation fail-safe semantics

### Pre-patch behavior (unsafe)

`liquidationStatus(subKey)` returned `ELIGIBLE_FOR_LIQUIDATION`
whenever ANY hook returned `ok=false` (stale provider, per-subKey
stale, or would-revert). It also returned ELIGIBLE for zero and
unknown subKeys. The rationale in the NatSpec was "downstream
liquidation execution independently verifies before seizing
collateral, so this default cannot itself trigger seizure" — but this
delegates safety to a WP-08 that does not exist yet, and violates
spec 06 § "Behaviour when the risk module is unavailable":
"Liquidation triggers MUST NOT trigger if `liquidationStatus` cannot
be computed."

Any consumer that reads the enum and trusts the affirmative value
would get **wrongful liquidation authority** from an unavailable risk
module. This is exactly the failure mode Part G calls out:
`INDETERMINATE_RISK_CAN_AUTHORIZE_LIQUIDATION_UNSAFELY`.

### Post-patch behavior (fail-safe)

`liquidationStatus(subKey)` now:
- reverts `SubKeyRequired` on `bytes32(0)`;
- reverts `UnknownSubaccount(subKey)` on an unregistered subKey;
- reverts `RiskModuleUnavailable` when either
  `_computeMarginRequirement` or `_computeAvailableMargin` returns
  `ok=false`;
- returns `HEALTHY` when `available >= required`;
- returns `WARN` when `_isWarnStatus` says so (concrete override);
- returns `ELIGIBLE_FOR_LIQUIDATION` ONLY when both hooks succeeded
  AND `available < required` AND `_isWarnStatus == false`.

Model selected: **LQ-2 (revert on indeterminate liquidation)**. The
frozen 3-value `LiquidationStatus` enum has no INDETERMINATE state
and adding one would break the WP-01 frozen ABI. LQ-3 (return
non-liquidatable) would misuse the HEALTHY / WARN values — neither
semantically means "unknown". LQ-2 matches the identical pattern
already used by `marginRequirement` / `availableMargin` / `marginRatio`
(all revert `RiskModuleUnavailable` on hook failure).

Consumers (WP-08 execution) MUST wrap the call in try/catch and treat
any revert as "no authority". The test
`test_documentsConsumerTryCatchPattern` demonstrates this pattern
inline.

### Verdict

`INDETERMINATE_RISK_CANNOT_AUTHORIZE_LIQUIDATION`.

## Part H — Required liquidation tests

Test file: `test/hybrid-v2/risk/RiskModuleV2LiquidationFailSafe.t.sol`
(14 unit + property tests) +
`test/hybrid-v2/risk/RiskModuleV2LiquidationFailSafeInvariant.t.sol`
(3 invariants at 64 × 64 depth).

Coverage:
- Zero subKey → revert.
- Unknown subaccount → revert.
- Global stale provider → revert.
- Per-subKey stale → revert.
- Requirement hook fails → revert.
- Healthy account → HEALTHY.
- Equal available and required → HEALTHY.
- Shortfall → ELIGIBLE.
- Zero requirement → HEALTHY (0 >= 0).
- Sibling subKey does not affect status.
- Classification does not mutate canonical Registry / Vault / Ledger
  state.
- Classification revert does not mutate canonical state.
- Affirmative ELIGIBLE requires both hooks succeeded (positive proof).
- Documented consumer try/catch pattern.
- Invariant `LIQ_I1` — indeterminate never authorizes across a fuzz
  handler.
- Invariant `LIQ_I2` — affirmative ELIGIBLE requires ghost `required
  > available` (positive proof under a fuzz handler).
- Invariant `LIQ consumerTryCatchNeverAuthorizesOnRevert` — the
  documented WP-08 consumer pattern never authorizes on a revert.

Missing-metadata / stale-price / provider-revert / unsupported-token /
unsupported-series / future-dated-price / invalid-decimals cases are
all exercised through the harness's `providerStale`, `subKeyStale`,
`tokenStale`, and `tokenPrice1e8Of == 0` toggles — the abstract's
fail-closed model collapses every one of these into
`ok=false → RiskModuleUnavailable revert`.

Omitted-positive-collateral-cannot-authorize-liquidation: proven by
the fact that WP-08 CANNOT be shipped with liquidation enabled until
Part I is resolved (see below).

Genuinely-unhealthy-complete-state-classified-correctly: covered by
`test_shortfallReturnsEligible` and invariant `LIQ_I2`.

Healthy-complete-state-never-liquidatable: covered by
`test_healthyAccountReturnsHealthy` and
`test_equalAvailableAndRequiredReturnsHealthy`.

Exact-maintenance-threshold-follows-frozen-rule: `available >=
required` is the frozen spec 06 rule; verified via the two above.

## Part I — Collateral full-set model

### Audit

WP-04B Vault:
- `_tokenEnabled[token]: mapping(address => bool)` — supported tokens.
  NO enumerable set; NO length view; NO index view.
- `supportedTokens(address)` view: bool membership only.

CT-1 (deployment-fixed bounded token universe): would require the
RiskModule (or a concrete Vault variant) to hold an immutable token
list at construction. Not currently the case. Would ALSO require
governance to lock the token list forever, which conflicts with
`addSupportedToken` / `removeSupportedToken` timelocked governance
(spec 03 §Admin).

CT-2 (bounded canonical Vault token enumeration): requires the Vault
to expose `supportedTokensAt(uint256) → address` +
`supportedTokensLength() → uint256`, plus track add/remove
consistency, plus a maximum cap. NOT in the current Vault. Adding it
would be a scoped WP-04B extension — not authorized by this milestone
(prompt scope: "Do not introduce a second token policy authority").

CT-3 (liquidation disabled until complete collateral proof exists):
withdrawal / transfer views remain available under conservative
omission; liquidation eligibility remains unavailable or
non-authorizing until CT-1 or CT-2 lands.

### Verdict

`LIQUIDATION_REMAINS_DISABLED_PENDING_COLLATERAL_COMPLETENESS`.

The abstract's `liquidationStatus` REMAINS callable but concrete WP-08
inheritors MUST NOT enable liquidation execution until (a) the
completeness patch's active-series proof is complemented by a canonical
collateral universe (CT-1 or CT-2), AND (b) the active-series maximum
is frozen.

Because the abstract's `_computeAvailableMargin` is a hook that
returns `(value, ok)`, a WP-08 concrete inheritor that cannot prove
complete collateral simply returns `ok=false` and the fail-safe
`liquidationStatus` reverts. No affirmative liquidation authority can
be issued.

## Part J — Single RiskModule enforcement

### Pre-patch state

The completeness patch documented the RM-1 pattern:
```
RISK_MODULE = CollateralVaultV2RiskIntegrated(vault_).RISK_MODULE();
```
and shipped `DownstreamConsumerCorrect` as a TEST-ONLY reference
consumer in `test/hybrid-v2/risk/RiskModuleV2SlotAuthority.t.sol`.

But there was NO production `abstract` boundary a future WP-08
MarginEngineV2 could inherit to enforce this pattern. A future WP-08
that ignored the documentation and took
`constructor(address vault, address independentRiskModule)` would
compile and deploy — the rule was documentation-only.

### Post-patch state

New production source file:
`src/hybrid-v2/risk/VaultRiskModuleConsumer.sol` — abstract contract
whose constructor:
- takes ONLY `address vault_`;
- reads `IRiskModule module = CollateralVaultV2RiskIntegrated(vault_).RISK_MODULE()`;
- rejects `vault_ == 0` (`InvalidVault`);
- rejects `module == 0` (`RiskModuleNotBoundOnVault`);
- re-verifies architecture version (defence in depth) —
  `RiskModuleArchitectureMismatch`;
- re-verifies canonical storage version (defence in depth) —
  `RiskModuleStorageVersionUnsupported`;
- stores `VAULT` + `RISK_MODULE` + `ARCHITECTURE_VERSION` +
  `SUPPORTED_STORAGE_VERSION` as `public immutable`;
- exposes no setter, no rotation, no admin surface.

Future WP-08 MarginEngineV2 MUST inherit `VaultRiskModuleConsumer`. It
CANNOT accept a second independent RiskModule argument without visibly
shadowing the parent's `RISK_MODULE` immutable (which would be a
review-flagged deviation).

Test file: `test/hybrid-v2/risk/VaultRiskModuleConsumer.t.sol` — 9
tests including happy path, zero-vault rejection, architecture
mismatch (via mock Vault + stub module), storage-version rejection,
Vault-with-zero-module rejection, two consumers agree, immutable
version pins, replacement policy (fresh redeploy = fresh cutover),
and documentation of absence of independent module arg.

### Verdict

`SINGLE_RISKMODULE_CONSUMER_BOUNDARY_ENFORCED`.

## Part K — Formula implementation status

| Formula | Frozen? | Implemented in production source? | Abstract hook? | Provider dependency | Parameter source | MarginEngine dependency |
|---|---|---|---|---|---|---|
| `MM_per_contract` (max of intrinsic / stressed / floor) | YES (legacy `src/risk/RiskModuleMargin.sol`) | NO in hybrid-v2 | `_computeMarginRequirement` | Oracle + OptionProductRegistry | `OptionProductRegistry.optionRiskConfigs` per-underlying | WP-08 concrete |
| `IM_per_contract = ceil(MM * imFactorBps / 10000)` | YES | NO in hybrid-v2 | (same) | (same) | (same) | WP-08 concrete |
| Oracle-down fallback `ceil(baseMmFloor * oracleDownMmMultiplierBps / 10000)` | YES | NO in hybrid-v2 | (same) | (same) | (same) | WP-08 concrete |
| Options aggregate: `Σ_active shortQty * MM_per_contract / 1e8` | YES (spec 06 aggregate rule) | NO in hybrid-v2 | `_computeMarginRequirement` | Ledger + oracle + registry | (same) | WP-08 concrete |
| Available margin (per-token summation, monotone) | YES (spec 06 + WP-07 abstract hook) | NO in hybrid-v2 | `_computeAvailableMargin` | Oracle + Vault | Deployment-config | WP-08 concrete |
| Withdrawal delta valuation | YES (spec 06) | NO in hybrid-v2 | `_valueOfWithdrawnAmount` | Oracle | Deployment-config | WP-08 concrete |

Every formula shape is FROZEN (via spec 06 aggregate rule + legacy
DeOpt V1 `src/risk/RiskModuleMargin.sol` for per-contract MM). Concrete
implementation lives in WP-08. The WP-07 abstract has NO permissive
default: every `_compute*` hook is `internal view virtual` returning
`(uint256, bool)` with the abstract itself failing closed when `ok=false`.

### Verdict

`RISK_FORMULAS_FROZEN_PROVIDER_IMPLEMENTATION_DEFERRED`.

This is the acceptable verdict per the prompt's guidance: "acceptable
only when WP-08 is explicitly designed to remain abstract until the
approved provider-backed implementation exists." That is exactly the
WP-07 posture: WP-08 will bind the oracle / OptionProductRegistry /
concrete formulas; the WP-07 abstract provides only the safety-negative
scaffolding.

No formulas are inside the (would-be) MarginEngine to "bypass the
RiskModule boundary" — WP-08 concrete RiskModule extends
`RiskModuleV2` and implements the hooks.

## Part L — Required source changes

Implemented:

- `src/hybrid-v2/risk/RiskModuleV2.sol` — `liquidationStatus` now
  reverts on indeterminate risk state (fail-safe LQ-2). NatSpec
  updated with rationale + spec 06 citation + supersession note.
- `src/hybrid-v2/interfaces/IRiskModule.sol` — NatSpec on
  `liquidationStatus` updated to record the fail-safe requirement.
- `src/hybrid-v2/risk/VaultRiskModuleConsumer.sol` (NEW) — abstract
  production consumer boundary for RM-1 enforcement.
- `test/hybrid-v2/risk/RiskModuleV2LiquidationFailSafe.t.sol` (NEW).
- `test/hybrid-v2/risk/RiskModuleV2LiquidationFailSafeInvariant.t.sol`
  (NEW).
- `test/hybrid-v2/risk/VaultRiskModuleConsumer.t.sol` (NEW).
- `test/hybrid-v2/risk/RiskModuleV2.t.sol` — two pre-existing tests
  that asserted the unsafe `ELIGIBLE_FOR_LIQUIDATION-on-failure`
  behavior updated to assert the new revert behavior.
- `test/hybrid-v2/risk/RiskModuleV2Invariant.t.sol` — pre-existing
  invariant `invariant_I4_I5_stateReflectsProviderStale` updated to
  assert `liquidationStatus` reverts (not returns ELIGIBLE) on stale
  provider.

Not implemented (explicit non-scope):
- Active-series maximum enforcement (product decision required).
- Enumerable supported-token set on the Vault (would require WP-04B
  extension).
- MarginEngine, matching, signatures, replay changes, premium
  transfer, liquidation execution, fees, settlement.

## Part M — Documentation

- This tracked doc (new).
- `ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_V1.md` — dated superseding note
  recording the liquidation fail-safe fix + new consumer boundary.
- `ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_COMPLETENESS_AND_SLOT_PATCH.md` —
  dated superseding note tightening the RM-1 documentation to
  reference the new production boundary.
- Local: `~/DEOPT/docs/ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_BOUNDEDNESS_AND_LIQUIDATION_SAFETY_PATCH_RESULT.md`.
- `RUN_STATE.md` — new dated section prepended.

## Part N — Verdict summary

- `ACTIVE_SERIES_BOUND_REQUIRES_PRODUCT_DECISION`
- `COLLATERAL_OMISSION_CONSERVATIVE_FOR_USER_OUTFLOWS`
- `COLLATERAL_OMISSION_NOT_SUFFICIENT_FOR_LIQUIDATION`
- `COLLATERAL_LIQUIDATION_COMPLETENESS_REQUIRES_EXTENSION`
- `LIQUIDATION_REMAINS_DISABLED_PENDING_COLLATERAL_COMPLETENESS`
- `INDETERMINATE_RISK_CANNOT_AUTHORIZE_LIQUIDATION`
- `SINGLE_RISKMODULE_CONSUMER_BOUNDARY_ENFORCED`
- `RISK_FORMULAS_FROZEN_PROVIDER_IMPLEMENTATION_DEFERRED`
- `RISK_MODULE_V2_BOUNDEDNESS_AND_LIQUIDATION_SAFETY_PATCH_COMPLETE`
- **`READY_FOR_ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1` NOT RETURNED**
  — pending the active-series maximum product decision.

## Part O — Final validation

Recorded in local result doc after commit.

## Safety posture

- Deployment: NO.
- Broadcast: NO.
- Base mainnet touched: NO.
- Backend / frontend / migrations: NO.
- Secrets exposed: NO.
- All repositories clean at close: recorded in local result doc.

## Deviations / blockers

- Active-series maximum requires a product decision — surfaced but
  not resolved. Prevents WP-08 readiness.

## Exact next milestone

Not `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` (WP-08) — blocked.

Required predecessor: **product decision on active-series maximum M
per subaccount** (options include: hard cap at ledger boundary,
per-token per-underlying subcap, cross-product cap, or a bounded
commitment scheme). Recommended venue: contract-spec addendum or a
dedicated `SECURITY-REVIEW-PREP` deliverable that closes on M.

Once M is frozen, the follow-up milestone can implement AB-1 (enforce
M at `_maybeIncrementActive`, add tests + invariants
`RISK-BOUND-I1/I2`), and can optionally combine with the collateral
CT-1 or CT-2 fix. After both land, WP-08 becomes shippable with
liquidation enabled.
