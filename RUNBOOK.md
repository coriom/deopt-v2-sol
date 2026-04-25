# RUNBOOK.md

## Purpose

Production operations runbook for DeOpt v2.

This document is an operator procedure. It does not change protocol logic, deployment scripts, ownership, economics, parameters, or contract behavior.

---

## Operating Principles

- The active deployment manifest is the environment source of truth for addresses, chain id, launch caps, roles, guardians, oracle feeds, collateral config, and verification state.
- `ROLE_MATRIX.md` is the authority model for expected role holders.
- `MONITORING_SPEC.md` is the monitoring and alerting model for detection, escalation, and dashboards.
- Mainnet launch must fail closed: if a required check is inconclusive, do not activate markets.
- Values must keep their native units: `...1e8` is normalized price/contract scale, `...Base` is base-collateral native units, and `...Bps` uses `10_000`.

---

## Launch-Day Procedure

### 1. Pre-Launch Checks

Complete before any production transaction:

- Confirm the correct environment manifest is selected and contains no unresolved mainnet placeholders.
- Confirm chain id, RPC URL, explorer URL, deployment block policy, deployer, base collateral token, and token decimals.
- Confirm `forge build` passes on the exact commit to deploy.
- Confirm scripts are reviewed and the expected sequence is unchanged:
  - `script/DeployCore.s.sol`
  - `script/WireCore.s.sol`
  - `script/ConfigureCore.s.sol`
  - `script/ConfigureMarkets.s.sol`
  - `script/VerifyDeployment.s.sol`
  - `script/TransferOwnerships.s.sol`
  - `script/AcceptOwnerships.s.sol`
- Confirm all env vars are prepared from the manifest and independently reviewed.
- Confirm oracle feeds return nonzero fresh prices normalized to `1e8`.
- Confirm initial products are inactive/restricted and perp markets are close-only or inactive as intended.
- Confirm launch caps, collateral caps, fee recipient, insurance funding plan, guardians, matching executors, and settlement operators.
- Confirm monitoring is live for oracle, roles, ownership, pauses, caps, insurance, bad debt, settlement, liquidation, and verification checks.
- Confirm emergency responder, guardian Safe, governance/multisig, oracle/feed admin, insurance operator, and matching operator are reachable.
- Confirm no deployer EOA is expected to retain production ownership after handoff.

### 2. Deploy / Wire / Configure / Verify Sequence

Execute in this order only:

1. Run `DeployCore.s.sol`.
2. Record all emitted or printed contract addresses into the active deployment manifest.
3. Confirm bytecode exists at every core address.
4. Run `WireCore.s.sol`.
5. Verify dependency pointers for vault, risk modules, engines, oracle router, collateral seizer, insurance fund, fees manager, and matching engines.
6. Run `ConfigureCore.s.sol`.
7. Verify collateral config, base collateral, risk parameters, fee defaults, insurance allowlists, and base settlement asset allowlists.
8. Configure oracle price sources for the target environment.
9. Run `ConfigureMarkets.s.sol`.
10. Verify option underlyings, option series, perp markets, launch caps, activation states, close-only states, funding config, risk config, and liquidation config.
11. Run `VerifyDeployment.s.sol` read-only.
12. Update manifest verification placeholders only after the corresponding checks pass.

### 3. Ownership Handoff

Execute only after `VerifyDeployment.s.sol` passes:

1. Run `TransferOwnerships.s.sol`.
2. Confirm ownership transfer started for every expected core module.
3. Confirm guardians, timelock proposers/executors, matching executors, insurance operators, backstop callers, settlement operators, and price-source owner transfers match the manifest.
4. Run `AcceptOwnerships.s.sol` from the expected final owner or approved timelock context.
5. Confirm every owner and pending owner matches `ROLE_MATRIX.md` and the active manifest.
6. Confirm deployer no longer owns production modules.
7. Confirm monitoring has observed and classified the handoff events.

### 4. Activation Sequence

Activation is the final phase. Do not combine it with deployment or handoff.

