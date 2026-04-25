# PROGRESS.md

## Purpose

Tracks what the agent has done, what is in progress, and what remains.

Must be updated after every meaningful modification.

---

## Format

### Entry Template

- Date:
- Scope:
- Files Modified:
- Summary:
- Invariants Impacted:
- Validation:
- Status:

---

## Example

- Date: 2026-04-14
- Scope: Perp liquidation fix
- Files Modified:
  - PerpEngineTrading.sol
  - CollateralSeizer.sol
- Summary:
  Fixed sign inconsistency in liquidation delta calculation.
- Invariants Impacted:
  - Position conservation
  - PnL sign correctness
- Validation:
  - forge build: OK
- Status: DONE

---

## Rules

- Do not skip entries
- Do not overwrite history
- Be concise and factual
- Always mention invariants impacted
- Always include validation result

---

## Status Legend

- TODO
- IN_PROGRESS
- DONE
- BLOCKED

---

## Objective

Maintain a clear, auditable history of system evolution.

---

- Date: 2026-04-25
- Scope: Future architecture roadmap finalization
- Files Modified:
  - FUTURE_ARCHITECTURE_ROADMAP.md
  - PROGRESS.md
- Summary:
  Added `FUTURE_ARCHITECTURE_ROADMAP.md`, a future architecture roadmap that separates v1 launch scope, post-v1 expansion scope, and explicitly deferred architecture work. The roadmap covers generalized product registry, product/risk adapters, futures, structured products, contextual fees, fee routing, collateral policy registry, collateral risk domains, portfolio margin, generalized execution, governance module adapters, observability/indexing standards, and a five-phase future architecture plan.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No deployment scripts changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance execution semantics, market, series, or economic parameter behavior changed
- Validation:
  - Markdown-only documentation change
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-25
- Scope: Production README rewrite
- Files Modified:
  - README.md
  - PROGRESS.md
- Summary:
  Rewrote `README.md` into a production-grade repository entrypoint for DeOpt v2, covering protocol purpose, options/perps/unified collateral/risk/liquidation/insurance/governance scope, architecture overview, deployment scripts, docs map, developer quickstart, build/test commands, targeted tests, deployment flow, production readiness references, launch gates, and security notice.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No deployment scripts changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance execution semantics, market, series, or economic parameter behavior changed
- Validation:
  - Markdown-only documentation change
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-25
- Scope: Final go/no-go launch checklist
- Files Modified:
  - FINAL_LAUNCH_CHECKLIST.md
  - PROGRESS.md
- Summary:
  Added `FINAL_LAUNCH_CHECKLIST.md`, a final launch decision checklist covering code, tests, deployment, configuration, ownership/governance, oracle, collateral/risk, insurance, monitoring, runbook, staging rehearsal, audit, market-maker/liquidity, and incident-response readiness. Each checklist item includes a status placeholder, required evidence artifact, responsible role, and blocking severity. The document also lists explicit no-go conditions and final sign-off fields.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No deployment scripts changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance execution semantics, market, series, or economic parameter behavior changed
- Validation:
  - Markdown-only documentation change
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-25
- Scope: Audit preparation pack
- Files Modified:
  - AUDIT_PREP.md
  - PROGRESS.md
- Summary:
  Added `AUDIT_PREP.md`, an audit preparation pack covering audit scope, protocol overview, critical invariants, high-risk review areas, testing summary, reproducibility commands, deployment rehearsal sequence, known non-goals and roadmap exclusions, expected auditor deliverables, and audit package inputs.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No deployment scripts changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance execution semantics, market, series, or economic parameter behavior changed
- Validation:
  - Markdown-only documentation change
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-25
- Scope: Staging rehearsal plan
- Files Modified:
  - STAGING_REHEARSAL.md
  - PROGRESS.md
- Summary:
  Added `STAGING_REHEARSAL.md`, a production-like staging rehearsal plan covering full deploy/wire/configure/verify/handoff/activation objectives, environment preparation, deployment and configuration phases, ownership/governance handoff, market activation, functional smoke tests, incident drills, rollback drills, final evidence collection, required scenarios, pass/fail criteria, required artifacts, and mainnet readiness gating.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No deployment scripts changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance execution semantics, market, series, or economic parameter behavior changed
- Validation:
  - Markdown-only documentation change
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-25
- Scope: Production operations runbook
- Files Modified:
  - RUNBOOK.md
  - PROGRESS.md
- Summary:
  Added `RUNBOOK.md`, a production operations runbook covering launch-day checks and sequencing, ownership handoff, activation and abort criteria, incident procedures for oracle, liquidation, bad debt, insurance, settlement, matching executor, guardian, role drift, market/collateral caps, emergency pause and close-only activation, governance operations, insurance operations, rollback/abort guidance, and required incident artifacts.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No deployment scripts changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance execution semantics, market, series, or economic parameter behavior changed
- Validation:
  - Markdown-only documentation change
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-25
- Scope: Production monitoring and alerting specification
- Files Modified:
  - MONITORING_SPEC.md
  - PROGRESS.md
- Summary:
  Added `MONITORING_SPEC.md`, a production monitoring and alerting specification covering critical event categories, required dashboards, alert rules with severity/source/trigger/operator response/escalation path, offchain indexing requirements, deployment manifest ingestion, role matrix ingestion, reorg handling, alert deduplication, and pre/post-launch monitoring checklists.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No deployment scripts changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance execution semantics, market, series, or economic parameter behavior changed
- Validation:
  - Markdown-only documentation change
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-25
- Scope: Production role matrix documentation
- Files Modified:
  - ROLE_MATRIX.md
  - PROGRESS.md
- Summary:
  Added `ROLE_MATRIX.md`, a production role matrix documenting deployer, final owner/timelock, multisig, governor, proposer, executor, guardian, settlement operator, matching executor, insurance operator, insurance backstop caller, oracle/feed admin, fee recipient/treasury, and emergency responder roles. The document covers each role's purpose, controlled modules, allowed and forbidden actions, local/testnet/mainnet holder guidance, compromise risk, rotation procedure, monitoring alerts, module-to-role mapping, pre-launch checklist, post-handoff checklist, and minimum alert set.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No deployment scripts changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance execution semantics, market, series, or economic parameter behavior changed
- Validation:
  - Markdown-only documentation change
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-25
- Scope: Deployment environment manifest templates
- Files Modified:
  - deployments/local.template.json
  - deployments/testnet.template.json
  - deployments/mainnet.template.json
  - PROGRESS.md
- Summary:
  Added local, testnet, and mainnet deployment manifest templates with explicit placeholder sections for chain metadata, core contract addresses, token addresses, oracle price sources, governance roles, guardians, matching executors, collateral configuration, risk configuration, fees, insurance, option underlyings and series, perp markets, launch safety controls, emergency controls, and verification status. No Solidity contracts or deployment scripts were modified.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance, market, series, or economic parameter behavior changed
  - Templates preserve existing unit labels for `1e8`, base-native, and BPS fields and keep launch activation placeholders conservative by default
- Validation:
  - JSON syntax parse for all three templates: OK
  - `forge build`: OK (compilation skipped because no Solidity files changed; existing repository warning/lint output remains)
- Status: DONE

---

- Date: 2026-04-24
- Scope: Accept ownership and final governance handoff verification script
- Files Modified:
  - script/AcceptOwnerships.s.sol
  - PROGRESS.md
