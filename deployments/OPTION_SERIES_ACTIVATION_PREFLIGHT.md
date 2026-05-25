# Option Series Activation Preflight V1G

## Scope

Preflight only. Do not broadcast, deploy, use private keys, modify backend,
modify frontend, or change contract logic from this document.

Target network: Base Sepolia, chain id `84532`.

## Current Inactive Series

Read-only Base Sepolia checks confirm the backend-tested ETH call series exists
in `OptionProductRegistry` but is not registry-active:

| Field | Value |
| --- | --- |
| `OPTION_PRODUCT_REGISTRY` | `0x3d52b033Fab00ed6104DD3bc0a715F8648344ecA` |
| `MARGIN_ENGINE` | `0x6C5665De05e7314cB63cD77F82DFa86508A5b5F8` |
| `OPTION_MATCHING_ENGINE` | `0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b` |
| `optionId` | `24145907678156652148089862289363692212069910767044828147380657249455352740183` |
| `underlying` | `0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02` |
| `settlementAsset` | `0x6eAe407f5640B006faC9965182e238582A3B412E` |
| `expiry` | `1893456000` |
| `strike1e8` | `300000000000` |
| `contractSize1e8` | `100000000` |
| `isCall` | `true` |
| `isEuropean` | `true` |
| `exists` | `true` |
| `isActive` | `false` |
| `MarginEngine.seriesActivationState` | `0` (`active`) |
| `MarginEngine.seriesShortOpenInterestCap` | `10000000000` |

Additional read-only state:

- `computeOptionId(...)` for the current ETH env tuple returns the tested
  `optionId`.
- `getSeriesByUnderlying(ETH_UNDERLYING)` returns only the tested `optionId`.
- `getActiveSeriesByUnderlying(ETH_UNDERLYING)` returns `[]`.
- `isSettlementAssetAllowed(BASE_COLLATERAL_TOKEN)` is `true`.
- ETH underlying config is enabled with oracle
  `0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581`, spot shocks `3000/3000`,
  vol shocks `0/2000`.

## Exact Simulation Failure

`OptionMatchingEngine` validates the option series before converting the trade
into a `MarginEngine` trade. It reads
`OptionProductRegistry.getSeriesIfExists(t.optionId)` and reverts with
`SeriesInactive()` when `series.isActive == false`.

The current failure is therefore caused by
`OptionProductRegistry.OptionSeries.isActive=false` for the tested option ID.
The margin-level activation state is already `0`, so the observed revert occurs
before `MarginEngine.seriesActivationState` can gate the trade.

## Activation Path

Direct registry function:

```solidity
OptionProductRegistry.setSeriesActive(uint256 optionId, bool isActive)
```

Requirements:

- caller must be `OptionProductRegistry.owner()`
- registry config must not be paused (`paused=false` and `configPaused=false`)
- the series must already exist

Scripted path:

`script/ConfigureMarkets.s.sol` can activate the existing ETH call series. For
each configured series it computes the option ID from:

- underlying
- settlement asset
- expiry
- strike
- fixed `contractSize1e8 = 1e8`
- call flag
- European flag

If the series already exists, the script skips creation and calls:

```solidity
registry.setSeriesActive(optionId, ETH_OPTION_SERIES_REGISTRY_ACTIVE[i]);
marginEngine.setSeriesShortOpenInterestCap(optionId, ETH_OPTION_SERIES_SHORT_OI_CAPS[i]);
marginEngine.setSeriesActivationState(optionId, ETH_OPTION_SERIES_ACTIVATION_STATES[i]);
```

For the existing backend-tested ETH series, set:

```bash
ETH_OPTION_SERIES_EXPIRIES=1893456000
ETH_OPTION_SERIES_STRIKES_1E8=300000000000
ETH_OPTION_SERIES_IS_CALLS=true
ETH_OPTION_SERIES_IS_EUROPEAN=true
ETH_OPTION_SERIES_REGISTRY_ACTIVE=true
ETH_OPTION_SERIES_ACTIVATION_STATES=0
ETH_OPTION_SERIES_SHORT_OI_CAPS=10000000000
```

Current `.env.base-sepolia` has the same ETH tuple but
`ETH_OPTION_SERIES_REGISTRY_ACTIVE=false`. That is the activation bit that must
change for this series.

## Required Env Vars

`ConfigureMarkets.s.sol` requires the full market configuration env, not only
the option series activation bit:

- Addresses: `ORACLE_ROUTER`, `OPTION_PRODUCT_REGISTRY`, `MARGIN_ENGINE`,
  `PERP_MARKET_REGISTRY`, `PERP_ENGINE`, `BASE_COLLATERAL_TOKEN`,
  `ETH_UNDERLYING`, `BTC_UNDERLYING`
