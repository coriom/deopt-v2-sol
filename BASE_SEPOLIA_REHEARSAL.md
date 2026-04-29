# Base Sepolia Rehearsal

## Purpose

This is the Base Sepolia deployment rehearsal workflow for DeOpt v2. It prepares and executes the current staged deployment scripts on testnet without changing protocol economics or core contract behavior.

Mock assets and mock oracle feeds are allowed only for controlled testnet rehearsal. They are not production guidance.

## Preconditions

- `forge build` and `forge build --sizes` pass on the exact commit.
- The deployer address has Base Sepolia ETH for every broadcast phase.
- `.env.base-sepolia` is created from `.env.base-sepolia.example`.
- Every `REQUIRED_*` and relevant `FILL_*` value is replaced before the script that consumes it.
- Markets and option series remain inactive / close-only during this rehearsal.

Load env before each phase after editing:

```bash
set -a
source .env.base-sepolia
set +a
```

## 1. Create Env

```bash
cp .env.base-sepolia.example .env.base-sepolia
```

Fill at minimum:

- `RPC_URL`
- `DEPLOYER_PRIVATE_KEY`
- `DEPLOYER_ADDRESS`
- role addresses
- collateral token / underlying token addresses, or enable controlled testnet mocks
- oracle source addresses, or enable controlled testnet mock feeds
- option expiries, strikes, and caps
- perp launch caps and max sizes

## 2. Deploy Testnet Assets If Needed

Skip this phase if suitable Base Sepolia ERC20s already exist.

Set `TESTNET_MOCKS_ENABLED=true`, choose `DEPLOY_TESTNET_MOCK_*` values, and run:

```bash
forge script script/DeployTestnetAssets.s.sol --rpc-url $RPC_URL --broadcast
```

Copy printed addresses into `.env.base-sepolia`:

```bash
BASE_COLLATERAL_TOKEN=<MockUSDC>
COLLATERAL_TOKENS=<MockUSDC>
ETH_UNDERLYING=<MockWETH>
BTC_UNDERLYING=<MockWBTC>
```

Record addresses, block numbers, and tx hashes in `deployments/testnet.template.json` or a copied rehearsal artifact.

## 3. Deploy Core

```bash
forge script script/DeployCore.s.sol --rpc-url $RPC_URL --broadcast
```

Copy printed addresses into `.env.base-sepolia`:

```bash
COLLATERAL_VAULT=<CollateralVault>
ORACLE_ROUTER=<OracleRouter>
OPTION_PRODUCT_REGISTRY=<OptionProductRegistry>
MARGIN_ENGINE=<MarginEngine>
RISK_MODULE=<RiskModule>
PERP_MARKET_REGISTRY=<PerpMarketRegistry>
PERP_ENGINE=<PerpEngine>
PERP_RISK_MODULE=<PerpRiskModule>
COLLATERAL_SEIZER=<CollateralSeizer>
FEES_MANAGER=<FeesManager>
INSURANCE_FUND=<InsuranceFund>
MATCHING_ENGINE=<MatchingEngine>
PERP_MATCHING_ENGINE=<PerpMatchingEngine>
PROTOCOL_TIMELOCK=<ProtocolTimelock>
RISK_GOVERNOR=<RiskGovernor>
```

Also set:

```bash
ETH_PERP_ORACLE=$ORACLE_ROUTER
BTC_PERP_ORACLE=$ORACLE_ROUTER
TIMELOCK_PROPOSERS=$RISK_GOVERNOR
```

Record deployment block numbers and tx hashes.

## 4. Wire Core

Reload env, then run:

```bash
forge script script/WireCore.s.sol --rpc-url $RPC_URL --broadcast
```

## 5. Configure Core

Reload env, then run:

```bash
forge script script/ConfigureCore.s.sol --rpc-url $RPC_URL --broadcast
```

## 6. Deploy Or Refresh Mock Feeds If Needed

Skip this phase if using externally supplied testnet oracle source contracts.

Deploy controlled testnet mock feeds:

```bash
forge script script/DeployTestnetMockFeeds.s.sol --rpc-url $RPC_URL --broadcast
```

Copy printed addresses into `.env.base-sepolia`:

```bash
ETH_USDC_PRIMARY_SOURCE=<ethPrimary>
ETH_USDC_SECONDARY_SOURCE=<ethSecondaryOrZero>
BTC_USDC_PRIMARY_SOURCE=<btcPrimary>
BTC_USDC_SECONDARY_SOURCE=<btcSecondaryOrZero>
ETH_OPTION_ORACLE=<ethPrimary>
BTC_OPTION_ORACLE=<btcPrimary>
```

Refresh mock feed timestamps immediately before verification if the configured `*_MAX_DELAY` is tight:

```bash
forge script script/RefreshTestnetMockFeeds.s.sol --rpc-url $RPC_URL --broadcast
```

## 7. Configure Markets

Reload env, then run:

```bash
forge script script/ConfigureMarkets.s.sol --rpc-url $RPC_URL --broadcast
```

Record emitted or printed market IDs and computed option series IDs in the rehearsal artifact. Initial products should remain inactive / close-only.

## 8. Verify Deployment

If using mock feeds, refresh them first:

```bash
forge script script/RefreshTestnetMockFeeds.s.sol --rpc-url $RPC_URL --broadcast
```

Run read-only verification:

```bash
forge script script/VerifyDeployment.s.sol --rpc-url $RPC_URL
```

Expected output:

```text
DeOpt v2 deployment verification OK
```

## 9. Transfer Ownerships

Reload env and confirm `GOVERNANCE_OWNER`, `TIMELOCK_OWNER`, `RISK_GOVERNOR_OWNER`, `TIMELOCK_PROPOSERS`, `TIMELOCK_EXECUTORS`, matching executors, and optional `PRICE_SOURCES` are final.

```bash
forge script script/TransferOwnerships.s.sol --rpc-url $RPC_URL --broadcast
```

## 10. Accept Ownerships

If owners are EOAs, load the corresponding owner private keys locally. If ownership is accepted through `ProtocolTimelock`, set `TIMELOCK_EXECUTOR_PRIVATE_KEY` and `TIMELOCK_ACCEPT_ETA` after queuing the accept calls.

```bash
forge script script/AcceptOwnerships.s.sol --rpc-url $RPC_URL --broadcast
```

## 11. Explorer Verification

Use Basescan for Base Sepolia. The exact constructor args are available in Foundry broadcast artifacts after each deployment.

Example shape:

```bash
forge verify-contract <address> <ContractName> \
  --chain 84532 \
  --verifier etherscan \
  --etherscan-api-key $BASESCAN_API_KEY
```

For constructor-argument contracts, include `--constructor-args` or `--constructor-args-path` from the broadcast artifact.

## Expected Artifacts

Create a copied artifact from `deployments/testnet.template.json` and fill:

- `chainMetadata.chainId`, RPC/explorer reference, deployment start/end blocks, and deployer
- tx hashes for every broadcast phase
- core module addresses
- mock/testnet asset addresses and owners
- oracle source addresses, source type, feed activity, prices, and freshness notes
- option series IDs, expiries, strikes, activation states, and short OI caps
- perp market IDs, symbols, activation states, close-only state, and caps
- final owners, guardians, timelock proposers/executors, matching executors, and insurance operators
- explorer verification status for each deployed contract

Stop after this workflow is prepared and verified. Product activation, smoke trading, incident drills, and monitoring evidence remain staging rehearsal tasks.