- Summary:
  Added `AcceptOwnerships.s.sol`, a seventh-pass Foundry handoff finalization script for a deployed DeOpt v2 stack after `TransferOwnerships.s.sol`. The script requires explicit env vars for all core protocol module addresses, final expected governance owners, deployer address, and the private key or timelock execution context needed to finalize pending transfers. It verifies module bytecode, accepts two-step ownership transfers from the correct final-owner context, supports already-transferred one-step price sources, supports timelock-executed `acceptOwnership` when queued and ready, verifies final owners and cleared pending owners across core modules, `ProtocolTimelock`, `RiskGovernor`, and optional price sources, and prints a final ownership verification summary.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, market, series, or economic parameter behavior changed
  - Handoff finalization fails loudly on missing env vars, missing bytecode, zero/deployer final owners, owner private-key mismatches, pending-owner mismatches, unsupported contract-owner execution paths, unavailable or unready timelock execution, uncleared pending owners, and any critical module remaining owned by the deployer unexpectedly
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains)
  - Local Anvil rehearsal: OK after broadcasting `DeployCore.s.sol`, deploying local ETH/BTC `MockPriceSource` contracts, broadcasting `TransferOwnerships.s.sol`, then broadcasting `AcceptOwnerships.s.sol`; final summary showed all core modules, `ProtocolTimelock`, and `RiskGovernor` owned by the configured final governance owner with pending owners cleared, and both mock price sources verified
- Status: DONE

---

- Date: 2026-04-24
- Scope: Ownership and governance handoff deployment script
- Files Modified:
  - script/TransferOwnerships.s.sol
  - PROGRESS.md
- Summary:
  Added `TransferOwnerships.s.sol`, a sixth-pass Foundry handoff script for a deployed, wired, configured, market-configured, and verified DeOpt v2 stack. The script requires explicit env vars for all core protocol module addresses plus governance owner targets, timelock proposer/executor role arrays, guardian address, optional matching-engine executor arrays, and optional price-source owner transfer arrays. It configures guardians on modules that expose guardian controls, configures timelock proposer/executor roles with `RISK_GOVERNOR` required as an allowed proposer, configures optional matching/perp matching executors, transfers optional ownable price sources through their available ownership path, and begins two-step ownership transfers for the core modules, protocol timelock, and risk governor without accepting ownership.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, market, series, or economic parameter behavior changed
  - Handoff script fails loudly on missing env vars, missing bytecode, zero governance targets, role array length mismatches, missing allowed timelock executor, missing `RISK_GOVERNOR` proposer authorization, unavailable price-source ownership paths, non-deployer current owners, unexpected pending owners, and post-transfer owner/pending-owner mismatches
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains)
  - Local Anvil rehearsal: OK after broadcasting `DeployCore.s.sol`, `WireCore.s.sol`, `ConfigureCore.s.sol`, deploying local ETH/BTC `MockPriceSource` contracts, broadcasting `ConfigureMarkets.s.sol`, running `VerifyDeployment.s.sol` read-only, then broadcasting `TransferOwnerships.s.sol`; final summary showed protocol modules pending to the timelock, timelock/risk-governor pending to the configured governance owner, and two mock price sources transferred
- Status: DONE

---

- Date: 2026-04-24
- Scope: Post-deployment verification script
- Files Modified:
  - script/VerifyDeployment.s.sol
  - PROGRESS.md
- Summary:
  Added `VerifyDeployment.s.sol`, a read-only fifth-pass verification script for a deployed, wired, core-configured, and market-configured DeOpt v2 stack. The script requires explicit env vars for all core addresses and expected parameters, verifies bytecode for core contracts, checks dependency wiring across the vault, risk modules, engines, collateral seizer, insurance fund, and matching engines, validates collateral support/decimals/factors/weights/caps/launch flags/restriction mode, verifies ETH/USDC and BTC/USDC oracle feed configuration and nonzero normalized prices when feeds are active, verifies ETH/BTC option underlying/risk profiles, configured option series activation states and short-OI caps, verifies ETH-PERP and BTC-PERP registry/engine risk, liquidation, funding, launch cap, and activation config, and checks basic fee and insurance token/backstop configuration. The script does not broadcast, transfer ownership, or modify protocol state.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance, or unit-scaling behavior changed
  - Verification fails loudly on missing env vars, missing bytecode, dependency drift, feed/config drift, zero active oracle prices, missing series/markets, and mismatched launch caps or activation states
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains)
  - Local Anvil rehearsal: OK after deploying core with `DeployCore.s.sol`, wiring with `WireCore.s.sol`, configuring core with `ConfigureCore.s.sol`, deploying local ETH/BTC `MockPriceSource` contracts, broadcasting `ConfigureMarkets.s.sol`, then running `VerifyDeployment.s.sol` read-only against the configured deployment
- Status: DONE

---

- Date: 2026-04-24
- Scope: Market, underlying, and oracle deployment configuration script
- Files Modified:
  - script/ConfigureMarkets.s.sol
  - PROGRESS.md
- Summary:
  Added `ConfigureMarkets.s.sol`, a fourth-pass Foundry configuration script for a deployed and core-configured DeOpt v2 stack. The script reads all required module addresses, ETH/BTC underlying addresses, feed source addresses, oracle feed parameters, option underlying/risk parameters, option series parameters, perp risk/funding/liquidation parameters, launch caps, and activation states from environment variables. It configures ETH/USDC and BTC/USDC oracle feeds, configures ETH and BTC option underlying risk profiles, creates or updates configured ETH/BTC option series with registry active flags, engine activation states, and short-open-interest caps, creates or updates ETH-PERP and BTC-PERP markets with registry status, risk, liquidation, funding, engine launch OI caps, and engine activation state. Ownership transfer remains intentionally deferred.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance, or unit-scaling behavior changed
  - Script fails early on missing env vars, zero/no-code contract addresses where code is required, invalid activation states, duplicate/invalid underlyings, and mismatched option-series array lengths
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains; no new `ConfigureMarkets.s.sol` unsafe-cast warnings after SafeCast cleanup)
  - Local Anvil simulation: OK after deploying core, wiring core, configuring core, deploying local `MockPriceSource` instances for ETH/USDC and BTC/USDC, then broadcasting `ConfigureMarkets.s.sol`; a second broadcast rerun also succeeded against the same deployment and reused existing option series/perp markets
- Status: DONE

---

- Date: 2026-04-24
- Scope: Core protocol configuration deployment script
- Files Modified:
  - script/ConfigureCore.s.sol
  - PROGRESS.md
- Summary:
  Added `ConfigureCore.s.sol`, a configuration-only Foundry script for a deployed and wired DeOpt v2 core stack. The script reads module addresses and parameter values from environment variables, configures vault-supported collateral tokens, collateral factors, deposit caps, launch-active flags, collateral restriction mode, `RiskModule` base parameters and collateral weights, `PerpRiskModule` base collateral/max-delay settings, base settlement asset allowlists for option/perp registries, `MarginEngine` risk-parameter cache, `FeesManager` default fee settings, and `InsuranceFund` token/operator allowlists. Product creation, market creation, oracle feed configuration, and ownership transfer remain intentionally deferred.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No pricing, funding, liquidation, fee formula, collateral accounting, risk formula, governance, or unit-scaling behavior changed
  - Script enforces explicit base collateral support, 100% base collateral factor/weight, bounded decimal exponents, and matching array lengths for multi-collateral env inputs
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains)
  - Local Anvil simulation: OK after sequentially deploying the core stack with `DeployCore.s.sol`, wiring it with `WireCore.s.sol`, and simulating `ConfigureCore.s.sol` against deployed contract bytecode
