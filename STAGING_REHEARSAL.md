# STAGING_REHEARSAL.md

## Purpose

Defines the staging rehearsal plan for DeOpt v2.

This document is a rehearsal and evidence plan only. It does not change protocol logic, deployment scripts, ownership, economics, parameters, or contract behavior.

---

## Rehearsal Objectives

The staging rehearsal must prove that a production-like DeOpt v2 deployment can be executed, operated, monitored, and safely rolled back before mainnet launch.

Required objectives:

- Deploy the full protocol stack from scratch on the staging environment.
- Wire all dependencies according to `DEPLOYMENT_PLAN.md`.
- Configure core collateral, risk, fee, insurance, oracle, and settlement surfaces.
- Configure initial ETH/BTC option series and ETH/BTC perp markets from the active manifest.
- Verify deployment bytecode, wiring, parameters, roles, oracles, markets, caps, and launch controls.
- Transfer and accept ownership according to `ROLE_MATRIX.md`.
- Activate markets and series progressively with launch caps and close-only/restricted controls.
- Exercise monitoring dashboards, alerts, and event indexing from `MONITORING_SPEC.md`.
- Execute runbook procedures from `RUNBOOK.md` for launch, incident response, governance, insurance, and rollback.
- Produce evidence sufficient for a mainnet readiness decision.

---

## Rehearsal Assumptions

- The rehearsal uses a staging or testnet deployment with production-like topology.
- The active deployment manifest is cloned from `deployments/testnet.template.json` or a staging-specific derivative.
- USDC remains the base collateral token with 6 decimals unless the manifest explicitly says otherwise.
- Prices returned to protocol consumers remain normalized to `1e8`.
- BPS values use `10_000`.
- Initial product scope is limited to ETH/BTC options and ETH/BTC perps.
- Mock price sources are allowed only in local or explicitly approved staging/testnet contexts.

---

## Rehearsal Phases

### 1. Environment Preparation

Required actions:

1. Select staging chain, RPC, explorer, deployer, final owner, guardian, proposers, executors, matching executors, settlement operator, insurance operator, treasury, and oracle/feed admin.
2. Fill a staging deployment manifest with all required addresses, tokens, oracle sources, roles, guardians, caps, and launch controls.
3. Confirm `forge build` passes on the exact commit under rehearsal.
4. Confirm monitoring indexer and dashboards are configured to ingest the staging manifest.
5. Confirm alert routing for `P0`, `P1`, and `P2` staging alerts.
6. Confirm runbook operators and signers are available for the rehearsal window.

Exit criteria:

- Manifest is syntactically valid.
- No unresolved staging placeholders remain for deployed or externally supplied addresses.
- Monitoring can ingest the manifest and role matrix.

### 2. Deployment Sequence

Required actions:

1. Deploy from scratch using `script/DeployCore.s.sol`.
2. Record all deployed addresses into the staging manifest.
3. Confirm bytecode exists for every core module.
4. Record deployment block and transaction hashes.

Exit criteria:

- Core module address set is complete.
- No duplicate or zero core addresses exist unless explicitly intentional.
- Deployment events are indexed.

### 3. Configuration Sequence

Required actions:

1. Wire dependencies with `script/WireCore.s.sol`.
2. Configure collateral, risk, fee, insurance, and settlement basics with `script/ConfigureCore.s.sol`.
3. Configure oracle feeds, option underlyings, option series, perp markets, launch caps, and activation states with `script/ConfigureMarkets.s.sol`.
4. Keep markets/series inactive, restricted, or close-only until activation phase.

Exit criteria:

- Vault, risk modules, engines, oracle router, collateral seizer, fees manager, insurance fund, and matching engines point to expected dependencies.
- Collateral config, risk parameters, fee defaults, insurance allowlists, and launch controls match the manifest.
- Oracle feeds are fresh, nonzero, active only where intended, and scaled to `1e8`.

### 4. Ownership / Governance Handoff

Required actions:

1. Run `script/VerifyDeployment.s.sol` before handoff.
2. Run `script/TransferOwnerships.s.sol`.
3. Confirm pending owners, guardians, timelock proposers/executors, matching executors, insurance operators, backstop callers, settlement operators, and price-source transfers.
4. Run `script/AcceptOwnerships.s.sol`.
5. Confirm final owners and cleared pending owners.
6. Run a harmless governance queue/cancel/execute rehearsal where staging timing permits.

