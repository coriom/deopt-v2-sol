# MONITORING_SPEC.md

## Purpose

Defines the production monitoring and alerting specification for DeOpt v2.

This document is an offchain operations specification only. It does not change protocol logic, deployment scripts, parameters, ownership, economics, or contract behavior.

---

## Scope

The monitoring system must ingest the deployment manifest for the active environment, ingest `ROLE_MATRIX.md` as the expected authority model, index protocol events, poll selected views, and alert on safety, solvency, oracle, role, market-cap, and verification drift.

All indexed numeric values must preserve the unit encoded by the contract or manifest field:

- `...1e8`: normalized `1e8` units.
- `...Base`: native base-collateral units.
- `...Bps`: basis points where `10_000` is 100%.
- Token-native amounts: native token decimals from the deployment manifest or onchain token metadata.

---

## Critical Event Categories

### Deposits And Withdrawals

Index:

- `CollateralVault.Deposited(user, token, amount)`
- `CollateralVault.Withdrawn(user, token, amount)`
- `MarginEngine.CollateralDeposited(trader, token, amount)`
- `MarginEngine.CollateralWithdrawn(trader, token, amount, marginRatioAfterBps)`
- `PerpEngine.CollateralDeposited(trader, token, amount)`
- `PerpEngine.CollateralWithdrawn(trader, token, amount, marginRatioAfterBps)`
- Insurance fund vault movement events: `FundedFromOwner`, `DepositedToVault`, `WithdrawnFromVault`, `MovedToStrategy`, `MovedToIdle`, `Synced`

Required dimensions:

- Environment, chain id, block number, transaction hash, log index.
- Account, token, native amount, normalized base value when available.
- Post-action margin ratio where emitted.
- Manifest collateral config at the time of the event.

### Internal Transfers

Index:

- `CollateralVault.InternalTransfer(token, from, to, amount)`
- Vault yield movement events: `MovedToStrategy`, `MovedToIdle`, `Synced`

Required dimensions:

- Source account, destination account, token, amount, transfer authority.
- Whether either side is a core module, insurance fund, settlement sink, or treasury address from the manifest.

### Trades

Index:

- `MatchingEngine.TradeSubmitted`
- `MarginEngine.TradeExecuted`
- `PerpMatchingEngine.TradeExecuted`
- `PerpEngine.TradeExecuted`
- `NonceCancelled` events on both matching engines
- Fee events linked to trades: `TradingFeeCharged`

Required dimensions:

- Trader, counterparty or executor where available, option id or market id.
- Size, premium, price, direction, fee, fee recipient.
- Matching executor address and whether it is authorized by manifest and role matrix.
- Resulting open interest and cap utilization where available by view polling.

### Funding Updates

Index:

- `PerpEngine.FundingUpdated`
- `PerpEngine.PositionFundingSettled`
- Perp market funding config changes: `FundingConfigSet`

Required dimensions:

- Market id, funding index, funding rate, timestamp, elapsed interval.
- Trader-level funding settlement where emitted.
- Funding pause state at the time of update.

### Liquidations

Index:

- `MarginEngine.Liquidation`
- `MarginEngine.LiquidationCashflow`
- `PerpEngine.Liquidation`
- `PerpEngine.LiquidationPenaltyPaid`
- `PerpEngine.LiquidationResolved`
- Liquidation parameter updates: `LiquidationParamsSet`, `LiquidationHardenParamsSet`, `LiquidationPricingParamsSet`, `LiquidationOracleMaxDelaySet`, `LiquidationConfigSet`

Required dimensions:

- Liquidated account, liquidator, option id or market id, closed size.
- Pre/post margin ratio when available.
- Penalty, recovered collateral, insurance coverage, shortfall, residual bad debt.
- Oracle timestamp and stale status used by the liquidation path when inferable from polling.

### Collateral Seizure

Index:

- `MarginEngine.LiquidationSeize`
- `CollateralSeizer.TokenSeizeConfigSet`
- `CollateralSeizer.OracleMaxDelaySet`
- `CollateralSeizer.OracleSet`, `VaultSet`, `RiskModuleSet`