- Status: DONE

---

- Date: 2026-04-24
- Scope: Core dependency wiring deployment script
- Files Modified:
  - script/WireCore.s.sol
  - PROGRESS.md
- Summary:
  Added `WireCore.s.sol`, a wiring-only Foundry script for an already deployed DeOpt v2 core stack. The script reads core addresses from environment variables, validates that each address has deployed code, wires vault risk and engine authorization, connects unified `RiskModule` to options/perps risk surfaces, sets engine oracle/risk/fees/insurance/seizer dependencies, authorizes insurance backstop callers, points matching engines to execution engines, and assigns guardians on supported operational modules. Market creation, option series creation, oracle feeds, collateral configuration, risk parameters, fee parameters, and activation remain intentionally deferred.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No pricing, funding, liquidation, fee, risk, collateral accounting, governance, or unit-scaling behavior changed
  - Wiring script fails early on missing/no-code env addresses to avoid silently accepting malformed deployment inputs
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains)
  - Local Anvil simulation: OK after deploying the core stack locally with `DeployCore.s.sol`; `WireCore.s.sol` simulation completed successfully against deployed contract bytecode
- Status: DONE

---

- Date: 2026-04-24
- Scope: First Foundry core deployment script
- Files Modified:
  - script/DeployCore.s.sol
  - PROGRESS.md
- Summary:
  Added `DeployCore.s.sol`, a deployment-only Foundry script for the core DeOpt v2 stack. The script uses `DEPLOYER_PRIVATE_KEY`, `INITIAL_OWNER`, `BASE_COLLATERAL_TOKEN`, optional `INITIAL_GUARDIAN`, optional `TIMELOCK_MIN_DELAY`, and optional fee default environment variables, deploys constructor-required dependencies in safe order, and prints all deployed addresses. Full post-deploy wiring, parameter bootstrap, market creation, and activation remain intentionally deferred.
- Invariants Impacted:
  - No protocol contracts or protocol logic changed
  - No pricing, funding, liquidation, fee, risk, collateral accounting, governance, or unit-scaling behavior changed
  - Deployment script keeps activation/configuration out of this block and only satisfies constructor dependency requirements
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains)
  - `forge script script/DeployCore.s.sol --dry-run`: not supported by the installed Foundry CLI
  - `DEPLOYER_PRIVATE_KEY=... BASE_COLLATERAL_TOKEN=... forge script script/DeployCore.s.sol`: OK (local simulation, no broadcast/fork)
- Status: DONE

---

- Date: 2026-04-24
- Scope: Final v1 shared-risk production blockers
- Files Modified:
  - src/risk/RiskModuleAdmin.sol
  - src/collateral/CollateralVaultStorage.sol
  - src/collateral/CollateralVaultYield.sol
  - src/perp/PerpEngineTrading.sol
  - src/perp/PerpRiskModule.sol
  - test/unit/risk/RiskModule.t.sol
  - test/unit/perp/PerpEngine.t.sol
  - PROGRESS.md
- Summary:
  Added owner-only `RiskModule` wiring setters for the perp risk module and perp engine so the unified risk surface can aggregate options and perps. Perp trade entry now fails closed when the perp risk module is unset. `PerpRiskModule` now respects vault launch collateral restriction flags consistently with `RiskModule`, and configured vault risk checks now fail closed if the risk module call itself fails. Added focused tests for shared vault withdrawals under combined option/perp exposure, unset perp risk-module trade rejection, and options/perps collateral restriction consistency.
- Invariants Impacted:
  - Vault withdrawal limits now use the configured unified risk module result and no longer become permissive if a configured risk module call fails
  - Perp trading cannot bypass post-trade margin enforcement through an unset risk module
  - Launch-inactive collateral remains withdrawable but does not improve either options or perps collateral equity
  - No pricing, funding, liquidation, fee, unit-scaling, or economic formula changed
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains)
  - `forge test --match-path test/unit/risk/RiskModule.t.sol`: OK (10 passed)
  - `forge test --match-path test/unit/perp/PerpEngine.t.sol`: OK (16 passed)
  - `forge test --match-path test/unit/vault/CollateralVault.t.sol`: OK (11 passed)
  - `forge test`: OK (155 passed)
- Status: DONE

---

- Date: 2026-04-24
- Scope: Options launch-stage activation controls
- Files Modified:
  - src/margin/MarginEngineTypes.sol
  - src/margin/MarginEngineStorage.sol
  - src/margin/MarginEngineAdmin.sol
  - src/margin/MarginEngineTrading.sol
  - test/unit/margin/MarginEngine.t.sol
  - PROGRESS.md
- Summary:
  Added minimal engine-level staged activation controls for option series through `seriesActivationState`: `active` (default), `restricted` (reduce-only), and `inactive` (strict close-to-zero only). The new owner-only `setSeriesActivationState` control gates matched option trades without changing premium transfer logic, fees, margin math, liquidation execution, settlement execution, pricing, or unit scaling. Existing perp-market staged activation remains unchanged.
- Invariants Impacted:
  - Default series behavior remains unchanged because unset activation state resolves to `active`
  - `restricted` only permits two-sided reduce-only transitions, while `inactive` only permits two-sided close-to-zero transitions; both block new exposure creation conservatively
  - Liquidations, settlements, withdrawals, protocol economics, pricing, fee logic, margin math, liquidation math, and unit scaling are unchanged
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains)
  - `forge test --match-path test/unit/perp/PerpEngine.t.sol`: OK (15 passed)
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (21 passed)
- Status: DONE

---

- Date: 2026-04-23
- Scope: Progressive perp-market activation controls
- Files Modified:
  - src/perp/PerpEngineTypes.sol
  - src/perp/PerpEngineStorage.sol
  - src/perp/PerpEngineAdmin.sol
  - src/perp/PerpEngineTrading.sol
  - test/unit/perp/PerpEngine.t.sol
  - PROGRESS.md
- Summary:
  Added a minimal engine-level staged activation framework for perp markets through `marketActivationState`: `active` (default), `restricted` (reduce-only), and `inactive` (strict close-to-zero only). The new owner-only `setMarketActivationState` control gates new risk-increasing and new opening flows inside `applyTrade` without changing pricing, funding, fee routing, liquidation execution, or unit scaling. Liquidations remain independently available, and matched risk-reducing exits remain possible under staged restrictions.
- Invariants Impacted:
  - Default market behavior remains unchanged because unset activation state resolves to `active`
  - `restricted` only permits two-sided reduce-only transitions, while `inactive` only permits two-sided close-to-zero transitions; both block new exposure creation conservatively
  - Liquidation logic, protocol economics, pricing, funding logic, fee logic, and unit scaling are unchanged
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warning/lint output remains, including pre-existing warnings outside this block)
  - `forge test --match-path test/unit/perp/PerpEngine.t.sol`: OK (15 passed)
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (19 passed)
- Status: DONE

---

- Date: 2026-04-23
- Scope: Launch-time collateral universe restriction mode
- Files Modified:
  - src/collateral/CollateralVaultStorage.sol
  - src/collateral/CollateralVaultAdmin.sol
  - src/collateral/CollateralVaultActions.sol
  - src/risk/RiskModuleCollateral.sol
  - src/risk/RiskModuleViews.sol
  - test/unit/vault/CollateralVault.t.sol
  - test/unit/risk/RiskModule.t.sol
  - PROGRESS.md
