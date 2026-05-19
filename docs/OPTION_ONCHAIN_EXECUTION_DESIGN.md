# Option On-chain Execution Design V1A/V1B/V1C

## Scope

This document defines the first production-oriented design for mapping DeOpt backend
option orderbook and RFQ fills into on-chain option positions. It also records the
V1B Solidity execution ingress and V1C deployment wiring added after the V1A
design pass.

Primary goal: make option fills deterministic, auditable, and reconcilable on
chain while preserving the existing option state machine in `MarginEngine`,
`OptionProductRegistry`, `RiskModule`, `CollateralVault`, and `FeesManager`.

Non-goals for V1A:

- no American exercise
- no physical delivery
- no fractional on-chain option contract quantity unless a later contract change
  explicitly supports it
- no generalized multi-product execution router
- no economic changes to option margin, settlement, liquidation, or fee math

V1B Solidity status:

- `src/matching/OptionMatchingEngine.sol` adds a dedicated option execution
  ingress.
- `MarginEngine.applyTrade` remains the canonical accounting entrypoint and is
  unchanged.
- V1B validates dual EIP-712 signatures, sequential per-address nonces, executor
  allowlisting, and signed option-series metadata before forwarding.
- V1C deployment wiring makes `OptionMatchingEngine` deployable through
  `script/DeployOptionMatchingEngine.s.sol`, optionally selectable by
  `WireCore.s.sol`, and verifiable through `VerifyDeployment.s.sol`.
- Backend option execution intents, calldata construction, broadcast, indexing,
  reconciliation, and confirmation are deferred to the V1D/backend phase.

## Current Solidity Option State

### OptionProductRegistry

`OptionProductRegistry` is the option instrument source of truth.

Observed behavior:

- Each option series is represented by `OptionSeries`.
- Series fields are:
  - `underlying`
  - `settlementAsset`
  - `expiry`
  - `strike`
  - `contractSize1e8`
  - `isCall`
  - `isEuropean`
  - `exists`
  - `isActive`
- `strike` and settlement prices are normalized to `1e8`.
- `contractSize1e8` is hard-locked to `1e8`.
- A settlement asset must be explicitly allowed before series creation.
- Underlyings have `UnderlyingConfig` and `OptionRiskConfig`.
- Settlement is European-style and explicit:
  - a settlement price can be proposed or finalized after expiry
  - `settlementFinalityDelay == 0` finalizes immediately
  - settlement prices are stored in `1e8`

There is no separate deployed option product id. On-chain execution uses
`optionId`, the deterministic `uint256` series id.

### MatchingEngine

`MatchingEngine` is the legacy option-side on-chain ingress contract.

Observed behavior:

- It verifies EIP-712 `MatchedTrade` signatures from both buyer and seller.
- It has an executor allowlist.
- It uses sequential per-trader nonces.
- Traders can cancel the next nonce or cancel nonces up to a target nonce.
- It forwards successful trades to `MarginEngine.applyTrade`.
- It emits `TradeSubmitted`.

Current `MatchedTrade` fields:

```solidity
struct MatchedTrade {
    address buyer;
    address seller;
    uint256 optionId;
    uint128 quantity;
    uint128 price;
    bool buyerIsMaker;
    uint256 buyerNonce;
    uint256 sellerNonce;
    uint256 deadline;
}
```

Important limits:

- There is no `intentId`, `fillId`, `rfqId`, or `quoteId` in the signed payload
  or execution event.
- The signature binds `optionId`, not expanded series terms.
- It supports a dual-signature matched-trade model, not the backend's current
  maker-signed option RFQ quote model by itself.
- Existing Solidity tests cover option execution mostly by directly calling
  `MarginEngine.applyTrade` from a mocked matching engine address. There is no
  dedicated option `MatchingEngine.executeTrade` unit suite comparable to the
  perp matching engine suite.

### OptionMatchingEngine

`OptionMatchingEngine` is the V1B dedicated option execution ingress.

Observed behavior:

- It verifies EIP-712 `OptionTrade` signatures from both buyer and seller.
- It includes `intentId` in the signed payload and execution event.
- It has an executor allowlist controlled by the owner.
- It uses sequential per-trader nonces and trader-driven nonce cancellation.
- It validates signed option metadata against `OptionProductRegistry`:
  - `underlying`
  - `settlementAsset`
  - `expiry`
  - `strike1e8`
  - `isCall`
  - `contractSize1e8`
- It rejects unknown and inactive series before forwarding.
- It forwards `buyer`, `seller`, `optionId`, raw whole-contract `quantity`,
  settlement-native `premiumPerContract`, and `buyerIsMaker` to
  `MarginEngine.applyTrade`.
- It emits `OptionTradeExecuted` with `intentId` for backend/indexer
  reconciliation.

Backend integration remains deferred to V1D. Until then, Solidity support exists
and deployment wiring exists, but production orderflow still needs backend
option execution intents, calldata building, broadcast, indexing,
reconciliation, and confirmation.

V1C deployment wiring status:

- `OptionMatchingEngine` is deployed by the isolated
  `DeployOptionMatchingEngine.s.sol` script after `DeployCore`.