Required dimensions:

- Seized token, seized amount, seized value in base units when emitted or reconstructed.
- Spread/discount configuration and whether the token is enabled.
- Seizer wiring from manifest vs onchain state.

### Settlement

Index:

- `OptionProductRegistry.SettlementPriceProposed`
- `OptionProductRegistry.SettlementPriceFinalized`
- `OptionProductRegistry.SettlementProposalCancelled`
- `MarginEngine.AccountSettled`
- `MarginEngine.AccountSettlementResolved`
- `MarginEngine.SeriesSettlementAccountingUpdated`
- `MarginEngine.SettlementShortfall`
- `MarginEngine.SettlementCollectionShortfall`
- `MarginEngine.SettlementInsuranceCoverage`
- `MarginEngine.SettlementBadDebtRecorded`

Required dimensions:

- Option id, expiry, underlying, settlement price, proposal/finality timestamps.
- Trader, payoff, collected collateral, shortfall, insurance coverage, residual bad debt.
- Settlement operator address and whether it is expected for the environment.

### Insurance Coverage

Index:

- `InsuranceFund.VaultBackstopPaid`
- `MarginEngine.SettlementInsuranceCoverage`
- `PerpEngine.LiquidationInsuranceCoverage`
- Insurance authority/config changes: `OperatorSet`, `BackstopCallerSet`, `TokenAllowed`, `VaultSet`, `YieldOptInSet`

Required dimensions:

- Covered token, requested amount, paid amount, uncovered residual.
- Insurance fund idle balance, vault balance, strategy exposure, and threshold utilization.
- Caller and whether it is an authorized backstop caller.

### Residual Bad Debt

Index:

- `MarginEngine.SettlementBadDebtRecorded`
- `PerpEngine.LiquidationBadDebtRecorded`
- `PerpEngine.ResidualBadDebtUpdated`
- `PerpEngine.ResidualBadDebtRepaid`

Required dimensions:

- Account, option id or market id, new residual bad debt, repaid amount.
- Aggregate bad debt by module, account, market, option series, and base collateral token.
- Whether the account is reduce-only or blocked from increasing exposure by view state.

### Oracle Updates And Stale Failures

Index:

- `OracleRouter.FeedConfigured`
- `OracleRouter.FeedCleared`
- `OracleRouter.FeedStatusSet`
- `OracleRouter.MaxOracleDelaySet`
- `MockPriceSource.PriceUpdated` in local/test environments
- Read/config pause events on `OracleRouter`
- Price-source ownership and rescue events where applicable

Poll:

- `OracleRouter.getFeed(baseAsset, quoteAsset)`
- `OracleRouter.hasActiveFeed(baseAsset, quoteAsset)`
- `OracleRouter.getPrice(baseAsset, quoteAsset)`
- `IPriceSource.getLatestPrice()`

Required dimensions:

- Base asset, quote asset, source address, decimals, active flag, max delay.
- Last price, last updated timestamp, block timestamp, staleness age.
- Zero price, future timestamp, unavailable read, or reverted read status.

### Fee Collection

Index:

- `MarginEngine.TradingFeeCharged`
- `FeesManager.DefaultFeesSet`
- `FeesManager.FeeBpsCapSet`
- `FeesManager.MerkleRootSet`
- `FeesManager.TierClaimed`
- `FeesManager.OverrideSet`
- Fee recipient changes on option and perp engines.

Required dimensions:

- Trader, maker/taker side, notional fee, premium cap fee, final charged fee.
- Fee recipient and whether it matches manifest treasury.
- Fee profile source: default, tier, or override.

### Emergency Pauses And Close-Only Flags

Index all pause and emergency-mode events across:

- `CollateralVault`
- `RiskModule`
- `OptionProductRegistry`
- `MarginEngine`
- `PerpMarketRegistry`
- `PerpEngine`
- `PerpRiskModule`
- `FeesManager`
- `InsuranceFund`
- `MatchingEngine`
- `PerpMatchingEngine`
- `OracleRouter`
- `ProtocolTimelock`

