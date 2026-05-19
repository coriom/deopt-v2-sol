# DEPLOYMENT_REHEARSAL.md

## Purpose

Deployment Rehearsal V1A makes the DeOpt v2 deployment process deterministic,
documented, and auditable without changing protocol logic.

This document is safe-by-default. Normal validation does not deploy, broadcast,
require RPC access, or require private keys. Broadcast commands are listed only
as dangerous manual operator commands.

## Safety Rules

- Do not run broadcast commands during ordinary validation.
- Do not run `cast send` as part of rehearsal validation.
- Do not put real private keys, RPC credentials, API keys, or operator secrets in
  committed files.
- Do not edit `.env.local`, `.env.base-sepolia`, or any filled manifest in a way
  that exposes secrets.
- Keep products inactive or close-only through deployment, wiring,
  configuration, verification, and ownership handoff.
- Treat `script/VerifyDeployment.s.sol` as the final read-only deployment gate
  before ownership handoff, activation planning, or staging evidence signoff.

## Safe No-RPC Validation

These commands are the default V1A validation path. They do not broadcast and do
not require RPC or private keys:

```bash
forge fmt --check
forge build
forge test
```

Do not replace this default validation with a live network script run.

## Script Audit Summary

| Script | Purpose | Consumes Private Key | Broadcasts If Run Normally | Primary Outputs |
| --- | --- | --- | --- | --- |
| `DeployTestnetAssets.s.sol` | Optional testnet mock ERC20 deployment | Yes | Yes | Mock USDC, WETH, WBTC addresses |
| `DeployCore.s.sol` | Core protocol deployment | Yes | Yes | Core contract addresses |
| `DeployOptionMatchingEngine.s.sol` | Optional dedicated option execution ingress deployment | Yes | Yes | `OptionMatchingEngine` address |
| `DeployPerpMatchingEngine.s.sol` | Optional replacement deploy for `PerpMatchingEngine` only | Yes | Yes | New `PerpMatchingEngine` address |
| `WireCore.s.sol` | Dependency wiring across deployed core modules | Yes | Yes | Wired dependency graph |
| `ConfigureCore.s.sol` | Collateral, risk, fees, insurance setup | Yes | Yes | Core config state |
| `DeployLocalMockFeeds.s.sol` | Local Anvil mock price source deployment | Yes | Yes | Local mock feed addresses |
| `DeployTestnetMockFeeds.s.sol` | Optional testnet mock price source deployment | Yes | Yes | Testnet mock feed addresses |
| `RefreshLocalMockFeeds.s.sol` | Local mock feed timestamp refresh | Yes | Yes | Fresh local mock feed timestamps |
| `RefreshTestnetMockFeeds.s.sol` | Testnet mock feed timestamp refresh | Yes | Yes | Fresh testnet mock feed timestamps |
| `ConfigureMarkets.s.sol` | Oracle feeds, option series, perp markets, launch caps | Yes | Yes | Market and series configuration |
| `VerifyDeployment.s.sol` | Read-only bytecode, wiring, config, oracle, fee, insurance checks | No | No | Pass/fail final deployment gate |
| `TransferOwnerships.s.sol` | Guardian, timelock, executor setup and two-step ownership transfer start | Yes | Yes | Pending ownership handoff |
| `AcceptOwnerships.s.sol` | Ownership acceptance and final owner verification | Yes, unless all accepted by prequeued timelock execution | Yes | Final owners and cleared pending owners |

`DeployPerpMatchingEngine.s.sol` is not part of the normal full deployment
sequence. Use it only for a controlled replacement of the perp matching engine
when the core stack is already deployed and preserved.

`DeployOptionMatchingEngine.s.sol` is the V1C option execution ingress path. It
is intentionally isolated from `DeployCore.s.sol` because `MarginEngine`
authorizes only one option matching caller. Deploy it only when the environment
intends `OptionMatchingEngine` to replace the legacy `MatchingEngine` as the
production option ingress.

## Exact Deployment Order

### Local Anvil Rehearsal

Use `LOCAL_REHEARSAL.md` for local-only details and Anvil setup. The deterministic
order is:

1. Start Anvil with the documented local code-size override.
2. Copy `.env.local.example` to `.env.local`.
3. Deploy core with `DeployCore.s.sol`.
4. Copy core addresses into `.env.local`, including `ETH_PERP_ORACLE`,
   `BTC_PERP_ORACLE`, and `TIMELOCK_PROPOSERS` derived from `DeployCore` output.
