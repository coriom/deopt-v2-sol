# AUDIT_PREP.md

## Purpose

Audit preparation pack for DeOpt v2.

This document summarizes audit scope, protocol flows, critical invariants, high-risk review areas, test coverage, reproduction commands, known exclusions, and expected auditor deliverables. It is documentation only and does not change protocol logic, deployment scripts, ownership, economics, parameters, or contract behavior.

---

## Audit Scope

### In-Scope Contracts

Core protocol contracts and their split modules are in scope:

- Collateral and vault accounting:
  - `src/collateral/CollateralVault.sol`
  - `src/collateral/CollateralVaultActions.sol`
  - `src/collateral/CollateralVaultAdmin.sol`
  - `src/collateral/CollateralVaultStorage.sol`
  - `src/collateral/CollateralVaultViews.sol`
  - `src/collateral/CollateralVaultYield.sol`
- Yield adapters used by the vault:
  - `src/yield/IYieldAdapter.sol`
  - `src/yield/AaveAdapter.sol`
  - `src/yield/ERC4626YieldAdapter.sol`
- Options registry and margin:
  - `src/OptionProductRegistry.sol`
  - `src/margin/MarginEngine.sol`
  - `src/margin/MarginEngineAdmin.sol`
  - `src/margin/MarginEngineOps.sol`
  - `src/margin/MarginEngineStorage.sol`
  - `src/margin/MarginEngineTrading.sol`
  - `src/margin/MarginEngineTypes.sol`
  - `src/margin/MarginEngineViews.sol`
- Risk:
  - `src/risk/IRiskModule.sol`
  - `src/risk/IMarginEngineState.sol`
  - `src/risk/RiskModule.sol`
  - `src/risk/RiskModuleAdmin.sol`
  - `src/risk/RiskModuleCollateral.sol`
  - `src/risk/RiskModuleMargin.sol`
  - `src/risk/RiskModuleOracle.sol`
  - `src/risk/RiskModuleStorage.sol`
  - `src/risk/RiskModuleUtils.sol`
  - `src/risk/RiskModuleViews.sol`
- Perps:
  - `src/perp/PerpMarketRegistry.sol`
  - `src/perp/PerpEngine.sol`
  - `src/perp/PerpEngineAdmin.sol`
  - `src/perp/PerpEngineStorage.sol`
  - `src/perp/PerpEngineTrading.sol`
  - `src/perp/PerpEngineTypes.sol`
  - `src/perp/PerpEngineViews.sol`
  - `src/perp/PerpRiskModule.sol`
- Liquidation:
  - `src/liquidation/CollateralSeizer.sol`
  - `src/liquidation/ICollateralSeizer.sol`
- Matching ingress:
  - `src/matching/MatchingEngine.sol`
  - `src/matching/PerpMatchingEngine.sol`
  - `src/matching/IMarginEngineTrade.sol`
  - `src/matching/IPerpEngineTrade.sol`
- Oracle and price sources:
  - `src/oracle/IOracle.sol`
  - `src/oracle/IPriceSource.sol`
  - `src/oracle/OracleRouter.sol`
  - `src/oracle/ChainlinkPriceSource.sol`
  - `src/oracle/PythPriceSource.sol`
  - `src/oracle/PeggedStablePriceSource.sol`
  - `src/oracle/MockPriceSource.sol`
- Fees:
  - `src/fees/FeesManager.sol`
  - `src/fees/IFeesManager.sol`
- Insurance:
  - `src/core/InsuranceFund.sol`
- Governance:
  - `src/gouvernance/ProtocolTimelock.sol`
  - `src/gouvernance/RiskGovernor.sol`
  - `src/gouvernance/RiskGovernorAdmin.sol`
  - `src/gouvernance/RiskGovernorInterfaces.sol`
  - `src/gouvernance/RiskGovernorQueue.sol`
  - `src/gouvernance/RiskGovernorStorage.sol`