- `DeployCore` remains unchanged to preserve the existing core deployment shape
  and avoid silently changing option ingress.
- Setting `OPTION_MATCHING_ENGINE_ADDR` before `WireCore` makes
  `MarginEngine.matchingEngine` point to `OptionMatchingEngine`.
- Leaving `OPTION_MATCHING_ENGINE_ADDR` zero or unset keeps legacy
  `MatchingEngine` as the authorized option ingress.
- `TransferOwnerships` can configure `OPTION_MATCHING_EXECUTORS` /
  `OPTION_MATCHING_EXECUTOR_ALLOWED` and includes optional ownership handoff.
- `VerifyDeployment` checks `OptionMatchingEngine` bytecode, owner when
  `OPTION_MATCHING_ENGINE_OWNER` is set, margin engine pointer, registry
  pointer, configured executor allowlist, and `MarginEngine` authorization
  alignment.

Production implication: `MarginEngine` has a single `matchingEngine` slot. If
`OptionMatchingEngine` is enabled as production option ingress, the legacy
`MatchingEngine` may remain deployed but cannot call `MarginEngine.applyTrade`
unless governance later switches the slot back.

### MarginEngine

`MarginEngine.applyTrade` is the canonical option position transition.

Observed behavior:

- Only the configured `matchingEngine` may call `applyTrade`.
- It rejects zero addresses, self-trade, zero quantity, and zero price.
- It requires `RiskModule` and synced base risk parameters.
- It loads the option series from `OptionProductRegistry`.
- It rejects expired series.
- It requires the settlement asset to be configured in `CollateralVault`.
- It applies position deltas:
  - buyer quantity increases by `quantity`
  - seller quantity decreases by `quantity`
- It keeps open-series indexes and short exposure aggregates synchronized.
- It enforces per-series short open-interest caps when configured.
- It enforces active, restricted, inactive, and emergency close-only states.
- It transfers premium from buyer to seller through `CollateralVault`.
- If `feesManager` is configured, it charges maker/taker fees to the configured
  fee recipient or insurance fund fallback.
- It emits `TradeExecuted`.
- It enforces post-trade initial margin on buyer and seller.

Critical unit convention:

- `quantity` is a raw number of option contracts.
- `price` is premium per contract in settlement-asset native units.
- `premium = quantity * price`.
- Risk values from `RiskModule` are base-collateral native units.

### RiskModule

`RiskModule` is the option-side risk source of truth.

Observed behavior:

- It values collateral through `CollateralVault` balances and oracle prices.
- It applies collateral weights conservatively.
- It computes account risk in base collateral native units.
- Short options contribute:
  - current intrinsic liability
  - stressed per-contract maintenance margin
  - base maintenance margin floor
  - initial margin via `imFactorBps`
- Long options are not credited as positive option equity in current risk views.
- It can aggregate optional perp risk for unified account views.

Call and put short margin are both cash-settled cross-margin requirements, not
physical collateral locks. Calls stress spot up; puts stress spot down.

### CollateralVault

`CollateralVault` is the shared internal balance layer.

Observed behavior:

- User balances are token-native.
- Deposits and withdrawals are explicit token transfers.
- Authorized engines can call `transferBetweenAccounts`.
- Internal transfers sync yield-aware balances where possible.
- Launch collateral restriction and token deposit caps are available.
- `MarginEngine`, `PerpEngine`, and future engines can be authorized.

Option premium, fee, liquidation, and settlement cashflows all route through
vault internal transfers.

### FeesManager

`FeesManager` quotes hybrid maker/taker fees.

Observed behavior:

- It computes:
  - notional fee
  - premium cap fee
  - applied fee
  - cap status
- It does not move funds.
- `MarginEngine` moves funds when `feesManager` is configured.
- Fee rates can come from defaults, claimed tiers, or admin overrides.

This means on-chain option fees already exist at the engine layer, but V1 option
backend execution should choose one fee source of truth to avoid double charging.

### Settlement and Liquidation

Observed option settlement behavior:

- Settlement is available only after expiry and a finalized settlement price.
- Settlement is per account and per series.
- Settlement is single-use through `isAccountSettled`.
- Payoff is cash-settled in the settlement asset.
- Positions are cleared before settlement cashflows.
- Short collections, long payouts, insurance coverage, and residual bad debt are
  explicitly recorded.

Observed liquidation behavior:

- Only unsafe accounts with short option exposure are liquidatable.
- Liquidation is bounded by close factor.
- Liquidation price uses current intrinsic value, optional intrinsic floor, and
  spread.
- Liquidation must improve account state or revert.
- Liquidator receives option position transfer and explicit cash/penalty flows.

## Current Backend Option State

The sibling backend currently has option services, persistence, RFQ, fee ledger,
and perp-specific on-chain execution infrastructure.

Observed option backend state:

- `option_series` stores backend option series with:
  - underlying/base/quote/settlement assets
  - expiry
  - `strike_1e8`
  - `is_call`
  - `contract_size_1e8`
  - status/source
  - optional `onchain_product_id`
  - optional `onchain_series_id`