1. Confirm post-handoff ownership checklist is complete.
2. Confirm oracle sanity, vault sanity, risk sanity, engine sanity, insurance sanity, governance sanity, and monitoring sanity.
3. Confirm insurance fund is funded to the launch threshold.
4. Confirm matching executors are authorized and no unknown executor is authorized.
5. Activate only the approved initial collateral tokens; keep collateral restriction mode enabled.
6. Activate only approved option underlyings and series with configured short-OI caps.
7. Activate only approved perp markets with launch OI caps and close-only/restricted controls as required.
8. Enable matching/trading incrementally:
   - first internal smoke transactions where allowed,
   - then restricted size,
   - then production limits only after monitoring confirms expected state.
9. Keep a launch watch active until the first deposit, withdrawal, trade, funding update, fee charge, oracle poll, and role poll are decoded correctly.

### 5. Abort Criteria

Abort launch and do not activate markets if any condition is true:

- Wrong chain id, wrong RPC, wrong deployer, or manifest mismatch.
- Any required core address has no bytecode.
- Any dependency pointer differs from the manifest.
- Any active oracle feed is stale, zero, unavailable, future-dated, incorrectly scaled, or points to an unexpected source.
- Any owner, pending owner, guardian, proposer, executor, matching executor, settlement operator, insurance operator, backstop caller, oracle/feed admin, or fee recipient mismatches the role matrix or manifest.
- Insurance fund is below the launch minimum.
- A product is active before verification and handoff complete.
- Launch caps are missing, placeholder, zero when not intended, or higher than approved.
- `VerifyDeployment.s.sol` fails.
- Monitoring cannot index role, pause, oracle, cap, settlement, liquidation, insurance, or bad-debt events.
- Any unexplained pause, close-only change, role change, bad debt, settlement shortfall, or liquidation anomaly occurs during activation.

---

## Incident Procedures

### Oracle Stale / Zero / Unavailable

| Field | Procedure |
| --- | --- |
| Detection source | Oracle health dashboard, `OracleRouter.getPrice`, `IPriceSource.getLatestPrice`, `FeedConfigured`, `FeedCleared`, `FeedStatusSet`, `MaxOracleDelaySet`, stale/zero/unavailable alerts |
| Severity | `P0` for zero price or unsafe active feed; `P1` for stale/unavailable feed without confirmed unsafe execution |
| Immediate action | Pause or close-only affected markets/series if stale pricing can affect margin, liquidation, settlement, or funding. Stop settlement finalization for affected options until price source is verified. |
| Contracts/modules involved | `OracleRouter`, price sources, `RiskModule`, `PerpRiskModule`, `MarginEngine`, `PerpEngine`, `CollateralSeizer`, product registries |
| Role responsible | Oracle/feed admin first; guardian/emergency responder for pause or close-only; multisig/timelock for feed config changes |
| Verification step | Confirm nonzero fresh `1e8` prices from the active router and independent reference sources; verify feed config, max delay, source bytecode, and active flags match manifest. |
| Recovery / unpause criteria | Feed is fresh, nonzero, correctly scaled, source owner is expected, no role drift exists, affected risk/settlement/funding views read successfully, and governance or owner has approved unpause. |
| Post-mortem artifact | Oracle incident report with feed pair, source address, first bad block, affected markets/series, pause txs, config txs, price evidence, and recovery txs. |

### Liquidation Anomaly

| Field | Procedure |
| --- | --- |
| Detection source | Liquidation dashboard, `Liquidation`, `LiquidationCashflow`, `LiquidationResolved`, `LiquidationPenaltyPaid`, liquidation spike alert |
| Severity | `P1`; escalate to `P0` if shortfall, bad debt, stale oracle, or repeated incorrect liquidations are observed |
| Immediate action | Check oracle health and affected account risk. If unsafe pricing or incorrect liquidation behavior is suspected, pause liquidation or set affected markets/series close-only where available. |
| Contracts/modules involved | `MarginEngine`, `PerpEngine`, `RiskModule`, `PerpRiskModule`, `CollateralSeizer`, `CollateralVault`, `InsuranceFund`, `OracleRouter` |
| Role responsible | Emergency responder and guardian; risk/governance operator for parameter review |
| Verification step | Recompute account risk, liquidation eligibility, close factor, penalty, seizure plan, and insurance coverage from onchain views and indexed events. |
| Recovery / unpause criteria | Oracle is healthy, liquidations improve solvency, no over-crediting or unexpected residual bad debt remains unexplained, and affected parameters match manifest or approved governance state. |
| Post-mortem artifact | Liquidation analysis with accounts, markets/series, pre/post risk, oracle timestamps, seized collateral, penalties, insurance usage, and any governance action. |

