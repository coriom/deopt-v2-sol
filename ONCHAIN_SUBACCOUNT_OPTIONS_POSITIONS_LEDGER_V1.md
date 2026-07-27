# ONCHAIN_SUBACCOUNT_OPTIONS_POSITIONS_LEDGER_V1

## Status

`IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL` — 2026-07-27. Product owner: Coriolan Morel.

Landed at `deopt-v2-sol` commit `98aa21a`
(`feat(subaccounts): add options positions ledger`, +2270 lines,
7 files, from base `3cda8f6`). Push: `3cda8f6..98aa21a main -> main`.

`EXPERIMENTAL — NOT SECURITY APPROVED`.

Not an audit sign-off. Not a security-reviewer sign-off. Not a deployment
approval. Not a production-readiness claim. Not authorized for Base mainnet
or real user funds. Internal reviewer status remains
`PENDING_INTERNAL_REVIEWER_ACKNOWLEDGEMENT`. External audit remains
`PENDING_EXTERNAL_REVIEW`.

## Purpose

Land the canonical immutable per-`subKey` Options-position ledger for the
DeOpt V2 hybrid subaccount architecture (WP-06). The ledger owns
position quantities + lifecycle state ONLY. Collateral, margin, matching,
signatures, replay, fees, oracles, and asset transfers remain owned by
their respective downstream milestones.

## Authoritative sources

Precedence (highest first):

1. Product-owner authorization for
   `ONCHAIN-SUBACCOUNT-OPTIONS-POSITIONS-LEDGER-V1` (2026-07-27) +
   its non-blocking conditions.
2. Tracked designs in `deopt-v2-sol/`:
   - `ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
   - `ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
   - `ONCHAIN_SUBACCOUNT_SHARED_TYPES_AND_INTERFACES_V1.md`
   - `ONCHAIN_SUBACCOUNT_REGISTRY_V1.md`
   - `ONCHAIN_SUBACCOUNT_CAPABILITY_CONTROLLER_V1.md`
   - `ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_A.md`
   - `ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_B.md`
   - `ONCHAIN_SUBACCOUNT_REPLAY_AND_EPOCH_FOUNDATION_V1.md`
3. Detailed contract specification:
   `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/` — especially
   `04_OPTIONS_POSITION_LEDGER_SPEC.md`, `07_ENGINE_CAPABILITIES_SPEC.md`,
   `08_SIGNATURES_AND_REPLAY_SPEC.md`, `14_STATE_MACHINES.md`,
   `15_SOLIDITY_INTERFACES.md`, `16_ERRORS_AND_EVENTS_CATALOGUE.md`,
   `17_SECURITY_INVARIANT_MAPPING.md`, `18_TEST_SPECIFICATION.md`,
   `21_DECISION_REGISTER.md`.
4. Detailed experimental-implementation-plan package.
5. Validated WP-01, WP-02, WP-03, WP-04A, WP-04B, WP-05 implementations
   at `3cda8f6`.

## ABI + ownership audit (Part C)

Verdict: `OPTIONS_LEDGER_ABI_AND_OWNERSHIP_RESOLVED`.

| Function | State affected | Required caller | Required capability | Registry dep. | Series dep. | Replay dep. | Risk dep. | Settlement dep. | WP-06? | Downstream if deferred |
|---|---|---|---|---|---|---|---|---|---|---|
| `applyFill(subKey, seriesId, side, qty, price)` | `_positions[subKey][seriesId]` (long OR short + basis) + `_activeSeriesCount` | engine with fill capability | `CAP_APPLY_OPTIONS_POSITION_DELTA` | `ownerOf(subKey)` | opaque `uint256 != 0` | none — engine's WP-05 controller consumed the nonce upstream | none | none | YES | — |
| `applyExercise(subKey, seriesId, qty, settlementPrice)` | `_positions.longQuantity1e8` decrement + `exerciseState` | engine with settle capability | `CAP_SETTLE_OPTION` | `ownerOf(subKey)` | opaque | none | none | asset transfer + PnL: WP-08 | YES (state only) | WP-08 (Vault debit/credit) |
| `applySettlement(subKey, seriesId, settlementPrice)` | zeros both quantities + `settlementState = FULL` | engine with settle capability | `CAP_SETTLE_OPTION` | `ownerOf(subKey)` | opaque | none | none | asset transfer: WP-08 | YES (state only) | WP-08 |
| `applyLiquidation(subKey, seriesId, qty, liquidatorSubKey)` | `_positions.shortQuantity1e8` decrement | engine with liquidate capability | `CAP_LIQUIDATE_OPTIONS` | `ownerOf(subKey)` + `ownerOf(liquidatorSubKey)` | opaque | none | eligibility selection: WP-07 + WP-08 | collateral seizure: WP-04B + WP-08 | YES (state only) | WP-07 (eligibility), WP-08 (seizure) |
| `positionOf(subKey, seriesId)` view | none | any | none | none | none | none | none | none | YES | — |
| `activeSeriesCount(subKey)` view | none | any | none | none | none | none | none | none | YES | — |

