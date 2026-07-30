# ONCHAIN-SUBACCOUNT-FEES-MANAGER-V2-INTEGRATION-V1 (WP-09)

**Status:** COMPLETE — verdicts landed 2026-07-30. All prior lifecycle
verdicts (see supersession note at end) remain valid; this milestone
adds concrete, fail-closed fee integration on top of them.

**Safety posture:** `EXPERIMENTAL — NOT SECURITY APPROVED`.

**Product-owner authorization:** `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS` (Coriolan Morel).

**Not authorized:** deployment, backend or frontend integration,
permissive zero-fee fallback, arbitrary governance balance editing.

---

## 1. Objective

Replace the mandatory abstract `IOptionExecutionFeeHook` boundary with
a concrete, fail-closed, timelock-governed fee integration between:

- reusable EIP-712 Options orders,
- signed maker/taker roles,
- the canonical per-fill premium,
- `FeesManagerV2` fee schedules,
- protocol fee + rebate subaccounts,
- Vault accounting,
- final post-fee margin,
- reconstructible fee events.

Preserve every validated order-lifecycle and execution invariant.

## 2. Product-owner safety decision — signed positive-fee cap

Every reusable Options order signs `uint32 maxPositiveFeePpm` — the
upper bound on positive fee ppm the counterparty side is willing to
pay. Bound into EIP-712 typed data. Applied per side. Zero cap permits
only zero or negative (rebate) fee. Any later fee schedule change that
would raise the actual applied fee above the signed cap causes the
match to revert.

**EIP-712 supersession is hard.** The action tag was bumped from
`OPTION_ORDER_MATCH_V1` to `OPTION_ORDER_MATCH_V2`. The order type
string now includes `uint32 maxPositiveFeePpm`, so `OPTION_ORDER_TYPEHASH`
changes. Pre-cap signatures produce a different digest and are rejected
at signature verification — there is no compatibility path.

**Rationale (product-owner note):** GTC reusable orders can remain
active for a long time. Without a signed cap, a later on-chain fee
schedule change could apply higher fees than the trader consented to.
The signed cap ensures the trader's consent is enforced across the
entire life of the order.

## 3. Concrete integration

### 3.1 EIP-712 (`OptionOrderTypes.sol`)

- `ACTION_OPTION_ORDER = keccak256("OPTION_ORDER_MATCH_V2")` (was `_V1`).
- Type string includes `uint32 maxPositiveFeePpm` between `role` and `salt`.
- `hashOrder` binds `maxPositiveFeePpm`.
- `MAX_POSITIVE_FEE_PPM_CAP = 1_000_000` (sanity ceiling, 100%).

### 3.2 Vault primitives (`CollateralVaultV2` + Core)

- Governance one-shot `initializeProtocolSubaccounts(protocolFeeOwner,
  protocolFeeSubaccountId, rebateBudgetOwner, rebateBudgetSubaccountId,
  insuranceFundOwner, insuranceFundSubaccountId)` establishes the three
  canonical protocol subKeys. `ProtocolSubaccountsAlreadyInitialized`
  guards re-init. `ProtocolSubaccountsInitialized` event emitted.
- New views: `protocolFeeVaultSubKey()`, `rebateBudgetSubKey()`,
  `insuranceFundSubKey()`, `protocolSubaccountsInitialized()`.
- `applyOptionFeeCharge(traderSubKey, token, amount)` — CAP_APPLY_FEE
  (bit 7) gated; debits trader available, credits protocol fee subKey.
- `applyOptionRebate(traderSubKey, token, amount)` — CAP_APPLY_REBATE
  (bit 8) gated; debits rebate budget subKey available, credits trader.
- Both primitives share the same defensive checks pattern as
  `applyOptionPremiumTransfer`. An unfunded rebate budget causes
  `applyOptionRebate` to revert `InsufficientAvailableCollateral`,
  atomically unwinding the whole trade.

### 3.3 Engine wiring (`OptionMatchingEngineV2`)

- `ExecutionScratch` gains `buyerRebate1e8` + `sellerRebate1e8`.
- `_quoteBothFees` → `_quoteFeesAndRebates` returns 4 amounts; rebate
  is no longer forbidden — only `fee > 0 AND rebate > 0` on the SAME
  side is rejected.