### Residual Bad Debt Creation

| Field | Procedure |
| --- | --- |
| Detection source | `SettlementBadDebtRecorded`, `LiquidationBadDebtRecorded`, `ResidualBadDebtUpdated`, `getTotalResidualBadDebt`, bad-debt alert |
| Severity | `P0` |
| Immediate action | Identify affected account and market/series. Confirm exposure increase is blocked where expected. Pause or close-only affected products if bad debt source is not understood. |
| Contracts/modules involved | `MarginEngine`, `PerpEngine`, `RiskModule`, `PerpRiskModule`, `InsuranceFund`, `CollateralVault`, `CollateralSeizer` |
| Role responsible | Emergency responder, insurance operator, multisig/timelock |
| Verification step | Verify event amount, account state, insurance payout, shortfall path, reduce-only state, and aggregate bad debt from views. |
| Recovery / unpause criteria | Root cause is understood, bad debt accounting is explicit, repayment or governance response is approved, affected account cannot increase exposure while debt remains, and monitoring confirms aggregate state. |
| Post-mortem artifact | Bad-debt report with creation tx, affected account, residual amount in base units, insurance coverage, repayment plan, and risk-control decision. |

### Insurance Fund Depletion

| Field | Procedure |
| --- | --- |
| Detection source | Insurance fund dashboard, token balances, `VaultBackstopPaid`, `WithdrawnFromVault`, `MovedToStrategy`, low balance alert |
| Severity | `P1`; escalate to `P0` if active shortfalls cannot be covered |
| Immediate action | Stop new risky activation, rebalance available funds from strategy to idle if authorized, and prepare treasury top-up. |
| Contracts/modules involved | `InsuranceFund`, `CollateralVault`, `MarginEngine`, `PerpEngine`, base collateral token, optional yield adapters |
| Role responsible | Insurance operator and treasury/multisig |
| Verification step | Confirm idle balance, vault balance, strategy exposure, allowed tokens, operator role, and backstop caller set. |
| Recovery / unpause criteria | Fund balance is above approved threshold, backstop callers are correct, no unexplained payouts remain, and treasury/insurance reconciliation is complete. |
| Post-mortem artifact | Insurance liquidity report with balances, payout history, top-up txs, strategy movement txs, and revised threshold recommendation if needed. |

### Settlement Shortfall

| Field | Procedure |
| --- | --- |
| Detection source | `SettlementShortfall`, `SettlementCollectionShortfall`, `SettlementInsuranceCoverage`, `SettlementBadDebtRecorded`, options dashboard |
| Severity | `P0` |
| Immediate action | Stop settlement operations for affected series. Verify settlement price, affected accounts, collected collateral, insurance coverage, and bad debt path. |
| Contracts/modules involved | `OptionProductRegistry`, `MarginEngine`, `RiskModule`, `CollateralVault`, `InsuranceFund`, `OracleRouter` |
| Role responsible | Settlement operator, emergency responder, insurance operator, multisig/timelock |
| Verification step | Confirm option expiry, final settlement price, settlement finality delay, series accounting, per-account settlement state, and insurance coverage amount. |
| Recovery / unpause criteria | Settlement price and accounting are verified, shortfall is covered or explicitly recorded, affected accounts cannot exploit repeated settlement, and governance approves any resumed settlement actions. |
| Post-mortem artifact | Settlement shortfall report with series id, settlement price evidence, account list, shortfall amount, coverage amount, bad debt, and operator txs. |