- Shared constants:
  - `src/ProtocolConstants.sol`

### Out-Of-Scope Items

- Frontend, user interface, hosted APIs, and user support workflows.
- Offchain matching service implementation, except for the onchain executor authorization, nonce, replay, and submission checks exposed by `MatchingEngine` and `PerpMatchingEngine`.
- Offchain indexer and alerting implementation, except where contract events/views are expected to support `MONITORING_SPEC.md`.
- External token contracts, external oracle networks, external yield protocols, RPC providers, explorers, bridges, and multisig custody systems.
- Economic parameter selection as a business decision, except for bounds, units, safety checks, consistency, and enforceability.
- Production key management and signer security, except where onchain role surfaces and handoff procedures are reviewed for correctness.

### Deployment Scripts Scope

Deployment scripts are in scope for deterministic deployment, dependency wiring, configuration ordering, required environment variables, verification coverage, ownership transfer, and ownership acceptance:

- `script/DeployCore.s.sol`
- `script/WireCore.s.sol`
- `script/ConfigureCore.s.sol`
- `script/ConfigureMarkets.s.sol`
- `script/VerifyDeployment.s.sol`
- `script/TransferOwnerships.s.sol`
- `script/AcceptOwnerships.s.sol`

Scripts are not in scope for private key custody, RPC availability, explorer uptime, or signer operational security.

### Docs / Ops Scope

Operational documents are in scope for consistency with contracts, manifests, roles, monitoring, launch sequencing, and audit readiness:

- `SPEC.md`
- `ARCHITECTURE_MAP.md`
- `INVARIANTS.md`
- `PARAMETERS.md`
- `TEST_MATRIX.md`
- `DEPLOYMENT_PLAN.md`
- `ROLE_MATRIX.md`
- `MONITORING_SPEC.md`
- `RUNBOOK.md`
- `STAGING_REHEARSAL.md`
- `deployments/local.template.json`
- `deployments/testnet.template.json`
- `deployments/mainnet.template.json`

These documents are not executable controls unless backed by contract logic, deployment scripts, or monitoring implementation.

---

## Protocol Overview

### Options Flow

Option underlyings and series are created in `OptionProductRegistry`, then enabled through configured launch states and caps. Signed or authorized orders enter through `MatchingEngine`, which calls `MarginEngine` for trade execution. `MarginEngine` updates option positions, charges configured fees through `FeesManager`, checks account risk through `RiskModule`, and uses `CollateralVault` balances as collateral. At expiry, settlement prices are proposed/finalized, then accounts are settled exactly once per series.

### Perps Flow

Perp markets are registered in `PerpMarketRegistry` and traded through `PerpMatchingEngine` into `PerpEngine`. `PerpEngine` updates signed position sizes, open interest, funding state, realized PnL, fees, and collateral effects. `PerpRiskModule` computes margin requirements using market and collateral config. Launch caps, close-only flags, funding controls, and liquidation settings bound market activation.

### Collateral Flow

Users deposit enabled collateral into `CollateralVault`. Vault balances remain token-native, while risk views convert collateral to base units using configured risk weights and oracle prices. `MarginEngine`, `PerpEngine`, `CollateralSeizer`, and `InsuranceFund` interact with the vault only through explicit authorized paths. Withdrawals must preserve margin requirements and must not mix raw token balances with base collateral accounting.

### Liquidation Flow

Liquidation eligibility is based on account equity and maintenance margin from the relevant risk module. Liquidation closes or reduces positions, applies configured close factors and penalties, seizes collateral where applicable, and must improve solvency. Any shortfall is routed explicitly to insurance coverage where available, then residual bad debt only if coverage is insufficient.

### Insurance / Bad Debt Flow

`InsuranceFund` holds allowed tokens and can provide bounded backstop payouts to approved callers such as `MarginEngine` and `PerpEngine`. Coverage is limited by real available fund balances and token allowlists. Uncovered losses must be recorded as residual bad debt, monitored, and prevented from silently disappearing or permitting unsafe exposure growth.