5. Optional: run `DeployOptionMatchingEngine.s.sol`, copy
   `OPTION_MATCHING_ENGINE_ADDR`, and decide that option orderflow will enter
   through `OptionMatchingEngine` instead of legacy `MatchingEngine`.
6. Run `WireCore.s.sol`.
7. Run `ConfigureCore.s.sol`.
8. Deploy local mock feeds with `DeployLocalMockFeeds.s.sol`.
9. Copy local mock feed addresses into `.env.local`.
10. Run `ConfigureMarkets.s.sol`.
11. Refresh local mock feeds with `RefreshLocalMockFeeds.s.sol` if feed
    `maxDelay` is tight.
12. Run `VerifyDeployment.s.sol` read-only. This must pass before handoff.
13. Run `TransferOwnerships.s.sol`.
14. Run `AcceptOwnerships.s.sol`.
15. Run `VerifyDeployment.s.sol` again read-only against the final manifest.
    This is the final deployment gate before activation planning.

### Base Sepolia Rehearsal

Use `BASE_SEPOLIA_REHEARSAL.md` for network-specific preparation. The
deterministic order is:

1. Copy `.env.base-sepolia.example` to `.env.base-sepolia`.
2. Create a filled manifest from
   `deployments/DEPLOYMENT_MANIFEST.example.json`.
3. Fill chain, deployer, role, collateral, oracle, cap, and market parameters.
4. Optional: run `DeployTestnetAssets.s.sol` if controlled mock ERC20s are used.
5. Run `DeployCore.s.sol`.
6. Copy core addresses into `.env.base-sepolia` and the manifest, including
   `ETH_PERP_ORACLE`, `BTC_PERP_ORACLE`, and `TIMELOCK_PROPOSERS`.
7. Optional: run `DeployOptionMatchingEngine.s.sol`, copy
   `OPTION_MATCHING_ENGINE_ADDR` into env and manifest, and confirm this
   deployment should replace legacy `MatchingEngine` as `MarginEngine` option
   ingress.
8. Run `WireCore.s.sol`.
9. Run `ConfigureCore.s.sol`.
10. Optional: run `DeployTestnetMockFeeds.s.sol` if controlled mock oracle
   sources are used.
11. Copy oracle source addresses into `.env.base-sepolia` and the manifest.
12. Run `ConfigureMarkets.s.sol`.
13. Optional: run `RefreshTestnetMockFeeds.s.sol` immediately before
    verification when mock feed timestamps can become stale.
14. Run `VerifyDeployment.s.sol` read-only. This must pass before ownership
    handoff.
15. Run `TransferOwnerships.s.sol`.
16. Run `AcceptOwnerships.s.sol`, either from expected EOA owners or through the
    documented timelock execution path.
17. Run `VerifyDeployment.s.sol` again read-only using the same manifest-backed
    env to confirm deployment config still matches. This is the final deployment
    gate before activation, staging evidence, or launch signoff.
18. Record explorer verification status as an artifact. Explorer verification is
    not a substitute for `VerifyDeployment.s.sol`.

## Required Env Vars By Phase

The filled env file and the filled manifest must agree. Array-valued env vars
are comma-delimited.

### Common

- `RPC_URL`: required only for live local/testnet script execution, not for safe
  no-RPC validation.
- `CHAIN_ID`: required by testnet mock scripts as a chain mismatch guard.
- `DEPLOYER_PRIVATE_KEY`: required by state-changing scripts only. Never commit.
- `DEPLOYER_ADDRESS`: required by ownership acceptance verification.

### DeployCore

- Required: `DEPLOYER_PRIVATE_KEY`, `BASE_COLLATERAL_TOKEN`.
- Optional/defaulted: `INITIAL_OWNER`, `INITIAL_GUARDIAN`,
  `TIMELOCK_MIN_DELAY`, `DEFAULT_MAKER_NOTIONAL_FEE_BPS`,
  `DEFAULT_MAKER_PREMIUM_CAP_BPS`, `DEFAULT_TAKER_NOTIONAL_FEE_BPS`,
  `DEFAULT_TAKER_PREMIUM_CAP_BPS`, `FEE_BPS_CAP`.