- Summary:
  Added an explicit launch restriction mode in `CollateralVault` with independent per-token `launchActiveCollateral` flags, so vault token support/configuration no longer automatically makes a token launch-active collateral. When restriction mode is enabled, `deposit` and `depositFor` reject non-launch-active tokens, while withdrawals and internal transfers remain available. `RiskModule` now excludes non-launch-active tokens from collateral contribution and withdraw-risk consumption, making them non-collateral balances that can still be exited safely.
- Invariants Impacted:
  - Supported/configured collateral tokens can now remain vault-supported without automatically becoming launch-active collateral tokens
  - In restriction mode, only launch-active tokens contribute to adjusted collateral value and collateral-backed solvency; non-launch-active tokens remain fully withdrawable
  - Protocol economics, liquidation math, fee logic, internal transfer accounting, and unit scaling are unchanged
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository lint notes/warnings remain)
  - `forge test --match-path test/unit/vault/CollateralVault.t.sol`: OK (11 passed)
  - `forge test --match-path test/unit/risk/RiskModule.t.sol`: OK (8 passed)
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (19 passed)
  - `forge test --match-path test/unit/perp/PerpEngine.t.sol`: OK (13 passed)
- Status: DONE

---

- Date: 2026-04-23
- Scope: Perp matching ingress emergency guardian and pause controls
- Files Modified:
  - src/matching/PerpMatchingEngine.sol
  - test/unit/matching/PerpMatchingEngine.t.sol
  - PROGRESS.md
- Summary:
  Added a minimal guardian-controlled emergency stop layer to `PerpMatchingEngine` with explicit guardian assignment, pause, and owner-only unpause controls. Matching ingress is now independently freezable through `executeTrade` and `executeBatch` without touching `PerpEngine`, while signature validation, nonce progression, trade forwarding, economics, fee behavior, liquidation behavior, and unit scaling remain unchanged when not paused.
- Invariants Impacted:
  - Perp matching ingress can now be halted independently from `PerpEngine` without altering core engine storage or execution paths
  - Unpaused matching preserves existing signed-trade execution semantics, forwarded trade fields, and nonce advancement behavior
  - No protocol economics, matching semantics, fee logic, liquidation logic, or unit scaling changed
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository lint notes/warnings remain)
  - `forge test --match-path test/unit/matching/PerpMatchingEngine.t.sol`: OK (2 passed)
- Status: DONE

---

- Date: 2026-04-23
- Scope: Critical event enrichment for liquidation, settlement, and bad-debt observability
- Files Modified:
  - src/perp/PerpEngineTypes.sol
  - src/perp/PerpEngineStorage.sol
  - src/perp/PerpEngineAdmin.sol
  - src/perp/PerpEngineTrading.sol
  - src/margin/MarginEngineTypes.sol
  - src/margin/MarginEngineAdmin.sol
  - src/margin/MarginEngineOps.sol
  - test/unit/perp/PerpEngine.t.sol
  - test/unit/perp/PerpEngineLiquidation.t.sol
  - test/unit/margin/MarginEngine.t.sol
  - PROGRESS.md
- Summary:
  Added companion observability events for per-market and per-series emergency close-only changes with caller attribution; added a full perp liquidation resolution event; emitted a unified residual bad debt balance update event on every record/reduce/clear path; and enriched option settlement observability by emitting full settlement computation details plus explicit payout shortfall, insurance coverage, short collection shortfall, and bad-debt events on settlement paths.
- Invariants Impacted:
  - Event enrichment makes liquidation shortfall routing, settlement shortfall routing, insurance coverage, emergency close-only changes, and residual bad debt lifecycle transitions more auditable without changing execution math
  - Perp liquidation, option settlement, residual bad debt accounting, fee logic, protocol economics, and unit scaling are unchanged
  - New event payloads preserve existing unit conventions: perp liquidation and bad debt values remain in base-token native units, while option settlement values remain in settlement-asset native units except where already normalized
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warnings/notes remain)
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (19 passed)
  - `forge test --match-path test/unit/perp/PerpEngine.t.sol`: OK (13 passed)
  - `forge test --match-path test/unit/perp/PerpEngineLiquidation.t.sol`: OK (10 passed)
- Status: DONE

---

- Date: 2026-04-23
- Scope: Options settlement and settlement-shortfall preview observability
- Files Modified:
  - src/margin/MarginEngineViews.sol
  - test/unit/margin/MarginEngine.t.sol
  - PROGRESS.md
- Summary:
  Added `previewDetailedSettlement`, a read-only option-settlement preview that exposes series expiry/finalization/proposal readiness, account settlement readiness, payoff and gross settlement amount, short-liability classification, trader/sink balance coverage, insurance-backed payout coverage, residual shortfall/bad-debt preview, and before/after account-risk style snapshots. The preview reuses existing registry settlement state, payoff helpers, vault balances, cached option-risk params, and settlement shortfall logic without changing settlement execution, liquidation execution, fees, or unit scaling.
- Invariants Impacted:
  - Option settlement preview outputs preserve unit conventions: settlement amounts remain in settlement-asset native units and risk snapshots remain in base-collateral native units
  - Settlement readiness, collateral coverage, insurance-backed payout coverage, and residual bad-debt paths are now inspectable before execution without mutating state
  - Option settlement math, liquidation math, shortfall routing, fee logic, protocol economics, and unit scaling are unchanged
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository lint notes/warnings remain)
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (17 passed)
- Status: DONE

---

- Date: 2026-04-22
- Scope: Perp liquidation preview observability
- Files Modified:
  - src/perp/PerpEngineTypes.sol
  - src/perp/PerpEngineViews.sol
  - test/unit/perp/PerpEngineLiquidation.t.sol
  - PROGRESS.md
- Summary:
  Added `previewDetailedLiquidation`, a read-only perp liquidation breakdown that exposes account risk before liquidation, executable close size, liquidation price, closed notional, realized cashflow preview, penalty target, collateral-seizer coverage, direct settlement-asset fallback coverage, insurance coverage, and residual shortfall / bad-debt preview. The preview reuses existing liquidation price, close-factor, position transition, penalty, seizer, insurance-balance, and shortfall helpers without changing execution paths.
- Invariants Impacted:
  - Perp liquidation preview outputs preserve unit conventions: sizes/prices/notionals in 1e8-normalized units and risk/penalty/coverage/shortfall in base-collateral native units
  - Penalty, seizer, insurance, and residual bad-debt routing are now observable before execution without mutating state
  - Perp liquidation math, funding logic, fee logic, position mutation, insurance execution, residual bad-debt recording, protocol economics, and unit scaling are unchanged
- Validation:
  - `forge build`: OK (existing repository lint notes/warnings remain)
  - `forge test --match-path test/unit/perp/PerpEngineLiquidation.t.sol`: OK (10 passed)
- Status: DONE

---

- Date: 2026-04-22
- Scope: Rich account risk breakdown observability
- Files Modified:
  - src/risk/IRiskModule.sol
  - src/risk/RiskModuleViews.sol
  - test/unit/risk/RiskModule.t.sol
  - PROGRESS.md
- Summary:
  Added `computeDetailedAccountRisk`, a read-only RiskModule view returning aggregate equity, initial margin, maintenance margin, free collateral, margin ratio, per-collateral token contributions, and options/perps product contributions. The view reuses existing collateral valuation, options margin snapshot, and product risk aggregation helpers.
- Invariants Impacted:
  - Risk outputs remain denominated in base-collateral native units and margin ratio remains in BPS
  - Per-collateral contributions reuse existing haircut and conservative pricing helpers; disabled, zero-weight, zero-balance, or unpriced collateral contributes zero
  - Options/perps product decomposition mirrors existing risk snapshot inputs without mutating state or changing economics