- `option_orders` stores option orderbook orders with:
  - `price_1e8`
  - `size_1e8`
  - optional nonce/deadline/signature
- `option_fills` stores matched orderbook fills off-chain.
- `option_rfqs`, `option_rfq_quotes`, and `option_rfq_fills` store option RFQ
  requests, quotes, and accepted fills.
- Signed option RFQ quotes use EIP-712:

```text
OptionRFQQuote(
    bytes32 optionRfqId,
    address mmAccount,
    bytes32 optionSeriesId,
    bool takerIsBuyer,
    uint128 price1e8,
    uint128 size1e8,
    uint256 quoteNonce,
    uint256 expiry
)
```

- Option RFQ signature mode can be disabled or strict.
- Strict mode verifies the recovered signer matches `mm_account`.
- Accepting an option RFQ quote creates an off-chain option RFQ fill and records
  fee ledger rows.
- Option orderbook fills and option RFQ fills feed the backend fee ledger and
  rebate accrual model.

Missing backend pieces for on-chain option execution:

- no option execution intent table
- no option calldata builder
- no option on-chain signature bundle model
- no option nonce sync against `OptionMatchingEngine.nonces`
- no option dry-run/simulation target
- no option broadcast target
- no option event decoder/indexer/reconciliation path
- no option settlement automation path

The existing execution pipeline is perp-specific. It builds calldata for
`PerpMatchingEngine`, indexes perp `TradeExecuted` events, reconciles by
`onchain_intent_id`, and confirms submitted perp execution transactions.

## Target Option Execution Lifecycle

The target lifecycle is:

1. Backend creates or syncs option series.
2. Backend accepts an option orderbook fill or option RFQ fill.
3. Backend creates an option execution intent.
4. Backend normalizes units:
   - backend `size_1e8` -> on-chain raw `quantity`
   - backend `price_1e8` -> settlement-native premium per contract
5. Backend collects required signatures.
6. Backend simulates the exact on-chain call.
7. Authorized executor submits the transaction.
8. Matching ingress verifies signatures, nonces, deadline, and executor.
9. Matching ingress calls `MarginEngine.applyTrade`.
10. `MarginEngine` updates buyer/seller positions.
11. `MarginEngine` transfers premium and, when enabled, on-chain fees.
12. `MarginEngine` enforces buyer and seller initial margin.
13. Indexer consumes execution events.
14. Backend reconciles indexed event to the option execution intent.
15. Confirmation marks the intent final only after receipt, indexed event, and
    reconciliation requirements pass.
16. At expiry, settlement price is proposed/finalized.
17. Accounts are settled through `MarginEngine.settleAccount` or
    `settleAccounts`.
18. Backend indexes settlement, payoff, insurance, and bad-debt events.

## Execution Model Options

### Approach A: Reuse Existing MatchingEngine and MarginEngine Trade Path

Description:

- Backend converts option fills into current `MatchingEngine.MatchedTrade`.
- Backend obtains buyer and seller signatures over current `MatchedTrade`.
- Executor calls `MatchingEngine.executeTrade`.
- `MatchingEngine` forwards to `MarginEngine.applyTrade`.

Pros:

- Smallest Solidity change if no event/payload changes are required.
- Reuses current nonce, executor, pause, signature, and forwarding logic.
- Reuses the full existing `MarginEngine` accounting path.
- Avoids touching position, margin, premium, settlement, or liquidation logic.

Cons:

- No `intentId` in signed data or events, making deterministic reconciliation
  weak for repeated same-terms fills.
- Current backend option RFQ has only maker quote signatures; taker acceptance is
  not an on-chain signature.
- Current backend order signatures are optional and not the same typed data as
  `MatchedTrade`.
- Backend `size_1e8` and `price_1e8` do not match current on-chain
  `quantity` and settlement-native `price`.
- The signed payload does not bind expanded series terms.
- Adding production-grade indexing and confirmation around this path would need
  off-chain heuristics or a separate intent id convention.

Use only as a compatibility or early dry-run path.

### Approach B: Dedicated OptionMatchingEngine / OptionExecutionIntent Path

Description:

- Add a minimal option execution ingress contract in a later phase.
- Keep `MarginEngine.applyTrade` unchanged.
- New ingress verifies an `OptionTrade` typed payload with an explicit
  `intentId`.
- New ingress emits an intent-addressed execution event.
- Backend adds option execution intents and extends simulation, broadcast,
  indexing, reconciliation, and confirmation for options.

Pros:

- Preserves `MarginEngine` as the accounting source of truth.
- Gives every fill a deterministic `intentId` for signing, events, indexing,
  reconciliation, and confirmation.
- Allows one canonical option typed-data shape for orderbook and RFQ fills.
- Allows backend RFQ quote ids and order fill ids to map to an execution intent
  without putting backend-only semantics into `MarginEngine`.
- Makes unit conversion explicit before signing and before calldata build.
- Can be audited independently from settlement and liquidation.

Cons:

- Requires a new Solidity contract or a breaking upgrade to `MatchingEngine`.
- Duplicates some option/perp matching engine concepts.
- Requires backend schema and pipeline work.
- Requires deployment wiring and monitoring updates.

Recommended for V1B.