### Matching Executor Compromise

| Field | Procedure |
| --- | --- |
| Detection source | Matching executor drift alert, `ExecutorSet`, unexpected executor submissions, nonce cancellation spike, trade volume anomaly |
| Severity | `P1`; escalate to `P0` if unauthorized trades or private key compromise is confirmed |
| Immediate action | Pause affected matching engine. Revoke compromised executor and authorize replacement through owner/timelock path. Rotate offchain service keys. |
| Contracts/modules involved | `MatchingEngine`, `PerpMatchingEngine`, `MarginEngine`, `PerpEngine`, `ProtocolTimelock` |
| Role responsible | Matching operator, guardian/emergency responder, multisig/timelock |
| Verification step | Confirm old executor is disallowed, new executor is allowed, matching engine points to canonical engine, and no unknown executor remains. |
| Recovery / unpause criteria | New executor infrastructure is live, backlog is reconciled, no invalid nonce/order behavior remains, and monitoring confirms only expected executor submissions. |
| Post-mortem artifact | Executor compromise report with affected key, submitted txs, revoked/added executor txs, order impact, and credential rotation evidence. |

### Guardian Compromise

| Field | Procedure |
| --- | --- |
| Detection source | `GuardianSet`, unexpected pause/cancel/close-only events, role drift alert |
| Severity | `P0` |
| Immediate action | Treat all guardian-controlled actions as suspect. Use owner/timelock/multisig to rotate guardian. Keep affected modules paused until ownership and roles are verified. |
| Contracts/modules involved | Guardian-enabled modules, `ProtocolTimelock`, `RiskGovernor` |
| Role responsible | Multisig/timelock and emergency responder |
| Verification step | Confirm old guardian cannot pause/cancel, new guardian matches manifest, owners and pending owners are correct, and no unauthorized queued operations remain. |
| Recovery / unpause criteria | Guardian is rotated, suspicious queued operations are canceled, role matrix and manifest are updated, and governance approves unpause. |
| Post-mortem artifact | Guardian incident report with suspect actions, rotation txs, canceled operations, updated role inventory, and unpause approval. |

### Role Drift / Ownership Mismatch

| Field | Procedure |
| --- | --- |
| Detection source | Governance/roles dashboard, ownership events, role polling, manifest vs `ROLE_MATRIX.md` mismatch alert |
| Severity | `P0` for core owner drift; `P1` for non-owner operational role drift |
| Immediate action | Stop nonessential operations. Pause or close-only affected modules if drift affects trading, oracle, settlement, insurance, or matching authority. |
| Contracts/modules involved | All ownable and role-bearing modules, `ProtocolTimelock`, `RiskGovernor` |
| Role responsible | Multisig/timelock, emergency responder, role owner for affected domain |
| Verification step | Compare onchain owner, pending owner, guardian, proposer, executor, operators, backstop callers, settlement operator, matching executors, and treasury recipients against manifest and role matrix. |
| Recovery / unpause criteria | Roles are restored or drift is explicitly approved and documented, pending owners are cleared where required, and monitoring shows no unknown privileged address. |
| Post-mortem artifact | Role drift report with expected vs actual roles, first drift block, corrective txs, and manifest update. |

### Market Cap Breach / OI Near Cap

| Field | Procedure |
| --- | --- |
| Detection source | Perp/options dashboards, `getMarketOpenInterest`, market state, `LaunchOpenInterestCapSet`, `SeriesShortOpenInterestCapSet`, OI near cap alert |
| Severity | `P2` near cap; `P1` if cap is breached or cap enforcement appears inconsistent |
| Immediate action | Do not raise caps reactively. Verify cap setting and current OI. Move affected market/series to restricted or close-only if cap enforcement is uncertain. |
| Contracts/modules involved | `PerpEngine`, `PerpMarketRegistry`, `MarginEngine`, `OptionProductRegistry`, `RiskModule`, `PerpRiskModule` |
| Role responsible | Risk operator, emergency responder, risk governor, multisig/timelock |
| Verification step | Confirm OI calculation, cap value, latest trades, activation state, and whether new exposure is blocked at cap. |
| Recovery / unpause criteria | OI is below approved threshold or a reviewed governance cap change has executed, monitoring confirms cap enforcement, and risk signoff is recorded. |
| Post-mortem artifact | Cap utilization report with market/series, cap, OI path, affected trades, and governance decision. |