- Validation:
  - `forge build`: OK (existing repository lint notes/warnings remain)
  - `forge test --match-path test/unit/risk/RiskModule.t.sol`: OK (7 passed)
- Status: DONE

---

- Date: 2026-04-22
- Scope: Options liquidation preview observability
- Files Modified:
  - src/margin/MarginEngineViews.sol
  - test/unit/margin/MarginEngine.t.sol
  - PROGRESS.md
- Summary:
  Added a read-only options liquidation preview that exposes before-risk state, close-factor capacity, per-leg executable quantities and price-per-contract, aggregated settlement-asset cash requests, and penalty preview for a requested liquidation bundle. No execution path or economics changed.
- Invariants Impacted:
  - Options liquidation preview mirrors existing close-factor, oracle freshness, intrinsic/spread pricing, and penalty calculations without mutating state
  - Outputs preserve unit conventions: risk and penalty in base-native units, option quantities as raw contracts, and liquidation prices/cash in settlement-asset native units
  - Option pricing, settlement economics, liquidation execution math, fee logic, protocol economics, and unit scaling are unchanged
- Validation:
  - `forge build`: OK (compilation skipped because artifacts were current; existing repository warnings/notes remain)
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (15 passed)
- Status: DONE

---

- Date: 2026-04-22
- Scope: Options per-series emergency close-only controls
- Files Modified:
  - src/margin/MarginEngineTypes.sol
  - src/margin/MarginEngineStorage.sol
  - src/margin/MarginEngineAdmin.sol
  - src/margin/MarginEngineTrading.sol
  - test/unit/margin/MarginEngine.t.sol
  - PROGRESS.md
- Summary:
  Added an engine-level per-series emergency close-only flag for option series, with guardian/owner controls and trade-time close-only enforcement when either the registry series is inactive or the engine emergency flag is active. Series emergency close-only does not require engine-wide trading pause and does not block liquidation.
- Invariants Impacted:
  - Option series emergency isolation now blocks new opening/flipping/increasing transitions for the isolated series while allowing strict two-sided reduce/close transitions
  - Liquidation remains available under series emergency close-only; settlement remains governed by the existing settlement pause path
  - Option pricing logic, settlement economics, liquidation math, fee logic, protocol economics, and unit scaling are unchanged
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warnings/notes remain)
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (14 passed)
- Status: DONE

---

- Date: 2026-04-22
- Scope: Perp per-market emergency close-only controls
- Files Modified:
  - src/perp/PerpEngineTypes.sol
  - src/perp/PerpEngineStorage.sol
  - src/perp/PerpEngineAdmin.sol
  - src/perp/PerpEngineTrading.sol
  - test/unit/perp/PerpEngine.t.sol
  - test/unit/perp/PerpEngineLiquidation.t.sol
  - PROGRESS.md
- Summary:
  Added an engine-level per-market emergency close-only flag for perp markets, with guardian/owner controls and trade-time reduce-only enforcement when either registry close-only or engine emergency close-only is active. Market emergency close-only does not require engine-wide trading pause and does not block liquidation.
- Invariants Impacted:
  - Perp market emergency isolation now blocks new exposure increases for the isolated market while allowing two-sided reduce/close transitions
  - Liquidation remains available under market emergency close-only and liquidation math, funding math, fee logic, protocol economics, and unit scaling are unchanged
  - Position sign and open-interest accounting continue through the existing position transition and OI update helpers
- Validation:
  - `forge build`: OK (compiler succeeded; existing repository warnings/notes remain)
  - `forge test --match-path test/unit/perp/PerpEngine.t.sol`: OK (12 passed)
  - `forge test --match-path test/unit/perp/PerpEngineLiquidation.t.sol`: OK (9 passed)
- Status: DONE

---

- Date: 2026-04-21
- Scope: Perp engine launch open-interest caps
- Files Modified:
  - src/perp/PerpEngineTypes.sol
  - src/perp/PerpEngineStorage.sol
  - src/perp/PerpEngineAdmin.sol
  - src/perp/PerpEngineTrading.sol
  - test/unit/perp/PerpEngine.t.sol
  - PROGRESS.md
- Summary:
  Added an owner-configurable per-market engine-level launch open-interest cap for perp markets, with disabled-by-default `0` semantics and trade-time enforcement only when effective market open interest increases. Reducing or closing exposure remains allowed after a cap is lowered below current open interest.
- Invariants Impacted:
  - Market open interest remains tracked in 1e8 underlying units
  - Launch caps bound new perp exposure increases without changing funding, liquidation, fee logic, or unit scaling
  - Risk-reducing trade transitions remain allowed even when the configured launch cap is below current market open interest
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/perp/PerpEngine.t.sol`: OK (10 passed)
- Status: DONE

---

- Date: 2026-04-21
- Scope: Collateral vault deposit caps
- Files Modified:
  - src/collateral/CollateralVaultStorage.sol
  - src/collateral/CollateralVaultAdmin.sol
  - src/collateral/CollateralVaultActions.sol
  - src/collateral/CollateralVaultYield.sol
  - test/unit/vault/CollateralVault.t.sol
  - PROGRESS.md
- Summary:
  Added an owner-configurable per-token aggregate deposit cap to `CollateralVault`, with `totalDepositedByToken` tracking in token-native units, disabled-by-default `tokenDepositCap` semantics, deposit-only cap enforcement on both `deposit` and `depositFor`, and withdrawal-side aggregate reduction. Internal transfers remain unaffected by caps.
- Invariants Impacted:
  - Vault aggregate deposited accounting is now explicit per supported token in token-native units
  - Deposit caps bound new external collateral inflows without changing withdrawals or internal account-to-account transfers
  - No protocol economics, yield strategy movement rules, liquidation flows, collateral weights, or unit scaling changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/vault/CollateralVault.t.sol`: OK (10 passed)
- Status: DONE

---

- Date: 2026-04-21
- Scope: Options launch safety caps
- Files Modified:
  - src/margin/MarginEngineTypes.sol
  - src/margin/MarginEngineStorage.sol
  - src/margin/MarginEngineAdmin.sol
  - src/margin/MarginEngineTrading.sol
  - test/unit/margin/MarginEngine.t.sol
  - PROGRESS.md
- Summary:
  Added an owner-configurable per-series aggregate short-open-interest cap to `MarginEngine`, with tracked `seriesShortOpenInterest`, disabled-by-default cap semantics, trade-time enforcement, and focused unit tests for cap rejection and reduce-through behavior after a cap is lowered.
- Invariants Impacted:
  - Aggregate option short exposure per series is now explicitly tracked and bounded when configured
  - Option position indexing and per-trader short exposure remain synchronized through the existing position mutation helper
  - No option pricing, margin, liquidation, settlement, fee, or unit-scaling economics changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (11 passed)
- Status: DONE

---

- Date: 2026-04-17
- Scope: Margin engine fuzz/property suite
- Files Modified:
  - test/fuzz/options/MarginEngineFuzz.t.sol
  - PROGRESS.md
- Summary:
  Added a bounded Foundry fuzz/property suite for `MarginEngine` using the real `MarginEngine`, `OptionProductRegistry`, and `CollateralVault`, with narrow in-file oracle and risk mocks only. The suite drives bounded option trade, reduce, close, settlement, inactive-series, expiry, and liquidation sequences and checks trader-series index coherence, zero-position index removal, aggregate short exposure consistency, reduce/close short-exposure monotonicity, settlement and lifecycle guard coherence, and bounded liquidation sizing.