### Governance Flow

Bootstrap ownership starts with deployment-controlled owners, then transfers to final governance or timelock holders according to `ROLE_MATRIX.md`. Sensitive operations are queued, canceled, or executed through `ProtocolTimelock` and `RiskGovernor` where applicable. Guardians and emergency responders may pause or restrict surfaces, but recovery and unpause paths must remain bounded and auditable.

---

## Critical Invariants

### Vault Accounting

- Vault balances must never credit more token-native amount than actually received.
- Internal transfers must preserve total accounted balances for each token.
- Yield strategy movement must not create phantom balances.
- Deposit caps, collateral enablement, and authorized engine checks must be enforced.

### Unit Scaling

- Oracle prices and product price fields use normalized `1e8` units.
- Contract size uses `1e8` as one underlying unit.
- BPS values use `10_000` as 100%.
- Fields ending in `...Base` remain in native base-collateral units.
- Base collateral is USDC with 6 decimals unless a controlled protocol-wide migration explicitly changes it.

### Risk Aggregation

- Account equity, initial margin, maintenance margin, free collateral, and margin ratio must be coherent across collateral, options, perps, fees, PnL, and funding.
- Disabled or non-risk-enabled collateral must not contribute to margin.
- `RiskModule` and `PerpRiskModule` must treat collateral weights, stale oracle behavior, and base units consistently.

### Margin Enforcement

- Risk-increasing trades and withdrawals must fail when post-action margin is insufficient.
- Close-only and reduce-only paths must block new exposure while preserving safe risk reduction.
- Accounts with residual bad debt must not silently regain unrestricted risk-increasing access.

### Liquidation Conservation

- Position reductions must conserve signed exposure and open interest.
- Liquidation penalties, seized value, recovered collateral, insurance coverage, shortfall, and residual bad debt must reconcile.
- Liquidation must improve or preserve solvency under the configured minimum improvement requirement.

### Settlement Conservation

- Option settlement must be idempotent per account and series.
- Finalized settlement prices must be used consistently for payoff calculation.
- Collected collateral, settlement payouts, insurance coverage, shortfall, and residual bad debt must reconcile.

### Insurance Payout Bounds

- Insurance payouts cannot exceed available fund balances.
- Only allowed tokens and approved backstop callers may use insurance coverage.
- Uncovered amounts must be explicit residual bad debt.

### Oracle Freshness

- Zero prices, stale prices, unavailable feeds, future timestamps, and inactive feeds must fail closed where protocol safety depends on pricing.
- Fallback behavior must be explicit, bounded, and observable.
- Price decimals must normalize to `1e8` before protocol consumption.

### Governance / Timelock Integrity

- Queued operations must be bound to target, value, calldata, ETA, and operation hash.
- Unauthorized proposers/executors must not queue or execute sensitive changes.
- Guardian powers must remain operationally useful but bounded.
- Ownership handoff must leave no unintended deployer ownership on production modules.

---

## High-Risk Review Areas

### Unified Collateral Withdrawals

Review withdrawal previews, actual withdrawals, collateral weights, stale oracle behavior, disabled tokens, margin checks, and divergence between options and perps risk paths.

### `RiskModule` + `PerpRiskModule` Consistency

Review base-unit calculations, margin ratios, collateral haircuts, oracle delay settings, liquidation thresholds, and treatment of bad-debt accounts across both risk modules.

### `CollateralVault` Yield / Accounting

Review idle versus strategy accounting, yield adapter trust assumptions, movement permissions, sync behavior, cap accounting, token decimal handling, and failure modes for strategy withdrawals.

### `OracleRouter` Fallback / Staleness Behavior

Review feed activation, feed clearing, max delay enforcement, zero/future timestamp rejection, primary/secondary behavior, source decimals, and pause or emergency controls.

### Liquidation And Collateral Seizure