### Collateral Cap Saturation

| Field | Procedure |
| --- | --- |
| Detection source | Collateral/vault dashboard, deposit cap alert, `Deposited`, `CollateralTokenConfigured`, collateral config views |
| Severity | `P2`; escalate to `P1` if deposits bypass cap or collateral concentration creates risk |
| Immediate action | Verify cap utilization and collateral concentration. Do not increase cap without risk review. Pause deposits for affected token if cap enforcement is uncertain. |
| Contracts/modules involved | `CollateralVault`, `RiskModule`, `PerpRiskModule`, `InsuranceFund`, collateral token |
| Role responsible | Risk operator, guardian/emergency responder for pause, multisig/timelock for cap changes |
| Verification step | Confirm token decimals, configured cap, vault balance, launch-active status, risk weight, and deposit behavior. |
| Recovery / unpause criteria | Cap is respected, concentration is approved, any cap increase has passed governance, and collateral valuation remains conservative. |
| Post-mortem artifact | Collateral cap report with token, cap, utilization, risk review, pause/unpause txs, and cap-change txs if any. |

### Emergency Pause / Close-Only Activation

| Field | Procedure |
| --- | --- |
| Detection source | Pause dashboard, `Paused`, `GlobalPauseSet`, module-specific pause events, `EmergencyModeUpdated`, close-only events |
| Severity | `P1`; `P0` if unexpected actor or active exploit condition exists |
| Immediate action | Identify caller and affected surfaces. If expected, continue incident containment. If unexpected, treat as role drift and verify owner/guardian immediately. |
| Contracts/modules involved | Guardian-enabled modules, `MarginEngine`, `PerpEngine`, registries, matching engines, `OracleRouter`, `CollateralVault`, `InsuranceFund`, `FeesManager` |
| Role responsible | Emergency responder and guardian; owner/timelock for unpause |
| Verification step | Confirm pause/close-only state from onchain views or events, verify caller role, verify no conflicting activation state, and check affected user flows. |
| Recovery / unpause criteria | Root cause is resolved, affected module state matches intended launch/emergency posture, owner/governance approves unpause, and monitoring is green for at least one finality window. |
| Post-mortem artifact | Emergency action report with reason, affected modules, caller, txs, user impact, recovery criteria, and unpause approval. |

---

## Governance Operation Procedures

### Queue Parameter Change

1. Identify target module, function selector, encoded calldata, value, earliest ETA, and expected post-state.
2. Confirm the change is allowed by `ROLE_MATRIX.md` and consistent with `PARAMETERS.md` or an approved parameter update.
3. Simulate calldata against the target state where possible.
4. Confirm the proposer is authorized on `ProtocolTimelock`.
5. Queue through `RiskGovernor` or direct `ProtocolTimelock` proposer path.
6. Record transaction hash, operation hash, target, calldata, ETA, reviewer, and expected post-state.
7. Confirm monitoring indexed `OperationQueued` or `TransactionQueued`.

### Review Queued Operation

1. Decode target, value, calldata selector, arguments, and ETA.
2. Compare against approved proposal text and manifest.
3. Verify no hidden ownership, treasury, oracle, pause, cap, or role effect exists.
4. Confirm ETA respects `minDelay`.
5. Check whether market conditions changed since queueing.
6. Mark the operation approved, needs changes, or unsafe.

### Execute Operation After Timelock

1. Confirm current time is at or after ETA and before any grace expiry policy.
2. Re-run pre-execution checks for target state and calldata.
3. Execute only from an authorized executor.
4. Confirm `TransactionExecuted` or `OperationExecuted` is indexed.
5. Verify the exact expected post-state onchain.
6. Update manifest or parameter reference if the operation intentionally changes operational baseline.