- Invariants Impacted:
  - Trader open-series indexing remains coherent with live non-zero option positions
  - Zero-quantity option positions remain absent from active trader series lists
  - `totalShortContracts` remains aligned with aggregate live short option quantities under tested sequences
  - Reduce and close transitions do not increase short exposure unexpectedly
  - Settlement, inactive-series, and expiry guards remain explicit and coherent under bounded inputs
  - Liquidation closes remain bounded by live short inventory and configured close-factor limits without creating impossible position signs
  - No protocol economics, storage layout, or contract logic changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/fuzz/options/MarginEngineFuzz.t.sol`: OK (6 passed)
- Status: DONE

---

- Date: 2026-04-17
- Scope: Perp engine fuzz/property suite
- Files Modified:
  - test/fuzz/perp/PerpEngineFuzz.t.sol
  - PROGRESS.md
- Summary:
  Added the first bounded Foundry fuzz/property suite for `PerpEngine` using the real `PerpEngine`, `PerpMarketRegistry`, and `CollateralVault`, with narrow in-file oracle, risk, and token mocks only. The suite drives bounded transition sequences across one perp market and checks reference-model position accounting, open-interest coherence, reduce-only exposure behavior, realized PnL cashflow consistency, and residual-bad-debt exposure gating.
- Invariants Impacted:
  - Position size, open-notional basis, and funding checkpoint accounting remain coherent across open, increase, reduce, close, and flip transitions
  - Market open interest remains aligned with aggregate live long and short positions under tested trade sequences
  - Reduce and close transitions do not increase absolute exposure unexpectedly
  - Realized PnL cashflows remain finite and consistent with bounded base-token vault transfers
  - Traders with residual bad debt remain unable to increase exposure until debt is cleared
  - No protocol economics, storage layout, or contract logic changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/fuzz/perp/PerpEngineFuzz.t.sol`: OK (5 passed)
- Status: DONE

---

- Date: 2026-04-17
- Scope: Liquidation and shortfall accounting invariant suite
- Files Modified:
  - test/invariant/liquidation/LiquidationInvariants.t.sol
  - PROGRESS.md
- Summary:
  Added a Foundry invariant suite for perp liquidation and shortfall accounting safety using the real `PerpEngine`, `PerpMarketRegistry`, and `CollateralVault`, with narrow in-file oracle, risk, seizer, insurance, and token mocks only. The handler drives deterministic fresh-trader liquidation cases spanning full seizure coverage, partial seizure plus insurance coverage, explicit residual shortfall creation, no-seizer shortfall, and over-planned seizure cases.
- Invariants Impacted:
  - Seized collateral effective value remains capped by conservative planned coverage
  - Liquidation crediting remains bounded by actual trader and insurance balances moved through the vault
  - Residual bad debt remains created only through explicit liquidation shortfall resolution
  - Insurance coverage remains capped by both requested shortfall and actual available fund balance
  - Liquidation bookkeeping remains coherent across trader debits, liquidator credits, seized collateral, and residual bad debt totals
  - No protocol economics, storage layout, or contract logic changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/invariant/liquidation/LiquidationInvariants.t.sol`: OK (6 passed)
- Status: DONE

---

- Date: 2026-04-17
- Scope: Position and index accounting invariant suite
- Files Modified:
  - test/invariant/engine/PositionIndexInvariants.t.sol
  - PROGRESS.md
- Summary:
  Added a Foundry invariant suite for option series indexing, perp market indexing, and perp open-interest accounting safety using the real `MarginEngine`, `PerpEngine`, `OptionProductRegistry`, `PerpMarketRegistry`, and `CollateralVault`, with narrow in-file token, oracle, and risk mocks only. The handler drives deterministic option and perp trade plus flatten transitions so both index insertion and index removal paths are exercised.
- Invariants Impacted:
  - Non-zero option positions remain represented in the active series index
  - Zero option positions remain absent from the active series index
  - Non-zero perp positions remain represented in the active market index
  - Zero perp positions remain absent from the active market index
  - No duplicate active series or market entries appear for a trader
  - Perp open interest remains coherent with aggregate live long and short positions under tested action sequences
  - No protocol economics, storage layout, or contract logic changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/invariant/engine/PositionIndexInvariants.t.sol`: OK (6 passed)
- Status: DONE

---

- Date: 2026-04-17
- Scope: Collateral vault accounting invariant suite
- Files Modified:
  - test/invariant/vault/CollateralVaultInvariants.t.sol
  - PROGRESS.md
- Summary:
  Added the first Foundry invariant suite for collateral vault accounting safety using the real `CollateralVault` and a narrow in-file handler with deterministic supported and unsupported token mocks. The suite exercises deposits, withdrawals, engine-authorized internal transfers, and rejected unsupported-token deposits to check accounting conservation and effective-balance safety across action sequences.
- Invariants Impacted:
  - Internal transfers conserve tracked accounting across participating accounts
  - Deposit and withdraw action sequences do not create phantom tracked balance
  - Unsupported tokens never enter tracked collateral accounting
  - Tested action sequences preserve non-negative effective accounting behavior under `checkInvariant`
  - No protocol economics, storage layout, or contract logic changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/invariant/vault/CollateralVaultInvariants.t.sol`: OK (4 passed)
- Status: DONE

---

- Date: 2026-04-17
- Scope: Oracle failure scenario suite
- Files Modified:
  - test/scenario/system/OracleFailureFlow.t.sol
  - PROGRESS.md
- Summary:
  Added a deterministic cross-module system scenario suite for oracle failure behavior using the real `OracleRouter`, `PerpEngine`, `PerpMarketRegistry`, and `CollateralVault`, with narrow in-file `IPriceSource`, risk, and insurance mocks only. The suite covers stale-price rejection on a protected liquidation path, zero-price rejection, future-timestamp rejection, unavailable-oracle safe failure, and conservative router fallback/deviation behavior when primary and secondary sources are configured.
- Invariants Impacted:
  - Oracle reads remain normalized to 1e8 and reject zero, stale, future, and unavailable data on protected paths
  - No liquidation path proceeds when the configured oracle state is unsafe or unusable
  - Primary/secondary fallback and deviation enforcement remain explicit and conservative
  - No protocol economics, storage layout, or contract logic changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/scenario/system/OracleFailureFlow.t.sol`: OK (5 passed)
- Status: DONE

---

- Date: 2026-04-17
- Scope: Residual bad debt repayment scenario suite
- Files Modified:
  - test/scenario/system/BadDebtRepaymentFlow.t.sol
  - PROGRESS.md
- Summary:
  Added a deterministic cross-module system scenario suite for perp residual bad debt repayment behavior using the real `PerpEngine`, `PerpMarketRegistry`, and `CollateralVault`, with narrow in-file oracle, risk, seizer, and insurance mocks only. The suite covers liquidation-created residual bad debt, exposure-increase blocking while debt exists, reduce-only transitions, debt-first routing of incoming realized cashflow, bounded partial/full repayment, and restoration of normal exposure increase once debt is fully cleared.