Review liquidation eligibility, close factor, penalty, price spread, minimum improvement, collateral seizure ordering, seized value calculation, liquidator credit, and stale-price protections.

### Insurance Shortfall Handling

Review insurance payout authorization, token allowlists, partial coverage, failed coverage, event emission, vault movement, and reconciliation of covered versus uncovered amounts.

### Residual Bad Debt Lifecycle

Review bad debt creation, aggregation, repayment, account restrictions, monitoring surfaces, and prevention of repeated exposure increases from insolvent accounts.

### Matching-Engine Ingress And Replay Protection

Review authorized executor checks, nonce cancellation, replay resistance, order domain separation, market/series activation checks, close-only enforcement, and whether invalid executor submissions fail safely.

### Governance / Guardian Powers

Review ownership transfer, pending owner acceptance, timelock queue/cancel/execute semantics, guardian cancellation or pause powers, proposer/executor authorization, and emergency recovery paths.

### Launch Safety Controls

Review initial inactive or close-only product state, launch caps, collateral restriction mode, post-deploy verification gates, governance handoff before trading, and mainnet audit/signoff gating in the deployment manifest.

---

## Testing Summary

### Unit Tests

Existing unit coverage includes:

- `test/unit/vault/CollateralVault.t.sol`
- `test/unit/risk/RiskModule.t.sol`
- `test/unit/margin/MarginEngine.t.sol`
- `test/unit/perp/PerpEngine.t.sol`
- `test/unit/perp/PerpEngineLiquidation.t.sol`
- `test/unit/perp/PerpEngineFunding.t.sol`
- `test/unit/liquidation/CollateralSeizer.t.sol`
- `test/unit/fees/FeesManager.t.sol`
- `test/unit/governance/Governance.t.sol`
- `test/unit/matching/PerpMatchingEngine.t.sol`

### Scenario Tests

Existing scenario coverage includes:

- `test/scenario/options/OptionSettlementFlow.t.sol`
- `test/scenario/perp/PerpFullLiquidationFlow.t.sol`
- `test/scenario/system/OracleFailureFlow.t.sol`
- `test/scenario/system/BadDebtRepaymentFlow.t.sol`

### Invariant Tests

Existing invariant coverage includes:

- `test/invariant/vault/CollateralVaultInvariants.t.sol`
- `test/invariant/engine/PositionIndexInvariants.t.sol`
- `test/invariant/liquidation/LiquidationInvariants.t.sol`

### Fuzz Tests

Existing fuzz coverage includes:

- `test/fuzz/options/MarginEngineFuzz.t.sol`
- `test/fuzz/perp/PerpEngineFuzz.t.sol`

### Deployment Rehearsal Tests

Deployment rehearsal coverage is specified in `STAGING_REHEARSAL.md` and must capture:

- Full deploy, wire, configure, verify, ownership transfer, ownership acceptance, and progressive activation.
- User deposit/withdraw, option open/close/settlement, perp open/reduce/close, funding update, liquidation with collateral seizure, insurance coverage, residual bad debt, governance timelock change, oracle stale incident, matching executor compromise, close-only activation, collateral cap saturation, and OI cap pressure.
- Deployed manifest, verified config output, role confirmation, monitoring logs, incident drill logs, governance logs, failed/reverted transaction log, and final rehearsal report.

### Known Gaps Or Deferred Future Work

- Mainnet manifest values are placeholders until production deployment inputs are finalized.
- Offchain monitoring/indexing implementation is specified but not part of this repository's Solidity test suite.
- Offchain matching infrastructure is outside this audit except for onchain authorization and replay surfaces.
- External oracle network, yield protocol, multisig, and token contract correctness depend on external systems.
- Future product adapters, portfolio margin, multi-base collateral domains, contextual fee routing, and dynamic governance registry designs are intentionally excluded from the current protocol scope.

---

## Reproducibility Commands

### Build

```bash
forge build
```

