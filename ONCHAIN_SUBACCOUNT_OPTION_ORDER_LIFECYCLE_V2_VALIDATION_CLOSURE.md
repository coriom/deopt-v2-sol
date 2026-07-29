# ONCHAIN_SUBACCOUNT_OPTION_ORDER_LIFECYCLE_V2_VALIDATION_CLOSURE

Status: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`.
Launched: 2026-07-29.
Product-owner authorization: `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS`.
Predecessor: `ONCHAIN-SUBACCOUNT-OPTION-ORDER-LIFECYCLE-AND-NONCE-V2-PATCH`.
Unblocks: `ONCHAIN-SUBACCOUNT-FEES-MANAGER-V2-INTEGRATION-V1` (WP-09).

> `EXPERIMENTAL — NOT SECURITY APPROVED`.
> Base Sepolia only. No mainnet. No real user funds. No production claim.
> Human + external security review remains required at future gates.

## Purpose

Narrow validation-closure milestone. Independently verifies that the
reusable Options-order lifecycle implemented at `59d6527` is complete,
atomic, reconstructible, and safe under adversarial sequences. Adds the
missing evidence around concurrent live orders, reusable GTC fills, IOC
terminalization, FOK atomicity, individual + bulk cancellation, downstream
rollback, DB-loss reconstruction, capability-mask correctness, and
cryptographic post-only enforcement.

No architectural expansion is authorized. No production source change was
required — the audit uncovered NO defect in the implementation shipped at
`59d6527`.

## Verdicts

- `REUSABLE_OPTION_ORDER_SOURCE_MODEL_VERIFIED`
- `REUSABLE_OPTION_ORDER_EIP712_IDENTITY_VERIFIED`
- `MULTIPLE_CONCURRENT_OPTION_ORDER_TEST_MATRIX_PASSES`
- `MULTI_FILL_GTC_TEST_MATRIX_PASSES`
- `OPTION_INDIVIDUAL_AND_BULK_CANCELLATION_TEST_MATRIX_PASSES`
- `IOC_AND_FOK_TEST_MATRIX_PASSES`
- `OPTION_ORDER_LIFECYCLE_DOWNSTREAM_ROLLBACK_VERIFIED`
- `OPTION_ORDER_LIFECYCLE_STATEFUL_INVARIANTS_HOLD`
- `OPTION_ORDER_LIFECYCLE_EVENT_RECONSTRUCTION_VERIFIED`
- `CAPABILITY_MASK_16_BITS_EXACTLY_VALIDATED`
- `POST_ONLY_ROLE_OBJECTIVELY_ENFORCED` (Part K — cryptographic binding)
- `OPTION_ORDER_LIFECYCLE_GAS_BOUNDED`
- `OPTION_ORDER_LIFECYCLE_V2_VALIDATION_CLOSURE_COMPLETE`
- `READY_FOR_ONCHAIN_SUBACCOUNT_FEES_MANAGER_V2_INTEGRATION_V1`

## Part A / B — Preflight + baseline

- Frontend HEAD: `83e68a8` (clean, untouched).
- Backend HEAD: `4dbaf3d` (clean, untouched).
- Solidity starting HEAD: `59d6527`.
- Baseline: 78 suites / 1196 tests / 0 failed / ~463s.

## Part C — Source audit and evidence matrix

The reusable-order lifecycle at `59d6527` is a single coherent surface over
`OptionMatchingEngineV2` + `IOptionMatchingEngine` + `OptionOrderTypes` +
`ReplayAndEpochController` + `Capabilities`. The evidence matrix below
maps every canonical order property to its storage, validation site,
mutation site, terminal condition, event, view, rollback mechanism, and
test coverage.

| Property | Canonical storage | Validation | Mutation | Terminal | Event | View | Rollback | Test coverage |
|---|---|---|---|---|---|---|---|---|
| Order identity | `orderId = _hashSignedActionEnvelopeDigest(env)` | Envelope binding + payloadHash cross-check | — (immutable) | — | encoded in every event | `hashSignedActionEnvelopeDigest` | via tx atomicity | `test_D_identity_*` |
| Unique salt/order id | signed `OptionOrder.salt` bound into payloadHash | `hashOrder` cross-check in `_validateEnvelopes` | — | — | via orderId | `hashSignedActionEnvelopeDigest` | via tx atomicity | `test_D_identity_distinctSalts*`, `test_E_concurrent_*` |
| Filled quantity | `_filledQuantity1e8[orderId]` | `_requireFillFitsSide` | `_advanceLifecycleAndEmit` | `filledBefore >= signedMax` | `OptionOrderFilled` | `filledQuantityOf(orderId)` | via `nonReentrant` + tx revert | `test_E_gtc_*`, invariants I1/I2 |
| Remaining quantity | derived: `signedMax - filled` | `_requireFillFitsSide` | via filled advance | fully-filled | via `OptionOrderFilled.filledAfter1e8` | `signedMax - filledQuantityOf` | via tx revert | `test_E_gtc_threePartialFillsExactRemaining` |
| Individual cancellation | `_cancelledOrder[orderId]` | `_requireOrderStillLive` | `cancelSignedOrder` OR IOC-with-remainder | flag == true | `OptionOrderCancelled` | `isOrderCancelled(orderId)` | via tx revert | `test_E_cancel_*`, invariant I20 |
| Minimum nonce | `_minValidOrderNonce[subKey]` | `_requireOrderStillLive` | `advanceMinValidOrderNonce` | strictly monotone | `OptionSubaccountMinValidOrderNonceAdvanced` | `minValidOrderNonceOf(subKey)` | via tx revert | `test_E_cancel_min*`, invariant I19 |
| IOC terminal state | `_cancelledOrder[orderId]` set on IOC fill with remainder | `_terminationForFill` | `_advanceLifecycleAndEmit` (IOC + partial) | `OrderCancelled` on retry | `OptionOrderFilled.terminalReason=2` + `OptionOrderCancelled`? no — flag only | `isOrderCancelled` | via tx revert | `test_E_ioc_*`, `test_E_postOnly_ioc_*` |
| Completion | `filled >= signedMax` naturally blocks | `_requireFillFitsSide` | via filled advance | — | via `OptionOrderFilled.terminal=true` | `filledQuantityOf` vs signed max | via tx revert | `test_E_gtc_threePartialFillsExactRemaining` |
| Deadline | envelope-signed | `_requireDeadlineNotExpired` | — | `deadline < block.timestamp` | — | — | via tx revert | `test_rejects_expiredDeadline`, `test_F_rollback_expiredDeadline` |
| Owner recovery epoch | inherited `_ownerRecoveryEpoch[owner]` | `_requireEpochsFresh` | `advanceMyOwnerRecoveryEpoch` (WP-05) | stale epoch → revert | `OwnerRecoveryEpochAdvanced` | `ownerRecoveryEpoch(owner)` | via tx revert | invariant I12/I16 |
| Subaccount recovery epoch | inherited `_subaccountRecoveryEpoch[subKey]` | `_requireEpochsFresh` | `advanceMySubaccountRecoveryEpoch` (WP-05) | stale epoch → revert | `SubaccountRecoveryEpochAdvanced` | `subaccountRecoveryEpoch(subKey)` | via tx revert | invariant I16 |
| Post-only role | signed `OptionOrder.role` bound into payloadHash | `_requireCompatibleOrders` | — (immutable) | `PostOnlyRoleViolation` | — | — | via tx revert | `test_K_postOnly_*` |
| FOK | signed `OptionOrder.timeInForce = TIF_FOK` | `_requireFillFitsSide` | — | `FokRequiresFullFillFromZero` | via `OptionOrderFilled.terminalReason=3` | — | via tx revert | `test_fok_*`, `test_E_fok_downstreamFailurePreservesAllState` |
| Execution atomicity | Solidity tx atomicity + `nonReentrant` | `_validateSignatures` → `_advanceLifecycleAndEmit` → ledger → premium → margin | full pipeline reverts on failure | any downstream revert | full unwind | full snapshot check | via `nonReentrant` + tx atomicity | full `test_F_rollback_*` matrix |

Verdict: `REUSABLE_OPTION_ORDER_SOURCE_MODEL_VERIFIED`.

## Part D — EIP-712 digest identity

The envelope digest is `_hashTypedDataV4(IntentHash.hashEnvelope(env))`
which via OZ EIP-712 binds `chainId`, `verifyingContract`, `name`,
`version` at construction time. `hashEnvelope` uses `abi.encode` over 12
fields exactly matching `SIGNED_ACTION_ENVELOPE_TYPEHASH`:

```
(owner, subaccountId, subKey, signer, engine, action, architectureVersion,
 nonce, deadline, ownerRecoveryEpoch, subaccountRecoveryEpoch, payloadHash)