- `_requirePositiveFeeCapHonoured(order, fillQty, feeAmount)` computes
  the per-fill premium basis and enforces
  `feeAmount1e8 ≤ ceil(basis1e8 · maxPositiveFeePpm / 1_000_000)`. On
  breach, reverts `PositiveFeeRateExceedsSignedMaximum(feeAmount1e8,
  maxAllowed1e8, signedMaxPpm)`.
- `_applyFeesAndRebates(...)` calls Vault primitives with proper scaling:
  fees round UP (`_scale1e8ToNativeCeil`), rebates round DOWN
  (`_scale1e8ToNativeFloor`).
- Execution order: envelopes → sigs → compat → series → fee quote →
  cap enforce → lifecycle → ledger fills → premium transfer → fees +
  rebates → seller reservation → both isHealthy → emit.

### 3.4 Concrete adapter (`OptionExecutionFeeAdapterV2`, new)

- Immutable `FEES_MANAGER`, `VAULT`, `REGISTRY`, `QUOTE_DECIMALS`.
- `quoteExecutionFee` resolves trader owner via Registry, computes
  native premium basis (ceil), calls `FeesManagerV2.quoteFees` with
  `OPTION`/`ORDERBOOK`, validates response, converts native → 1e8
  (ceil for fee, floor for rebate).
- `try/catch` on `FeesManager` call → `ok = false` on revert.
- Rejects any product/settlementAsset/isMaker mismatch in the returned
  quote → `ok = false`.
- READ-ONLY. Never mutates FeesManager state; all rebate-budget
  bookkeeping lives on the Vault side.

## 4. Fail-closed contract

The engine ALWAYS requires a non-`address(0)` fee hook. If the hook
returns `ok = false`, or reverts, the match reverts. Any fee/rebate
that would silently short-charge or over-refund fails closed. No
permissive zero-fee fallback exists.

## 5. Test evidence

**Baseline:** 1246 tests / 0 failed / 645s across 80 suites (post-WP-09).
Previous baseline: 1234 tests. Delta: +12 new deterministic fee
integration tests. All prior invariants remain green (256 runs ×
128000 calls, 0 reverts).

### 5.1 New deterministic suite

`test/hybrid-v2/options/OptionFeesIntegrationV1.t.sol` (12 tests):

- **Fee-cap enforcement (Part E):**
  - `test_feeCap_belowCapAccepted_feeAccountedToProtocol`
  - `test_feeCap_aboveCapReverts`
  - `test_feeCap_zeroCapAllowsZeroFee`
  - `test_feeCap_zeroCapPositiveFeeReverts`
  - `test_feeCap_digestChangesWithCap`
- **Vault accounting conservation (Part M):**
  - `test_conservation_totalAccountedInvariantHolds`
  - `test_conservation_balanceSumMatchesInitial`
- **Reusable-order per-fill fee semantics (Part N):**
  - `test_perFillFee_gtcSequenceChargesEachDelta`
- **Rollback atomicity (Part Q):**
  - `test_rollback_feeCapExceededPreservesEverything`
- **Rebate accounting + budget (Part Q):**
  - `test_rebate_makerRebateCreditedFromBudget`
  - `test_rebate_insufficientBudgetReverts`
- **Adapter construction:**
  - `test_adapter_constructor_rejectsZeroDependencies`

### 5.2 Fee invariants coverage (FEE-I1..I16)

The pre-existing stateful invariant suite (`OptionMatchingEngineV2Invariant.t.sol`)
now runs the full fee-charging path with configured `CAP_APPLY_FEE` /
`CAP_APPLY_REBATE` capabilities and protocol subaccounts initialized.
Its 6 invariants (256 runs × ~128 000 calls each) — including
`totalAccounted`-preservation and reusable-order fill-monotonicity —
continue to hold, empirically covering FEE-I1 (`totalAccounted` invariant
holds under fees), FEE-I3 (rebate budget only decreases via approved
paths), FEE-I5 (protocol fee subKey monotonically non-decreasing under
positive fees), and FEE-I13 (per-fill fee ≤ signed cap).

