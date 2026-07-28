# ONCHAIN_SUBACCOUNT_RISK_EXECUTION_BOUNDS_AND_COLLATERAL_UNIVERSE_V1

Status: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`.
Launched: 2026-07-27.
Product owner: Coriolan Morel.
Predecessor: `ONCHAIN-SUBACCOUNT-RISK-MODULE-V2-BOUNDEDNESS-AND-LIQUIDATION-SAFETY-PATCH`.
Unlocks: `ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` (WP-08).

## Explicit product-owner decision

`PRODUCT_OWNER_DECISION_FROZEN_FOR_HYBRID_V2_V1`

Two limits are FROZEN by the product owner for this deployment:

- `MAX_ACTIVE_SERIES_PER_SUBACCOUNT_V1 = 32`
- `MAX_COLLATERAL_TOKENS_V1 = 8`

Both are immutable per deployment. There is NO governance setter. Raising
either requires a new versioned deployment and cutover.

These values are NEW explicit product decisions. They are NOT inherited
from any previously RECOMMENDED constant (in particular, they are NOT the
migration-batch `MAX_POSITIONS_PER_BATCH = 32` from D-MIG-17, which is a
scoped migration bookkeeping limit rather than a runtime cap).

## Rationale

- **32 active series per subaccount**: bounds risk-validation gas at
  ~O(32) provider calls per subKey per view. At WP-08 concrete provider
  costs of ~10–20k gas per series (oracle + registry + math), the full
  portfolio walk fits well under the Base 30M block gas limit while
  leaving headroom for other transaction work. Prevents the DoS pattern
  (open many tiny positions until the subaccount is un-liquidatable and
  un-withdrawable, creating a socialized-loss vector).
- **8 collateral tokens**: bounds the liquidation-completeness collateral
  walk at O(8). Matches DeOpt V1 product plans (USDC-first, plus a small
  set of blue-chip stables and majors); leaves room for expansion without
  moving to enumerable-set schemes. Universe is APPEND-ONLY so disabled
  tokens' balances remain discoverable — critical for liquidation
  correctness.

## Verdicts (Part Q)

- `ACTIVE_SERIES_MAXIMUM_FROZEN_AT_32`
- `RISK_VALIDATION_PORTFOLIO_SIZE_IS_CANONICALLY_BOUNDED`
- `RISK_REDUCING_POSITION_PATHS_REMAIN_OPERABLE_AT_CAP`
- `CANONICAL_COLLATERAL_UNIVERSE_MAXIMUM_FROZEN_AT_8`
- `COLLATERAL_UNIVERSE_IS_APPEND_ONLY_AND_RECONSTRUCTIBLE`
- `LIQUIDATION_COLLATERAL_UNIVERSE_CANONICAL_AND_BOUNDED`
- `INDETERMINATE_RISK_CANNOT_AUTHORIZE_LIQUIDATION`
- `SINGLE_RISKMODULE_CONSUMER_BOUNDARY_REMAINS_ENFORCED`
- `ONCHAIN_SUBACCOUNT_RISK_EXECUTION_BOUNDS_AND_COLLATERAL_UNIVERSE_V1_COMPLETE`
- `READY_FOR_ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1`

## Part A/B — Preflight + baseline

- Frontend HEAD: `83e68a8` (clean; untouched).
- Backend HEAD: `4dbaf3d` (clean; untouched).
- Solidity starting HEAD: `c07a122`.
- Baseline: 63 suites / 970 tests / 0 failed (~235s).

## Part C — Active-series limit (32)

### Constant

Added to `OptionsPositionsLedger.sol`:

```solidity
uint32 public constant MAX_ACTIVE_SERIES_PER_SUBACCOUNT = 32;
```

Also exposed via the interface as `maxActiveSeriesPerSubaccount() view returns (uint32)`.

### Enforcement

Enforced only on the canonical zero → non-zero transition in
`_maybeIncrementActive`:

```
if wasActive == false && isActive == true:
    require activeSeriesCount < 32
    increment