- Oracle feed vars: `ETH_USDC_PRIMARY_SOURCE`,
  `ETH_USDC_SECONDARY_SOURCE`, `ETH_USDC_MAX_DELAY`,
  `ETH_USDC_MAX_DEVIATION_BPS`, `ETH_USDC_FEED_ACTIVE`,
  `BTC_USDC_PRIMARY_SOURCE`, `BTC_USDC_SECONDARY_SOURCE`,
  `BTC_USDC_MAX_DELAY`, `BTC_USDC_MAX_DEVIATION_BPS`,
  `BTC_USDC_FEED_ACTIVE`, `ORACLE_ROUTER_MAX_DELAY`
- Option underlying vars for `ETH_OPTION_*` and `BTC_OPTION_*`: `ORACLE`,
  `SPOT_SHOCK_DOWN_BPS`, `SPOT_SHOCK_UP_BPS`, `VOL_SHOCK_DOWN_BPS`,
  `VOL_SHOCK_UP_BPS`, `UNDERLYING_ENABLED`, `BASE_MM_PER_CONTRACT_BASE`,
  `IM_FACTOR_BPS`, `ORACLE_DOWN_MM_MULTIPLIER_BPS`
- Option series vars for `ETH_OPTION_SERIES_*` and `BTC_OPTION_SERIES_*`:
  `EXPIRIES`, `STRIKES_1E8`, `IS_CALLS`, `IS_EUROPEAN`,
  `REGISTRY_ACTIVE`, `ACTIVATION_STATES`, `SHORT_OI_CAPS`
- Perp vars for `ETH_PERP_*` and `BTC_PERP_*`

`ConfigureMarkets.s.sol` also reads `DEPLOYER_PRIVATE_KEY` because it uses
`vm.startBroadcast`. Do not print or commit that value. No private key was used
for this preflight.

## Required Authority

Read-only owner checks on Base Sepolia:

| Contract | Required for `ConfigureMarkets` | Current owner |
| --- | --- | --- |
| `OracleRouter` | feed/max-delay updates | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |
| `OptionProductRegistry` | settlement asset, underlying profile, series active flag | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |
| `MarginEngine` | series cap and activation state | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |
| `PerpMarketRegistry` | perp registry config | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |
| `PerpEngine` | perp launch cap and activation state | `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27` |

For a minimal activation of only the existing ETH series, the necessary
authority is `OptionProductRegistry.owner()` for `setSeriesActive(optionId,
true)`. If changing `seriesActivationState` or short OI cap in the same
operation, `MarginEngine.owner()` is also required.

Current registry safety state:

- `OptionProductRegistry.pendingOwner()` is zero.
- `OptionProductRegistry.guardian()` is
  `0xc35F7A8A103A9A4464adfaa76B9B514093D23C27`.
- `paused=false`, `creationPaused=false`, `configPaused=false`.

## Existing Series Vs New Series

The safer protocol path for the current backend blocker is activating the
existing ETH call series, not configuring a new active series.

Reasons:

- the backend-tested `optionId` exactly matches the current ETH series env tuple
- the series exists with the expected underlying, settlement asset, expiry,
  strike, contract size, call flag, and European flag
- settlement asset and underlying config are already enabled
- margin activation state is already `0`
- creating a new active series would require backend order/calldata inputs to
  move to a different option ID and would leave the current tested path blocked

Operational caveat: `ConfigureMarkets.s.sol` is the existing scripted path but
is broad. It re-applies oracle feeds, underlying risk profiles, ETH and BTC
option series settings, and perp market settings. A dedicated activation-only
script or direct owner transaction would be lower surface area, but no new
script is introduced in this preflight.

## Safe Dry Run

Not run in this preflight because `ConfigureMarkets.s.sol` requires
`DEPLOYER_PRIVATE_KEY`, and this task explicitly forbids private-key use.

Operator-only dry-run command, no broadcast:

```bash
set -a
source .env.base-sepolia
set +a

forge script script/ConfigureMarkets.s.sol --rpc-url "$RPC_URL"
```

Before running, ensure `ETH_OPTION_SERIES_REGISTRY_ACTIVE=true` and the rest of
the ETH tuple remains unchanged. This command still reads a private key for
Foundry sender simulation; do not print env and do not add `--broadcast`.

## Manual Broadcast Command

Manual only. Mutates Base Sepolia. Do not run as validation.

```bash
set -a
source .env.base-sepolia
set +a

forge script script/ConfigureMarkets.s.sol \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Only use this broad script if the operator intentionally wants to re-apply the
entire market configuration. Otherwise prefer a reviewed, minimal owner action
that calls only:

```solidity
OptionProductRegistry.setSeriesActive(
    24145907678156652148089862289363692212069910767044828147380657249455352740183,
    true
)
```

## Post-Activation Verification Commands

Read-only checks after manual activation:

```bash
cast call "$OPTION_PRODUCT_REGISTRY" \
  "getSeries(uint256)((address,address,uint64,uint64,uint128,bool,bool,bool,bool))" \
  24145907678156652148089862289363692212069910767044828147380657249455352740183 \
  --rpc-url "$RPC_URL"

