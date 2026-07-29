# `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1`

Status: `IMPLEMENTED_AND_VALIDATED_EXPERIMENTAL`
Product owner: Coriolan Morel
Authorization: `PRODUCT_OWNER_AUTHORIZES_WITH_NON_BLOCKING_CONDITIONS`
Work package: `WP-08B` — Signed Options matching and atomic execution engine
Date: 2026-07-29

> `EXPERIMENTAL — NOT SECURITY APPROVED`
> Base Sepolia only. No mainnet. No real user funds. No production
> claim. Human + external security review remains required at future gates.

## Milestone summary

Lands the concrete `OptionMatchingEngineV2` at `src/hybrid-v2/options/OptionMatchingEngineV2.sol`
— the first Hybrid V2 milestone permitted to atomically compose Registry
identity, EIP-712 signature envelopes, WP-05 replay protection, canonical
Options position mutation, cross-owner Vault-scoped premium accounting,
engine-owned margin reservation, and post-state MarginEngine health checks.

D.1 matching + order discovery remain OFF-CHAIN. D.2 (execution) is fully
on-chain and reconstructible from events with no backend dependency.

## Authoritative sources

- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_ARCHITECTURE_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_CONTRACT_SPEC_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_COLLATERAL_VAULT_V2_A.md` + `_B.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_OPTIONS_POSITIONS_LEDGER_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_REPLAY_AND_EPOCH_FOUNDATION_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_RISK_MODULE_V2_V1.md`
- `deopt-v2-sol/ONCHAIN_SUBACCOUNT_MARGIN_ENGINE_V2_V1.md`
- `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/06_RISK_MARGIN_MODULE_SPEC.md`
- `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/08_SIGNATURES_AND_REPLAY_SPEC.md`
- `~/DEOPT/docs/onchain-subaccounts-v1/contract-spec/11_FEES_AND_ACCOUNTING.md`

## Verdicts

- `ONCHAIN_SUBACCOUNT_OPTION_MATCHING_ENGINE_V2_V1_COMPLETE`
- `OPTION_ENGINE_ABI_AND_OWNERSHIP_RESOLVED`
- `OPTION_ORDER_TYPED_DATA_MODEL_RESOLVED`
- `EOA_AND_ERC1271_OPTION_SIGNATURES_VALIDATED`
- `OPTION_SIGNED_INTENT_IS_SINGLE_EXACT_FILL` (PF-2)
- Nonce/cancellation model: WP-05 sequential-per-signer-per-engine
  (inherited FROZEN); no live-order concurrency limit — the D.1 book has
  no on-chain concurrent-nonce coordination requirement under PF-2 because
  each nonce fires with exactly one on-chain execution.
- `OPTION_ENGINE_ABSTRACT_PENDING_FEES_INTEGRATION` (FEES-2) — mandatory
  fee-hook boundary, no zero-fee production default.
- `VAULT_OPTION_PREMIUM_TRANSFER_PRIMITIVE_IMPLEMENTED_NARROWLY` —
  `applyOptionPremiumTransfer(payerSubKey, receiverSubKey, token, amount)`
  added to `CollateralVaultV2` under new `CAP_APPLY_OPTIONS_PREMIUM =
  1 << 15` capability.
- `OPTION_PREMIUM_UNITS_AND_ROUNDING_RESOLVED`.
- `OPTION_MARGIN_RESERVATION_SERIES_SETTLEMENT_TOKEN`.
- `OPTION_MATCH_COMPATIBILITY_RULES_RESOLVED`.
- `OPTION_TIF_AND_POST_ONLY_SEMANTICS_VALIDATED`.
- `OPTION_EXECUTION_ATOMICITY_MODEL_RESOLVED`.
- `BOUNDED_OPTION_EXECUTION_INPUTS_VALIDATED`.
- `OPTION_EXECUTION_RECONSTRUCTIBLE_AND_DB_INDEPENDENT`.
- `NO_SETTLEMENT_LIQUIDATION_OR_PERPS_EXECUTION_IMPLEMENTED`.
- Next readiness: `READY_FOR_ONCHAIN_SUBACCOUNT_FEES_MANAGER_V2_INTEGRATION_V1`.

## Part D — Signed order model

Signed envelope: FROZEN `IntentHash.SignedActionEnvelope` from WP-05:
`(owner, subaccountId, subKey, signer, engine, action, architectureVersion,
nonce, deadline, ownerRecoveryEpoch, subaccountRecoveryEpoch, payloadHash)`.

Signed payload: new `OptionOrderTypes.OptionOrder` at
`src/hybrid-v2/options/OptionOrderTypes.sol`:
`(seriesId, side, quantity1e8, pricePerContract1e8, limitPricePerContract1e8,
premiumToken, timeInForce, role, salt)`.

`envelope.action = keccak256("OPTION_ORDER_MATCH_V1")`;
`envelope.payloadHash = keccak256(abi.encode(OPTION_ORDER_TYPEHASH,
<fields>))`. Encoding is `abi.encode` — never packed.

Deployment separation via chainId + verifyingContract + registry-scoped
subKey. `storageVersion`, `eventVersion`, `deploymentVersion` are NOT signed
per spec 08.

## Part E — Signer authorization

- V1: `envelope.signer` MUST equal `envelope.owner`. No session-key
  delegation.
- OpenZeppelin `SignatureChecker.isValidSignatureNow(owner, digest, sig)`:
  - EOA path: `ECDSA.tryRecover` under strict s-canonicalization.
  - ERC-1271 path: fallback to `IERC1271.isValidSignature(digest, sig)` on
    the owner contract.
- Any of the following fail closed: malformed signature; wrong signer/owner;
  wrong chain; wrong engine; wrong architecture version; stale owner epoch;
  stale subaccount epoch; expired deadline; zero subaccount id; unregistered
  subKey.

## Part F — Partial fills

Verdict: `OPTION_SIGNED_INTENT_IS_SINGLE_EXACT_FILL` (PF-2).

- Each signed intent (nonce) corresponds to EXACTLY one on-chain execution
  of the signed `quantity1e8`.
- No on-chain filled-quantity mapping. No cumulative order state.
- GTC "remaining" semantics live entirely in the D.1 book. The backend
  emits fresh signed intents for each matched partial fill.
- FOK is trivially satisfied by PF-2 (signed quantity == executed quantity).
- IOC differs from GTC only via `deadline` semantics + off-chain policy.

## Part G — Nonce + cancellation

- Nonces are sequential per-signer per-engine (FROZEN, WP-05).
- `cancelNextNonce()` advances by one; `cancelNoncesUpTo(nextValid)` bulk
  advances. Both are inherited via `ReplayAndEpochController`.
- Fully filled orders consume the nonce; cancelled orders equally advance
  the nonce.
- Failed executions produce ZERO nonce mutation (Solidity atomicity).

## Part H — Fee boundary

Verdict: `OPTION_ENGINE_ABSTRACT_PENDING_FEES_INTEGRATION` (FEES-2).

- The engine's constructor requires a non-zero `IOptionExecutionFeeHook`.
- Test-only zero-fee hooks acceptable in test suites.
- Production FeesManagerV2 adapter lands in the next milestone.
- V1 rebate MUST be zero — hook returning `rebateAmount1e8 > 0` fails
  execution closed.
- Fee hook's `ok = false` fails execution closed.
- No permissive zero-fee production default.

## Part I — Premium primitive

Verdict: `VAULT_OPTION_PREMIUM_TRANSFER_PRIMITIVE_IMPLEMENTED_NARROWLY`.

Added to `CollateralVaultV2` at
`src/hybrid-v2/vault/CollateralVaultV2.sol`:

```
function applyOptionPremiumTransfer(
    bytes32 payerSubKey,
    bytes32 receiverSubKey,
    address token,
    uint256 amount
) external
```

- Capability-gated by new `CAP_APPLY_OPTIONS_PREMIUM = 1 << 15` (bumped
  `HIGHEST_ASSIGNED_BIT` from 14 to 15).
- Rejects: zero amount, either subKey zero, unregistered subKey, self-transfer,
  unknown collateral token, insufficient payer AVAILABLE balance, corrupted
  lock.
- Effect: buyer's accounted balance decreases; seller's increases;
  `_totalAccounted[token]` UNCHANGED. No ERC-20 movement.
- Isolation: payer's own reservations untouched; no other engine's
  reservations touched; positions untouched.
- Reconstructible via `OptionPremiumTransferred(payer, receiver, token,
  amount, engine, eventVersion)`.

## Part J — Premium accounting

- Signed price per contract in 1e8 quote-token units.
- Both counterparties sign SAME `pricePerContract1e8` — no per-side
  execution derivation.
- Buyer's `limitPricePerContract1e8` = MAX (buyer rejects execution price
  above this).
- Seller's `limitPricePerContract1e8` = MIN (seller rejects execution price
  below this).
- Total premium in 1e8: `qty1e8 * price / 1e8`.
- Native (6-dec USDC): `totalPremium1e8 / 10^(8-6) = totalPremium1e8 / 100`,
  rounded UP against the buyer.

## Part K — Reservation policy

Verdict: `OPTION_MARGIN_RESERVATION_SERIES_SETTLEMENT_TOKEN`.

- Reservations are held in the series' `settlementAsset` = frozen
  `QUOTE_TOKEN`.
- Target reservation = seller's IM (from MarginEngine's witness view) in
  1e18 quote units, scaled to native token units by
  `10^(18-quoteDecimals)`, rounded UP against the seller.
- Long positions contribute 0 to portfolio margin in V1 → buyer's target
  reservation is 0.
- Reservation delta:
  - `target > current` → `applyLock(deltaUp)`.
  - `target < current` → `applyUnlock(deltaDown)`.
  - `target == current` → no-op.
- Only the engine's OWN reservation slot is touched (Vault's
  `applyUnlock` isolation invariant).

## Part L — Implementation form

Concrete engine at `src/hybrid-v2/options/OptionMatchingEngineV2.sol`:

- Inherits `IOptionMatchingEngine`, `ReplayAndEpochController`,
  `ReentrancyGuard`.
- Constructor: `(vault, marginEngine, feeHook, guardian, governance,
  engineVersion)`. Every reference validated non-zero.
- RM-1 posture: `RISK_MODULE` is INLINE-read from the vault's
  `RISK_MODULE()` at construction (not via `VaultRiskModuleConsumer`
  because that abstract collides with `ReplayAndEpochController` on
  `ARCHITECTURE_VERSION` immutable).
- Dependency cross-checks: MarginEngine's Vault == our Vault; MarginEngine's
  RiskModule == the Vault's RiskModule; MarginEngine's Ledger + Provider
  non-zero.
- Guardian: pause-only. Governance: unpause-only. Neither can fabricate a
  trade.

## Part M — Dependency consistency

Constructor rejects:
- Zero vault (via base check).
- Zero MarginEngine, fee hook, guardian, governance, engine version.
- MarginEngine binding mismatch (`DependencyMismatch`).
- Vault's RISK_MODULE zero.

## Part N — Match compatibility

- Buyer side = `SIDE_LONG`, seller side = `SIDE_SHORT`. Same-side → revert.
- Same series id, same premium token.
- Same signed `pricePerContract1e8` and `quantity1e8`.
- Buyer's `subKey` != seller's `subKey` (`SelfTrade` reverted). Sibling-
  subaccount (same owner, distinct id) not explicitly tested at the engine
  layer — both subKeys resolve to distinct values so trades succeed unless
  their MarginEngine `isHealthy` check fails; V1 policy discourages via
  D.1 book construction.
- Roles: exactly one MAKER + one TAKER. Both maker or both taker → revert.
- Post-only: signed `TIF_POST_ONLY` MUST equal `role = ROLE_MAKER`.

## Part O — TIF + post-only

- `TIF_GTC`, `TIF_IOC`, `TIF_FOK`, `TIF_POST_ONLY` are FROZEN signed
  metadata.
- Under PF-2, GTC vs IOC vs FOK differ only in the OFF-CHAIN book's willingness
  to re-emit intents (deadline is the on-chain enforcement).
- Post-only is CRYPTOGRAPHICALLY bound via the signed `role` field:
  a POST_ONLY-signed order that arrives with `role != ROLE_MAKER` is
  rejected pre-consumption, so no relabel-attack is possible.

## Part P — Atomic execution

Order inside `executeMatch`:

1. `nonReentrant`.
2. `!executionPaused`.
3. Envelope binding + payload-hash validation.
4. Deadline + epoch freshness.
5. Signature verification (EOA + ERC-1271).
6. Match compatibility.
7. Series metadata validation (active, not expired, correct
   contractSize/quote/strike).
8. Fee hook quote (both sides).
9. Nonce + intent consumption (both sides).
10. Ledger `applyFill` (buyer long, seller short).
11. `Vault.applyOptionPremiumTransfer(buyer, seller, token, amount)`.
12. Seller reservation delta via `applyLock`/`applyUnlock`.
13. MarginEngine `isHealthy` post-state check (both sides).
14. Emit `OptionOrderPairExecuted`.

Any failure at any step reverts EVERYTHING atomically. Failed executions
produce zero mutation of positions, balances, reservations, nonces,
intent-consumed set, or events.

## Part T — Events

`OptionOrderPairExecuted(executionId, buyerOrderHash, sellerOrderHash,
seriesId, buyerSubKey, sellerSubKey, buyerOwner, sellerOwner,
buyerSubaccountId, sellerSubaccountId, filledQuantity1e8,
pricePerContract1e8, totalPremium, premiumToken, buyerRole, sellerRole,
buyerFee, sellerFee, actor, eventVersion)`.

Plus inherited from WP-05: `IntentConsumed`.
Plus new on Vault: `OptionPremiumTransferred`.
Plus inherited ledger events: `OptionPositionOpened` / `OptionPositionModified`.

## Tests + invariants

Suites shipped:

- `test/hybrid-v2/options/OptionMatchingEngineV2.t.sol` — 8 constructor tests.
- `test/hybrid-v2/options/OptionMatchingEngineV2Execution.t.sol` — 23 execution
  tests (happy-path EOA/EOA, order compatibility, signature, deadline,
  replay, cancellation, series, post-state margin, rollback atomicity,
  fee hook, pause, isolation).
- `test/hybrid-v2/options/OptionMatchingEngineV2ERC1271.t.sol` — 2 ERC-1271
  tests.
- `test/hybrid-v2/options/OptionMatchingEngineV2Reconstruction.t.sol` — 4
  reconstruction/DB-loss tests.
- `test/hybrid-v2/options/OptionMatchingEngineV2Invariant.t.sol` — 9
  invariants at 256×500: `OPTION-EXEC-I1/I2/I8/I9/I11/I14/I16/I17/I18`.

## Storage review

Engine state:
- Immutables: VAULT, RISK_MODULE, OPTIONS_LEDGER, MARGIN_ENGINE,
  RISK_PROVIDER, QUOTE_TOKEN, QUOTE_DECIMALS, FEE_HOOK, GUARDIAN,
  GOVERNANCE, ENGINE_VERSION, EIP-712 domain constants.
- Mutable: `executionPaused` bool (guardian pause).
- Inherited from `ReplayAndEpochController`: `_nextNonceOfSigner`,
  `_consumedIntent`, `_ownerRecoveryEpoch`, `_subaccountRecoveryEpoch`.

NO cached balances, NO copied positions, NO cached margin, NO cached
series metadata, NO cached collateral list, NO on-chain order book, NO
signature storage, NO backend-matching state, NO reset functions, NO
governance clear.

## Gas / DoS

- Every loop bounded by 32 (series) or 8 (tokens) — inherited from
  MarginEngine + Vault.
- No unbounded caller-supplied arrays.
- One matched pair per external call.
- Fee hook is an `external view` — one call per side, bounded gas.
- Signature verification is O(1) (EOA) or bounded by ERC-1271 wallet
  implementation (a caller-controlled wallet can grief with its own gas
  budget only).

Development gas (approximate):
- Full happy-path EOA/EOA: ~770 k.
- ERC-1271: comparable + wallet-owned overhead.
- Rejection paths: 250-350 k depending on validation site.
- Rollback atomicity: no gas cost beyond the aborted state (checked by
  the atomicity test).

## Non-goals reconfirmed

- No on-chain order book / global order iteration.
- No RFQ / multi-leg execution.
- No settlement / exercise / liquidation execution.
- No signature or replay mutation outside D.2.
- No perps.
- No unrestricted Vault debit/credit — the premium primitive is narrowly
  scoped.
- No zero-fee production default.
- No backend-matching state anywhere.
- No Base mainnet reference.