Ownership summary:
- WP-06 owns: position quantities (long + short), premium basis + short-recv,
  `lastFillBlock`, `settlementState`, `exerciseState`, `_activeSeriesCount`,
  and the events + errors defined in `IOptionsPositionsLedger`.
- WP-06 does NOT own: replay validation (WP-05 controller), collateral
  balances / reservations / capabilities (WP-04), margin + eligibility
  (WP-07), oracle prices (future oracle module), matching + signatures
  (WP-08 engines), fee / rebate accounting (WP-09), asset transfers
  (WP-04B + WP-08), Perps state (deferred).

## Position representation (Part D)

Verdict: `OPTIONS_POSITION_MODEL_STRUCTURED`.

Uses the WP-01 frozen `PositionTypes.OptionPosition` struct verbatim:

```solidity
struct OptionPosition {
    uint128 longQuantity1e8;
    uint128 shortQuantity1e8;
    uint128 premiumBasis1e8;
    uint128 shortPremiumRecv1e8;
    uint64  lastFillBlock;
    uint8   settlementState;   // 0 = none, 1 = partial, 2 = full
    uint8   exerciseState;     // 0 = none, 1 = partial, 2 = full
}
```

- Long + short as separate uint128 quantities (spec 04 FROZEN — never
  signed net). A subaccount MAY hold both non-zero simultaneously in the
  same series (hedged position).
- All accumulators overflow-checked against `type(uint128).max`.
- Underflow prevented at every decrement path
  (`OptionInsufficientLongForExercise` /
  `OptionInsufficientShortForLiquidation`).
- No cross-series netting.
- No cross-subaccount netting.
- No cross-owner netting.
- No silent long-to-short netting.
- No position deletion (zero-state is the canonical "empty" representation).

## Series identity (Part E)

Verdict: `OPTIONS_SERIES_IDENTITY_RESOLVED`.

- Position identity is `(subKey, uint256 seriesId)`.
- `seriesId` is treated as an opaque non-zero `uint256`. The ledger
  requires it to be non-zero and otherwise does not validate it. The
  seriesId scheme (equal to `optionId` from the frozen
  `OptionProductRegistry` per spec 04) is enforced upstream by the WP-08
  matching engine, which will validate the series through its own
  immutable product-registry reference before invoking the ledger.
- WP-06 does not depend on a concrete `OptionProductRegistry` deployment
  and does not embed complete immutable series metadata inside every
  position. Subaccount identity is enforced via the Registry; series
  identity validity is a downstream concern.

## Implementation form (Part F)

- `src/hybrid-v2/positions/OptionsPositionsLedger.sol` — concrete
  contract inheriting `IOptionsPositionsLedger`. Not abstract; no
  downstream validation hook is required.
- Immutable references only: `ISubaccountRegistry REGISTRY` +
  `ICollateralVault CAPABILITY_AUTHORITY`.
- No mutable owner. No local authorized-engine boolean. No local
  capability controller. No proxy initialization. No admin position
  editor.

## Authorization / capability model (Part G)

Verdict: `OPTIONS_LEDGER_CAPABILITY_PATH_RESOLVED`.

- The `CollateralVault` is the sole capability authority (spec 07 + WP-03
  FROZEN).