- Produces: `COLLATERAL_VAULT`, `ORACLE_ROUTER`,
  `OPTION_PRODUCT_REGISTRY`, `MARGIN_ENGINE`, `RISK_MODULE`,
  `PERP_MARKET_REGISTRY`, `PERP_ENGINE`, `PERP_RISK_MODULE`,
  `COLLATERAL_SEIZER`, `FEES_MANAGER`, `INSURANCE_FUND`,
  `MATCHING_ENGINE`, `PERP_MATCHING_ENGINE`, `PROTOCOL_TIMELOCK`,
  `RISK_GOVERNOR`.

### DeployOptionMatchingEngine

- Required: `DEPLOYER_PRIVATE_KEY`, `MARGIN_ENGINE`,
  `OPTION_PRODUCT_REGISTRY`.
- Optional/defaulted: `INITIAL_OWNER`.
- Produces: `OPTION_MATCHING_ENGINE_ADDR`.
- Production implication: if `OPTION_MATCHING_ENGINE_ADDR` is nonzero when
  `WireCore.s.sol` runs, `MarginEngine.matchingEngine` is set to
  `OptionMatchingEngine`. The legacy `MATCHING_ENGINE` remains deployed and
  configurable, but it is no longer authorized to call `MarginEngine.applyTrade`.

### WireCore

- Required: `DEPLOYER_PRIVATE_KEY`, all `DeployCore` output addresses.
- Optional/defaulted: `INITIAL_GUARDIAN`, `OPTION_MATCHING_ENGINE_ADDR`.

### ConfigureCore

- Required: `DEPLOYER_PRIVATE_KEY`, `COLLATERAL_VAULT`, `RISK_MODULE`,
  `PERP_RISK_MODULE`, `MARGIN_ENGINE`, `OPTION_PRODUCT_REGISTRY`,
  `PERP_MARKET_REGISTRY`, `FEES_MANAGER`, `INSURANCE_FUND`,
  `BASE_COLLATERAL_TOKEN`.
- Optional/defaulted: `BASE_COLLATERAL_DECIMALS`,
  `BASE_MAINTENANCE_MARGIN_PER_CONTRACT_BASE`, `IM_FACTOR_BPS`,
  `ORACLE_DOWN_MM_MULTIPLIER_BPS`, `RISK_MAX_ORACLE_DELAY`,
  `PERP_RISK_MAX_ORACLE_DELAY`, `COLLATERAL_RESTRICTION_MODE`,
  `ALLOW_COLLATERAL_AS_SETTLEMENT_ASSETS`, fee defaults,
  `COLLATERAL_TOKENS`, `COLLATERAL_DECIMALS`, `COLLATERAL_FACTORS_BPS`,
  `COLLATERAL_WEIGHTS_BPS`, `COLLATERAL_DEPOSIT_CAPS`,
  `COLLATERAL_LAUNCH_ACTIVE`, `COLLATERAL_RISK_ENABLED`,
  `INSURANCE_TOKEN_ALLOWED`, `INSURANCE_OPERATORS`.

### Mock Assets And Feeds

- `DeployTestnetAssets.s.sol`: `DEPLOYER_PRIVATE_KEY`,
  `TESTNET_MOCKS_ENABLED=true`, optional `DEPLOY_TESTNET_MOCK_USDC`,
  `DEPLOY_TESTNET_MOCK_ETH`, `DEPLOY_TESTNET_MOCK_BTC`,
  `TESTNET_MOCK_TOKEN_OWNER`, `TESTNET_MOCK_MINT_RECEIVER`, and mint amounts.
- `DeployLocalMockFeeds.s.sol`: `DEPLOYER_PRIVATE_KEY`, optional
  `ETH_USDC_MOCK_PRICE_1E8`, `BTC_USDC_MOCK_PRICE_1E8`, `ORACLE_ROUTER`.
- `DeployTestnetMockFeeds.s.sol`: `DEPLOYER_PRIVATE_KEY`,
  `TESTNET_MOCKS_ENABLED=true`, optional `DEPLOY_TESTNET_SECONDARY_FEEDS`,
  mock prices, `CHAIN_ID`, `ORACLE_ROUTER`.
- Refresh scripts require `DEPLOYER_PRIVATE_KEY`, the relevant feed source
  addresses, mock prices, and testnet mock guards where applicable.