- Invariants Impacted:
  - Residual bad debt remains created only through the explicit liquidation shortfall path
  - Accounts with residual bad debt remain strict reduce-only until debt is cleared
  - Incoming realized cashflow and explicit repayment remain capped by outstanding debt and actual transferable base balance
  - No protocol economics, storage layout, or contract logic changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/scenario/system/BadDebtRepaymentFlow.t.sol`: OK (8 passed)
- Status: DONE

---

- Date: 2026-04-15
- Scope: Baseline build check
- Files Modified:
  - PROGRESS.md
- Summary:
  Ran `forge build` after reviewing the required repository docs. The build completed without a blocking compiler error, so no Solidity source change was made.
- Invariants Impacted:
  - None
- Validation:
  - `forge build`: OK
- Status: DONE

---

- Date: 2026-04-15
- Scope: Oracle unsafe cast hardening
- Files Modified:
  - src/oracle/ChainlinkPriceSource.sol
  - src/oracle/PythPriceSource.sol
  - src/oracle/OracleRouter.sol
  - PROGRESS.md
- Summary:
  Removed the `unsafe-typecast` warnings under the requested `src/oracle/*` files by using `SafeCast` for signed feed values, replacing width-only `BPS` comparisons with width-neutral checks, and making the Pyth exponent bound explicit in signed form. Oracle normalization, timestamp checks, and deviation behavior were otherwise unchanged.
- Invariants Impacted:
  - No protocol economics changed
  - Oracle outputs remain normalized to 1e8
  - Staleness, future-timestamp rejection, and deviation enforcement remain explicit
- Validation:
  - `forge build`: OK
- Status: DONE

---

- Date: 2026-04-15
- Scope: Perp unsafe cast hardening
- Files Modified:
  - src/perp/PerpEngineTypes.sol
  - src/perp/PerpEngineStorage.sol
  - src/perp/PerpRiskModule.sol
  - src/perp/PerpEngineTrading.sol
  - src/perp/PerpMarketRegistry.sol
  - PROGRESS.md
- Summary:
  Removed the `unsafe-typecast` warnings under the requested `src/perp/*` files by routing bounded signed/unsigned and narrowing conversions through existing perp helpers or `SafeCast`, and by replacing registry bound comparisons with width-neutral `BPS` checks only. No perp pricing, funding, liquidation, or risk formulas were changed.
- Invariants Impacted:
  - No protocol economics changed
  - Position sign handling and aggregate exposure accounting remain explicit
  - Funding checkpoint math and margin ratios remain in their existing 1e18, 1e8, and base-native units
- Validation:
  - `forge build`: OK
- Status: DONE

---

- Date: 2026-04-15
- Scope: Margin unsafe cast hardening
- Files Modified:
  - src/margin/MarginEngineTypes.sol
  - src/margin/MarginEngineViews.sol
  - src/margin/MarginEngineOps.sol
  - src/margin/MarginEngineStorage.sol
  - PROGRESS.md
- Summary:
  Removed the `unsafe-typecast` warnings under `src/margin/*` by replacing bounded narrowing and signed/unsigned conversions with `SafeCast`, reusing the existing `_absInt128` guard for negative quantity magnitudes, and adding explicit justification comments only where surrounding logic already made the cast trivially safe.
- Invariants Impacted:
  - No protocol economics changed
  - Quantity sign and `int128.min` exclusion remain explicit in margin paths
  - Margin and settlement values remain in their existing base-native and settlement-native units
- Validation:
  - `forge build`: OK
- Status: DONE

---

- Date: 2026-04-15
- Scope: Risk-module unsafe cast hardening
- Files Modified:
  - src/risk/RiskModuleUtils.sol
  - src/risk/RiskModuleViews.sol
  - src/risk/RiskModuleAdmin.sol
  - PROGRESS.md
- Summary:
  Replaced `src/risk/*` unsafe narrowing/signed casts with explicit safe conversions or width-neutral comparisons only. This removed the risk-module `unsafe-typecast` warnings without changing valuation, margin, or liquidation economics.
- Invariants Impacted:
  - No economic invariant changed
  - Safer enforcement of unit-consistent signed/unsigned conversions in risk paths
- Validation:
  - `forge build`: OK
- Status: DONE

---

- Date: 2026-04-15
- Scope: Registry, fees, and liquidation unsafe cast hardening
- Files Modified:
  - src/OptionProductRegistry.sol
  - src/fees/FeesManager.sol
  - src/liquidation/CollateralSeizer.sol
  - PROGRESS.md
- Summary:
  Removed the remaining `unsafe-typecast` warnings in the requested registry, fees, and liquidation files by replacing width-only comparisons with width-neutral checks and by introducing a typed contract-size lock constant for the options registry. No option sizing, expiry gating, fee caps, or seizure economics changed.
- Invariants Impacted:
  - No protocol economics changed
  - Option contract size remains hard-locked to `1e8`
  - Min-expiry enforcement remains explicit
  - Fee and spread BPS bounds remain capped at `10_000`
- Validation:
  - `forge build`: OK
  - `forge build 2>&1 | rg "unsafe-typecast"`: no matches
- Status: DONE

---

- Date: 2026-04-15
- Scope: Initial collateral vault unit test suite
- Files Modified:
  - src/risk/RiskModuleUtils.sol
  - test/unit/vault/CollateralVault.t.sol
  - PROGRESS.md
- Summary:
  Removed the single unused `Math` import from `RiskModuleUtils` and added the first minimal Foundry unit tests for `CollateralVault`, covering deposit, withdraw, insufficient-balance revert, unsupported-token revert, internal transfer conservation, and token config/decimals sanity.
- Invariants Impacted:
  - Vault balances remain explicit token-native accounting
  - Unsupported tokens remain excluded from vault accounting paths
  - Internal transfers preserve aggregate in-vault token balances
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/vault/CollateralVault.t.sol`: OK (6 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: First perp full-liquidation scenario suite
- Files Modified:
  - test/scenario/perp/PerpFullLiquidationFlow.t.sol
  - PROGRESS.md
- Summary:
  Added the first deterministic cross-module perp liquidation scenario suite using the real `PerpEngine`, `PerpMarketRegistry`, and `CollateralVault` with narrow in-file oracle, risk, seizer, and insurance mocks only. The scenarios cover adverse-price liquidation with solvency improvement, collateral-seizer plan consumption, insurance-fund top-up when seized collateral is insufficient, residual bad-debt recording after collateral and insurance are exhausted, and healthy-account liquidation rejection.
- Invariants Impacted:
  - Liquidation remains explicit across seized collateral, insurance coverage, and residual bad debt
  - Position conservation and post-liquidation solvency improvement remain enforced on the real engine path
  - No protocol economics, perp logic, or contract storage/layout changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/scenario/perp/PerpFullLiquidationFlow.t.sol`: OK (5 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: First option settlement scenario suite
- Files Modified:
  - test/scenario/options/OptionSettlementFlow.t.sol
  - PROGRESS.md
- Summary:
  Added the first deterministic cross-module option-settlement scenario suite using the real `MarginEngine`, `OptionProductRegistry`, and `CollateralVault` with narrow in-file oracle, risk, and insurance mocks only. The scenarios cover ITM settlement with correct payoff, OTM zero-payoff settlement, per-account settlement idempotency, premium-plus-payoff accounting coherence across the full flow, insurance-fund-backed payout on settlement shortfall, and residual bad-debt recording when payout coverage remains insufficient.
- Invariants Impacted:
  - Option settlement remains idempotent per account and series
  - Collected, paid, and bad-debt series accounting remains explicit in settlement-asset native units
  - Insurance usage and residual shortfall remain explicit without changing protocol economics or storage/layout
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/scenario/options/OptionSettlementFlow.t.sol`: OK (6 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Deterministic margin engine core unit test suite
- Files Modified:
  - test/unit/margin/MarginEngine.t.sol
  - PROGRESS.md
- Summary:
  Added a deterministic Foundry unit suite for `MarginEngine` using the real engine, registry, and vault with in-file oracle and risk-module mocks only. The suite covers trader open-series tracking on open/close, total short exposure updates, premium transfer, expiry settlement payoff, single-use settlement behavior, liquidation size reduction, liquidation penalty routing, and the empty-account read surface.
- Invariants Impacted:
  - Open-series indexing remains consistent with non-zero option positions
  - Total short exposure remains coherent with short position transitions and liquidation reductions
  - Premium, settlement payoff, and liquidation penalty cashflows remain explicit in settlement/base native units without changing protocol economics
  - Option settlement idempotency remains enforced per account and per series
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/margin/MarginEngine.t.sol`: OK (9 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Deterministic fees manager unit test suite
- Files Modified:
  - test/unit/fees/FeesManager.t.sol
  - PROGRESS.md
- Summary:
  Added a deterministic Foundry unit suite for `FeesManager` using the real contract with minimal in-file Merkle helpers only. The suite covers default maker/taker quotes, individual field cap enforcement, tier profile lookups, override precedence, expired-override fallback, min(notional fee, premium cap fee) quote behavior, zero-input zero-fee behavior, successful Merkle tier claim, and invalid-proof revert behavior.
- Invariants Impacted:
  - Fee quotes remain explicit in `BPS = 10_000` using `min(notionalFee, premiumCapFee)` semantics
  - Active override precedence and expired override fallback remain explicit without changing protocol economics
  - Merkle tier claims remain bound to the current epoch and reject invalid proofs
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/fees/FeesManager.t.sol`: OK (10 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Deterministic governance and timelock unit/integration test suite
- Files Modified:
  - test/unit/governance/Governance.t.sol
  - PROGRESS.md
- Summary:
  Added a deterministic Foundry suite covering `RiskGovernor` and `ProtocolTimelock` with a real `FeesManager` target owned by the timelock. The suite covers operation-hash/bookkeeping storage on queue, queued-operation cancellation state, pre-eta execution rejection, post-eta execution success, queued fee-parameter updates on the live target module, owner/proposer queue authorization, guardian/owner cancel permissions, and malformed calldata execution failure behavior.
- Invariants Impacted:
  - Timelock operation identity remains explicit as `keccak256(abi.encode(target, value, data, eta))`
  - Queue, cancel, and execute permission boundaries remain explicit across governor-owner, timelock-proposer, and guardian/owner cancel paths
  - Queued parameter changes remain delayed by timelock eta before mutating the target module
  - Malformed calldata cannot mutate target state and leaves the queued operation intact after failed execution
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/governance/Governance.t.sol`: OK (8 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Deterministic perp liquidation unit test suite
- Files Modified:
  - test/unit/perp/PerpEngineLiquidation.t.sol
  - PROGRESS.md
- Summary:
  Added a deterministic Foundry unit suite for `PerpEngine` liquidation behavior using the real engine, registry, and vault with in-file oracle, risk, seizer, and insurance mocks only. The suite covers healthy-account rejection, partial liquidation, close-factor enforcement, direct penalty transfer with sufficient collateral, configured seizer-plan usage, insurance-fund coverage when seizure is insufficient, residual bad debt recording when both seizure and insurance are insufficient, and the solvency-improvement guard.
- Invariants Impacted:
  - Position reductions remain bounded by configured close factor and preserve sign consistency
  - Penalty routing, insurance coverage, and residual bad debt recording remain explicit in base-token native units
  - Liquidation improvement gating remains explicit and reverts atomically when solvency does not improve
  - No protocol economics or contract storage/layout changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/perp/PerpEngineLiquidation.t.sol`: OK (8 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Deterministic perp funding unit test suite
- Files Modified:
  - test/unit/perp/PerpEngineFunding.t.sol
  - PROGRESS.md
- Summary:
  Added a deterministic Foundry unit suite for `PerpEngine` funding behavior using the real engine, registry, and vault with in-file oracle and risk-module mocks only. The suite covers first-call funding initialization, disabled-funding and zero-elapsed no-op cases, positive and negative premium deltas, deadband suppression, cap clamping, and accrued funding visibility on an open position after a funding update.
- Invariants Impacted:
  - Funding accumulator updates remain explicit in 1e18 precision
  - Funding accrual on open positions remains consistent with stored cumulative checkpoints
  - No protocol economics, liquidation behavior, or contract storage/layout changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/perp/PerpEngineFunding.t.sol`: OK (8 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Initial perp engine unit test suite
- Files Modified:
  - test/unit/perp/PerpEngine.t.sol
  - PROGRESS.md
- Summary:
  Added the first deterministic Foundry unit suite for `PerpEngine` using the real engine, registry, and vault with in-file oracle and risk-module mocks only. The suite covers long/opening position accounting, offsetting open-interest updates, same-side increases, reduction PnL realization, full close reset, side-flip basis reset, bad-debt exposure-increase blocking, and reduce-only transitions under residual bad debt.
- Invariants Impacted:
  - Position sign transitions remain explicit across increase, reduce, close, and flip flows
  - Open interest remains consistent with aggregate long and short exposure
  - Residual bad debt continues to block exposure increases while allowing strict reduce-only transitions
  - No protocol economics or contract storage/layout changed
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/perp/PerpEngine.t.sol`: OK (8 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Collateral seizer unit test suite
- Files Modified:
  - test/unit/liquidation/CollateralSeizer.t.sol
  - PROGRESS.md
- Summary:
  Added a minimal deterministic Foundry unit suite for `CollateralSeizer` using the real vault and seizer with in-file oracle and risk-config mocks. The tests cover token discount behavior, base and non-base valuation previews, base-first seizure ordering, secondary-collateral usage, partial-coverage planning, and the zero-target empty-plan case.
- Invariants Impacted:
  - Base-value conversion remains explicit in native base-token units with `PRICE_SCALE = 1e8`
  - Token discounting remains explicit through collateral weight and spread in `BPS = 10_000`
  - Seizure planning remains conservative, base-first, and partial when collateral is insufficient
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/liquidation/CollateralSeizer.t.sol`: OK (8 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Risk module unit test suite
- Files Modified:
  - test/unit/risk/RiskModule.t.sol
  - PROGRESS.md
- Summary:
  Added a minimal deterministic Foundry unit suite for `RiskModule` using the real vault, registry, and risk module with in-file oracle and margin-engine mocks. The tests cover account-risk consistency, margin-ratio thresholds, zero-position margins, collateral-weight adjustment, multi-collateral aggregation, free-collateral consistency, and below-threshold liquidation-condition detection.
- Invariants Impacted:
  - Equity, maintenance margin, and initial margin remain coherent in base-native units
  - Collateral valuation remains normalized through `PRICE_SCALE` and `BPS`
  - Haircut-adjusted collateral aggregation remains explicit across supported tokens
  - Margin-ratio threshold behavior remains explicit at above, equal, and below `BPS`
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/risk/RiskModule.t.sol`: OK (7 passed)
- Status: DONE

---

- Date: 2026-04-16
- Scope: Collateral vault unit test validation
- Files Modified:
  - PROGRESS.md
- Summary:
  Reviewed the required repository docs, confirmed `test/unit/vault/CollateralVault.t.sol` already contains only the requested six collateral-vault unit tests, and verified the file against the current vault interfaces without changing protocol contracts.
- Invariants Impacted:
  - None
  - Existing vault token-native accounting and internal transfer conservation checks remain unchanged
- Validation:
  - `forge build`: OK
  - `forge test --match-path test/unit/vault/CollateralVault.t.sol`: OK (6 passed)
- Status: DONE