- Every mutation reads `CAPABILITY_AUTHORITY.engineCapabilityBits(msg.sender)`
  and requires the exact `CAP_*` bit set. No blanket "authorized engine"
  check.
- Mapping:
  - `applyFill`         → `CAP_APPLY_OPTIONS_POSITION_DELTA` (bit 5).
  - `applyExercise`     → `CAP_SETTLE_OPTION` (bit 9).
  - `applySettlement`   → `CAP_SETTLE_OPTION` (bit 9).
  - `applyLiquidation`  → `CAP_LIQUIDATE_OPTIONS` (bit 10).
- Guardian revocation on the Vault immediately blocks future mutations
  (the ledger reads the current bits on every call). Existing position
  state is NEVER altered by revocation.
- Governance / guardian have NO direct position-editor path. Governance is
  not automatically an engine and would need to be explicitly granted an
  Options capability to mutate positions.

## Storage model (Part H)

```solidity
mapping(bytes32 subKey => mapping(uint256 seriesId => OptionPosition)) internal _positions;
mapping(bytes32 subKey => uint32) internal _activeSeriesCount;
```

- Registry-backed subKey — the ledger validates `REGISTRY.ownerOf(subKey)`
  is non-zero on every mutation. Account 0 subKeys cannot exist (Registry
  rejects `subaccountId == 0`), so a valid Registry lookup already implies
  a non-zero subaccountId.
- No address-keyed legacy position mapping.
- O(1) lookup + O(1) mutation.
- No global position array. No unbounded owner or series enumeration.
- No collateral, margin, price, or fee storage.
- `_activeSeriesCount[subKey]` is a bounded hint used by off-chain
  reconciliation. It increments on the transition from all-zero → any
  non-zero position field; decrements on the transition back to all-zero.
  Bounded per subKey by the number of distinct series the subaccount has
  traded.

## Trade / mutation semantics (Part I)

- `applyFill(subKey, seriesId, side, quantity1e8, price1e8)`:
  - `msg.sender` MUST hold `CAP_APPLY_OPTIONS_POSITION_DELTA`.
  - Rejects zero subKey, zero seriesId, zero quantity, invalid side.
  - Rejects mutation of a `settlementState == FULL` position
    (`OptionFillAfterFullSettlement`).
  - Overflow-checked (`OptionQuantityOverflow`, `OptionPremiumBasisOverflow`).
  - Increments the specified side ONLY (no automatic netting).
  - Updates `lastFillBlock = block.number`.
  - Increments `_activeSeriesCount[subKey]` if the position was all-zero
    pre-mutation.
  - Emits `OptionPositionOpened` on first-fill for a side (side was zero
    pre-mutation); emits `OptionPositionModified` for subsequent fills.
  - No collateral, margin, or asset transfer. No replay-state consumption.
  - Re-opening long after a fully-exercised prior long resets the
    per-position `exerciseState` to `STATE_NONE` (fresh long-side batch).

## Netting rules (Part J)

Verdict: `OPTIONS_POSITION_NETTING_RULES_RESOLVED`.

- Buying always increases `longQuantity1e8`. Selling always increases
  `shortQuantity1e8`. Long + short may coexist for the same
  `(subKey, seriesId)` (hedged / spread position).
- No automatic netting between long and short. Closing a long via a
  trade requires an opposite-side sell that increments short (not a
  long decrement); the true reduction of a long side only happens via
  `applyExercise` or `applySettlement`. The true reduction of a short
  side only happens via `applyLiquidation` or `applySettlement`.
- This matches spec 04 §Position representation: "long + short as
  separate uint128 quantities" + "longQuantity1e8 and shortQuantity1e8
  accumulate".

## Duplicate-mutation boundary (Part K)

Verdict: `LEDGER_RELIES_ON_ATOMIC_ENGINE_REPLAY_BY_APPROVED_DESIGN`.

- The ledger does NOT maintain a fill / execution / settlement mutation
  identifier. Spec 04 §Idempotency: "The ledger itself does not maintain
  a fill nonce; it trusts the engine's nonce check."