Exit criteria:

- No core module is still owned by the deployer unless explicitly documented for staging.
- `ROLE_MATRIX.md`, manifest roles, and onchain roles match.
- Monitoring has indexed all ownership and role changes.

### 5. Market Activation

Required actions:

1. Activate collateral in the approved launch set only.
2. Activate one option series or one perp market at a time.
3. Start with inactive or restricted state, then close-only where applicable, then active only after smoke tests pass.
4. Keep launch OI caps and short-OI caps at staging-approved values.
5. Confirm monitoring sees activation, cap, and close-only state changes.

Exit criteria:

- Active products match the manifest.
- Caps are enforced and visible.
- No unapproved product is active.

### 6. Functional Smoke Tests

Required actions:

1. Execute user deposit and withdraw.
2. Execute option open, close, and settlement.
3. Execute perp open, reduce, close, and funding update.
4. Execute liquidation with collateral seizure.
5. Exercise insurance coverage and residual bad debt paths in controlled staging accounts.
6. Confirm all expected events and views are indexed.

Exit criteria:

- State transitions match expected accounting.
- No unexpected bad debt, shortfall, role drift, pause, or oracle alert occurs outside the controlled drills.

### 7. Incident Drills

Required actions:

1. Execute oracle stale incident drill.
2. Execute matching executor compromise drill.
3. Execute emergency close-only activation drill.
4. Execute collateral cap saturation drill.
5. Execute launch OI cap nearing limit drill.
6. Record detection source, alert id, operator response, verification, and recovery evidence.

Exit criteria:

- Alerts fire with expected severity.
- Operators follow `RUNBOOK.md`.
- Recovery and unpause criteria are verified.

### 8. Rollback Drills

Required actions:

1. Abort before market activation using inactive products.
2. Roll back after partial activation using restricted or close-only states.
3. Simulate full activation rollback using targeted pauses and close-only states.
4. Verify withdrawals remain available where safe.
5. Confirm monitoring records pause, close-only, and recovery events.

Exit criteria:

- Operators can halt expansion without broad unrelated changes.
- Affected modules return to the expected manifest state after recovery.

### 9. Final Evidence Collection

Required actions:

1. Freeze staging manifest copy used for rehearsal.
2. Export verification outputs, monitoring logs, dashboard screenshots, alert ids, and transaction list.
3. Collect incident drill logs and governance operation logs.
4. Collect failed or reverted transaction log.
5. Produce final rehearsal report with pass/fail decision and open issues.

Exit criteria:

- Evidence is sufficient for a mainnet readiness review.
- Any failed criteria has an owner, severity, and remediation path.

---

## Required Scenarios

Each scenario must be executed with controlled staging accounts and bounded values. Any unexpected revert, alert, role drift, cap drift, or accounting mismatch must be recorded in the failed/reverted transaction log.

### Scenario Matrix

