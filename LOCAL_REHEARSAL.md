# LOCAL_REHEARSAL.md

## Purpose

This is the local-only Anvil rehearsal flow for DeOpt v2. It uses placeholder local token addresses, local `MockPriceSource` feeds, Anvil private keys, and inactive/close-only markets. Do not reuse this procedure as production deployment guidance.

## Known Local Warning

Two contracts exceed the EIP-170 24,576-byte contract size limit. Local Anvil rehearsal works only because Anvil is started with `--code-size-limit 50000`. This must be fixed before real testnet or mainnet deployment.

## Full Flow

Start Anvil:

```bash
anvil --host 127.0.0.1 --port 8545 --code-size-limit 50000 --gas-limit 200000000
```

Create the local env file:

```bash
cp .env.local.example .env.local
```

Load env before each phase after editing `.env.local`:

```bash
set -a
source .env.local
set +a
```

Deploy core:

```bash
forge script script/DeployCore.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Copy the `DeployCore` outputs into `.env.local`:

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

Reload env:

```bash
set -a
source .env.local
set +a
```

Wire and configure core:

```bash
forge script script/WireCore.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
forge script script/ConfigureCore.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Deploy local mock feeds:

```bash
forge script script/DeployLocalMockFeeds.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Copy the printed mock feed env lines into `.env.local`:

```bash
ETH_USDC_PRIMARY_SOURCE=<ethPrimary>
ETH_USDC_SECONDARY_SOURCE=<ethSecondary>
BTC_USDC_PRIMARY_SOURCE=<btcPrimary>
BTC_USDC_SECONDARY_SOURCE=<btcSecondary>
ETH_OPTION_ORACLE=<ethPrimary>
BTC_OPTION_ORACLE=<btcPrimary>
```

Reload env:

```bash
set -a
source .env.local
set +a
```

Configure markets:

```bash
forge script script/ConfigureMarkets.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Refresh mocks immediately before verification because local mock feeds can become stale under `maxDelay=60`:

```bash
forge script script/RefreshLocalMockFeeds.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

Verify deployment:

```bash
forge script script/VerifyDeployment.s.sol --rpc-url http://127.0.0.1:8545
```

Run ownership handoff:

```bash
forge script script/TransferOwnerships.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
forge script script/AcceptOwnerships.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
```

## Expected Result

`VerifyDeployment` logs:

```text
DeOpt v2 deployment verification OK
```

`AcceptOwnerships` logs every core module, `ProtocolTimelock`, and `RiskGovernor` owner as:

```text
0x70997970C51812dc3A010C7d01b50e0d17dc79C8
```

and each `pendingOwner` as:

```text
0x0000000000000000000000000000000000000000
```