## 6. Existing test files updated for supersession

- All existing option test files gained `maxPositiveFeePpm: 100_000,`
  in every `OptionOrder({...})` construction site (5 files: base,
  Execution, ERC1271, Invariant, Lifecycle closure).
- Base + invariant fixtures initialize protocol subaccounts and grant
  `CAP_APPLY_FEE` + `CAP_APPLY_REBATE` to the engine.
- `ICollateralVault` gains declarations for `applyOptionFeeCharge`,
  `applyOptionRebate`, `initializeProtocolSubaccounts`,
  `rebateBudgetSubKey`, `protocolSubaccountsInitialized`.
- `IOptionMatchingEngine` gains
  `error PositiveFeeRateExceedsSignedMaximum(uint128 feeAmount1e8, uint128 maxAllowed1e8, uint32 signedMaxPpm)`.
- Test-only mock `MockOptionExecutionFeeHook` gains a maker-rebate
  control (`setMakerRebate(bool enabled, uint128 rebate1e8)`) to exercise
  rebate paths independently of the positive-fee bps setter.

## 7. Verdicts

- `IOPTION_EXECUTION_FEE_HOOK_MANDATORY_BOUNDARY_HELD`
- `SIGNED_POSITIVE_FEE_PPM_CAP_IN_EIP712_TYPED_DATA`
- `OPTION_ORDER_EIP712_MATCH_V2_SUPERSESSION_HARD`
- `OLD_PRE_CAP_SIGNATURES_INVALID_UNDER_MATCH_V2`
- `PROTOCOL_FEE_AND_REBATE_SUBKEYS_GOV_ONE_SHOT_INITIALIZED`
- `CAP_APPLY_FEE_AND_CAP_APPLY_REBATE_ATOMIC_GATE_ENFORCED`
- `FEE_AND_REBATE_ROUNDING_PROTECTS_PROTOCOL`
- `EXECUTION_ROLLBACK_ATOMIC_ACROSS_LIFECYCLE_LEDGER_FEES_RESERVATIONS`
- `REUSABLE_ORDER_FEE_PER_FILL_DELTA_ENFORCED`
- `REBATE_BUDGET_INSUFFICIENCY_FAILS_CLOSED`
- `TOTAL_ACCOUNTED_INVARIANT_HOLDS_UNDER_FEES_AND_REBATES`
- `OPTION_EXECUTION_FEE_ADAPTER_V2_READ_ONLY_AND_FAIL_CLOSED`
- `PRIOR_LIFECYCLE_VALIDATION_CLOSURE_VERDICTS_PRESERVED`
- `ONCHAIN_SUBACCOUNT_FEES_MANAGER_V2_INTEGRATION_V1_COMPLETE`

## 8. Non-goals / out of scope

- Backend and frontend integration (`FeesManagerV2` client, fee-preview
  UI, tier-proof plumbing).
- Deployment scripts / on-chain broadcast.
- Governance UI for fee schedule authoring.
- Adapter-side rebate budget bookkeeping (Vault-side balance is
  canonical).
- `FeesManagerV2` `consumeFees` state-mutation path (unused by this
  hybrid-v2 wiring — the adapter is READ-ONLY).

## 9. Supersession note (prior lifecycle docs)

Nothing in this milestone invalidates the following. Their verdicts
remain load-bearing and still describe production source at the
respective commits. WP-09 layers concrete fee accounting on top:

- `ONCHAIN_SUBACCOUNT_OPTION_MATCHING_ENGINE_V2_V1.md`
- `ONCHAIN_SUBACCOUNT_OPTION_ORDER_LIFECYCLE_AND_NONCE_V2_PATCH.md`
- `ONCHAIN_SUBACCOUNT_OPTION_ORDER_LIFECYCLE_V2_VALIDATION_CLOSURE.md`

However — because the EIP-712 order-type identity is hard-superseded,
any tooling that reproduces the order digest MUST use the
`OPTION_ORDER_MATCH_V2` typehash and include `maxPositiveFeePpm` in
the encoded struct. Off-chain reproduction of `V1` digests is no longer
matchable on-chain.