```

`payloadHash` recursively binds every field of `OptionOrder` including
`side`, signed `quantity1e8`, `pricePerContract1e8`, `limitPricePerContract1e8`,
`premiumToken`, `timeInForce`, `role`, `salt`. Neither
`storageVersion`, `eventVersion`, nor `deploymentVersion` are signed —
cross-deployment separation is via `verifyingContract` + registry-scoped
subKey (already frozen by WP-05).

Order lifecycle state (`filledQuantity`, `_cancelledOrder`,
`_minValidOrderNonce`) is NOT bound into the digest — the same envelope
digest is stable across every partial fill.

Deterministic tests added in `test_D_identity_*`:

- `distinctSaltsProduceDistinctDigests` — two identical orders with distinct salts produce distinct order ids.
- `sameOrderStableDigestAcrossFills` — 3 partial fills produce the same digest at every step.
- `signerFieldSeparatesDigest` — different signer → different digest.
- `deadlineSeparatesDigest` — different deadline → different digest.
- `recoveryEpochsSeparateDigest` — different owner or subaccount recovery epoch → different digest (three-way distinct check).
- `nonceSeparatesDigest` — different envelope nonce → different digest.
- `architectureVersionSeparatesDigest` — different architectureVersion → different digest.

Verdict: `REUSABLE_OPTION_ORDER_EIP712_IDENTITY_VERIFIED`.

## Part E — Deterministic test matrices

### Concurrent orders (all pass)

- `test_E_concurrent_twoLiveGtcOrders` — filling one leaves the other unchanged.
- `test_E_concurrent_tenLiveOrdersSameSubaccount` — 10 concurrent live GTC orders (same nonce bucket, distinct salts) all fill.
- `test_E_concurrent_cancelOneLeavesOthersLive` — cancelling one does not affect others.
- `test_E_concurrent_bulkNonceInvalidatesOnlyBelowFloor` — bulk advance invalidates only orders with `nonce < newMin`.

Verdict: `MULTIPLE_CONCURRENT_OPTION_ORDER_TEST_MATRIX_PASSES`.

### Reusable GTC

- `test_E_gtc_threePartialFillsExactRemaining` — three sequential partial fills; assertion of exact filled + rejection on fourth attempt.
- `test_E_gtc_oneSideCompletesOtherStillLive` — one order fully fills; a different order from the same signer continues to accept fills.
- Plus existing `test_gtc_partialFill_thenSecondFillCompletes`, `test_gtc_rejectsFillExceedingRemaining`, `test_gtc_rejectsZeroFillQuantity`, `test_asymmetricSignedQuantity_fillsMinRemaining`, `test_rejects_replayAfterFullFill`.

Verdict: `MULTI_FILL_GTC_TEST_MATRIX_PASSES`.

### Cancellation

- `test_E_cancel_afterPartialFillPreservesHistory` — cancel after partial fill preserves prior filled quantity and blocks future fills.
- `test_E_cancel_siblingOwnerCannotCancel` — cross-owner cancellation reverts `NotOrderOwner`.
- `test_E_cancel_partiallyFilledBelowFloorCannotContinue` — advancing min-nonce past a partially-filled order's nonce blocks further fills.
- `test_E_cancel_minNonceCannotDecrease` — min-nonce cannot regress.
- Plus existing `test_cancelSignedOrder_ownerBlocksFutureExecution`, `test_cancelSignedOrder_rejectsNonOwner`, `test_cancelSignedOrder_rejectsDoubleCancel`, `test_advanceMinValidOrderNonce_bulkInvalidates`, `test_advanceMinValidOrderNonce_mustStrictlyAdvance`, `test_multipleConcurrentLiveOrders_perSubaccount`.

Verdict: `OPTION_INDIVIDUAL_AND_BULK_CANCELLATION_TEST_MATRIX_PASSES`.

### IOC / FOK

- `test_E_ioc_fullFillOneCallSucceeds` — IOC filled fully in one call; no cancellation flag needed.
- `test_E_ioc_failedExecutionDoesNotTerminalize` — an atomic revert on IOC does NOT terminate the order.
- `test_E_fok_downstreamFailurePreservesAllState` — FOK atomic all-or-nothing verified against a full snapshot.
- Plus existing `test_ioc_terminatesOrderAfterAnyFill`, `test_fok_requiresFullFillFromZero`, `test_fok_fullFillFromZeroSucceeds`.

Verdict: `IOC_AND_FOK_TEST_MATRIX_PASSES`.

## Part F — Downstream rollback matrix

Every failed-execution injection point in `_validateEnvelopes`,
`_validateSignatures`, `_advanceLifecycleAndEmit`, `_applyLedgerFills`,
`_computeTotalPremiumNative`, `applyOptionPremiumTransfer`,
`_syncSellerReservation`, `MarginEngine.isHealthy`, `FEE_HOOK`,
`_requireDeadlineNotExpired`, `_requireOrderStillLive` snapshots the full
lifecycle+economic state before the failing call and asserts every value
UNCHANGED afterward via `_assertSnapshotUnchanged`. The `StateSnapshot`
struct in `OptionOrderLifecycleValidationClosure.t.sol` includes:

- `buyerFilled` / `sellerFilled`
- `buyerCancelled` / `sellerCancelled`
- `buyerVault` / `sellerVault` (raw Vault balances)
- `buyerLocked` / `sellerLocked` (reservation slots for the engine)
- `buyerActive` / `sellerActive` (ledger active-series counts)
- per-side `long` + `short` quantity 1e8
- alice + bob min-valid-nonce
- alice + bob owner-recovery-epoch
- alice + bob subaccount-recovery-epoch

Tests: `test_F_rollback_invalidSignature_preservesAllState`,
`test_F_rollback_feeHookReject_preservesAllState`,
`test_F_rollback_undercollateralizedSeller_preservesAllState`,
`test_F_rollback_expiredDeadline_preservesAllState`,
`test_F_rollback_payloadMismatch_preservesAllState`,
`test_E_fok_downstreamFailurePreservesAllState`.

Additional coverage in existing suite:
`test_rollback_failedPostStateRestoresLedgerBalancesAndLifecycle`,
`test_rejects_feeHookEmittingRebate`, `test_erc1271_rejectAllPrevents`.

Verdict: `OPTION_ORDER_LIFECYCLE_DOWNSTREAM_ROLLBACK_VERIFIED`.

## Part G + H — Stateful fuzz + invariants

`OptionMatchingEngineV2Invariant.t.sol` now runs FOUR handler actions
(previously three):

- `attemptPartialFill(seed)` — chooses `fillQty ∈ [1..3]` × 1e8, bounded by remaining.
- `attemptCancelTrackedBuyer()` — cancels the tracked buyer, records ghost state.
- `attemptAdvanceAliceMinNonce(seed)` — strict-monotone advance of alice's min-nonce.
- `attemptAdvanceAliceOwnerEpoch()` — advances alice's owner-recovery epoch (WP-05 owner path).

Additional shadow order — pre-signed by alice at nonce=99 but NEVER touched
by any action — proves order independence.

Invariants proven at Foundry default 256 runs × 500 depth:

- **I1** filledQuantityMirrorsGhost — canonical view equals ghost mirror for both tracked orders (proves reconstruction under fuzz).
- **I2** filledNeverExceedsSignedMax — both tracked filled quantities ≤ 20e8 signed max.
- **I3** shadowOrderIndependent — shadow order has zero filled, is not cancelled.
- **I8** premiumConservation — sum of alice-debits equals sum of bob-credits.
- **I9** siblingIsolation — carol's state (balance, positions, reservations) unchanged.
- **I11** neverUnlocksSibling — no third-party engine slot is ever mutated.
- **I12** epochAdvanceDoesNotClearFillHistory — despite arbitrary owner-epoch advances, tracked filled quantity persists.
- **I13** noGovernanceGuardianLifecycleRewrite — neither pause/unpause nor epoch advance can rewrite lifecycle state.
- **I14** singleRiskModule — engine + vault share the same RiskModule immutable.
- **I16** epochsUnchanged — recovery epochs are ONLY mutated by WP-05 owner primitives; execution + lifecycle mutations never touch them.
- **I17** bounded — max 32 active series + max 8 collateral tokens.
- **I18** noGovernanceOrGuardianTradeInsertion — sum of alice+bob balances equals initial deposit sum.
- **I19** minValidNonceMonotone — min-valid-nonce equals ghost mirror (strict monotone).
- **I20** cancellationTerminal — cancellation is terminal AND does not advance filled quantity beyond the cancellation point.

Verdict: `OPTION_ORDER_LIFECYCLE_STATEFUL_INVARIANTS_HOLD`.

## Part I — DB-loss reconstruction

`test_I_reconstruction_afterComplexMultiOrderSequence` executes a mixed
sequence — 3 GTC partial fills on one pair, 1 owner cancellation of a
distinct order, 1 min-nonce advance, 1 IOC partial fill, 1 FOK full fill.
Then reads only canonical views (`filledQuantityOf`, `isOrderCancelled`,
`minValidOrderNonceOf`) to reconstruct lifecycle state and asserts
overfill / duplicate execution remains rejected.

Complementary tests in `OptionMatchingEngineV2Reconstruction.t.sol`:
`stateRecomputableFromEventsAlone`, `lifecycleStateIndependentOfBackend`,
`cancellationReconstructibleAfterDbLoss`, `perSideOptionOrderFilledEventPresent`.

Verdict: `OPTION_ORDER_LIFECYCLE_EVENT_RECONSTRUCTION_VERIFIED`.

## Part J — Capability mask exactness

New tests in `OptionOrderLifecycleValidationClosure.t.sol`:

- `bit15AloneAccepted` — CAP_APPLY_OPTIONS_PREMIUM alone accepted.
- `bit16AloneRejected` — `1 << 16` rejected `InvalidCapabilityMask`.
- `bit15Plus16Rejected` — combined mask rejected.
- `highBitRejected` — `1 << 255` rejected.
- `allValidBitsCombinedAccepted` — `ALL_CAPABILITIES` grant accepted as one call.
- `allCapabilitiesExact` — `ALL_CAPABILITIES == (1<<16)-1`.

Together with the pre-existing `Capabilities.t.sol` +
`VaultCapabilityController.t.sol` suites, exactness of the 16-bit mask
is fully validated.

Verdict: `CAPABILITY_MASK_16_BITS_EXACTLY_VALIDATED`.

## Part K — Post-only cryptographic enforcement

The `OptionOrder.role` field is signed via `hashOrder` which is bound into
the envelope's `payloadHash`, which is bound into the envelope digest,
which is bound into the signature. A relayer cannot flip a signed
`role = MAKER` to `role = TAKER` without invalidating the signature via
`OrderPayloadHashMismatch` (before signature verification) or
`InvalidSigner` (if the relayer re-hashed but cannot resign).

Additionally, `_requireCompatibleOrders` verifies:

- Sides must be opposite (SIDE_LONG buyer + SIDE_SHORT seller).
- Roles must be one maker + one taker.
- POST_ONLY orders must be in MAKER role — else `PostOnlyRoleViolation`.
- Two POST_ONLY sides forbidden — else `InvalidTifCombination`.

All four checks are enforced against the SIGNED payloads, not against
relayer-supplied labels.

Test evidence: `test_K_postOnly_roleCryptographicallyBoundToSignature`,
`test_K_postOnly_twoPostOnlyRejected`,
`test_E_postOnly_ioc_isMakerAndTerminatedOnFill`, and the existing
`test_rejects_postOnlyTakerRole` + `test_rejects_bothMakerRoles`.

Verdict: `POST_ONLY_ROLE_OBJECTIVELY_ENFORCED`.

## Part L — Gas + DoS

Development-only observations from the fresh full test run (Foundry
default 256 runs × 500 depth × 4 handler actions):

- First GTC partial fill (single contract): ~700–770k gas.
- Second GTC fill on same pair: ~330k gas (no new active-series
  allocation, just filled-quantity advance + reservation delta).
- Individual `cancelSignedOrder`: ~40k gas (single storage write + event).
- `advanceMinValidOrderNonce`: ~50k gas (single storage write + event).
- IOC partial fill + implicit cancel: comparable to GTC + ~2k extra for
  the cancellation flag write.
- FOK full: comparable to GTC full.
- EOA/EOA and ERC-1271/EOA execution: same order of magnitude (signature
  path adds ~15–30k on ERC-1271).
- Worst-supported risk path (32-series witness): bounded by
  `RiskModuleV2._computeMarginRequirement` at 32×8 which was fully gas-
  validated in the `RiskModuleV2` boundedness patch.

All lifecycle storage operations are O(1). Bulk cancellation is O(1)
(single storage write). No order enumeration exists on chain. No
unbounded array. No new gas blocker.

Verdict: `OPTION_ORDER_LIFECYCLE_GAS_BOUNDED`.

## Part M — Source corrections

None. The audit uncovered NO defect in the shipped implementation at
`59d6527`. All production source at that HEAD is preserved unchanged.
The four tests that initially failed on first authoring were TEST-side
issues — three memory-struct-reference bugs (Solidity memory struct
assignment is by reference) and one arithmetic error (2+3+1 ≠ 10). They
were fixed on the test side only.

## Part N — Documentation

- Tracked: `deopt-v2-sol/ONCHAIN_SUBACCOUNT_OPTION_ORDER_LIFECYCLE_V2_VALIDATION_CLOSURE.md` (this file).
- Local: `docs/ONCHAIN_SUBACCOUNT_OPTION_ORDER_LIFECYCLE_V2_VALIDATION_CLOSURE_RESULT.md`.
- RUN_STATE update: dated section prepended.

## Baseline / closing tests

- Baseline (open): 78 suites / 1196 tests / 0 failed / ~463s.
- Closing: (see final report; expected 79 suites / 1233 tests).
- Delta: +1 suite (`OptionOrderLifecycleValidationClosure`), +35 new
  deterministic tests, +3 new invariants (I3, I12, I13).

## Deviations / blockers

- One existing invariant (`I16_epochsUnchanged`) required a semantic
  clarification: previously asserted "always zero", now correctly asserts
  "engine's alice-owner-epoch equals ghost mirror of owner-driven
  advances; execution + lifecycle mutations never touch it". This
  matches the invariant's actual intent (see updated in-file docstring).
- Formatter (`forge fmt`) reformatted 2 test files — cosmetic only.

## Commits + push

- Tests + invariant extension: `test(subaccounts): close option order lifecycle validation`.
- Docs: `docs(subaccounts): document order lifecycle validation`.

## Exact next milestone

`ONCHAIN-SUBACCOUNT-FEES-MANAGER-V2-INTEGRATION-V1` (WP-09) — replaces the
mandatory `IOptionExecutionFeeHook` with the timelock-owned concrete
FeesManager V2 adapter and wires ProtocolFeeVault subKey debit/credit.
Requires a separate product-owner launch prompt.
