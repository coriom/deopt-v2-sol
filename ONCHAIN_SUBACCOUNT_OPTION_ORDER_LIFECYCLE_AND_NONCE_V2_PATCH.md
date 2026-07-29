# ONCHAIN_SUBACCOUNT_OPTION_ORDER_LIFECYCLE_AND_NONCE_V2_PATCH

Status: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`.
Launched: 2026-07-29.
Product-owner authorization: `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS`.
Predecessor: `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` (WP-08B).
Unblocks: `ONCHAIN-SUBACCOUNT-FEES-MANAGER-V2-INTEGRATION-V1` (WP-09).

> `EXPERIMENTAL — NOT SECURITY APPROVED`.
> Local Solidity + Base Sepolia only. No mainnet. No real user funds. No
> production claim. Human + external security review remains required at
> future gates.

## Purpose

Narrow corrective patch that supersedes the WP-08B `PF-2` exact-fill order
model with a reusable partial-fill lifecycle. Under `PF-2`, each signed
envelope was consumed as a single exact-fill of `quantity1e8` — GTC
"remaining" semantics lived entirely off chain, a fully-connected D.1 book
was required for every partial fill, and orders shared a strict sequential
per-signer per-engine nonce that permitted at most one live order per
signer at a time.

This patch replaces that model with canonical on-chain
`filledQuantity1e8[orderId]` + explicit cancellation + a per-subaccount
monotonic min-valid-nonce, delivering:

1. reusable GTC orders that fill across many `executeMatch` calls until the
   signed maximum is reached;
2. multiple concurrent live orders per subaccount (distinct salts and/or
   nonces);
3. individual owner cancellation of a specific signed order;
4. per-subaccount bulk cancellation via monotonic min-valid-nonce
   advancement;
5. IOC that terminates after any successful fill regardless of remainder;
6. FOK that requires exact full-fill from a zero-filled state or reverts;
7. POST_ONLY maker enforcement preserved;
8. EOA + ERC-1271 signature verification preserved;
9. Vault-scoped premium accounting, engine-owned reservations, mandatory
   fee hook, and post-state MarginEngine health checks all preserved;
10. every downstream failure atomically rolls back lifecycle state alongside
    positions, balances, and reservations;
11. lifecycle state entirely reconstructible from emitted events without
    any backend or off-chain database dependency;
12. capability bit 15 (`CAP_APPLY_OPTIONS_PREMIUM`) validated unchanged;
    bit 16 explicitly reserved.

## Verdicts

- `OPTION_ORDER_FILLED_QUANTITY_CANONICAL_ONCHAIN`
- `OPTION_REUSABLE_ORDER_NONCE_NAMESPACE_IMPLEMENTED`
- `MULTIPLE_CONCURRENT_LIVE_OPTION_ORDERS_SUPPORTED`
- `GTC_PARTIAL_FILL_REMAINDER_CANONICAL_AND_REUSABLE`
- `IOC_REMAINDER_TERMINALLY_INVALIDATED`
- `FOK_EXECUTION_ATOMIC`
- `OPTION_INDIVIDUAL_AND_BULK_CANCELLATION_VALIDATED`
- `OPTION_ORDER_LIFECYCLE_RECONSTRUCTIBLE_AND_DB_INDEPENDENT`
- `CAPABILITY_BIT_15_EXTENSION_CONSISTENT`
- `OPTION_ORDER_LIFECYCLE_AND_NONCE_V2_PATCH_COMPLETE`
- `READY_FOR_ONCHAIN_SUBACCOUNT_FEES_MANAGER_V2_INTEGRATION_V1`

## Part A / B — Preflight + baseline

- Frontend HEAD: `83e68a8` (clean, untouched).
- Backend HEAD: `4dbaf3d` (clean, untouched).
- Solidity starting HEAD: `d8d7ebf`.
- Baseline: 78 suites / 1181 tests / 0 failed / ~764s.

## Part C — Cardinal design decision

**Order identity** = `_hashSignedActionEnvelopeDigest(envelope)`, i.e. the
frozen EIP-712 typed-data digest of the outer envelope, which already binds
`(owner, subaccountId, subKey, signer, engine, action, architectureVersion,
nonce, deadline, ownerRecoveryEpoch, subaccountRecoveryEpoch, payloadHash)`
where `payloadHash` further binds all `OptionOrder` fields including the
signer-chosen `salt`. This preserves every WP-05 replay-separation property
and adds no new domain-separator surface.

**Nonce namespace**: `envelope.nonce` becomes a signer-chosen ORDER nonce
(not a sequential replay counter). The engine explicitly BYPASSES the base
`_consumeNonce` primitive from `ReplayAndEpochController`. Replay protection
is provided instead by monotone `filledQuantity1e8[orderId]` bounded by the
signed maximum, and by the terminal `_cancelledOrder[orderId]` flag. The
inherited `cancelNextNonce` / `cancelNoncesUpTo` still work on the abstract
but no longer affect option-order acceptance. Sequential nonces remain
available to future engines that inherit `ReplayAndEpochController`.

**Termination reasons** (`terminalReason` field on `OptionOrderFilled`):

- `0` = not terminal (fill left unfilled remainder for a non-IOC order).
- `1` = fully filled (any TIF).
- `2` = IOC remainder terminated (IOC with unfilled remainder).
- `3` = FOK consumed (FOK completing its only allowed fill).

Only reason `2` triggers a write to `_cancelledOrder[orderId]` — fully
filled orders are naturally blocked on retry by the `filledBefore >=
signedMax` check inside `_requireFillFitsSide`, keeping cancellation events
focused on non-natural terminations.

## Part D — Engine surface changes

### Interface: `IOptionMatchingEngine`

- **`executeMatch(...)` signature** gains a new `uint128 fillQuantity1e8`
  parameter between `sellerOrder` and `buyerActiveSeriesIds`. The signed
  `quantity1e8` on each side is now a MAXIMUM; the per-call
  `fillQuantity1e8` is bounded by `min(buyerRemaining, sellerRemaining)`.
- **`cancelSignedOrder(envelope)`** — owner-only individual cancellation.
- **`advanceMinValidOrderNonce(subaccountId, newMin)`** — owner-only
  strictly-monotonic bulk cancellation. Any envelope for this subKey with
  `nonce < newMin` is terminally invalid.
- **Views**: `filledQuantityOf(orderId)`, `isOrderCancelled(orderId)`,
  `minValidOrderNonceOf(subKey)`.
- **New events**: `OptionOrderFilled(orderId, subKey, seriesId, side,
  timeInForce, fillQuantity1e8, filledBefore1e8, filledAfter1e8,
  orderMaxQuantity1e8, terminal, terminalReason, actor, eventVersion)`,
  `OptionOrderCancelled(orderId, subKey, owner, actor, eventVersion)`,
  `OptionSubaccountMinValidOrderNonceAdvanced(subKey, owner, previousMin,
  newMin, actor, eventVersion)`.
- **Preserved**: `OptionOrderPairExecuted` (same 20 fields — its
  `filledQuantity1e8` field is now the per-call fill, unchanged shape;
  topics `buyerOrderId` / `sellerOrderId` were renamed from `buyerOrderHash`
  / `sellerOrderHash` to reflect the canonical id semantics).
- **New errors**: `FillQuantityInvalid`, `OrderAlreadyFullyFilled`,
  `OrderCancelled`, `OrderNonceStale`, `FokRequiresFullFillFromZero`,
  `NotOrderOwner`, `MinValidOrderNonceNotAdvancing`.
- **Removed error**: `QuantityDisagreement` (buyer and seller quantities
  may now differ).

### Concrete engine: `OptionMatchingEngineV2`

- Storage additions: `mapping(bytes32 => uint128) _filledQuantity1e8`,
  `mapping(bytes32 => bool) _cancelledOrder`, `mapping(bytes32 => uint256)
  _minValidOrderNonce`. All keyed by canonical identifiers (orderId /
  subKey) so reconstruction is direct.
- `executeMatch` executes lifecycle preconditions (min-valid-nonce, not
  cancelled, remaining capacity, TIF rules) BEFORE any mutation, then
  advances filled-quantity + emits per-side `OptionOrderFilled` BEFORE
  ledger `applyFill`, premium transfer, and margin sync. Any downstream
  revert atomically rolls back lifecycle state alongside every other
  economic mutation.
- `_consumeNonce` and `_consumeIntent` are NOT called for option orders.
  `IntentConsumed` events are NOT emitted by this engine; reconstruction
  uses `OptionOrderFilled` + `OptionOrderCancelled` +
  `OptionSubaccountMinValidOrderNonceAdvanced` instead.

### Library: `OptionOrderTypes`

- Struct unchanged. Semantic comments updated: `quantity1e8` is now a
  SIGNED MAXIMUM (not exact fill); TIF semantics rewritten to reference
  the on-chain lifecycle model.

### Library: `Capabilities`

- No new capability bits. Comments clarify that bit 15
  (`CAP_APPLY_OPTIONS_PREMIUM`) is preserved and bit 16 is explicitly
  RESERVED for future capabilities.

## Part E — TIF semantics (post-patch)

- **GTC**: `_filledQuantity1e8[orderId]` accumulates across executions until
  `signedMax`. Fully-filled orders are blocked on retry by the
  `filledBefore >= signedMax` check.
- **IOC**: any successful fill (partial OR full) triggers termination —
  `_cancelledOrder[orderId] = true` when `filledAfter < signedMax`.
  Subsequent calls revert `OrderCancelled`.
- **FOK**: `fillQuantity1e8 == quantity1e8` AND `filledBefore == 0`
  REQUIRED. Any partial fill or attempt on a partially-filled FOK order
  reverts `FokRequiresFullFillFromZero`. Full fill is naturally single-use.
- **POST_ONLY**: MUST equal `role = ROLE_MAKER` (unchanged from WP-08B).

## Part F — Cancellation model

- **Individual**: `cancelSignedOrder(envelope)` — `msg.sender == owner`,
  order not already cancelled. Sets `_cancelledOrder[orderId] = true`,
  emits `OptionOrderCancelled`. Reverts on double-cancel.
- **Bulk**: `advanceMinValidOrderNonce(subaccountId, newMin)` — `msg.sender
  == owner`, subaccount registered, `newMin > current`. Sets
  `_minValidOrderNonce[subKey] = newMin`, emits
  `OptionSubaccountMinValidOrderNonceAdvanced`. Reverts
  `MinValidOrderNonceNotAdvancing` on regression or no-op.

## Part G — Reconstruction

Every canonical piece of lifecycle state is reconstructible from chain
events alone:

- `filledQuantity1e8[orderId]` = sum of `OptionOrderFilled.fillQuantity1e8`
  for all events with matching `orderId`.
- `isOrderCancelled(orderId)` = existence of any `OptionOrderCancelled` for
  `orderId` OR an `OptionOrderFilled` for `orderId` with `terminal == true`
  and `terminalReason == 2` (IOC remainder).
- `minValidOrderNonceOf(subKey)` = latest
  `OptionSubaccountMinValidOrderNonceAdvanced.newMin` for `subKey`
  (or 0 if no advance ever occurred).

Positions + balances + reservations reconstruct from existing
ledger / vault events unchanged. DB loss cannot reset any of this state.

## Part H — Atomicity

Preserved from WP-08B — every economic mutation reverts atomically on any
downstream failure. Lifecycle mutations (filled quantity advances,
cancellation writes, min-nonce advances) participate in the same
transaction rollback: a failed post-state health check unwinds a filled
quantity write together with positions, balances, and reservations.

## Part I — Isolation

Preserved from WP-08B. Additionally:

- `cancelSignedOrder(envelope)` writes ONLY `_cancelledOrder[orderId]` and
  emits ONE event.
- `advanceMinValidOrderNonce(subaccountId, newMin)` writes ONLY
  `_minValidOrderNonce[subKey]` and emits ONE event.
- Neither owner-path lifecycle mutation touches balances, positions,
  reservations, replay state, or recovery epochs.
- Sibling subaccounts + sibling owners remain fully isolated.

## Part J — Tests (61 in the Option suites; 15 net new)

`test/hybrid-v2/options/`:

- `OptionMatchingEngineV2.t.sol` — base fixture + 8 constructor tests.
- `OptionMatchingEngineV2Execution.t.sol` — 35 execution + lifecycle
  tests (was 23, +12 new):
  - Happy path (EOA/EOA), asymmetric quantities, self-trade, zero
    account id, same-side, different series, price disagreement, buyer
    limit violation, POST_ONLY taker, both makers, signer != owner,
    invalid signature bytes, expired deadline, replay after full fill,
    wrong engine, GTC partial-then-full, GTC oversize fill, zero fill,
    IOC remainder termination, FOK requires-full-from-zero, FOK success,
    cancelSignedOrder happy, cancel non-owner rejected, double-cancel
    rejected, advanceMinValidOrderNonce bulk-invalidates, advance
    strictly-monotone, multiple concurrent live orders, unknown series,
    undercollateralized seller, rollback lifecycle preserved, fee hook
    reject, fee hook rebate, pause behavior, sibling untouched.
- `OptionMatchingEngineV2ERC1271.t.sol` — 2 ERC-1271 tests.
- `OptionMatchingEngineV2Reconstruction.t.sol` — 6 reconstruction tests
  (was 4, +2 new: `perSideOptionOrderFilledEventPresent`,
  `cancellationReconstructibleAfterDbLoss`; two updated for lifecycle
  independence).
- `OptionMatchingEngineV2Invariant.t.sol` — 11 invariants (was 9, +2
  new): I19 min-valid-nonce monotone, I20 cancellation terminal.

## Part K — Invariants (bounded 256×500)

- **I1** filled quantity equals ghost mirror.
- **I2** filled quantity never exceeds signed maximum.
- **I8** premium buyer debit == seller credit.
- **I9** sibling isolation.
- **I11** engine never unlocks another engine's reservation slot.
- **I14** engine + vault share the same immutable RiskModule.
- **I16** recovery epochs unchanged by execution or lifecycle mutations.
- **I17** bounded input processing.
- **I18** no governance/guardian trade fabrication.
- **I19** min-valid-nonce monotone non-decreasing per subKey.
- **I20** cancellation is terminal.

All invariants pass 256×500 (default). No shrinking.

## Part L — Gas (development observations)

- Full-fill happy path (single-contract): ~770k.
- GTC partial fill: comparable, slightly lower due to no full-fill
  branch.
- IOC termination (partial + cancel flag): +~2k for the flag write.
- Individual cancel: ~50k (single storage write + event).
- Bulk min-nonce advance: ~50k (single storage write + event).

Not audited. Not a production-gas promise.

## Part M — Deviations / blockers

None. Formatter (`forge fmt`) reformatted 4 files after initial write —
purely cosmetic, no semantic change.

## Part N — Commits + push

- Code + tests commit: `fix(subaccounts): support reusable option order lifecycle`.
- Docs commit: `docs(subaccounts): supersede exact-fill order model`.
- Push to origin/main.

## Exact next milestone

`ONCHAIN-SUBACCOUNT-FEES-MANAGER-V2-INTEGRATION-V1` (WP-09) — replaces the
mandatory `IOptionExecutionFeeHook` with the timelock-owned concrete
FeesManager V2 adapter and wires ProtocolFeeVault subKey debit / credit.
Requires a separate product-owner launch prompt.
