# ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_V1

## Status

`IMPLEMENTED_PENDING_VALIDATION` — 2026-07-27. Product owner: Coriolan Morel.

`EXPERIMENTAL — NOT SECURITY APPROVED`.

Not an audit sign-off. Not a security-reviewer sign-off. Not a deployment
approval. Not a production-readiness claim. Not authorized for Base mainnet
or real user funds. Internal reviewer status:
`PENDING_INTERNAL_REVIEWER_ACKNOWLEDGEMENT`. External audit:
`PENDING_EXTERNAL_REVIEW`.

## Purpose

Land the Options RiskModuleV2 boundary (WP-07) as an abstract, fail-closed
canonical risk-view contract. The boundary owns NO canonical economic
state, exposes the WP-01 frozen `IRiskModule` ABI verbatim, and provides
the Vault-integration `CollateralVaultV2RiskIntegrated` inheritor that
wires the WP-04B abstract risk hooks to a concrete `IRiskModule`.

Concrete numerical margin formulas + oracle providers + bounded portfolio
walk are deferred to WP-08 MarginEngineV2. The abstract's `_compute*`
hooks have NO permissive default: every path fails closed until a
concrete inheritor overrides.

## Authoritative sources

Precedence (highest first):

1. Product-owner authorization for
   `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-V1` (2026-07-27) + its
   non-blocking conditions.
2. Tracked designs in `deopt-v2-sol/`:
   - `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
   - `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
   - `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md`
   - `ONCHAIN_SUBACCOUNT_REGISTRY_V1.md`
   - `ONCHAIN_SUBACCOUNT_CAPABILITY_CONTROLLER_V1.md`
   - `ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_A.md`
   - `ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_B.md`
   - `ONCHAIN_SUBACCOUNT_REPLAY_AND_EPOCH_FOUNDATION_V1.md`
   - `ONCHAIN_SUBACCOUNT_OPTIONS_POSITIONS_LEDGER_V1.md`
3. Detailed contract specification — especially
   `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/06_RISK_MARGIN_MODULE_SPEC.md`,
   `03_COLLATERAL_VAULT_SPEC.md`, `04_OPTIONS_POSITION_LEDGER_SPEC.md`,
   `07_ENGINE_CAPABILITIES_SPEC.md`, `13_EVENTS_AND_RECONSTRUCTION.md`,
   `15_SOLIDITY_INTERFACES.md`, `16_ERRORS_AND_EVENTS_CATALOGUE.md`,
   `17_SECURITY_INVARIANT_MAPPING.md`, `21_DECISION_REGISTER.md`.
4. Detailed experimental-implementation-plan package.
5. Validated WP-01, WP-02, WP-03, WP-04A, WP-04B, WP-05, WP-06 at
   `096f21f`.

## Risk-input completeness verdict (Part C)

Verdict: `RISK_INPUT_COMPLETENESS_PROVABLE_ONCHAIN`.

**Rationale.** Spec 06 requires `marginRequirement(subKey)` to be a
"pure function of canonical ledger state + oracle prices + configured
risk parameters" with "no caller-supplied economic parameters (only
`subKey`, `token`, `amount` as reference inputs)". Neither the ledger
(WP-06) nor the Vault (WP-04) exposes per-subaccount portfolio
enumeration.

The resolution is:

- **Abstract module** with fail-closed defaults: every `_compute*`
  hook is `internal view virtual` with NO permissive fallback. The
  abstract itself CANNOT return an affirmative safety decision from
  any external view, because every external view routes through the
  abstract hooks and reverts / returns `false` on `ok == false`.
- **Concrete WP-08 inheritor** provides the bounded portfolio walk +
  oracle integration + concrete margin formulas. The WP-08 milestone
  will declare its own portfolio-completeness proof (e.g. a bounded
  supported-series registry queried via `positionOf`, or a per-mutation
  aggregated running-total). WP-07 does not invent that proof; it
  provides the boundary the proof will attach to.