### ConfigureMarkets And VerifyDeployment

- Required addresses: `ORACLE_ROUTER`, `OPTION_PRODUCT_REGISTRY`,
  `MARGIN_ENGINE`, `PERP_MARKET_REGISTRY`, `PERP_ENGINE`,
  `BASE_COLLATERAL_TOKEN`, `ETH_UNDERLYING`, `BTC_UNDERLYING`.
- Required oracle vars: `ETH_USDC_PRIMARY_SOURCE`,
  `ETH_USDC_SECONDARY_SOURCE`, `ETH_USDC_MAX_DELAY`,
  `ETH_USDC_MAX_DEVIATION_BPS`, `ETH_USDC_FEED_ACTIVE`,
  `BTC_USDC_PRIMARY_SOURCE`, `BTC_USDC_SECONDARY_SOURCE`,
  `BTC_USDC_MAX_DELAY`, `BTC_USDC_MAX_DEVIATION_BPS`,
  `BTC_USDC_FEED_ACTIVE`, `ORACLE_ROUTER_MAX_DELAY`.
- Required option vars for `ETH_OPTION` and `BTC_OPTION`: oracle, spot shocks,
  vol shocks, underlying enabled flag, base MM per contract, IM factor, and
  oracle-down MM multiplier.
- Required option series vars for ETH and BTC: expiries, strikes in `1e8`,
  call flags, European flags, registry active flags, activation states, and
  short OI caps.
- Required perp vars for ETH and BTC: symbol, oracle, registry active,
  close-only, engine activation state, launch OI cap in `1e8`, margin BPS,
  liquidation config, max position and OI in `1e8`, reduce-only flag, and
  funding config.
- `VerifyDeployment.s.sol` also requires the core config and collateral arrays
  so it can compare actual state against the manifest-backed env exactly.
- Optional option execution vars: `OPTION_MATCHING_ENGINE_ADDR`,
  `OPTION_MATCHING_ENGINE_OWNER`, `OPTION_MATCHING_EXECUTOR`,
  `OPTION_MATCHING_EXECUTORS`, `OPTION_MATCHING_EXECUTOR_ALLOWED`. When
  `OPTION_MATCHING_ENGINE_ADDR` is zero or unset, option matching verification is
  skipped and legacy `MATCHING_ENGINE` remains the expected option ingress.

### Ownership Handoff

- `TransferOwnerships.s.sol` requires all core addresses plus
  `GOVERNANCE_OWNER`, `TIMELOCK_OWNER`, `RISK_GOVERNOR_OWNER`,
  `GOVERNANCE_GUARDIAN`, `TIMELOCK_PROPOSERS`,
  `TIMELOCK_PROPOSER_ALLOWED`, `TIMELOCK_EXECUTORS`,
  `TIMELOCK_EXECUTOR_ALLOWED`.
- Optional executor arrays: `MATCHING_EXECUTORS`,
  `MATCHING_EXECUTOR_ALLOWED`, `PERP_MATCHING_EXECUTORS`,
  `PERP_MATCHING_EXECUTOR_ALLOWED`, `OPTION_MATCHING_EXECUTORS`,
  `OPTION_MATCHING_EXECUTOR_ALLOWED`.
- Optional price source ownership arrays: `PRICE_SOURCES`,
  `PRICE_SOURCE_OWNERS`.
- `AcceptOwnerships.s.sol` requires all core addresses plus
  `GOVERNANCE_OWNER`, `FINAL_GOVERNANCE_OWNER`, `DEPLOYER_ADDRESS`, and
  optional `TIMELOCK_OWNER`, `RISK_GOVERNOR_OWNER`,
  `OPTION_MATCHING_ENGINE_ADDR`, `PRICE_SOURCES`, `PRICE_SOURCE_OWNERS`.
- EOA acceptance requires the relevant owner private key env var. Timelock
  acceptance requires `TIMELOCK_EXECUTOR_PRIVATE_KEY` and
  `TIMELOCK_ACCEPT_ETA` after accept calls are queued.

## Dry-Run Command Templates

Default V1A dry-run validation is the no-RPC validation block above.

Script dry-runs are operator-only simulations. They can still require private
key env vars because the scripts derive sender addresses and use
`vm.startBroadcast`, but they must omit `--broadcast`.