### Approach C: RFQ-specific Option Settlement Path

Description:

- Add an RFQ-specific on-chain path that accepts a maker signed RFQ quote and a
  taker acceptance.
- On-chain execution derives buyer/seller from the RFQ side.
- Orderbook fills continue off-chain or use another path.

Pros:

- Closely matches current backend option RFQ objects.
- Can use the existing signed option RFQ quote payload as an input.
- Smaller for RFQ-only launch if orderbook execution is explicitly deferred.

Cons:

- Does not solve orderbook option fills.
- Splits option execution into multiple paths.
- Duplicates buyer/seller, premium, nonce, and deadline semantics.
- Increases audit burden around RFQ/orderbook parity.
- Current signed RFQ quote omits taker acceptance, on-chain option id as
  `uint256`, and settlement-native premium.

Defer unless the launch intentionally excludes orderbook option execution.

## Recommendation

Use Approach B for V1B: add a minimal `OptionMatchingEngine` dedicated to option
execution intents, while continuing to call the existing
`MarginEngine.applyTrade` unchanged.

Rationale:

- The existing `MarginEngine` trade path is already the right accounting path.
- Production execution needs an explicit on-chain intent id for deterministic
  indexing and reconciliation.
- Backend orderbook fills and RFQ fills should converge into one execution
  intent model.
- The current RFQ signed quote is useful input, but it is not sufficient as the
  final on-chain fill authorization.
- Avoiding a generalized execution router keeps V1 audit scope bounded.

Compatibility rule:

- Existing `MatchingEngine` can remain deployed for compatibility or controlled
  tests.
- New production option execution should use the intent-addressed option ingress
  once implemented and wired.

## Required Data Model

### Backend OptionExecutionIntent

Recommended backend fields:

```text
option_execution_intent_id UUID primary key
onchain_intent_id bytes32 hex
source_type enum: option_orderbook_fill | option_rfq_fill
source_id string
option_series_id bytes32 hex
onchain_option_id uint256 string
buyer address
seller address
underlying address
settlement_asset address
expiry uint64
strike_1e8 uint64
is_call bool
contract_size_1e8 uint128
quantity_contracts uint128
source_size_1e8 uint128
source_price_1e8 uint128
premium_per_contract_native uint128
buyer_is_maker bool
buyer_nonce uint256
seller_nonce uint256
deadline uint256
buyer_signature nullable bytes
seller_signature nullable bytes
rfq_id nullable bytes32
quote_id nullable bytes32
maker_order_id nullable string
taker_order_id nullable string
fee_mode enum: backend_ledger | onchain
status enum:
  pending
  signatures_ready
  calldata_ready
  simulation_ok
  simulation_failed
  submitted
  reconciled
  confirmed
  failed
created_at_ms
updated_at_ms
```

Backend id rules:

- `onchain_option_id` must be the registry `optionId`.
- `option_series_id` should be the 32-byte hex representation of the same
  value, unless a future backend id migration intentionally separates them.
- `onchain_intent_id` should be `keccak256(option_execution_intent_id)` or an
  equivalent deterministic bytes32 mapping.

### Solidity OptionTrade

Recommended V1B on-chain typed struct:

```solidity
struct OptionTrade {
    bytes32 intentId;
    address buyer;
    address seller;
    uint256 optionId;
    address underlying;
    address settlementAsset;
    uint64 expiry;
    uint64 strike1e8;
    bool isCall;
    uint128 contractSize1e8;
    uint128 quantity;
    uint128 premiumPerContract;
    bool buyerIsMaker;
    uint256 buyerNonce;
    uint256 sellerNonce;
    uint256 deadline;
}
```

Field conventions:

- `intentId`: backend-onchain correlation id; must be nonzero.
- `optionId`: `OptionProductRegistry` series id.
- `underlying`, `settlementAsset`, `expiry`, `strike1e8`, `isCall`, and
  `contractSize1e8`: redundant safety fields that the ingress validates against
  registry state before forwarding.
- `quantity`: raw whole option contracts for V1B.
- `premiumPerContract`: settlement-asset native units per contract.
- `buyerIsMaker`: maker/taker fee attribution.
- `buyerNonce` and `sellerNonce`: sequential on-chain nonces.
- `deadline`: unix seconds. `0` may mean no deadline only if explicitly kept
  from current `MatchingEngine`; production orderflow should use finite
  deadlines.

### Unit Conversion Rules

Current backend option fills use `size_1e8` and `price_1e8`.

Current Solidity option trade execution uses raw `quantity` and
settlement-native premium per contract.

V1B conversion:

```text
require(size_1e8 % 1e8 == 0)
quantity = size_1e8 / 1e8
premium_per_contract_native =
    floor(price_1e8 * 10 ** settlement_asset_decimals / 1e8)
```

V1B should reject fills where:

- `quantity == 0`
- `premium_per_contract_native == 0`
- `size_1e8` is not an exact whole-contract multiple
- settlement asset decimals are unavailable or unsupported

Fractional on-chain option quantities are deferred. Supporting them safely would
require a contract-level quantity scaling change and a full storage/economics
review.

## EIP-712 Signing Model

Recommended domain:

```text
name:    DeOptV2-OptionMatchingEngine
version: 1
chainId: current chain id
verifyingContract: OptionMatchingEngine address
```

Recommended type:

```text
OptionTrade(
    bytes32 intentId,
    address buyer,
    address seller,
    uint256 optionId,
    address underlying,
    address settlementAsset,
    uint64 expiry,
    uint64 strike1e8,
    bool isCall,
    uint128 contractSize1e8,
    uint128 quantity,
    uint128 premiumPerContract,
    bool buyerIsMaker,
    uint256 buyerNonce,
    uint256 sellerNonce,
    uint256 deadline
)
```

Signature requirements:

- Orderbook fills: buyer and seller both sign the final `OptionTrade`.
- RFQ fills: the market maker quote signature can remain a backend admission
  control, but final on-chain execution should still require both buyer and
  seller signatures over `OptionTrade`.
- If RFQ taker signing is deferred, executor trust increases materially and the
  flow should remain testnet-only or explicitly permissioned.

Nonce model:

- Use sequential per-address nonces in the option ingress contract.
- Consume buyer and seller nonces atomically before forwarding, with full revert
  rollback if `MarginEngine.applyTrade` reverts.
- Keep `cancelNextNonce` and `cancelNoncesUpTo`.
- Backend must read/sync on-chain nonces before preparing signatures.
- Backend must not reserve a nonce for two live intents for the same trader.

Replay protection:

- EIP-712 domain binds chain id and verifying contract.
- `intentId` binds the backend fill to the signed payload.
- `optionId` and expanded series terms bind the instrument.
- Sequential nonces prevent reuse.
- Deadline bounds stale signatures.

Signature malleability:

- Use OpenZeppelin `ECDSA.tryRecover` or equivalent low-s enforcement.
- Reject malformed signature length and unsupported `v`.
- Future ERC-1271 support should be explicit and separately tested.

## Margin and Collateral Model

### Buyer Requirements

The buyer pays premium and any buyer-side fee from vault balance.

Buyer checks:

- buyer address nonzero
- buyer is not seller
- buyer signature valid
- buyer nonce current
- buyer has enough settlement-asset balance for premium and fees
- post-trade account risk satisfies initial margin

Current risk model does not credit long option mark value as positive equity, so
the buyer's main immediate risk impact is cash outflow for premium and fees.

### Seller Requirements

The seller receives premium, then takes short option exposure.

Seller checks:

- seller address nonzero
- seller signature valid
- seller nonce current
- seller has enough balance for seller-side fee when on-chain fees are enabled
- post-trade account risk satisfies initial margin
- series short open-interest cap is not exceeded

Seller short margin is computed by `RiskModule` in base collateral native units.

### Call Collateral

Calls are cash-settled. V1 does not require the seller to escrow underlying.

Short call margin is based on the max of:

- current intrinsic liability
- stressed spot-up liability
- base maintenance margin floor
- conservative oracle-down fallback when needed

Collateral remains in `CollateralVault` and can include supported, enabled
tokens with configured weights.

### Put Collateral

Puts are cash-settled. V1 does not require isolated full strike collateral.

Short put margin is based on the max of:

- current intrinsic liability
- stressed spot-down liability
- base maintenance margin floor
- conservative oracle-down fallback when needed

Settlement asset and base collateral are expected to be USDC at launch unless a
controlled protocol-wide migration changes that assumption.

### Cross-margin Implications

Option execution uses shared vault collateral and unified risk views.

Implications:

- Existing perps exposure can affect option trade acceptance.
- Existing option shorts can affect perps and withdrawability through the shared
  risk surface.
- Non-base collateral contributes only after conservative haircut and successful
  valuation.
- Disabled or launch-inactive collateral must not improve adjusted collateral.

### Failure Cases

Execution must revert or fail before confirmation on:

- invalid or unknown `optionId`
- mismatched signed series fields
- inactive, restricted, close-only, or expired series when the transition is not
  allowed
- unsupported settlement asset
- zero quantity or premium
- non-whole-contract backend size in V1B
- insufficient premium or fee balance
- margin breach after trade
- stale or unavailable risk oracle where the risk path requires it
- short OI cap breach
- invalid signatures
- bad nonces
- deadline expiry
- self-trade

## Premium and Cashflow Model

Trade premium:

```text
premium_native = quantity * premium_per_contract_native
```

Current on-chain cashflow:

- `CollateralVault.transferBetweenAccounts(settlementAsset, buyer, seller,
  premium_native)`
- optional fee transfer from buyer to fee recipient
- optional fee transfer from seller to fee recipient
- post-trade margin enforcement on both accounts

Atomicity:

- If any transfer, fee charge, or margin check fails, the full transaction
  reverts.
- Reverted execution must leave backend intent unconfirmed.

Backend reconciliation:

- Backend must record both source normalized values and on-chain native values.
- Indexer should reconcile event premium fields against intent-native fields,
  not recompute from `price_1e8` with different rounding.

Rounding rule:

- V1B should use floor conversion from `price_1e8` to native premium per
  contract.