### Cancel Unsafe Operation

1. Identify the operation hash and reason for unsafe status.
2. Confirm guardian or owner cancellation authority.
3. Cancel through `ProtocolTimelock` or `RiskGovernor` as applicable.
4. Confirm cancellation event is indexed.
5. Notify governance reviewers and mark the operation closed.
6. If the operation was malicious or unexpected, open a role-drift incident.

### Verify Post-State

Minimum checks after every executed governance operation:

- Target storage/view equals the expected value.
- No unrelated role, owner, guardian, treasury, oracle, pause, cap, or activation state changed.
- Monitoring dashboards reflect the new state.
- Deployment manifest or parameter document is updated only when the new state is intended as baseline.
- Incident or governance artifact links execution tx and verification evidence.

---

## Insurance Operations

### Top-Up

1. Confirm token, amount, source treasury, destination fund path, and token decimals.
2. Confirm token is allowed by `InsuranceFund`.
3. Confirm operator is authorized if an operator action is required.
4. Transfer or fund through the approved path.
5. Confirm `FundedFromOwner`, `DepositedToVault`, or token transfer evidence.
6. Verify idle plus vault balance exceeds the target threshold.

### Low Balance Response

1. Trigger from insurance fund below threshold alert.
2. Reconcile idle, vault, and strategy balances.
3. Move strategy exposure to idle if authorized and safe.
4. Prepare treasury top-up if available balance remains below threshold.
5. Keep new market activation halted until threshold is restored.

### Backstop Caller Verification

1. Compare `BackstopCallerSet` events and current allowlist state to manifest.
2. Confirm only canonical `MarginEngine`, `PerpEngine`, or explicitly approved modules can request coverage.
3. Verify no EOA is authorized as a production backstop caller unless explicitly approved.
4. Confirm unauthorized caller test or read-only verification where available.
5. Treat unknown caller as `P0` role drift.

### Depletion Response

1. Declare `P0` if an active shortfall cannot be covered.
2. Pause or close-only affected products until solvency impact is understood.
3. Identify all recent coverage events and uncovered residuals.
4. Reconcile fund balances and strategy positions.
5. Queue or execute approved treasury funding if available.
6. Document residual bad debt and recovery plan before unpausing.

---

## Rollback / Abort Guidance

### Before Market Activation

Use this path when contracts are deployed/configured but products are inactive:

- Do not activate products.
- Keep all trading and matching surfaces paused or inactive.
- Fix safe configuration drift if owner/deployer still has intended bootstrap authority.
- If core deployment addresses or constructor choices are wrong, redeploy in non-production or abandon the faulty production deployment before activation.
- Do not proceed to ownership handoff until verification passes.
- Update the deployment manifest with aborted status and reason.

### After Partial Activation

Use this path when only some products or caps are live:

- Set affected markets/series to close-only or restricted.
- Pause matching engines if trade ingress is involved.
- Keep withdrawals available unless the incident specifically affects vault solvency or oracle-dependent withdrawal safety.
- Do not expand caps or activate additional products during incident response.
- Re-run verification and monitoring checks for active and inactive products separately.
- Resume only the subset that passes recovery criteria.

### After Full Activation

Use this path when all launch products are live:

- Prefer targeted close-only and module-specific pauses over blanket shutdown when the fault domain is known.
- Use global pauses when oracle integrity, vault accounting, ownership, matching authority, or systemic solvency is uncertain.
- Preserve user exit paths where safe.
- Queue governance remediation for parameter, role, oracle, or cap changes that are not guardian-level actions.
- Require post-mortem approval before returning from global emergency posture to normal trading.

---

## Required Artifacts

Every launch or incident operation must produce:

- Active manifest hash or commit reference.
- Environment, chain id, block range, and finality policy.
- Transaction list with purpose and result.
- Expected vs actual role state where roles are involved.
- Expected vs actual parameter state where parameters are involved.
- Monitoring alert ids and dashboard snapshots.
- Recovery decision and unpause approval where applicable.