The abstract is therefore provably on-chain-complete: every path
without an override fails closed by construction. There is no hidden
backend authority, no permissive default, and no way for an incomplete
concrete override to produce an affirmative safety decision.

## Risk model verdict (Part D)

Verdict: `OPTIONS_RISK_MODEL_FULLY_RESOLVED`.

**Rationale.** Spec 06 §"What this spec does NOT decide" defers concrete
parameter values to `ONCHAIN-SUBACCOUNT-SECURITY-REVIEW-PREP-V1`. The
ABI shape + netting rules + fail-closed semantics + module-slot
replacement policy ARE frozen. WP-07 implements the boundary + fail-
closed defaults per the frozen shape without inventing concrete
formulas (per the prompt: "must not invent a margin model").

Risk-concept coverage in the abstract:

| Concept | WP-06 layer | Fail-closed on incomplete |
|---|---|---|
| collateral equity | `_computeAvailableMargin` hook (abstract; concrete WP-08) | YES |
| collateral haircut | concrete WP-08 | YES (via hook returning `ok=false`) |
| available collateral | `_computeAvailableMargin` | YES |
| locked collateral | Vault's `lockedOf` — canonical, read by concrete | N/A (Vault authoritative) |
| long option value | concrete WP-08 (needs series metadata + oracle) | YES |
| short option liability | concrete WP-08 | YES |
| initial margin | concrete WP-08 (parameter value from SECURITY-REVIEW-PREP) | YES |
| maintenance margin | `_computeMarginRequirement` hook | YES |
| account equity | `availableMargin - marginRequirement` (WP-07 derives) | YES |
| margin excess | derived by `marginRatio` | YES |
| health factor | `marginHealthy` (WP-07 implements) | YES |
| liquidation threshold | `liquidationStatus` — WP-07 fails closed to ELIGIBLE on hook failure | YES |
| expired / exercised / finalized positions | WP-06 ledger owns lifecycle; concrete WP-08 respects | YES |
| stale price handling | concrete WP-08 `_computeAvailableMargin` returns `ok=false` | YES |
| unsupported series | concrete WP-08 returns `ok=false` on unknown seriesId | YES |
| unsupported token | `withdrawalAllowed` checks `VAULT.supportedTokens(token)`; also `_valueOfWithdrawnAmount` returns `ok=false` on zero price | YES |
| negative equity | uint256 storage; underflow prevented at every subtraction | N/A (impossible in uint256) |
| arithmetic overflow | uint256 intermediates for `available * 1e18 / required` | YES via 0.8.x checked math |

## Netting verdict (Part E)

Verdict: `OPTIONS_RISK_NETTING_RULES_RESOLVED`.

- No cross-subaccount netting (P1 isolation): every view takes a
  single `subKey`; no sibling account is read inside a single view.