### Full Test Suite

```bash
forge test
```

### Targeted Tests

```bash
forge test --match-path test/unit/vault/CollateralVault.t.sol
forge test --match-path test/unit/risk/RiskModule.t.sol
forge test --match-path test/unit/margin/MarginEngine.t.sol
forge test --match-path test/unit/perp/PerpEngine.t.sol
forge test --match-path test/unit/perp/PerpEngineLiquidation.t.sol
forge test --match-path test/unit/perp/PerpEngineFunding.t.sol
forge test --match-path test/unit/liquidation/CollateralSeizer.t.sol
forge test --match-path test/unit/fees/FeesManager.t.sol
forge test --match-path test/unit/governance/Governance.t.sol
forge test --match-path test/unit/matching/PerpMatchingEngine.t.sol
forge test --match-path test/scenario/options/OptionSettlementFlow.t.sol
forge test --match-path test/scenario/perp/PerpFullLiquidationFlow.t.sol
forge test --match-path test/scenario/system/OracleFailureFlow.t.sol
forge test --match-path test/scenario/system/BadDebtRepaymentFlow.t.sol
forge test --match-path test/invariant/vault/CollateralVaultInvariants.t.sol
forge test --match-path test/invariant/engine/PositionIndexInvariants.t.sol
forge test --match-path test/invariant/liquidation/LiquidationInvariants.t.sol
forge test --match-path test/fuzz/options/MarginEngineFuzz.t.sol
forge test --match-path test/fuzz/perp/PerpEngineFuzz.t.sol
```

### Deployment Rehearsal Sequence

Use a filled environment manifest derived from `deployments/local.template.json`, `deployments/testnet.template.json`, or `deployments/mainnet.template.json`.

```bash
forge script script/DeployCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/WireCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/ConfigureCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/ConfigureMarkets.s.sol --rpc-url $RPC_URL --broadcast
forge script script/VerifyDeployment.s.sol --rpc-url $RPC_URL
forge script script/TransferOwnerships.s.sol --rpc-url $RPC_URL --broadcast
forge script script/AcceptOwnerships.s.sol --rpc-url $RPC_URL --broadcast
```

For staging or mainnet rehearsal, record every transaction hash, deployed address, verification output, role handoff event, and monitoring alert artifact as required by `STAGING_REHEARSAL.md`.

---

## Known Non-Goals / Future Roadmap Exclusions

- Generalized product adapters are not part of the v2 launch audit scope.
- Portfolio margin is not part of the current margin model.
- Contextual fee routing beyond the configured `FeesManager` and recipient surfaces is excluded.
- Multi-base collateral domains are excluded; USDC remains the base collateral domain unless explicitly migrated.
- A full dynamic governance module registry is excluded from the current governance design.

---

## Auditor Deliverables Expected

Auditors are expected to provide:

- Findings report with title, severity, affected files/contracts, impact, exploitability, recommendation, and affected invariants.
- Severity classification using at least Critical, High, Medium, Low, and Informational categories.
- Proof-of-concept tests where applicable, preferably as Foundry tests that reproduce the issue against this repository.
- Remediation review for every accepted fix, including whether the fix fully resolves the reported issue and whether new risk was introduced.
- Final closure matrix mapping every finding to status, remediation commit or rationale, retest result, and residual risk.

---

## Audit Package Inputs

Auditors should review this document together with:

- `AGENTS.md`
- `SPEC.md`
- `ARCHITECTURE_MAP.md`
- `INVARIANTS.md`
- `PARAMETERS.md`
- `TEST_MATRIX.md`
- `DEPLOYMENT_PLAN.md`
- `PROGRESS.md`
- `ROLE_MATRIX.md`
- `MONITORING_SPEC.md`
- `RUNBOOK.md`
- `STAGING_REHEARSAL.md`
- Deployment manifests under `deployments/`
- Current `src/`, `script/`, and `test/` contents at the audited commit