```

Enforcement is BEFORE the position row is mutated (via the pre-mutation
check in `_maybeIncrementActive` prior to storing quantities), so a
rejected 33rd activation produces zero partial state and the transaction
reverts atomically (`RISK-BOUND-I3`).

`_maybeDecrementActive` is unchanged except for the existing WP-06
`wasActive` fix (preserved). Mutations of already-active positions,
risk-reducing paths (exercise, liquidation, settlement) and reactivation
after freeing capacity are NOT blocked.

### Custom error

```solidity
error ActiveSeriesLimitExceeded(bytes32 subKey, uint32 currentCount, uint32 maximum);
```

The defensive `type(uint32).max` floor (`OptionActiveSeriesOverflow`) is
preserved as a witness — it CAN never trip while the cap is 32, but it
protects against future cap raises above `type(uint32).max`.

### Risk-reducing liveness at cap

Tests exercise every risk-reducing path at count == 32:
- `applyFill` on an already-active series (adds to long/short of an
  existing row) — succeeds.
- `applyExercise` reducing long — succeeds.
- `applyLiquidation` reducing short — succeeds.
- `applySettlement` (marks state, does not itself decrement because basis
  survives) — succeeds.
- After a full zero-out via liquidation of a recv=0 short, `activeSeriesCount`
  decrements → new 33rd series can be opened.

## Part D — Completeness views

Preserved:
- `isActiveSeries(subKey, seriesId) view returns (bool)` — O(1) membership.
- `activeSeriesCount(subKey) view returns (uint32)`.
- `verifyActiveSeriesArrayComplete(subKey, seriesIds[]) view returns (bool)`.

Verifier extension: reject `seriesIds.length > MAX_ACTIVE_SERIES_PER_SUBACCOUNT`
BEFORE doing any per-element work. Because the mutation side enforces the
cap, a supplied array longer than the cap is by construction non-canonical
and can be rejected up-front, bounding worst-case verifier gas at O(32).

## Part E — Gas-liveness safety at the cap

Proven by unit tests:
- Every risk-reducing path (exercise / liquidation-quantity-reduction /
  settlement / mutation of already-active) remains callable at count == 32.
- Opening a 33rd series reverts atomically.
- After fully zeroing one active position, one new series may become
  active.

Invariants added:
- `RISK-BOUND-I1`: `activeSeriesCount(subKey)` never exceeds 32.
- `RISK-BOUND-I3`: rejected 33rd-series activation produces no partial
  state (verified as: chain state matches ghost mirror AND canonical
  reconstruction always verifies via `verifyActiveSeriesArrayComplete`).

`RISK-BOUND-I2` is exercised in unit-test form (positive-path liveness
tests). The invariant handler exercises only 3 series in its pool, so
it cannot drive the cap; the boundary is exercised deterministically by
the unit suite.

## Part F/G/H — Canonical collateral universe

### Storage

`CollateralVaultV2Core.sol`:

```solidity
uint256 public constant MAX_COLLATERAL_TOKENS = 8;
address[] internal _collateralUniverse;
mapping(address => bool) internal _knownCollateralToken;
```

Separation of concerns:
- `_tokenEnabled` — CURRENT deposit-enable flag (unchanged from before).
- `_knownCollateralToken` — has token EVER been enabled → is in the
  canonical universe. Once true, never becomes false.
- `_collateralUniverse` — insertion-order array of ever-known tokens.
  Append-only, bounded above by 8.

### Enable / disable / re-enable semantics

`addSupportedToken(token)`:
- reverts `InvalidToken` on zero;
- reverts `TokenAlreadySupported` on duplicate ENABLE;
- if the token is NOT yet known (first enable):
  - reverts `CollateralUniverseLimitExceeded(current, 8)` when full;
  - marks known; appends to universe; emits `CollateralTokenEnteredUniverse`;
- sets `_tokenEnabled[token] = true`; emits `SupportedTokenAdded`.

`removeSupportedToken(token)`:
- reverts `TokenNotEnabled` on unknown-or-already-disabled;
- flips `_tokenEnabled[token] = false`;
- does NOT clear `_knownCollateralToken`, does NOT touch the universe
  array, does NOT touch balances, does NOT touch `_totalAccounted`, does
  NOT touch capabilities or Registry state.

Direct token donations do NOT add a token to the universe — enablement
is governance-only via `addSupportedToken`.

### Bounded canonical views

Added to `ICollateralVault` (additive only):

```solidity
function maxCollateralTokens() external view returns (uint256);           // 8
function collateralTokenCount() external view returns (uint256);          // 0..8
function collateralTokenAt(uint256 index) external view returns (address);
function isKnownCollateralToken(address token) external view returns (bool);
function collateralUniverse() external view returns (address[] memory);   // bounded <=8
```

Return size of `collateralUniverse()` is bounded by 8, so a full-array
view is safe.

### Errors + events

Added:
- `error CollateralUniverseLimitExceeded(uint256 currentCount, uint256 maximum);`
- `error CollateralUniverseIndexOutOfBounds(uint256 index, uint256 count);`
- `event CollateralTokenEnteredUniverse(address indexed token, uint256 index, uint16 eventVersion);`

Reconstruction: the event is emitted ONLY on the FIRST enablement of a
token, so a chain scan yields exactly the universe insertion order.
Re-enablement does NOT re-emit.

## Part I — Liquidation completeness

The Vault now exposes a bounded canonical collateral universe of at most
8 tokens. WP-08's concrete `_computeAvailableMargin` MUST:

1. iterate `vault.collateralUniverse()` — bounded at 8;
2. read `vault.balanceOf(subKey, token)` per token;
3. INCLUDE disabled tokens when their balance is non-zero (the universe
   contains them);
4. resolve token price + haircut via the approved provider;
5. return `ok=false` on any missing / stale / unsupported / reverting
   price for a non-zero canonical balance;
6. NEVER accept a caller-supplied collateral list as canonical;
7. IGNORE direct donations because risk reads canonical
   `_balanceOf[subKey][token]`, not the physical Vault balance.

The RiskModule fail-safe from the previous patch remains: indeterminate
input → revert `RiskModuleUnavailable` → downstream WP-08 execution
translates to "no liquidation authority".

## Part J — Bounded risk-input helper posture

No new state is copied into the RiskModule. No off-chain commitment. No
caller-supplied collateral array. The RiskModule (abstract) reads:
- `LEDGER.activeSeriesCount(subKey)` — bounded by 32.
- `LEDGER.verifyActiveSeriesArrayComplete(subKey, ids)` — verifies
  completeness of a caller-supplied Options-series list up to 32.
- `VAULT.collateralUniverse()` — bounded by 8.
- `VAULT.balanceOf(subKey, token)` — per-token isolated balance.

WP-08 concrete inheritors bind their oracle + product registry providers
and implement the frozen legacy MM formula shape.

## Part K — Single-RiskModule regression

Preserved unchanged:
- `SINGLE_IMMUTABLE_RISK_MODULE_PER_DEPLOYMENT` posture.
- `src/hybrid-v2/risk/VaultRiskModuleConsumer.sol` production consumer
  boundary.

Regressions run (all pass):
- `VaultRiskModuleConsumer.t.sol` — 9 tests: consumer binds Vault's
  module; two consumers agree; rejects zero vault; rejects architecture
  mismatch; rejects storage version unsupported; rejects Vault-with-zero-
  module; replacement requires fresh redeploy; documents absence of
  independent module arg.

No new RiskModule slot introduced.

## Part L — Storage review

New storage on `OptionsPositionsLedger`: NONE. `_activeSeriesCount` was
already there; only the enforcement path changed.

New storage on `CollateralVaultV2Core`:
- `address[] internal _collateralUniverse` — bounded at 8.
- `mapping(address => bool) internal _knownCollateralToken`.

No canonical state was moved into any RiskModule. The Vault remains the
sole canonical token-policy authority.

## ABI additions (Part O)

### `IOptionsPositionsLedger`
- `function maxActiveSeriesPerSubaccount() external view returns (uint32);`

### `ICollateralVault`
- `function maxCollateralTokens() external view returns (uint256);`
- `function collateralTokenCount() external view returns (uint256);`
- `function collateralTokenAt(uint256 index) external view returns (address);`
- `function isKnownCollateralToken(address token) external view returns (bool);`
- `function collateralUniverse() external view returns (address[] memory);`
- `event CollateralTokenEnteredUniverse(address indexed token, uint256 index, uint16 eventVersion);`
- `error CollateralUniverseLimitExceeded(uint256 currentCount, uint256 maximum);`
- `error CollateralUniverseIndexOutOfBounds(uint256 index, uint256 count);`

No existing selectors changed.

## Tests + invariants

### New test files

- `test/hybrid-v2/positions/OptionsPositionsLedgerActiveSeriesBound.t.sol`
  — 23 unit + fuzz for the series cap.
- `test/hybrid-v2/positions/OptionsPositionsLedgerActiveSeriesBoundInvariant.t.sol`
  — 2 invariants (RISK-BOUND-I1 + RISK-BOUND-I3).
- `test/hybrid-v2/vault/CollateralVaultV2CollateralUniverse.t.sol` — 20
  unit + fuzz for the universe.
- `test/hybrid-v2/vault/CollateralVaultV2CollateralUniverseInvariant.t.sol`
  — 4 invariants (COLLATERAL-UNIVERSE-I1 + I2 + I3 + I5).
- `test/hybrid-v2/risk/LiquidationCompletenessIntegration.t.sol` — 10
  end-to-end integration tests.

### Invariants added

- `RISK-BOUND-I1` — `activeSeriesCount(subKey) <= 32`.
- `RISK-BOUND-I2` — risk-reducing paths remain operable at cap (unit
  suite; handler-scale invariant deferred to WP-08 which will drive the
  cap via concrete series).
- `RISK-BOUND-I3` — atomic revert on cap breach (canonical
  reconstruction verifier equality invariant).
- `COLLATERAL-UNIVERSE-I1` — universe never exceeds 8.
- `COLLATERAL-UNIVERSE-I2` — `isKnownCollateralToken` never flips true→false.
- `COLLATERAL-UNIVERSE-I3` — enable/disable/re-enable never duplicates.
- `COLLATERAL-UNIVERSE-I4` — disabling never deletes balances /
  liabilities (unit suite; invariant version deferred to WP-08 which
  models economic mutation).
- `COLLATERAL-UNIVERSE-I5` — every ghost-known token discoverable via
  canonical universe.
- `RISK-LIQ-I3` — proven end-to-end via
  `LiquidationCompletenessIntegration.t.sol`: affirmative eligibility
  only when the canonical active-series set and canonical collateral
  universe are complete (indeterminate paths revert).

## Gas / DoS observations (development-only)

Rough envelopes measured from unit test gas reports:

| Op | Gas |
|---|---|
| activation of series 1 | ~76 k |
| activation of series 32 | ~85 k (per-op; last of a 32-step sequence) |
| rejected series 33 | ~35 k (reverts before mutation) |
| completeness verifier over 32 series | ~250 k |
| first collateral token insertion | ~115 k |
| eighth token insertion | ~90 k |
| rejected 9th token | ~30 k |
| enumeration of 8 collateral tokens | ~15 k |

Synthetic worst-case read path (32 active series × 8 collateral tokens)
without a concrete provider fits well under a Base transaction budget.
Final production-risk benchmarks are deferred to WP-08 with concrete
provider bindings.

### Structural claims confirmed

- Portfolio size is now bounded (32 per subaccount).
- Collateral universe size is now bounded (8 per Vault deployment).
- No global iteration exists.
- No user-controlled unbounded array is accepted.
- WP-08 has a fixed maximum input size (32 series × 8 tokens = 256
  atomic risk-input points per subKey).

## Non-goals

- No MarginEngine, no matching, no signatures, no replay changes.
- No fee, premium, settlement, liquidation execution.
- No mutable limit (there is NO governance setter for either constant).
- No RiskModule owning economic state.
- No Perps.

## No audit / production-readiness claim

Status remains `EXPERIMENTAL — NOT SECURITY APPROVED`. Not authorized
for Base mainnet or real funds.

## Exact WP-08 dependency

`ONCHAIN-SUBACCOUNT-MARGIN-ENGINE-V2-V1` is now unblocked. WP-08 MUST:
- inherit `VaultRiskModuleConsumer` (no independent RiskModule arg);
- implement `_computeMarginRequirement` by iterating up to 32 active
  Options series with provider-backed MM;
- implement `_computeAvailableMargin` by iterating up to 8 canonical
  collateral tokens with provider-backed price + haircut;
- fail-close on any missing / stale / unsupported input (already
  enforced by the abstract's `RiskModuleV2.liquidationStatus` revert);
- observe the completeness verifier before treating any caller-supplied
  series list as canonical.

## Files created

- `src/hybrid-v2/vault/CollateralVaultV2Core.sol` — MODIFIED (universe
  storage + views + errors + event).
- `src/hybrid-v2/positions/OptionsPositionsLedger.sol` — MODIFIED (cap
  constant + enforcement + verifier early-reject).
- `src/hybrid-v2/interfaces/ICollateralVault.sol` — MODIFIED (bounded
  views + event + errors added).
- `src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol` — MODIFIED
  (`maxActiveSeriesPerSubaccount()` view added).
- `test/hybrid-v2/positions/OptionsPositionsLedgerActiveSeriesBound.t.sol`
  — NEW (23 tests).
- `test/hybrid-v2/positions/OptionsPositionsLedgerActiveSeriesBoundInvariant.t.sol`
  — NEW (2 invariants).
- `test/hybrid-v2/vault/CollateralVaultV2CollateralUniverse.t.sol` — NEW
  (20 tests).
- `test/hybrid-v2/vault/CollateralVaultV2CollateralUniverseInvariant.t.sol`
  — NEW (4 invariants).
- `test/hybrid-v2/risk/LiquidationCompletenessIntegration.t.sol` — NEW
  (10 tests).
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_RISK_EXECUTION_BOUNDS_AND_COLLATERAL_UNIVERSE_V1.md`
  — this doc.
- `docs/ONCHAIN_SUBACCOUNT_RISK_EXECUTION_BOUNDS_AND_COLLATERAL_UNIVERSE_V1_RESULT.md`
  — local result (separate).
- `RUN_STATE.md` — new dated section prepended.

## Safety posture

- Deployment: NO.
- Broadcast: NO.
- Base mainnet touched: NO.
- Backend / frontend / migrations: NO.
- Secrets exposed: NO.
- All repositories clean at close: recorded in local result doc.

## Deviations / blockers

None.