cast call "$OPTION_PRODUCT_REGISTRY" \
  "getActiveSeriesByUnderlying(address)(uint256[])" \
  "$ETH_UNDERLYING" \
  --rpc-url "$RPC_URL"

cast call "$MARGIN_ENGINE" \
  "seriesActivationState(uint256)(uint8)" \
  24145907678156652148089862289363692212069910767044828147380657249455352740183 \
  --rpc-url "$RPC_URL"

cast call "$MARGIN_ENGINE" \
  "seriesShortOpenInterestCap(uint256)(uint256)" \
  24145907678156652148089862289363692212069910767044828147380657249455352740183 \
  --rpc-url "$RPC_URL"

cast call "$MARGIN_ENGINE" \
  "matchingEngine()(address)" \
  --rpc-url "$RPC_URL"

cast call "$OPTION_MATCHING_ENGINE_ADDR" \
  "marginEngine()(address)" \
  --rpc-url "$RPC_URL"

cast call "$OPTION_MATCHING_ENGINE_ADDR" \
  "optionRegistry()(address)" \
  --rpc-url "$RPC_URL"
```

Expected activation assertions:

- `getSeries(...)` returns the same tuple with final `isActive=true`.
- `getActiveSeriesByUnderlying(ETH_UNDERLYING)` includes the tested `optionId`.
- `seriesActivationState(optionId) == 0`.
- `seriesShortOpenInterestCap(optionId) == 10000000000`, unless intentionally
  changed by the reviewed activation.
- `MarginEngine.matchingEngine()` equals the verified `OptionMatchingEngine`.
- `OptionMatchingEngine.marginEngine()` equals `MARGIN_ENGINE`.
- `OptionMatchingEngine.optionRegistry()` equals `OPTION_PRODUCT_REGISTRY`.

## Backend Follow-Up

After activation is verified on-chain:

1. Rerun the backend live option nonce endpoint against
   `OptionMatchingEngine.nonces(address)`.
2. Recreate the option execution intent using the activated option series.
3. Rerun buyer/seller signing and calldata generation.
4. Rerun the live `eth_call` simulation against `OptionMatchingEngine`.
5. Continue with collateral, margin, valid signatures, and executor readiness
   blockers after `SeriesInactive()` is cleared.

Backend config caveat: the local `.env.base-sepolia` currently has
`OPTION_MATCHING_ENGINE_ADDR` empty, while on-chain `MarginEngine.matchingEngine`
returns `0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b`. The draft manifest also
still lists `OptionMatchingEngine` as `null`. Reconcile operator env and the
filled manifest before relying on `VerifyDeployment.s.sol` or backend live
simulation config.

## Read-Only Evidence Commands Run

No private keys and no broadcasts were used. The read-only checks used public
Base Sepolia RPC calls equivalent to:

```bash
cast call 0x3d52b033fab00ed6104dd3bc0a715f8648344eca "owner()(address)" --rpc-url https://sepolia.base.org
cast call 0x3d52b033fab00ed6104dd3bc0a715f8648344eca "getSeries(uint256)((address,address,uint64,uint64,uint128,bool,bool,bool,bool))" 24145907678156652148089862289363692212069910767044828147380657249455352740183 --rpc-url https://sepolia.base.org
cast call 0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8 "seriesActivationState(uint256)(uint8)" 24145907678156652148089862289363692212069910767044828147380657249455352740183 --rpc-url https://sepolia.base.org
cast call 0x6c5665de05e7314cb63cd77f82dfa86508a5b5f8 "matchingEngine()(address)" --rpc-url https://sepolia.base.org
cast call 0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b "marginEngine()(address)" --rpc-url https://sepolia.base.org
cast call 0xf2D1D85cD363Be3bc160d14883C80e7C2c4F420b "optionRegistry()(address)" --rpc-url https://sepolia.base.org
```

## Remaining Blockers

- Actual activation broadcast is deferred.
- Operator must decide whether to use broad `ConfigureMarkets.s.sol` or a
  minimal owner action.
- If using `ConfigureMarkets.s.sol`, operator env must set
  `ETH_OPTION_SERIES_REGISTRY_ACTIVE=true` and preserve all other intended
  market settings.
- `.env.base-sepolia` and the draft manifest are stale for
  `OPTION_MATCHING_ENGINE_ADDR`; reconcile before read-only deployment
  verification or backend live reruns.
- Backend live simulation still needs valid signatures, collateral and margin
  setup, and executor readiness after series activation.