Index launch and close-only controls:

- `SeriesActivationStateSet`
- `SeriesShortOpenInterestCapSet`
- `SeriesEmergencyCloseOnlySet`
- `SeriesEmergencyCloseOnlyUpdated`
- `MarketActivationStateSet`
- `LaunchOpenInterestCapSet`
- `MarketEmergencyCloseOnlySet`
- `MarketEmergencyCloseOnlyUpdated`
- Registry status events: `SeriesStatusUpdated`, `MarketStatusUpdated`

Required dimensions:

- Module, flag name, old value where emitted, new value, caller.
- Whether the new state matches the deployment manifest launch safety controls.

### Governance Queue, Cancel, Execute

Index:

- `ProtocolTimelock.TransactionQueued`
- `ProtocolTimelock.TransactionCancelled`
- `ProtocolTimelock.TransactionExecuted`
- `RiskGovernor.OperationQueued`
- `RiskGovernor.OperationCancelled`
- `RiskGovernor.OperationExecuted`
- `ProtocolTimelock.QueuePaused`
- `ProtocolTimelock.QueueUnpaused`
- `ProtocolTimelock.MinDelaySet`

Required dimensions:

- Transaction hash, target, value, calldata selector, ETA, execution timestamp.
- Proposer, executor, cancellation actor where recoverable.
- Target module classification and expected role from `ROLE_MATRIX.md`.
- Whether calldata mutates risk, oracle, pause, ownership, treasury, or insurance parameters.

### Ownership, Guardian, And Role Changes

Index:

- `OwnershipTransferStarted`
- `OwnershipTransferred`
- `GuardianSet`
- `ProposerSet`
- `ExecutorSet`
- `OperatorSet`
- `BackstopCallerSet`
- `SettlementOperatorSet`
- `SeriesCreatorSet`
- `MarketCreatorSet`
- `AuthorizedEngineSet`
- `MatchingEngineSet`, `MarginEngineSet`, `PerpEngineSet`, `RiskModuleSet`, `OracleSet`, `VaultSet`, `FeesManagerSet`, `InsuranceFundSet`, `CollateralSeizerSet`

Required dimensions:

- Module, changed role, previous address, new address, caller.
- Expected holder by environment from deployment manifest and role matrix.
- Pending owner state until accepted or canceled by replacement transfer.

---

## Minimum Dashboards

### Protocol Overview

Must show:

- Environment, chain id, indexed block, finality lag, indexer health.
- Core contract address set from manifest with onchain bytecode presence.
- Total collateral value, total open interest, active option series, active perp markets.
- Global pause/emergency state across all modules.
- Active critical alerts by severity.
- Verification status placeholders from the deployment manifest and latest verification poll result.

### Collateral / Vault Dashboard

Must show:

- Token balances by account category: traders, insurance fund, treasury, strategy adapters.
- Deposit cap utilization per collateral token.
- Withdrawals, deposits, internal transfers, and yield movements over time.
- Enabled/disabled collateral tokens, weight BPS, factor BPS, decimals, caps.
- Vault pause flags: global, deposit, withdrawal, internal transfer, yield ops.
- Authorized engines and strategy adapter wiring.

### Risk Dashboard

Must show:

- Account risk distribution: equity, initial margin, maintenance margin, free collateral, margin ratio.
- Liquidatable accounts and near-liquidation accounts.
- Risk parameter changes and current values.
- Oracle-down multiplier, max oracle delay, collateral valuation pause state.
- Aggregate residual bad debt and accounts with reduce-only restrictions.

### Perp Markets Dashboard

Must show:

- Market ids, underlyings, quote/settlement assets, active and close-only flags.
- Long OI, short OI, skew, launch cap utilization, market activation state.
- Mark price, index price, oracle freshness, funding index, funding rate.
- Per-market risk, liquidation, and funding config.
- Trading, funding, liquidation, collateral ops, and global pause state.

### Options Dashboard

Must show:

- Option ids, underlyings, strikes, expiries, call/put type, active state.
- Engine activation state, emergency close-only state, short-OI cap utilization.
- Settlement lifecycle: pending, proposed, finalized, canceled, settled accounts.
- Series settlement accounting, settlement shortfalls, insurance coverage, bad debt.
- Option risk config and underlying config changes.

### Liquidation Dashboard

Must show:

- Liquidations per block, hour, and market/series.
- Liquidated accounts, liquidators, closed size, penalty, seized collateral, shortfall.
- Liquidation improvement and close factor data where available.
- Insurance coverage and bad debt produced by liquidation.
- Liquidation pause flags and liquidation parameter changes.

### Oracle Health Dashboard

Must show:

- Feed inventory by base/quote pair and source address.
- Current price, updated timestamp, age, max delay, active flag.
- Stale, zero, unavailable, future timestamp, and reverted read states.
- Feed config changes, feed clears, feed status changes, source owner changes.
- Price-source deviation between primary and fallback/source peers where available.

### Insurance Fund Dashboard

Must show:

- Idle and vault balances by token.
- Strategy exposure and yield opt-in state.
- Backstop payouts, settlement coverage, liquidation coverage, uncovered residuals.
- Token allowlist, operators, backstop callers, vault wiring.
- Funding, withdraw, yield ops, and global pause flags.

### Governance / Roles Dashboard

Must show:

- Owner and pending owner for every ownable module.
- Guardian, proposer, executor, operator, settlement operator, matching executor, oracle/feed admin, treasury, and emergency responder addresses.
- Role drift against deployment manifest and `ROLE_MATRIX.md`.
- Timelock queue, ETA, executable operations, canceled operations, executed operations.
- RiskGovernor queue/cancel/execute operations and decoded targets/selectors.

---

## Alert Rules

Severity levels:

- `P0`: Immediate incident response. Protocol solvency, control plane, or live trading safety may be at risk.
- `P1`: Urgent operator action required. Risk is material but not yet confirmed as protocol-wide loss or control failure.
- `P2`: Timely investigation required. Drift or threshold pressure may become unsafe if unattended.
- `P3`: Informational or routine operational follow-up.

