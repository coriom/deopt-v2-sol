# DEOPT_WETH_COLLATERAL_ACTIVATION_DESIGN_V1

Design-only. WETH remains inactive. Base is the only chain.

## Purpose

Define the exact on-chain + backend + frontend activation path for
WETH as a *collateral* asset on Base while preserving USDC as the
sole settlement / PnL denomination.

## Scope

- Enable WETH deposits into `CollateralVault`.
- Value WETH deposits in USD via a dedicated Chainlink WETH/USD feed
  routed through `OracleRouter`.
- Apply a collateral haircut so risk-adjusted value < raw USD value.
- Preserve every existing Options / Perps / Subaccount economic
  guarantee for USDC-only subaccounts.

Out of scope for this milestone (and for the first WETH closed test):

- WETH as a *quote* / settlement asset (would break the immutable
  `QUOTE_TOKEN` V2 invariant).
- Cross-collateral netting between subaccounts.
- Automated collateral rebalancing.

## On-chain activation path

### Contract calls (all timelock-owned)

1. `CollateralVault.addCollateralToken(WETH_ADDRESS, 18)` (or its
   configured equivalent) — registers WETH with 18 decimals and an
   empty `CollateralTokenConfig`.
2. `CollateralVault.setCollateralTokenConfig(...)` (or its
   configured equivalent) — sets the on-chain config: `decimals=18`,
   `enabled=true`, `depositCap=<cap in 1e18 wei>`.
3. `OracleRouter.setFeed(WETH, USDC, chainlinkWethUsd, secondaryWethUsd,
   maxDelay=1500, maxDeviationBps=<see below>, isActive=true)` —
   registers the WETH/USD price feed under the dual-source invariant.

All three calls go through `ProtocolTimelock` (queue → wait
`minDelay` → execute), matching the pattern in
`BASE_SEPOLIA_INFRA_BROADCAST_V1.md`.

### Oracle configuration

WETH/USD requires a dual-source feed like every other configured
router entry:

- **Primary**: Chainlink WETH/USD aggregator on Base (proxy address,
  8 decimals, ~1200s heartbeat).
- **Secondary**: Pyth WETH/USD price feed
  (`0xff61491a...`), same 1e8 normalisation.
- `maxDelay`: 1500s (matches the existing BTC/ETH-PERP entries).
- `maxDeviationBps`: 100 bps (1%), matching the canonical
  `OracleRouterDualSourceInvariantTest.DEV_BPS` value chosen for BTC/USD.

### Parameter framework (values chosen by risk committee at activation, not here)

| Parameter | Type | Bounds | Purpose |
|---|---|---|---|
| `depositCap` | `uint256` (1e18 wei) | ≥ 0. Recommend seeding at $500k-$1M USD notional equivalent for a first closed test. | Bounds worst-case oracle-manipulation loss + concentration risk. |
| `collateralFactorBps` | `uint16` (bps) | 0 ≤ value < `COLLATERAL_FACTOR_BPS_MAX` (10_000). For WETH suggest 8000–9000 (80–90%) as *first-pass* haircut. Never 10_000. | Applied at valuation time: risk-adjusted USD = raw USD × factor. |
| `liquidationFactorBps` | `uint16` (bps) | ≤ `collateralFactorBps`. Suggest 8500–9500 (85–95%). | Applied at liquidation-eligibility check; must be ≥ collateralFactor so a subaccount can never drift straight from "safe" to "liquidatable" solely because of the ratio inversion. |
| `depositEnabled` | `bool` | `true` at activation | Vault-level deposit gate. |
| `withdrawalEnabled` | `bool` | `true` at activation | Vault-level withdrawal gate. Independent from deposit so an incident response can freeze deposits without trapping user funds. |
| `oracleMaxDelay` | `uint32` (seconds) | 900 ≤ value ≤ 3600. Chose 1500 to match ETH-PERP/BTC-PERP. | Router-level staleness gate. |
| `oracleMaxDeviationBps` | `uint16` (bps) | 50 ≤ value ≤ 300. Chose 100 (1%) as a conservative match for the codebase's canonical dev bps. | Router-level deviation gate between primary + secondary sources. |