```bash
forge script script/DeployCore.s.sol
forge script script/DeployOptionMatchingEngine.s.sol
forge script script/WireCore.s.sol
forge script script/ConfigureCore.s.sol
forge script script/ConfigureMarkets.s.sol
forge script script/VerifyDeployment.s.sol
forge script script/TransferOwnerships.s.sol
forge script script/AcceptOwnerships.s.sol
```

For local Anvil or testnet simulations against live state, add `--rpc-url` only
inside an operator environment. Do not add `--broadcast` to a dry-run command.

## Dangerous Manual Broadcast Commands

The following command shapes mutate chain state. They are intentionally separated
from validation and must never be run by default:

```bash
forge script script/DeployTestnetAssets.s.sol --rpc-url $RPC_URL --broadcast
forge script script/DeployCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/DeployOptionMatchingEngine.s.sol --rpc-url $RPC_URL --broadcast
forge script script/WireCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/ConfigureCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/DeployTestnetMockFeeds.s.sol --rpc-url $RPC_URL --broadcast
forge script script/ConfigureMarkets.s.sol --rpc-url $RPC_URL --broadcast
forge script script/RefreshTestnetMockFeeds.s.sol --rpc-url $RPC_URL --broadcast
forge script script/TransferOwnerships.s.sol --rpc-url $RPC_URL --broadcast
forge script script/AcceptOwnerships.s.sol --rpc-url $RPC_URL --broadcast
```

Local Anvil broadcast commands are also state-changing, even though they target a
throwaway chain.

## Manifest Requirements

Start from `deployments/DEPLOYMENT_MANIFEST.example.json` and write a filled copy
outside committed secrets. The manifest must capture:

- network name, chain id, RPC and explorer references without credentials
- exact git commit, Foundry version, and validation command results
- every script phase, transaction hash, block number, and operator signer
- all deployed core contract addresses
- optional `OptionMatchingEngine` address, selected option ingress, and executor
  allowlist when option on-chain execution is enabled
- collateral tokens, decimals, caps, launch-active flags, and risk weights
- oracle source addresses, max delay, deviation limits, activity, and price scale
- option series ids, expiries, strikes, activation states, and short OI caps
- perp market ids, activation states, close-only flags, launch caps, and risk config
- final owners, pending owners, guardians, timelock roles, executors, and operators
- `VerifyDeployment.s.sol` status, block number, timestamp, and reviewer

## Expected Artifacts

- Filled deployment manifest for the specific rehearsal.
- Foundry validation output for `forge fmt --check`, `forge build`, and
  `forge test`.
- Broadcast artifacts only for manual local/testnet runs.
- Read-only `VerifyDeployment.s.sol` pass evidence.
- Ownership handoff evidence from `TransferOwnerships.s.sol` and
  `AcceptOwnerships.s.sol` when handoff is part of the rehearsal.

## Rollback And Abort Limits

There is no protocol-level rollback script. Before activation, a failed rehearsal
is handled by stopping, preserving evidence, correcting env or configuration if
safe, or abandoning/redeploying the faulty environment. After any activation,
use the incident procedures in `RUNBOOK.md`; do not treat redeploy as a user
state rollback.

Abort immediately if chain id, deployer, bytecode, dependency wiring, oracle
freshness, unit scale, owner, guardian, executor, collateral cap, launch cap, or
`VerifyDeployment.s.sol` output differs from the manifest.

## Troubleshooting

- Missing env: compare the failing variable to `.env.local.example`,
  `.env.base-sepolia.example`, and the manifest.
- `no code`: the address was not deployed on the selected chain, the wrong chain
  is selected, or the manifest is stale.
- `optionMatching.marginEngine` or `margin.matchingEngine` mismatch: confirm
  whether `OPTION_MATCHING_ENGINE_ADDR` was intentionally set before `WireCore`.
  `MarginEngine` authorizes only one option matching engine at a time.
- `CHAIN_ID mismatch`: the loaded env file is for a different chain.
- Oracle price unavailable: refresh controlled mock feeds or verify the external
  source adapter, max delay, active flag, and scale.
- Option expiry in past: update rehearsal expiries before market configuration.
- Pending owner mismatch: stop and reconcile `TransferOwnerships.s.sol` output
  against the manifest before attempting acceptance.
- `VerifyDeployment.s.sol` failure: do not hand off ownership or activate any
  product until the exact mismatch is understood and corrected.