| Scenario | Setup | Action | Expected Result | Contracts / Modules Involved | Monitoring Alert Expected | Evidence To Capture |
| --- | --- | --- | --- | --- | --- | --- |
| User deposit / withdraw | USDC configured as launch-active collateral; vault unpaused; user has approved token spend | Deposit a small USDC amount, then withdraw a safe portion | `Deposited` and `Withdrawn` events are indexed; vault balance changes by token-native amounts; risk views remain coherent | `CollateralVault`, `RiskModule`, USDC token | No critical alert; dashboard should record deposit/withdraw activity | Tx hashes, user balance before/after, vault balance, dashboard panel, event logs |
| Option open / close / settlement | One option series configured with fresh oracle price, settlement asset allowed, matching executor authorized | Open a small option position, close it, advance to expiry/finality in staging if possible, finalize settlement and settle account | Trade, premium, fee, settlement, and account settlement events are indexed; open-series index clears after close/settlement | `OptionProductRegistry`, `MarginEngine`, `RiskModule`, `CollateralVault`, `MatchingEngine`, `FeesManager`, `OracleRouter` | No critical alert; options dashboard should show lifecycle state changes | Trade txs, settlement txs, option id, position before/after, fee event, settlement accounting |
| Perp open / reduce / close | One perp market configured with fresh oracle price, funding config, launch OI cap, matching executor authorized | Open a small perp position, reduce it, then close it | Position size updates correctly; open interest increases then decreases; realized PnL and fees are explicit | `PerpMarketRegistry`, `PerpEngine`, `PerpRiskModule`, `CollateralVault`, `PerpMatchingEngine`, `FeesManager`, `OracleRouter` | No critical alert; perp dashboard should show OI and position state | Trade txs, position views, OI before/after, fee event, account risk after each step |
| Perp funding update | Perp market active or staging-enabled for funding; oracle fresh; funding interval elapsed or staged time advanced | Trigger funding update and settle funding on a position where available | `FundingUpdated` and position funding state are indexed; funding stays within configured clamp | `PerpEngine`, `PerpMarketRegistry`, `OracleRouter`, `PerpRiskModule` | No critical alert; funding dashboard update expected | Funding tx, market state before/after, funding config, oracle timestamp |
| Liquidation with collateral seizure | Controlled trader has undercollateralized position and configured collateral balance; seizer token config enabled | Trigger liquidation with collateral seizure path | Liquidation reduces risk; seized collateral is bounded by plan; penalty and cashflow events are explicit | `MarginEngine` or `PerpEngine`, `CollateralSeizer`, `CollateralVault`, `RiskModule`, `PerpRiskModule`, `OracleRouter` | Liquidation event visible; no spike alert unless intentionally triggered | Liquidation tx, pre/post account risk, seizure plan, seized amount, liquidator credit |
| Insurance coverage path | Controlled account shortfall exceeds seized collateral but insurance fund has sufficient allowed balance | Execute settlement or liquidation path that consumes insurance coverage | Insurance coverage event is emitted; payout is bounded by available fund balance; residual bad debt remains zero if fully covered | `InsuranceFund`, `MarginEngine` or `PerpEngine`, `CollateralVault`, `CollateralSeizer` | Insurance coverage event; no low-balance alert unless threshold intentionally crossed | Coverage tx, fund balance before/after, coverage amount, account resolution event |
| Residual bad debt path | Controlled account shortfall exceeds collateral and available insurance in staging only | Execute liquidation or settlement that records residual bad debt | Residual bad debt event is emitted; aggregate bad debt increases; affected account is blocked or reduce-only where applicable | `PerpEngine` or `MarginEngine`, `InsuranceFund`, `CollateralVault`, `RiskModule` | `P0` residual bad debt alert expected | Bad debt tx, residual amount, account status, aggregate bad debt view, alert id |
| Governance parameter change through timelock | Timelock proposer/executor configured; harmless parameter selected; expected post-state defined | Queue, review, wait until eta, execute, and verify post-state | Queue and execute events indexed; post-state equals expected value; no unrelated state drift | `ProtocolTimelock`, `RiskGovernor`, target module such as `FeesManager` or risk config module | Governance queue/execute event; no unsafe-operation alert | Queue tx, operation hash, decoded calldata, ETA, execute tx, post-state read |
| Oracle stale incident | Staging oracle source can be made stale or inactive safely | Stop updating source or advance time beyond max delay, then attempt protected read/path | Oracle stale alert fires; protected paths fail closed or operators pause/close-only affected products per runbook | `OracleRouter`, price sources, `RiskModule`, `PerpRiskModule`, engines, registries | `P1` oracle stale alert expected | Alert id, stale timestamp, failed read/tx, pause or close-only tx, recovery tx |
| Matching executor compromise incident | Matching executor allowlist includes current executor; replacement executor prepared | Simulate compromise by submitting from unknown executor or revoking current executor and rotating | Unknown executor fails or alert fires; compromised executor is revoked; replacement is authorized; matching resumes only after verification | `MatchingEngine`, `PerpMatchingEngine`, `MarginEngine`, `PerpEngine`, `ProtocolTimelock` | `P1` matching executor drift or unexpected submission alert expected | Failed/blocked tx, `ExecutorSet` events, old/new executor state, service rotation note |
| Emergency close-only activation | Market/series active; guardian or owner available; monitoring active | Set affected market/series close-only or restricted using approved emergency path | New exposure is blocked; reduce/close flow remains possible where designed; close-only event indexed | `MarginEngine`, `PerpEngine`, `OptionProductRegistry`, `PerpMarketRegistry`, matching engines | `P1` emergency flag/close-only alert expected | Close-only tx, activation state before/after, attempted blocked open, successful reduce/close |
| Collateral cap saturation | Collateral deposit cap configured low for staging; test accounts funded | Deposit until warning threshold and near-full threshold are reached | Cap utilization dashboard updates; warning alert fires near configured threshold; deposits above cap fail or are blocked | `CollateralVault`, `RiskModule`, collateral token | `P2` collateral cap near full alert expected | Deposit txs, cap value, utilization chart, failed over-cap tx if applicable |
| Launch OI cap nearing limit | Market or option series launch cap configured low for staging | Execute trades until OI reaches warning threshold without exceeding approved cap | OI cap utilization alert fires; further risk-increasing trades near/above cap are blocked or require governance decision | `PerpEngine`, `MarginEngine`, `PerpMarketRegistry`, `OptionProductRegistry`, matching engines | `P2` market OI near cap alert expected | Trade txs, OI before/after, cap value, alert id, blocked trade or close-only decision |