| Alert | Severity | Source Event/View | Trigger Condition | Expected Operator Response | Escalation Path |
| --- | --- | --- | --- | --- | --- |
| Oracle stale | P1 | `OracleRouter.getPrice`, `IPriceSource.getLatestPrice`, feed `maxDelay` from manifest/onchain config | Any active feed age exceeds its configured max delay, or view reverts with a stale-data reason if decoded | Confirm source outage, compare independent price sources, pause affected reads/trading if stale data can affect margin, liquidation, settlement, or funding | Oracle/feed admin -> guardian/emergency responder -> multisig/timelock if config change is needed |
| Oracle zero | P0 | Same oracle views plus `PriceUpdated` in local/test | Any active feed returns price `0` or a zero value is emitted as the latest price | Treat feed as invalid, halt affected markets/series where possible, switch or disable the feed through approved governance path | Oracle/feed admin -> emergency responder -> multisig/timelock |
| Oracle unavailable | P1 | `OracleRouter.getPrice`, `hasActiveFeed`, feed status events | Active feed has no source, inactive status, cleared feed, no bytecode at source, or repeated read revert above retry threshold | Confirm manifest/onchain drift, pause affected operations if needed, restore feed or mark market close-only | Oracle/feed admin -> guardian/emergency responder -> multisig/timelock |
| Residual bad debt created | P0 | `SettlementBadDebtRecorded`, `LiquidationBadDebtRecorded`, `ResidualBadDebtUpdated`, `getTotalResidualBadDebt` | Any new residual bad debt greater than zero, or aggregate bad debt increases | Identify affected account and market/series, verify insurance coverage path, disable exposure increase where expected, prepare repayment or governance response | Emergency responder -> insurance operator -> multisig/timelock |
| Settlement shortfall | P0 | `SettlementShortfall`, `SettlementCollectionShortfall`, `AccountSettlementResolved`, `SeriesSettlementAccountingUpdated` | Any settlement shortfall or collection shortfall greater than zero | Freeze settlement runbook for affected series, verify settlement price and account balances, check insurance coverage and bad debt accounting | Settlement operator -> emergency responder -> insurance operator -> multisig/timelock |
| Liquidation spike | P1 | `Liquidation`, `LiquidationCashflow`, `LiquidationResolved` | Liquidation count or liquidated notional in a rolling window exceeds configured environment threshold, or exceeds baseline by configured multiple | Check oracle health and market move context, verify liquidators are not exploiting stale prices, consider close-only or liquidation pause if unsafe | Emergency responder -> guardian -> multisig/timelock |
| Insurance fund below threshold | P1 | Insurance fund balances, `VaultBackstopPaid`, `WithdrawnFromVault`, `MovedToStrategy`, token balances | Idle plus available vault balance for base collateral falls below manifest minimum or below required coverage threshold | Rebalance from strategy to idle, fund from owner/treasury if authorized, limit risky market activation until coverage is restored | Insurance operator -> treasury/multisig -> timelock if parameter change needed |
| Unexpected pause or emergency flag | P1 | `Paused`, `Unpaused`, `GlobalPauseSet`, module-specific pause events, close-only events, `EmergencyModeUpdated` | Any pause/close-only/emergency flag changes outside approved operation window or does not match manifest expected state | Identify caller and target, compare to incident ticket or governance action, publish operator status, verify no unauthorized role drift | Emergency responder -> guardian -> multisig/timelock |
| Ownership mismatch or role drift | P0 | Ownership/role events, periodic `owner`, `pendingOwner`, role view polling, manifest, `ROLE_MATRIX.md` | Any core owner, guardian, proposer, executor, matching executor, settlement operator, insurance operator, backstop caller, oracle/feed admin, or treasury differs from expected holder | Stop nonessential operations, verify transaction provenance, rotate compromised role if needed, queue ownership correction through timelock or multisig | Multisig -> timelock -> emergency responder for immediate pause if needed |
| Market OI near cap | P2 | `getMarketOpenInterest`, `marketState`, `LaunchOpenInterestCapSet`, trade events | Long or short OI reaches configured warning threshold, default `>= 80%` of launch/open-interest cap, or critical threshold, default `>= 95%` | Notify market operators, verify cap setting, decide whether to raise cap by governance or keep close-only posture | Market operator -> risk governor -> multisig/timelock |
| Collateral deposit cap near full | P2 | Vault collateral config views, `Deposited`, `CollateralTokenConfigured` | Token deposits reach configured warning threshold, default `>= 80%` of deposit cap, or critical threshold, default `>= 95%` | Review collateral concentration and liquidity, decide whether to raise cap, disable deposits, or add collateral capacity | Risk operator -> multisig/timelock |
| Failed verification check | P1 | Deployment manifest verification placeholders, periodic verification poller, bytecode and wiring reads | Any expected core address has no bytecode, wrong chain id, wrong module wiring, stale manifest hash, failed source verification status, or role matrix mismatch | Stop promotion to production, isolate changed field, rerun verification, correct manifest or governance state through approved path | Deployment owner -> multisig/timelock -> emergency responder if live system is affected |

Alert thresholds must be environment-specific and loaded from the deployment manifest or monitoring config. Mainnet thresholds must be stricter than local/testnet defaults and must not rely on placeholder values.

---

## Offchain Indexing Requirements

### Event Indexing

- Index all events listed in this document from deployment block onward for every address in the active deployment manifest.
- Store canonical keys as `(chainId, blockNumber, transactionHash, logIndex)`.
- Store decoded event name, module name, contract address, indexed topics, decoded fields, block timestamp, transaction sender, and transaction status.
- Classify every event into one or more monitoring categories.
- Preserve raw logs for decoder upgrades and audit replay.
- Decode calldata for governance queue/execute events at least to function selector, target module, and parameter class.

### Periodic View Polling

Poll at a cadence appropriate for the environment:

- Local/testnet: operator-configurable, default relaxed cadence.
- Mainnet: frequent polling for oracle, pause, role, cap, insurance, and verification state.

Minimum views to poll:

- Oracle: feed configs, active status, latest prices, timestamps.
- Vault: collateral configs, balances for treasury/insurance/core accounts, cap utilization where exposed.
- Risk: account risk for watched accounts, collateral tokens, risk parameters, free collateral and margin ratios.
- Options: series metadata, active state, settlement state/accounting, settlement prices.
- Perps: market metadata, market state, OI, skew, funding config, funding state, liquidation params.
- Insurance: token balances, vault/strategy movement state, operators, backstop callers.
- Governance/roles: owners, pending owners, guardians, proposers, executors, operators, settlement operator, matching executors.

Watched accounts must include governance addresses, treasury, insurance fund, matching executors, known liquidators, large traders, accounts with recent failed risk checks where available, and accounts with residual bad debt.

### Deployment Manifest Ingestion

- Load exactly one deployment manifest for the active environment.
- Validate JSON syntax before ingestion.
- Reject manifests with missing chain metadata, zero core addresses for required modules, placeholder mainnet addresses, or duplicate core module addresses unless explicitly marked as intentional.
- Ingest chain id, deployment block, core contracts, tokens, price sources, governance roles, guardians, matching executors, collateral/risk/fee/insurance config, option series, perp markets, launch safety controls, emergency controls, and verification placeholders.
- Keep manifest version/hash in every indexed alert and dashboard snapshot.

### Role Matrix Ingestion

- Parse `ROLE_MATRIX.md` or a derived structured role artifact produced from it.
- Build expected role ownership by module and environment.
- Compare role matrix expectations against deployment manifest and onchain role polling.
- Treat unresolved conflicts between manifest and role matrix as verification failures until explicitly waived for the environment.

### Chain Reorg Handling

- Use environment-specific finality depth:
  - Local: `1` block unless the local chain is reset.
  - Testnet: configurable, default at least `12` blocks.
  - Mainnet: configurable, default at least `64` blocks or the chain-specific finality policy.
- Mark alerts as provisional before finality and canonical after finality.
- If a reorg removes or changes an alerting event, close the provisional alert with reorg reason and replay from the last canonical block.
- Never drop raw orphaned logs; retain them with orphaned status for auditability.

### Alert Deduplication

- Deduplicate alerts by `(environment, chainId, alertType, affectedModule, affectedEntity, severity, conditionWindow)`.
- Escalate an existing alert when severity increases or the affected value crosses a higher threshold.
- Suppress repeated notifications only while the condition remains unchanged and acknowledged.
- Reopen alerts when the same condition reappears after resolution or after a new final block range.
- Store operator acknowledgement, response owner, escalation owner, resolution transaction hash, and postmortem link when applicable.

---

## Pre-Launch Monitoring Checklist

- Deployment manifest for the target environment is syntactically valid and loaded.
- `ROLE_MATRIX.md` has been ingested and checked against the manifest.
- All core addresses have bytecode on the expected chain.
- All expected events can be decoded by the indexer.
- Oracle feeds return nonzero, fresh prices with expected `1e8` normalization.
- Dashboard panels render for vault, risk, perps, options, liquidation, oracle, insurance, and governance.
- Alert routing is tested for all P0 and P1 alerts.
- Reorg replay is tested against a fork or local reset.
- Verification placeholder checks are wired to fail closed for mainnet.

---

## Post-Handoff Monitoring Checklist

- Every owner and pending owner matches the expected post-handoff state.
- Timelock proposers/executors match `ROLE_MATRIX.md`.
- Guardians, emergency responders, settlement operators, matching executors, insurance operators, backstop callers, oracle/feed admins, and treasury recipients match manifest expectations.
- No deployer address retains ownership or privileged roles unless explicitly documented for local/testnet.
- All launch caps, close-only flags, pause flags, collateral caps, and market/series activation states match the intended launch state.
- First live events for deposits, trades, funding, settlement, insurance, liquidation, governance, and role changes are decoded and classified correctly.