- WP-05 `ReplayAndEpochController` owns canonical D.2 replay protection.
  The WP-08 matching engine consumes the signed D.2 intent (per-signer
  sequential nonce OR consumed-intent hash) BEFORE invoking the ledger.
  If the ledger call OR any subsequent engine logic reverts, the whole
  transaction unwinds atomically — no partial ledger mutation can outlive
  a failed engine execution.
- Off-chain indexer deduplication remains an off-chain concern and does
  not replace the chain-side barrier.

## Exercise + settlement scope (Part L)

Verdict: `OPTIONS_LEDGER_LIFECYCLE_SCOPE_RESOLVED`.

WP-06 owns:
- `settlementState` monotonic transitions
  (`STATE_NONE` → `STATE_PARTIAL` implicit via applyExercise on partial
  long remainders → `STATE_FULL` via `applySettlement`).
- `exerciseState` monotonic transitions
  (`STATE_NONE` → `STATE_PARTIAL` → `STATE_FULL` via `applyExercise`).
- Exercise-quantity bounded by `longQuantity1e8`.
- Duplicate settlement rejected (`OptionAlreadySettled`).
- No mutation permitted after `settlementState == STATE_FULL`.
- `applyExercise` decrements long only. `applyLiquidation` decrements
  short only. `applySettlement` zeros both quantities and sets
  `settlementState = STATE_FULL`; if the position had a non-zero long at
  settlement, `exerciseState` is escalated to `STATE_FULL` implicitly.

