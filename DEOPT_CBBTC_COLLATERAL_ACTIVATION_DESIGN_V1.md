# DEOPT_CBBTC_COLLATERAL_ACTIVATION_DESIGN_V1

Design-only. cbBTC remains inactive. Base is the only chain.

## Purpose

Define the exact on-chain + backend + frontend activation path for
Coinbase Wrapped BTC (cbBTC) as a *collateral* asset on Base.
Repeats the WETH design with the differences that matter for a
BTC-priced ERC-20: volatility, token-contract custody risk, and
concentration coupling with BTC-perp exposure.

## Scope

Same as WETH: cbBTC deposits into `CollateralVault`, dual-source
oracle valuation, USDC-denominated PnL preserved.

Out of scope: cbBTC as quote asset, cross-collateral netting,
on-protocol WBTC swaps.

## Custody / token contract risk

cbBTC on Base is issued by Coinbase Custody with a documented mint /
burn model. Risks specific to cbBTC that DO NOT apply to WETH:

- **Issuer freeze**: Coinbase can pause transfers (in practice, has
  never done so for cbBTC on Base; the contract does not expose a
  pause admin, but the underlying custody could still be seized). A
  frozen collateral cannot be used to close positions, which means
  liquidators may be unable to seize.
- **Depeg risk**: cbBTC pegs 1:1 to BTC by trust in Coinbase custody.
  Historical depeg events on other wrapped-BTC issuances (WBTC ~2%
  depeg 2024) inform the haircut floor.
- **Contract upgrade**: cbBTC contract on Base is a proxy. A
  malicious upgrade could brick balances. Not our threat model to
  detect, but the deposit cap must be sized to acceptable loss.

Mitigations:

- Lower `collateralFactorBps` than WETH.
- Lower `depositCap` than WETH.
- Explicit issuer-freeze guardian pause path (frontend banner + fail-
  closed router).

## On-chain activation path

Identical structure to WETH:

1. `CollateralVault.addCollateralToken(CBBTC_ADDRESS, 8)` — 8
   decimals (not 18; note the difference from WETH).
2. `CollateralVault.setCollateralTokenConfig(CBBTC, depositCap=…,
   depositEnabled=true, withdrawalEnabled=true)`.
3. `OracleRouter.setFeed(CBBTC, USDC, chainlinkCbBtcUsd,
   secondaryCbBtcUsd, maxDelay=1500, maxDeviationBps=<see below>,
   isActive=true)`.

Timelock-mediated.

## Oracle configuration

BTC/USD spot is used to price cbBTC — we DO NOT try to price the
peg separately. Any cbBTC ≠ BTC deviation is intentionally absorbed
by the collateral haircut, not by a separate peg oracle. Rationale:
BTC oracles are deep and reliable; wrapping-specific price feeds
are thin and manipulable.

- **Primary**: Chainlink BTC/USD aggregator on Base (proxy address
  `0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298`, 8 decimals, 1200s
  heartbeat) — same as BTC-PERP.
- **Secondary**: Pyth BTC/USD price feed
  (`0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43`).
- `maxDelay`: 1500s.
- `maxDeviationBps`: 100 bps (matches BTC-PERP router entry).

## Parameter framework

| Parameter | Type | Bounds | Cf. WETH |
|---|---|---|---|
| `depositCap` | 1e8 wei (cbBTC has 8 decimals) | Recommend $250k–$500k USD notional for first closed test. | ~50% of WETH cap. |
| `collateralFactorBps` | `uint16` | 6500–8000 (65–80%) suggested first-pass. Never 10_000. | Lower than WETH (WETH: 8000–9000) to reflect wrap risk + BTC volatility + BTC-perp concentration. |
| `liquidationFactorBps` | `uint16` | ≤ `collateralFactorBps`. Suggest 7500–8500 (75–85%). | Same buffer rule as WETH. |
| `oracleMaxDelay` | seconds | 1500 (fixed, matches BTC-PERP). | Same as WETH. |
| `oracleMaxDeviationBps` | bps | 100 (matches BTC-PERP). | Same as WETH. |

### Safe bounds (hard rules)

- `collateralFactorBps ≤ 8_000` (never trust cbBTC at more than 80%
  until an issuer-freeze incident model is written).
- `depositCap` per-wallet not just protocol-total: consider adding a
  per-wallet cbBTC cap as a *concentration* limit (see Part F).
- `liquidationFactorBps - collateralFactorBps ≥ 500` (same buffer).
- `depositCap × collateralFactorBps × (1 + concentration_penalty) ≤ insurance_fund_USD` —
  the protocol MUST hold enough USDC in the insurance fund to absorb
  the worst-case liquidation loss.

## Margin valuation + liquidation

Same generic path as WETH. Two cbBTC-specific rules:

1. **Seizure discount** should be larger than WETH (suggest 3–5%
   vs. WETH's 2%) to reflect the harder path to convert seized
   cbBTC → USDC in an incident.
2. **Insurance fund credit** MUST convert to USDC before booking,
   same as WETH.

## Subaccount isolation

Unchanged from USDC/WETH — per-`(chain_id, owner, subaccount_id,
token)` balance rows.

## Concentration coupling — see Part F

A subaccount holding cbBTC collateral AND a long BTC-perp position
has correlated downside risk. Part F designs the concentration
policy that must be layered on top of these parameters.

## Rollback / disable path

Identical structure to WETH:

1. Timelock: `OracleRouter.setFeed(CBBTC, ..., isActive=false)`.
2. Timelock: freeze deposits (`depositEnabled=false`).
3. Guardian: freeze withdrawals — emergency only.

## Tests required before activation

- All WETH tests, repeated for cbBTC (parameters differ).
- Concentration test: subaccount with cbBTC collateral + long BTC-
  perp must produce a haircut EXCEEDING sum of individual factors.
  See Part F.
- Issuer-freeze simulation: cbBTC transferFrom reverts → router falls
  back to fail-closed; no partial-fill panic.
- Depeg simulation: primary BTC/USD moves 10%, secondary lags →
  deviation cap trips → router returns stale/refused → margin engine
  gracefully denies new positions on cbBTC-backed subaccounts.

## Verdict

`DEOPT_CBBTC_COLLATERAL_ACTIVATION_DESIGN_VALIDATED`