- Backend should reject any fill where floor conversion would produce zero.
- Future support for alternate rounding must be explicit because it changes
  buyer/seller cashflow.

## Fees Model

### V1 Path: Backend Ledger-only

Recommended first integration mode:

- Keep option fee source of truth in the backend fee ledger.
- Do not add fee fields to the V1B `OptionTrade`.
- Do not require on-chain fee collection for option execution intents.
- Ensure deployment/configuration cannot double charge:
  - either `MarginEngine.feesManager` is unset for the option execution launch,
  - or option fee bps are effectively zero,
  - or backend marks on-chain fees as enabled and disables duplicate ledger
    accrual for the same fills.

Reason:

- The backend already records option orderbook and RFQ fee events and rebate
  accruals.
- First option on-chain execution should prove position/cashflow/indexing
  correctness before adding fee settlement complexity.

### V2 Path: On-chain FeesManager

V2 can enable on-chain option fee collection through existing `FeesManager`
integration.

Required V2 decisions:

- fee recipient: treasury, insurance fund, or explicit fee recipient
- rebate accounting source of truth
- whether backend ledger records gross fees, on-chain collected fees, or
  accounting-only mirror rows
- how to prevent fee drift between backend fee schedule and `FeesManager`
- whether orderbook/RFQ product fee tiers should map to one on-chain profile

V2 invariants:

- Fee transfers must be explicit settlement-asset-native amounts.
- Fee caps must remain bounded by configured BPS caps.
- Maker/taker attribution must match `buyerIsMaker`.
- Backend must not accrue duplicate protocol revenue for a fee already collected
  on chain.

## Settlement and Exercise Model

V1 options are European cash-settled options.

There is no separate early exercise flow. "Exercise" means account settlement
after expiry using the finalized settlement price.

Payoff per contract:

```text
call intrinsic_1e8 = max(settlementPrice1e8 - strike1e8, 0)
put intrinsic_1e8  = max(strike1e8 - settlementPrice1e8, 0)
payoff_native      = floor(intrinsic_1e8 * 10 ** settlement_decimals / 1e8)
```

Account settlement:

- Long quantity receives `abs(quantity) * payoff_native`.
- Short quantity owes `abs(quantity) * payoff_native`.
- Account position is set to zero before cashflow.
- Open-series and short exposure indexes are updated.
- Settlement is blocked until expiry and finalized settlement price.
- Repeated settlement for the same account and series reverts.

Settlement cashflow:

- Losing shorts are collected into the settlement sink.
- Winning longs are paid from the settlement sink.
- Insurance can top up payout shortfall when configured.
- Uncovered residual becomes explicit series bad debt.

Settlement price source:

- Settlement price is written through `OptionProductRegistry` by owner or
  settlement operator.
- Production operation must define the oracle observation time, data source,
  finality delay, dispute/cancel procedure, and monitoring alerts.

Expired option cleanup:

- Expired options cannot be traded.
- Positions remain in the open-series index until each account is settled.
- Backend should queue affected accounts for settlement and retry failures
  without marking them complete until on-chain events confirm settlement.

## Events and Indexing Model

### Current Events to Index

Execution:

- `MatchingEngine.TradeSubmitted`
- `MarginEngine.TradeExecuted`
- `MarginEngine.TradingFeeCharged` when on-chain fees are enabled
- `CollateralVault.InternalTransfer`

Settlement:

- `OptionProductRegistry.SettlementPriceProposed`
- `OptionProductRegistry.SettlementPriceFinalized`
- `OptionProductRegistry.SettlementProposalCancelled`
- `MarginEngine.AccountSettlementResolved`
- `MarginEngine.AccountSettled`
- `MarginEngine.SeriesSettlementAccountingUpdated`
- `MarginEngine.SettlementShortfall`
- `MarginEngine.SettlementCollectionShortfall`
- `MarginEngine.SettlementInsuranceCoverage`
- `MarginEngine.SettlementBadDebtRecorded`

Lifecycle and safety:

- `OptionProductRegistry.SeriesCreated`
- `OptionProductRegistry.SeriesStatusUpdated`
- `MarginEngine.SeriesShortOpenInterestCapSet`
- `MarginEngine.SeriesActivationStateSet`
- `MarginEngine.SeriesEmergencyCloseOnlySet`
- `MatchingEngine.ExecutorSet`
- pause and role events across registry, engine, vault, and matching ingress

### Recommended V1B Event

The new option ingress should emit:

```solidity
event OptionTradeExecuted(
    bytes32 indexed intentId,
    address indexed buyer,
    address indexed seller,
    uint256 optionId,
    uint128 quantity,
    uint128 premiumPerContract,
    bool buyerIsMaker,
    uint256 buyerNonce,
    uint256 sellerNonce
);
```

Optional follow-up event:

```solidity
event OptionTradeSubmitted(
    bytes32 indexed intentId,
    bytes32 indexed sourceId,
    uint8 sourceType
);
```

The optional event is useful only if source id/type must be visible on chain.
Otherwise backend can keep source mapping off-chain and reconcile by `intentId`.

### Backend Indexer Requirements

The backend indexer must:

- decode option execution events by contract address and topic
- normalize addresses to lowercase
- parse `intentId` as bytes32 hex
- store block number, block hash, tx hash, and log index
- reconcile exactly one indexed execution event to exactly one option execution
  intent
- treat zero matches as unmatched
- treat multiple matches as ambiguous
- require receipt success, indexed event, and reconciliation before confirmation
- handle reorgs according to the existing confirmation policy

Settlement indexing must:

- link account settlement events by `optionId` and trader
- update account/series settlement views
- record shortfalls, insurance coverage, and bad debt separately
- avoid treating a submitted tx as settled without the matching settlement event

## Security Considerations

Replay:

- Bind chain id and verifying contract in EIP-712.
- Include nonzero `intentId`.
- Use sequential nonces.
- Include finite deadlines.

Signature malleability:

- Use low-s ECDSA recovery.
- Reject malformed signatures.
- Treat recovered signer mismatch as fatal.

Stale oracle:

- Trading relies on `RiskModule` and oracle-backed account risk.
- If risk computation cannot conservatively value required paths, execution must
  fail closed.
- Settlement price setting needs an operational oracle finality procedure.

Expired series:

- Backend must not create intents for expired series.
- On-chain ingress and `MarginEngine` must reject expired trading.

Invalid product:

- On-chain ingress must load `OptionProductRegistry.getSeries(optionId)`.
- Signed series metadata must match registry metadata.
- Unknown or inactive series must not execute new exposure.

Insufficient margin:

- `MarginEngine` enforces post-trade IM.
- Backend simulation should surface the exact revert reason before broadcast.
- Confirmation must not mark failed transactions as executed.

Self-trade:

- Buyer and seller must differ.
- Backend should reject self-trades before signing.
- On-chain ingress must still reject self-trades.

Double-fill:

- Backend source fill id must map to at most one option execution intent.
- `intentId` must be unique.
- On-chain nonces prevent reusing the same signed execution.
- Confirmation should reject duplicate indexed events for one intent.

Nonce reuse:

- Backend must reserve nonces per trader.
- Backend must sync from on-chain `nonces(account)`.
- Cancellation must invalidate pending signatures and intents.

Fee manipulation:

- V1 must avoid double charging between backend ledger and on-chain fees.
- V2 must reconcile charged fee events to backend ledger rows.
- Fee recipient must not be buyer or seller when on-chain fees are enabled.

Settlement oracle manipulation:

- Settlement operator powers can cause direct economic loss.
- Use finality delay, monitoring, and an explicit cancel/dispute runbook.
- Do not settle accounts before price finalization is verified.

Partial fills:

- Each partial fill should become its own option execution intent.
- Signed quantity must equal executable partial quantity.
- Backend must not sign a larger remaining order amount and then execute a
  smaller amount unless the typed data explicitly supports partial fill
  semantics.

Cancellation race:

- Off-chain order/RFQ cancellation can race with already signed on-chain intent.
- Once both on-chain signatures are issued, cancellation requires nonce
  cancellation on chain.
- Backend UI/API must distinguish off-chain cancellation from on-chain nonce
  invalidation.

Backend/orderbook mismatch:

- Backend orderbook price/size are not authoritative on chain.
- The final signed `OptionTrade` is authoritative for on-chain execution.
- Backend must reconcile source fill values to signed and indexed values.

Executor risk:

- Executor can censor or delay valid trades.
- Executor must not be able to forge signatures.
- Unknown executors must fail.
- Executor role changes must be monitored.

Unit mismatch:

- `price_1e8` and settlement-native `premiumPerContract` must not be confused.
- `size_1e8` and raw `quantity` must not be confused.
- V1B whole-contract restriction must be enforced consistently.

## Phased Implementation Plan

### V1A: Design

- Add this document.
- Do not implement contract or backend changes.

### V1B: Solidity Minimal Execution

Scope:

- Add `OptionMatchingEngine`.
- Keep `MarginEngine.applyTrade` unchanged.
- Add `intentId` to signed payload and event.
- Validate signed series metadata against `OptionProductRegistry`.
- Reuse sequential nonces, executor allowlist, cancellation, pause, and ECDSA
  recovery patterns.
- Forward only `IMarginEngineTrade.Trade` to `MarginEngine`.
- Do not add backend execution, deployment, broadcast, indexing, or confirmation
  changes in V1B.

Tests:

- signature success/failure
- nonce success/failure/cancel
- deadline expiry
- series metadata mismatch
- whole-contract quantity
- event emission with `intentId`
- `MarginEngine` forwarding and revert rollback

### V1C: Deployment Wiring

Scope:

- Add isolated `OptionMatchingEngine` deployment support.
- Wire `WireCore` to select `OptionMatchingEngine` as option ingress only when
  `OPTION_MATCHING_ENGINE_ADDR` is configured.
- Extend ownership handoff and executor configuration for optional option
  matching.
- Extend deployment verification for optional option matching.
- Update env templates, manifest, runbooks, and rehearsal docs.
- Do not change `MarginEngine.applyTrade`, storage layout, or protocol
  economics.
- Do not add backend execution, calldata, broadcast, indexing, or confirmation.

### V1D: Backend Option Execution Intents

Scope:

- Add option execution intent persistence.
- Convert orderbook fills and RFQ fills to option execution intents.
- Store source normalized values and on-chain native values.
- Add option nonce reservation/sync.
- Add option EIP-712 payload generation.
- Require final buyer/seller signatures for production execution.
- Keep RFQ quote signatures as quote authenticity checks.

### V1E: Simulation, Broadcast, Indexing, Reconciliation

Scope:

- Add option calldata builder.
- Extend dry-run simulation to option execution.
- Add option broadcast target and transaction rows.
- Decode option execution events.
- Reconcile by `intentId`.
- Confirm only after receipt success, indexed event, and reconciliation match.
- Keep real broadcast disabled by default until testnet rehearsal passes.

### V1F: Settlement and Exercise Operations

Scope:

- Add backend expiry scanner for active option series.
- Add settlement price proposal/finalization runbook hooks.
- Add account settlement queue.
- Index and reconcile settlement events.
- Surface settlement shortfall, insurance coverage, and bad debt dashboards.

### V2: On-chain Fees

Scope:

- Enable `FeesManager` for option execution after V1 execution reconciliation is
  stable.
- Define fee recipient and rebate source of truth.
- Reconcile `TradingFeeCharged` events to backend fee ledger.
- Add fee drift alarms between backend schedule and on-chain config.

## Test Plan

### Solidity Unit Tests

- `OptionMatchingEngine` EIP-712 domain and typehash.
- Valid dual-signature execution.
- Invalid buyer signature.
- Invalid seller signature.
- Wrong chain/verifying contract signature.
- Nonce mismatch.
- Nonce cancellation.
- Deadline expiry.
- Zero intent id rejection.
- Zero quantity and zero premium rejection.
- Self-trade rejection.
- Unknown option id rejection.
- Series metadata mismatch rejection.
- Expired series rejection.
- Close-only/restricted/inactive series behavior through `MarginEngine`.
- Short OI cap enforcement through `MarginEngine`.
- Premium transfer exactness.
- Fee disabled V1 mode does not collect on-chain fee.
- Fee enabled V2 mode collects expected maker/taker fees.

### Solidity Scenario Tests

- Orderbook fill opens long/short positions and transfers premium.
- Orderbook partial fills create separate intents and positions aggregate.
- RFQ fill opens positions with maker/taker attribution.
- Buyer insufficient premium reverts.
- Seller insufficient IM reverts.
- Existing perp exposure blocks unsafe option short.
- Series emergency close-only allows reduction but blocks new exposure.
- Expiry blocks new trades.
- ITM settlement pays longs and collects shorts.
- OTM settlement clears positions without payoff.
- Insurance covers settlement shortfall.
- Residual bad debt is recorded when collateral and insurance are insufficient.

### Fuzz Tests

- Random valid/invalid signed option trade payloads preserve nonce invariants.
- Random whole-contract fills preserve open-series indexing.
- Random reduce/close sequences do not increase short exposure unexpectedly.
- Random price/decimal conversions never silently produce zero premium for a
  nonzero accepted fill.
- Settlement remains single-use per account and series.

### Invariant Tests

- Sum of buyer/seller position deltas is zero per executed trade.
- Series short OI equals aggregate live short positions.
- Trader open-series list contains exactly nonzero positions.
- Premium plus fee transfers conserve vault balances excluding explicit fee
  recipient movements.
- No confirmed backend intent lacks exactly one indexed on-chain execution event.
- No account settlement is marked complete without an indexed `AccountSettled`.

### Backend E2E Tests

- Create/sync option series with `onchain_option_id`.
- Submit option order, match fill, create option execution intent.
- Create option RFQ, submit signed quote, accept quote, create option execution
  intent.
- Generate final EIP-712 payload for buyer and seller.
- Reject non-whole-contract `size_1e8` in V1B.
- Convert `price_1e8` to settlement-native premium exactly once.
- Sync and reserve nonces.
- Build calldata only when signatures are present.
- Dry-run simulation records success/failure.
- Broadcast disabled never fabricates tx hash.
- Indexer decodes option execution event.
- Reconciliation marks exact match, unmatched, and ambiguous cases correctly.
- Confirmation requires reconciliation.
- Fee ledger does not double count on-chain fee mode.

### Testnet Rehearsal

- Deploy/wire option matching ingress.
- Configure one ETH option and one BTC option series.
- Execute one small orderbook fill.
- Execute one small RFQ fill.
- Verify positions, premium, margin, events, indexed rows, reconciliation, and
  confirmations.
- Advance or use a short-lived test series for settlement rehearsal.
- Finalize settlement price and settle both accounts.
- Capture tx hashes, events, indexed rows, reconciliation rows, and dashboard
  screenshots as launch evidence.

## Deferred Items

- Fractional option quantity support.
- ERC-1271 smart account signatures.
- Generalized multi-product `ExecutionRouter`.
- Multi-leg option strategies.
- On-chain RFQ quote acceptance with single maker quote signature.
- Physical delivery.
- American exercise.
- Dynamic option mark-to-market credit for long options.
- On-chain rebate claims or automatic rebate settlement.
- Cross-chain settlement.