WP-06 does NOT own:
- PnL / delta computation from settlement price (the ledger does not know
  strike / underlying / contract shape — that's the product registry).
  Event fields `OptionExercised.delta`, `OptionSettled.pnlDelta`, and
  `OptionPositionLiquidated.seizedCollateral` are emitted as `0` from the
  ledger; the WP-08 settlement engine emits paired richer events with
  the real economic values in the same atomic transaction.
- No oracle price is chosen by the ledger. `settlementPrice1e8` is a
  pass-through parameter carried into events for reconstruction.
- No asset transfer.

## Liquidation boundary (Part M)

- `applyLiquidation` reduces `shortQuantity1e8` by the specified quantity
  and validates the liquidator subKey exists in the Registry.
- No margin / eligibility / seizure computation. Eligibility selection is
  owned by WP-07 (RiskModule) + WP-08 (MarginEngine); the actual
  collateral seizure to `liquidatorSubKey` is owned by WP-04B (Vault
  `applyLiquidationDebit`) — the engine calls both in the same atomic
  transaction.
- No broad liquidation admin. Governance / guardian cannot erase short
  positions. Capability revocation blocks future liquidations but does
  NOT alter existing positions.

## Views + enumeration (Part N)

- `positionOf(subKey, seriesId)` — O(1) single-position lookup. Returns
  a zero struct for unknown pairs (no revert on view).
- `activeSeriesCount(subKey)` — O(1) bounded reconciler hint.
- No global enumeration. No unbounded "all positions for owner" surface.
- No fabricated zero-state registration on view access.

## Events + reconstruction (Part O)

All events from `IOptionsPositionsLedger` carry the readable `owner` +
`subaccountId` alongside the indexed `subKey` + `seriesId`, so full state
is replayable from block 0 without a private mapping:

- `OptionPositionOpened(subKey, seriesId, side, quantity1e8, price1e8, engine, owner, subaccountId, eventVersion)`
- `OptionPositionModified(subKey, seriesId, side, int128 quantityDelta, price1e8, engine, owner, subaccountId, eventVersion)`
- `OptionPositionClosed(subKey, seriesId, side, engine, owner, subaccountId, eventVersion)`
- `OptionExercised(subKey, seriesId, quantity1e8, settlementPrice1e8, delta, owner, subaccountId, eventVersion)`
- `OptionSettled(subKey, seriesId, settlementPrice1e8, pnlDelta, owner, subaccountId, eventVersion)`
- `OptionPositionLiquidated(subKey, seriesId, quantity1e8, seizedCollateral, liquidatorSubKey, eventVersion)`

Every event carries `eventVersion = Versions.EVENT_VERSION` (=1). No
opaque-hash-only events. No signatures leaked.

## Errors (Part P)

Interface errors reused from `IOptionsPositionsLedger`:
- `OptionSubKeyNotFound`
- `OptionSeriesNotFound` (declared; not emitted by WP-06 since series
  validation is deferred — retained for downstream Options engines)
- `OptionSeriesInactive` (declared; downstream)
- `OptionInvalidSide`
- `OptionQuantityZero`
- `OptionInsufficientLongForExercise`
- `OptionInsufficientShortForLiquidation`
- `OptionAlreadySettled`
- `OptionMissingCapability`

Ledger-local errors:
- `InvalidRegistry` (constructor)
- `InvalidCapabilityAuthority` (constructor)
- `SubKeyRequired`
- `SeriesIdRequired`
- `LiquidatorSubKeyRequired`
- `LiquidatorSubKeyNotFound`
- `OptionExerciseAfterFullSettlement`
- `OptionLiquidationAfterFullSettlement`
- `OptionFillAfterFullSettlement`
- `OptionQuantityOverflow`
- `OptionPremiumBasisOverflow`
- `OptionActiveSeriesOverflow`

No string reverts. Selectors distinct from prior interface errors.

## Registry / Vault / Replay isolation (Part Q)

Proved via `OptionsPositionsLedgerIntegration.t.sol` (10 tests):

- Registry `ownerOf(subKey)` is the canonical identity source.
- Account 0 subKey rejected (no `ownerOf` binding).
- Unknown subaccount rejected.
- Unauthorized engine rejected.
- Position mutation does NOT alter Vault balances, `totalAccounted`,
  physical, or `lockedOf`.
- Position mutation does NOT alter WP-05 replay state (nonces, consumed
  intents, owner-wide epoch, per-subaccount epoch).
- Epoch advancement does NOT alter positions.
- Guardian capability revocation blocks future mutations but preserves
  existing state.
- Events carry `engine + owner + subaccountId` sufficient to reconstruct
  without consulting Vault, Registry, or ReplayController.

## DB-loss reconstruction (Part T)

Proved via `OptionsPositionsLedgerIntegration.t.sol.test_reconstructionFromEvents`:

- Multiple owners + subaccounts + series, many mutations recorded via
  `vm.recordLogs()`.
- Reconstruction walks event log and re-derives per-`(subKey, seriesId)`
  long + short quantities (`OptionPositionOpened` sets baseline;
  `OptionPositionModified` applies delta; `OptionExercised` decrements
  long).
- Reconstructed values equal canonical `positionOf(sk, seriesId)`.
- The test does NOT clear canonical Solidity storage — it exercises the
  reconstructibility of the derived DB purely from event data.

## Storage review (Part U)

- Immutable Registry reference (`REGISTRY`).
- Immutable capability authority reference (`CAPABILITY_AUTHORITY`).
- No local authorized-engine mapping.
- No local capability controller.
- No duplicate Registry storage.
- No collateral, margin, fee, oracle, or replay state.
- Position mapping + active-series counter are the only new storage.
- `_activeSeriesCount` cannot collide with position storage — different
  slot namespace.
- No `settlementId` / `exerciseId` / `fillId` mapping (idempotency
  deferred to WP-05 + WP-08 per spec 04).
- No storage reset function. No proxy assumptions.
- Future RiskModule (WP-07), MarginEngine + MatchingEngine (WP-08),
  FeesManager (WP-09), and EscapeController (WP-10) can integrate
  without modifying this contract.
- Future PerpsPositionsLedger remains fully separate (different
  contract, different storage namespace).

## Gas / DoS (Part V)

- `applyFill` first-fill: O(1) — one struct write + one counter
  increment.
- `applyFill` subsequent: O(1) — one struct write.
- `applyExercise`, `applySettlement`, `applyLiquidation`: O(1) each.
- Views: O(1).
- No owner / account / series iteration.
- No signature-array iteration.
- No multi-leg batch surface in WP-06 (multi-leg execution is decomposed
  by the WP-08 engine into N atomic `applyFill` calls in a single
  transaction, per spec 04).
- Callers pay gas. Position-storage growth is proportional to canonical
  positions.

## Tests + invariants

- **Unit + fuzz** (`OptionsPositionsLedger.t.sol`): 36 tests covering
  construction, capability, identity, mutations, isolation, lifecycle,
  overflow boundaries.
- **Invariants** (`OptionsPositionsLedgerInvariant.t.sol`): 12 tests
  covering OPT-POS-I1..I14 at 64 runs × 64 depth each (~4096 handler
  calls per invariant).
- **Integration + DB-loss**
  (`OptionsPositionsLedgerIntegration.t.sol`): 10 tests covering Registry
  / Vault / Replay isolation + reconstruction from events.

OPT-POS-I* coverage:
- I1: unknown Registry identities never acquire positions.
- I2 + I3: sibling subaccount / sibling series isolation (ghost mirror
  matches chain).
- I4 + I5: capability required; revocation blocks future + preserves
  state.
- I6: no underflow / overflow (uint128 witnesses).
- I7: engine-visible conservation (open long / short bounded by ghost
  total added).
- I8: no ledger-side fill ID (ghost mirror equality proves lack of
  double-mutation).
- I9: monotonic lifecycle (settled implies both quantities zero; full
  exercise implies long zero).
- I10: ledger never mutates Vault capability bits.
- I11: ledger never mutates replay state (type-level + integration proof).
- I12: event-derived ghost matches storage.
- I13: no governance / guardian position editor (governance has no
  capability bit).
- I14: DB-loss / off-chain ghost clear does not alter canonical positions.

## Explicit non-goals

- No matching, RFQ, multi-leg execution logic.
- No collateral custody, reservation, capability grant/revoke.
- No margin / risk / eligibility / liquidation-selection.
- No fee / rebate accounting.
- No oracle price selection.
- No settlement asset transfer.
- No signature verification / ECDSA / ERC-1271.
- No replay controller mutation.
- No pause mechanism (no field explicitly permits governance-driven pause
  in WP-06; the WP-08 engine layer can institute engine-level pauses).
- No Perps behavior.
- No deployment script; no Base Sepolia deployment; no broadcast; no
  backend or frontend change.

## Downstream ownership

| Deferred concept | Downstream milestone |
|---|---|
| Concrete margin computation from position quantities | WP-07 RiskModule |
| Signature verification + replay consumption + position-mutation orchestration | WP-08 MarginEngine + OptionMatchingEngine |
| Actual asset debit / credit at exercise + settlement + liquidation | WP-04B Vault (`applySettlementCreditDebit`, `applyLiquidationDebit`) invoked by WP-08 |
| Fee / rebate accounting integration | WP-09 FeesManager |
| Fallback settlement + escape recovery | WP-10 EscapeController + RecoveryFinalizer |
| PerpsPositionsLedger | future Perps milestone |

## Decision register (this milestone)

| ID | Decision | Status |
|---|---|---|
| D-OPL-01 | Position model: `PositionTypes.OptionPosition` struct verbatim; gross long+short (D-C-06 upheld) | FROZEN |
| D-OPL-02 | Series identity: opaque non-zero `uint256`; WP-08 engine validates against `OptionProductRegistry` upstream | FROZEN |
| D-OPL-03 | Capability model: Vault-owned; ledger reads `engineCapabilityBits(msg.sender)` per call; no local mapping | FROZEN |
| D-OPL-04 | Idempotency: engine consumes signed D.2 intent (WP-05); ledger has no fill ID | FROZEN |
| D-OPL-05 | Netting: gross positions; long + short accumulate independently; no auto-net | FROZEN |
| D-OPL-06 | Lifecycle: WP-06 owns state transitions (exerciseState, settlementState); PnL / asset transfer owned by WP-08; events emit 0 for delta / seizedCollateral | FROZEN |
| D-OPL-07 | Re-opening a long after full exercise resets `exerciseState` to `STATE_NONE` (fresh long-side batch semantics) | FROZEN |
| D-OPL-08 | Liquidator subKey MUST exist in Registry (bounded O(1) validation) | FROZEN |
| D-OPL-09 | No pause; no admin position editor; no `setPosition`; governance cannot mutate positions without holding an engine capability | FROZEN |

None BLOCKING. None DEFERRED_WITH_OWNER at this milestone (downstream
owners already frozen).

## No audit or production claim

Same disclaimer as every prior WP milestone. Not audited. Not security-
reviewed. Not authorized for real user funds.