---

## Pass / Fail Criteria

### Pass Criteria

The rehearsal passes only if all of the following are true:

- Full deployment from scratch completes on the staging environment.
- All core addresses are recorded in the deployed address manifest.
- `VerifyDeployment.s.sol` passes against the final configured stack.
- Ownership transfer and acceptance complete with no deployer-owned production-style modules remaining.
- Role matrix confirmation matches onchain role state and the manifest.
- Markets and series activate progressively with approved caps and no unintended active products.
- Required functional smoke tests pass.
- Required incident drills produce expected alerts and follow `RUNBOOK.md`.
- Rollback drills preserve safe exits where applicable and return modules to expected state.
- Governance parameter change through timelock is queued, reviewed, executed, and verified.
- Insurance coverage and residual bad debt paths are explicit and bounded in controlled staging accounts.
- Monitoring indexes events and view polls for deposits, withdrawals, trades, funding, liquidations, settlement, insurance, bad debt, oracle, governance, roles, pauses, and caps.
- Final evidence package is complete.

### Fail Criteria

The rehearsal fails if any of the following occur:

- Any required script fails without a documented and resolved cause.
- Any core dependency pointer, owner, guardian, proposer, executor, matching executor, insurance operator, backstop caller, settlement operator, oracle/feed admin, or treasury address mismatches the manifest unexpectedly.
- Any active oracle feed is stale, zero, unavailable, future-dated, incorrectly scaled, or points to an unexpected source outside a controlled drill.
- Any product activates before verification and ownership handoff.
- Any cap is missing, unenforced, or materially different from the manifest.
- Liquidation, settlement, insurance, or bad-debt accounting cannot be reconciled from events and views.
- Monitoring misses a required `P0` or `P1` alert.
- Rollback or emergency procedures cannot be executed by the assigned roles.
- Evidence is insufficient to reconstruct the rehearsal.

Failures must be assigned an owner, severity, remediation plan, and retest requirement before mainnet readiness can be approved.

---

## Required Artifacts

The final evidence package must include:

- Deployed address manifest with chain id, deployment block, core addresses, token addresses, oracle sources, roles, guardians, caps, launch controls, and verification placeholders updated.
- Verified config output from `VerifyDeployment.s.sol`.
- Role matrix confirmation showing expected vs actual owners, pending owners, guardians, proposers, executors, matching executors, insurance operators, backstop callers, settlement operators, oracle/feed admins, and fee recipients.
- Monitoring screenshots or logs for protocol overview, collateral/vault, risk, perp markets, options, liquidation, oracle health, insurance fund, and governance/roles dashboards.
- Incident drill logs for oracle stale, matching executor compromise, emergency close-only activation, collateral cap saturation, and launch OI cap nearing limit.
- Governance operation logs for queue, review, execute, cancel if tested, and post-state verification.
- Insurance operation logs for top-up, low-balance response if tested, backstop caller verification, coverage, and depletion response where applicable.
- Failed/reverted transaction log with tx hash, caller, target, revert reason if available, expected result, actual result, and disposition.
- Final rehearsal report with pass/fail decision, open issues, severity, owner, remediation plan, and retest scope.

---

## Mainnet Readiness Gate

Mainnet launch must not proceed until:

- The final rehearsal report is marked pass or all failures are explicitly waived by the approved governance/multisig process.
- The deployment manifest, role matrix, monitoring spec, runbook, and staging evidence agree on the expected launch state.
- All `P0` and `P1` rehearsal issues are resolved and retested.
- Any remaining `P2` issues have documented risk acceptance and monitoring coverage.