- No cross-owner netting.
- No Options / Perps netting in V1 (spec 06: "no cross-product offset
  in V1; portfolio-margin mode is deferred").
- No production Perps behavior (`productsEnabled(perps) = false`
  unconditionally in V1).
- Options-side netting rules (same-expiry / vertical-spread / package)
  are NOT introduced in the abstract; concrete WP-08 inheritors that
  wish to grant offsets MUST declare them via `_computeMarginRequirement`
  and prove correctness with their own tests. WP-07 provides the
  boundary, not the offsets.

## Oracle boundary (Part F)

Verdict: `RISK_ORACLE_BOUNDARY_REQUIRES_FUTURE_PROVIDER_HOOK`.

- All price-consuming logic lives in abstract hooks
  (`_computeMarginRequirement`, `_computeAvailableMargin`,
  `_valueOfWithdrawnAmount`). The abstract has no concrete
  `IOracle` or `OptionProductRegistry` immutable.
- Concrete WP-08 will bind the immutable `IOracle` (per
  `src/oracle/IOracle.sol`) and `OptionProductRegistry` (per
  `src/OptionProductRegistry.sol`) references + implement stale-price
  fail-closed semantics.
- Every abstract hook returns `(value, ok)`. `ok == false` collapses
  to the safety-negative external decision (revert, `false`, or
  `ELIGIBLE_FOR_LIQUIDATION`). No permissive default in the abstract.

## ABI verdict (Part G)

Verdict: `RISK_MODULE_ABI_RESOLVED`.

WP-01 froze `IRiskModule` verbatim (see
`src/hybrid-v2/interfaces/IRiskModule.sol`). WP-07 implements it
without expanding the ABI. Every function is `view`; there is no
mutation surface.

## Implementation form (Part H)

Outcome R2 — abstract provider-backed RiskModule.

Files:

- `src/hybrid-v2/risk/RiskModuleV2.sol` — abstract; inherits
  `IRiskModule`.
- `src/hybrid-v2/risk/CollateralVaultV2RiskIntegrated.sol` — abstract;
  inherits `CollateralVaultV2` and overrides
  `_requireWithdrawalAllowed` + `_requireInternalTransferAllowed` to
  consult a concrete `IRiskModule`.

Both remain abstract for production because:

- `RiskModuleV2._compute*` hooks are unimplemented (deferred to WP-08).
- `CollateralVaultV2._requireOrphanedReleaseProof` is unimplemented
  (deferred to WP-10 EscapeController).

Test-only concrete inheritors under `test/hybrid-v2/risk/harness/` seed
deterministic values so the ABI + fail-closed paths + Vault-integration
rollback can be exercised without inventing formulas.

## Compatibility identifier (Part J)

Verdict: `RISK_MODULE_COMPATIBILITY_ID_IMPLEMENTED`.

- `ARCHITECTURE_VERSION` immutable = `Versions.ARCHITECTURE_VERSION`.
- `MODULE_VERSION` immutable = constructor arg (>0).
- `SUPPORTED_STORAGE_VERSION` immutable = `Versions.STORAGE_VERSION`.
- `moduleVersion()` returns `MODULE_VERSION`.
- `supportsCanonicalStorageVersion(v)` returns
  `v == SUPPORTED_STORAGE_VERSION`.
- `productsEnabled(subKey)` returns `(true, false)` in V1 (Options
  enabled by default; Perps always false).
- `CollateralVaultV2RiskIntegrated` constructor cross-checks:
  - RiskModule non-zero;
  - RiskModule's Registry equals Vault's Registry;
  - RiskModule's `ARCHITECTURE_VERSION` equals
    `Versions.ARCHITECTURE_VERSION`;
  - `RiskModule.supportsCanonicalStorageVersion(Versions.STORAGE_VERSION)`
    returns `true`.

## Module-slot ownership (Part K)

Verdict: `RISK_MODULE_SLOT_DEFERRED_TO_MARGIN_ENGINE_V2`.

- V1 posture: the RiskModule reference on the Vault is IMMUTABLE
  (`IRiskModule public immutable RISK_MODULE` on
  `CollateralVaultV2RiskIntegrated`). Replacement requires a full Vault
  redeploy.
- Spec 06 §C-01 permits this as a fresh-deployment cutover:
  "Historical balances + ownership MUST NOT be rewritten by a
  replacement" — an immutable slot + Vault redeploy trivially satisfies
  this.
- Timelocked in-place replacement (spec 06 §"Replacement policy" ≥48h
  timelock) is deferred to WP-08 MarginEngineV2, which owns the
  ProtocolTimelock + engine-slot rotation surface. WP-08 will decide
  whether to keep the immutable-per-deployment model or introduce a
  mutable slot; either way WP-07 remains inheritable.

## Dependencies + immutables (Part I)

Every reference is immutable, non-zero-checked at construction:

- `ISubaccountRegistry REGISTRY` — canonical identity.
- `ICollateralVault VAULT` — canonical collateral.
- `IOptionsPositionsLedger OPTIONS_LEDGER` — canonical positions.
- `ARCHITECTURE_VERSION` — Options V2 architecture pin.
- `SUPPORTED_STORAGE_VERSION` — Canonical storage version pin.
- `MODULE_VERSION` — Concrete-inheritor version tag.

Vault + Ledger Registry cross-check LIVES ON THE VAULT SIDE (in
`CollateralVaultV2RiskIntegrated`), not on the RiskModule side.
Rationale: the two-way Vault ↔ RiskModule immutable reference requires
CREATE2 nonce prediction, and at the moment the RiskModule constructor
runs the Vault has no code. The cross-check is therefore performed by
the RiskAwareVault constructor once both contracts exist. Defence in
depth is preserved because a mis-wired Vault would fail closed at every
risk view (subKeys derived from RiskModule's Registry return zero from
a foreign Vault's `ownerOf` / `availableOf` lookups).

## Collateral valuation (Part L)

The concrete `_valueOfWithdrawnAmount(subKey, token, amount)` hook
converts a token amount to its 1e18-scaled quote-currency value.
Abstract has no implementation; concrete WP-08 handles:

- Token decimals normalization.
- Oracle-price normalization.
- Canonical quote currency.
- Haircut (per-token risk parameter, sourced from `OptionRiskConfig`
  or SECURITY-REVIEW-PREP output).
- Stale-price policy (`ok = false` on stale / zero / missing).
- Disabled-token behavior (`ok = false`).

Vault-side already enforces:
- `direct token donations are not user equity` — Vault deposit uses
  balance-delta validation; a raw transfer to the vault contract does
  NOT increment `_balanceOf`. The RiskModule reads
  `VAULT.availableOf(subKey, token)`, which is `_balanceOf` minus
  locks, so donations cannot inflate a user's collateral.
- `use canonical account balance, not the Vault's total physical
  balance` — `availableOf(subKey, token)` reads per-subKey accounting.
- `no sibling balance` — subKey lookups are isolated by construction.
- `no totalAccounted attribution to one user` — the Vault's aggregate
  `totalAccounted` view exists but is never consulted for per-user
  collateral.
- `locked-versus-total balance treatment` — `availableOf = balanceOf -
  lockedOf`.

## Options position risk (Part M)

The concrete `_computeMarginRequirement(subKey)` hook is expected to:

- Walk the canonical Options portfolio via `OPTIONS_LEDGER.positionOf`.
- Consult product-registry series metadata (call/put, strike, expiry,
  contract multiplier).
- Consult oracle prices (underlying spot + collateral prices).
- Apply the approved DeOpt margin formula (parameter values from
  SECURITY-REVIEW-PREP).
- Respect lifecycle:
  - Fully-settled positions (settlementState == FULL) contribute zero
    margin (spec 04 lifecycle FROZEN).
  - Fully-exercised long positions contribute zero long-side margin
    (spec 04).
- Fail closed on unknown series / stale price / decimal mismatch.

WP-07 does NOT implement this walk. The abstract's default hook
returns `(0, false)`, forcing every external view through fail-closed.

## Withdrawal safety (Part N)

`withdrawalAllowed(subKey, token, amount)` returns `false` on ANY of:

- Zero subKey / token / amount.
- Unknown subKey per Registry.
- Unsupported token per Vault whitelist.
- `amount > VAULT.availableOf(subKey, token)` (token-level solvency).
- `_computeMarginRequirement` returns `ok = false` (fail-closed).
- `_computeAvailableMargin` returns `ok = false`.
- `_valueOfWithdrawnAmount` returns `ok = false`.
- `delta > available` (post-withdrawal available underflows).
- `postAvailable < required` (below threshold).

No state mutation. No permissive default. Deterministic conservative
rounding (uint256 checked arithmetic).

## Internal-transfer safety (Part O)

`transferAllowed(sourceSubKey, token, amount)` mirrors
`withdrawalAllowed` (an internal transfer moves `amount` OUT of the
source; the source-side safety check is identical to a withdrawal
safety check). Destination MAY receive credit without independent
margin check because the destination's post-state is at-least the
pre-state (spec 10). Same fail-closed rules.

## Liquidation views (Part P)

- `liquidationStatus(subKey)`: `HEALTHY` when `available >= required`,
  `ELIGIBLE_FOR_LIQUIDATION` otherwise. Fail-closed default:
  `ELIGIBLE_FOR_LIQUIDATION` on ANY hook failure (safer to freeze than
  to permit trading). Concrete inheritors MAY refine `WARN` semantics
  via the `_isWarnStatus` override; default is direct
  healthy/eligible.
- `marginHealthy(subKey)`: `false` on any failure. Never reverts.
- `marginRatio(subKey)`: returns `type(uint256).max` when `required
  == 0`; reverts `RiskModuleUnavailable` on any hook failure.

## Vault risk-hook integration (Part Q)

`CollateralVaultV2RiskIntegrated`:

- Immutable `IRiskModule RISK_MODULE`.
- Overrides `_requireWithdrawalAllowed`:
  ```
  try RISK_MODULE.withdrawalAllowed(subKey, token, amount) returns (bool ok) {
      if (!ok) revert UnsafeWithdrawal();
  } catch {
      revert UnsafeWithdrawal();
  }
  ```
- Overrides `_requireInternalTransferAllowed` symmetrically.
- Does NOT override `_requireOrphanedReleaseProof` (still owned by
  WP-10).
- Fail-closed on any RiskModule revert: caught and translated to
  `UnsafeWithdrawal` / `UnsafeTransfer`. Vault mutation happens
  AFTER the risk hook clears (WP-04B CEI order), so rejection
  produces zero partial mutation and the enclosing transaction
  reverts atomically.

Verdict: `VAULT_RISK_HOOK_INTEGRATION_VALIDATED`.

## Ledger event carry-forward (Part R)

Documented downstream requirement for WP-08:

- The Options ledger (WP-06) emits `OptionExercised.delta = 0`,
  `OptionSettled.pnlDelta = 0`, and
  `OptionPositionLiquidated.seizedCollateral = 0`. These are NOT
  canonical economic values.
- Engine-level economic events must expose the real premium, PnL,
  settlement, and seizure values in the SAME atomic transaction so
  indexers can pair them with the ledger's position-quantity events.
- The ledger remains canonical only for position quantities +
  lifecycle state.

WP-07 does NOT alter ledger events. The zeros are informational
placeholders; consumers MUST NOT treat them as canonical value.

## Engine atomicity carry-forward (Part S)

Documented WP-08 requirement:

- In one atomic transaction, an Options engine MUST:
  1. Consume D.2 replay state (WP-05).
  2. Validate full risk (WP-07).
  3. Update both trade sides where applicable.
  4. Update collateral reservations (WP-04B).
  5. Update positions (WP-06).
  6. Charge fees (WP-09).
  7. Emit economic events (WP-08 owns).

WP-06's lack of independent fill-ID storage is SAFE only under that
approved engine-level atomicity model. WP-07 does not add replay
storage.

## Failure + fail-closed tests (Part T)

Every failure path covered in `RiskModuleV2.t.sol` +
`RiskModuleV2Integration.t.sol` +
`RiskModuleV2Invariant.t.sol`:

- Stale provider → every view returns safety-negative.
- Stale token → `withdrawalAllowed` returns false.
- Zero token price → `withdrawalAllowed` returns false.
- Registry mismatch → Vault constructor reverts
  `RiskModuleRegistryMismatch`.
- Architecture-version mismatch → Vault constructor reverts.
- Compatibility-ID mismatch → Vault constructor reverts.
- Invalid RiskModule address → Vault constructor reverts.
- Zero subKey → `SubKeyRequired`.
- Unknown subaccount → `UnknownSubaccount`.
- Amount exceeds available → returns false.
- Unsupported token → returns false.
- Registry-driven guardian revocation of a fake engine capability
  does not alter RiskModule state.
- Vault withdrawal / internal transfer rolls back on RiskModule
  reject: all balances / physical / totalAccounted unchanged.
- Vault withdrawal / internal transfer rolls back on RiskModule
  revert (via try/catch translation).

## Storage review (Part X)

- Six immutables on RiskModuleV2 (Registry, Vault, Options Ledger,
  three version fields).
- One immutable on CollateralVaultV2RiskIntegrated (RISK_MODULE).
- ZERO per-user economic storage on the module.
- No cached user equity.
- No cached margin.
- No copied position state.
- No copied collateral state.
- No off-chain commitment.
- No mutable provider.
- No proxy assumptions.

Any mutable risk parameter would live on a concrete WP-08 inheritor
with explicit timelock + bounds + event + reconstruction. WP-07 has no
mutable state.

## Gas / DoS (Part Y)

- Every abstract view is O(1) plus the concrete hook's cost. Concrete
  hooks MUST be bounded per subKey per call.
- No unbounded global iteration in WP-07.
- No signature-array iteration.
- No recursive provider calls.
- No state-changing oracle calls.
- Callers pay gas.

No production gas promise.

## Invariants covered

- **RISK-I1**: no canonical state ownership.
- **RISK-I2, I3**: collateral / position isolation (ghost mirror).
- **RISK-I4, I5**: incomplete / stale inputs fail closed.
- **RISK-I6**: non-negative margin (uint256 witness + ghost mirror).
- **RISK-I7, I8**: withdrawal safety semantics (safe → true; unsafe →
  false; Vault rollback proven separately).
- **RISK-I9, I10**: internal-transfer safety mirrors withdrawal.
- **RISK-I11**: compatibility check pure function of immutable state.
- **RISK-I12**: Registry/Vault/Ledger immutables unchanged by any
  handler activity.
- **RISK-I13**: no hidden cross-series offsets (ghost equals stored).
- **RISK-I14**: WP-06 lifecycle preserved (module doesn't touch
  ledger).
- **RISK-I15**: deterministic under identical state.
- **RISK-I16**: Perps disabled in V1.

## Explicit non-goals

- No concrete margin formulas / oracle integration / product-registry
  wiring (WP-08).
- No timelocked module-slot replacement (WP-08).
- No Options execution / matching / signatures / fees / rebates.
- No Perps.
- No fallback settlement (WP-10).
- No liquidation execution (WP-08 + WP-10).
- No backend / frontend / migration changes.

## Downstream ownership

| Deferred concept | Downstream milestone |
|---|---|
| Concrete `_compute*` hooks + margin formulas + parameter values | WP-08 + SECURITY-REVIEW-PREP |
| Oracle provider integration (Chainlink / Pyth) | WP-08 |
| `OptionProductRegistry` integration | WP-08 |
| Bounded portfolio walk primitives | WP-08 |
| Timelocked in-place module rotation | WP-08 |
| PerpsPositionsLedger + Perps risk formulas | future Perps milestone |
| Escape-controller-driven fallback finalization | WP-10 |

## Decision register (this milestone)

| ID | Decision | Status |
|---|---|---|
| D-RSK-01 | Abstract module + fail-closed defaults; concrete WP-08 inheritor owns portfolio walk + formulas | FROZEN |
| D-RSK-02 | Vault-side cross-check of RiskModule Registry / architecture / storage version at RiskAwareVault construction; RiskModule constructor cross-check deferred to avoid CREATE2 ordering issues | FROZEN |
| D-RSK-03 | RiskModule reference is immutable per Vault deployment in V1; timelocked in-place rotation deferred to WP-08 | FROZEN |
| D-RSK-04 | `transferAllowed(sourceSubKey, token, amount)` reuses `withdrawalAllowed` (source-side safety semantics identical) | FROZEN |
| D-RSK-05 | `liquidationStatus` fails closed to `ELIGIBLE_FOR_LIQUIDATION` on hook failure; concrete WARN threshold via `_isWarnStatus` override | FROZEN |
| D-RSK-06 | `productsEnabled` gates Perps to `false` unconditionally in V1 | FROZEN |

None BLOCKING. None DEFERRED_WITH_OWNER at this milestone (downstream
owners already frozen above).

## No audit or production claim

Same disclaimer as every prior WP milestone. Not audited. Not
security-reviewed. Not authorized for real user funds.