### Safe bounds (do not exceed without external audit)

- `collateralFactorBps ≤ 9_000` (never trust WETH at more than 90%
  of spot until BTC-perp / ETH-perp exposure limits are re-audited).
- `depositCap × maxDeviationBps ≤ maxAcceptableLoss` — the product
  bounds the theoretical stale/mispriced loss on a bad-oracle event.
- `liquidationFactorBps - collateralFactorBps ≥ 500` (5% buffer so
  small oracle drift cannot flip solvency).

## Margin valuation

`RiskModuleCollateral._tokenAmountToBaseValue(WETH, amount, price_1e8)`
already handles per-token decimals. The activation step is purely to:

1. Read `CollateralTokenConfig(WETH).decimals = 18`.
2. Convert to normalised 1e8 base value.
3. Multiply by `collateralFactorBps / 10_000` at
   *margin-availability* computation time.
4. Multiply by `liquidationFactorBps / 10_000` at
   *liquidation-eligibility* computation time.

Settlement / PnL denomination remains `QUOTE_TOKEN = USDC`. WETH
collateral is never quoted, sold, or auto-swapped by the protocol —
it is either withdrawn intact by the user or seized during
liquidation and moved to the insurance fund.

## Liquidation behaviour

Same three-phase model as USDC:

1. Detection: risk engine reads `sum(collateral_i × liquidation_factor_i)`
   and compares against `sum(margin_requirement_j)`. If the sum falls
   short → liquidatable.
2. Seizure: liquidator takes WETH collateral at oracle price minus a
   penalty (e.g. 2%) discount. Discount lives in a per-token config
   field to be added at activation.
3. PnL settlement: liquidation proceeds land in the insurance fund
   denominated in USDC (via the liquidator swapping WETH externally
   and depositing the USDC). The protocol does not perform on-chain
   swaps.

## Subaccount isolation

Subaccount balance keys are already `(chain_id, owner, subaccount_id,
token)` in the Hybrid V2 tables (migration 0046). A subaccount that
holds WETH cannot use WETH to back positions in a *different*
subaccount, even for the same wallet. No cross-subaccount netting.

## History / API / frontend representation

- History rows already carry `token` per-entry (see `IndexedPerpTrade`
  and `option_fills` — token is embedded in the series metadata).
- API `Balance` type carries `token`, `symbol`, `decimals`, `balance`
  fields — see `deopt-v2-frontend/src/lib/trading-types.ts::Balance`.
  No shape change needed to display multi-asset balances.
- Frontend `BalancesCard` iterates over backend-returned balances and
  displays them in a table. Rendering three rows (USDC, WETH,
  cbBTC) instead of one requires no component change.
- Adding a "risk-adjusted margin value" column will require a new
  API field. Suggested: `Balance.risk_adjusted_usd_1e8` returned
  from a new backend endpoint that reads the collateral registry.

## Rollback / disable path

1. `OracleRouter.setFeed(WETH, USDC, ..., isActive=false)` via
   timelock → new deposits still allowed but no new positions can
   value WETH.
2. `CollateralVault.setCollateralTokenConfig(WETH, depositEnabled=false)`
   via timelock → freezes deposits; existing balances withdrawable.
3. `CollateralVault.setCollateralTokenConfig(WETH,
   withdrawalEnabled=false)` — emergency only, traps user funds.
   Requires guardian action + post-incident post-mortem.

## Tests required before activation

- `RiskModuleCollateral` unit tests: WETH factor application under
  price up/down/stale/zero.
- `OracleRouter` invariant: dual-source WETH/USD dev-cap enforced.
- Vault: deposit cap enforcement.
- Withdrawal safety: partial withdrawal that would drop
  `risk_adjusted_collateral < maintenance_margin` MUST revert.
- Liquidation: seize WETH at oracle price − discount, insurance
  fund credit in USDC.
- Backend regression: `assert_v1_single_collateral_invariant()`
  should FAIL when WETH is activated (that assertion is a V1 guard
  — activation is a deliberate change).

## Verdict

`DEOPT_WETH_COLLATERAL_ACTIVATION_DESIGN_VALIDATED`
