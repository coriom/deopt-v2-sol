# FINAL_LAUNCH_CHECKLIST.md

## Purpose

Final go/no-go launch checklist for DeOpt v2.

This document is a launch decision artifact only. It does not change protocol logic, deployment scripts, ownership, economics, parameters, or contract behavior.

Status placeholders:

- `PENDING`: evidence not yet reviewed.
- `GO`: evidence reviewed and accepted.
- `NO-GO`: failed or missing evidence; launch must not proceed.
- `WAIVED`: accepted by the required signers with written rationale. `P0` failures must not be waived for mainnet activation.

Blocking severity:

- `P0`: hard no-go for mainnet activation.
- `P1`: no-go unless remediated or formally waived by all final signers.
- `P2`: launch-risk item requiring explicit owner, mitigation, and sign-off.

---

## Go / No-Go Checklist

### Code Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Audited commit is frozen and tagged for launch | PENDING | Git commit hash, tag, signed release note | Protocol lead | P0 |
| No unreviewed Solidity or script changes after audit closure | PENDING | Diff against audited commit and final closure matrix | Security lead | P0 |
| `forge build` passes on the exact launch commit | PENDING | Build log with commit hash and timestamp | Protocol lead | P0 |
| Contract addresses in manifest match deployed bytecode for launch commit | PENDING | Manifest hash, bytecode/source verification output | Deployment owner | P0 |
| No unresolved storage-layout or unit-scaling concern remains | PENDING | Security review notes and invariant checklist | Security lead | P0 |

### Test Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Full `forge test` suite passes | PENDING | Full test log with commit hash | Protocol lead | P0 |
| Unit tests pass for vault, risk, margin, perps, liquidation, fees, matching, and governance | PENDING | Targeted unit test logs | Protocol lead | P0 |
| Scenario tests pass for settlement, liquidation, oracle failure, and bad debt repayment | PENDING | Scenario test logs | Security lead | P0 |
| Invariant tests pass for vault accounting, position/OI indexing, and liquidation/shortfall accounting | PENDING | Invariant test logs and configured run counts | Security lead | P0 |
| Fuzz tests pass for options and perps arithmetic/state transitions | PENDING | Fuzz test logs and configured runs | Security lead | P1 |

### Deployment Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Active deployment manifest is complete for target environment | PENDING | Filled manifest with hash and no unresolved production placeholders | Deployment owner | P0 |
| Chain id, RPC, explorer, deployer, and deployment block policy are verified | PENDING | Manifest review record and chain-id verification log | Deployment owner | P0 |
| Deployment sequence matches `DEPLOYMENT_PLAN.md` and `RUNBOOK.md` | PENDING | Reviewed transaction plan using `DeployCore`, `WireCore`, `ConfigureCore`, `ConfigureMarkets`, `VerifyDeployment`, `TransferOwnerships`, `AcceptOwnerships` | Ops lead | P0 |
| Every core contract has bytecode at the expected address | PENDING | Bytecode check output for all core addresses | Deployment owner | P0 |
| `VerifyDeployment.s.sol` passes against the final configured stack | PENDING | Verify script output and transaction/read context | Deployment owner | P0 |

### Configuration Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Core dependency wiring matches manifest | PENDING | Verify output for vault, risk, engines, oracle, seizer, insurance, fees, and matching pointers | Deployment owner | P0 |
| Initial products remain inactive, restricted, or close-only until final activation | PENDING | Manifest activation states and onchain view output | Ops lead | P0 |
| Launch caps are configured for all initial option series and perp markets | PENDING | Cap values, onchain reads, and approval record | Risk operator | P0 |
| Fee configuration and treasury recipient match approved launch state | PENDING | Fee manager and engine fee-recipient read output | Governance/multisig lead | P1 |
| No mainnet manifest placeholder remains for required addresses, caps, roles, or feeds | PENDING | Manifest placeholder scan and reviewer sign-off | Ops lead | P0 |

### Ownership / Governance Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Ownership transfer and acceptance completed for all core modules | PENDING | Ownership event log and post-handoff owner reads | Governance/multisig lead | P0 |
| No production module remains owned by the deployer unless explicitly approved | PENDING | Owner/pending-owner diff against manifest and `ROLE_MATRIX.md` | Governance/multisig lead | P0 |
| Timelock proposers, executors, guardian, and min delay match approved policy | PENDING | Timelock role reads and event history | Governance/multisig lead | P0 |
| `RiskGovernor` ownership and timelock proposer authorization are verified | PENDING | Governor owner reads and `ProposerSet` evidence | Governance/multisig lead | P1 |
| Harmless governance queue/cancel/execute rehearsal has passed in staging | PENDING | Governance operation log with post-state reads | Governance/multisig lead | P1 |

### Oracle Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| ETH/USDC and BTC/USDC active feeds are configured from approved sources | PENDING | Feed config reads and manifest source mapping | Oracle/feed admin | P0 |
| Every active feed returns nonzero fresh `1e8` prices | PENDING | Oracle sanity output with price, timestamp, age, max delay, and scale evidence | Oracle/feed admin | P0 |
| Stale, zero, unavailable, and future timestamp failure modes are tested | PENDING | Oracle failure scenario or staging drill evidence | Security lead | P0 |
| No mainnet feed uses mock sources | PENDING | Manifest and source bytecode/type verification | Oracle/feed admin | P0 |
| Oracle alerting is live for stale, zero, unavailable, deviation, and feed drift | PENDING | Monitoring alert test evidence | Ops lead | P0 |

### Collateral / Risk Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Base collateral token, decimals, and vault support match manifest | PENDING | Vault config reads and token decimal evidence | Risk operator | P0 |
| Collateral restriction mode and launch-active collateral set match manifest | PENDING | Vault/risk reads and manifest comparison | Risk operator | P0 |
| Deposit caps are configured and below approved launch limits | PENDING | Cap reads, utilization dashboard, and approval record | Risk operator | P0 |
| `RiskModule` and `PerpRiskModule` return coherent base-native risk outputs | PENDING | Risk sanity output and targeted test evidence | Security lead | P0 |
| Liquidation and collateral seizure previews are reconciled against configured parameters | PENDING | Liquidation/seizer test logs and staging evidence | Security lead | P0 |

### Insurance Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Insurance fund is funded above approved launch threshold | PENDING | Fund balances, vault balances, threshold calculation | Insurance operator | P0 |
| Allowed tokens and custody token match manifest | PENDING | Insurance token allowlist reads | Insurance operator | P0 |
| Backstop callers are only canonical approved engines/modules | PENDING | Backstop caller reads and manifest comparison | Insurance operator | P0 |
| Insurance coverage path and residual bad debt path were rehearsed | PENDING | Staging rehearsal evidence and alert ids | Security lead | P1 |
| Low-balance and depletion response procedures are ready | PENDING | Runbook operator assignment and escalation test | Ops lead | P1 |

### Monitoring Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Active deployment manifest is ingested by monitoring | PENDING | Manifest hash in indexer/dashboard | Ops lead | P0 |
| `ROLE_MATRIX.md` expectations are ingested and checked against onchain state | PENDING | Role drift dashboard output | Ops lead | P0 |
| Required dashboards render for overview, vault, risk, perps, options, liquidation, oracle, insurance, and governance/roles | PENDING | Dashboard screenshots or exported panel logs | Ops lead | P1 |
| Required `P0` and `P1` alerts have been tested end-to-end | PENDING | Alert test report with routed notifications and acknowledgements | Ops lead | P0 |
| Reorg handling, alert deduplication, and failed verification alerting are configured | PENDING | Indexer config and test evidence | Ops lead | P1 |

### Runbook Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Launch-day procedure is assigned to named operators | PENDING | Operator roster and launch timeline | Ops lead | P1 |
| Abort criteria are reviewed before deployment and activation | PENDING | Signed launch-room checklist | Ops lead | P0 |
| Incident procedures are assigned for oracle, liquidation, bad debt, insurance, settlement, matching, guardian, role drift, caps, and emergency activation | PENDING | Incident response roster and escalation map | Ops lead | P1 |
| Governance and insurance operation procedures are rehearsed or dry-run | PENDING | Rehearsal logs and operator notes | Governance/multisig lead | P1 |
| Required incident artifacts template is ready | PENDING | Incident artifact template and storage location | Ops lead | P2 |

### Staging Rehearsal Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Full staging rehearsal is marked pass | PENDING | Final staging rehearsal report | Ops lead | P0 |
| Deployment, configuration, handoff, and activation phases completed in staging | PENDING | Staging transaction list and manifest | Deployment owner | P0 |
| Functional smoke tests completed for deposit/withdraw, options, perps, funding, liquidation, insurance, and bad debt | PENDING | Smoke test evidence package | Security lead | P0 |
| Incident drills completed for oracle stale, matching compromise, close-only, collateral cap, and OI cap | PENDING | Incident drill logs and alert ids | Ops lead | P0 |
| Failed/reverted transaction log is complete and all material failures are resolved or accepted | PENDING | Failed/reverted transaction log with dispositions | Security lead | P1 |

### Audit Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Audit scope and package are complete | PENDING | `AUDIT_PREP.md`, audited commit hash, package archive/hash | Security lead | P0 |
| External audit findings report is received and reviewed | PENDING | Final findings report | Security lead | P0 |
| No unresolved Critical or High audit issue remains | PENDING | Final closure matrix and remediation review | Security lead | P0 |
| Medium findings have remediation, waiver, or explicit launch-risk acceptance | PENDING | Closure matrix with owner and rationale | Security lead | P1 |
| Post-remediation `forge build`, tests, and targeted PoC retests pass | PENDING | Retest logs and remediation review | Security lead | P0 |

### Market-Maker / Liquidity Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Initial market-maker accounts are identified and role-separated from privileged protocol roles | PENDING | Account list and role-conflict review | Market/liquidity lead | P1 |
| Initial liquidity plan is approved for each launch option series and perp market | PENDING | Liquidity plan with market, size, spread, and cap assumptions | Market/liquidity lead | P1 |
| Market-maker funding and collateral deposits are ready within launch caps | PENDING | Funding transaction plan and collateral cap utilization estimate | Market/liquidity lead | P1 |
| Matching executor and market-maker operational handoff is tested | PENDING | Dry-run trade evidence and matching service status | Market/liquidity lead | P1 |
| Liquidity withdrawal or halt plan exists for incident response | PENDING | Liquidity incident procedure and contact roster | Market/liquidity lead | P2 |

### Incident Response Readiness

| Item | Status | Evidence Artifact Required | Responsible Role | Blocking Severity If Failed |
| --- | --- | --- | --- | --- |
| Guardian and emergency responder access is verified | PENDING | Guardian Safe/access check and pause transaction rehearsal | Ops lead | P0 |
| Emergency pause and close-only controls are tested | PENDING | Drill logs, onchain events, and post-state reads | Ops lead | P0 |
| Escalation paths for `P0`, `P1`, and `P2` alerts are tested | PENDING | Alert routing and acknowledgement evidence | Ops lead | P0 |
| Communications and incident evidence capture are ready | PENDING | Incident channel, artifact storage, and template evidence | Ops lead | P2 |
| Recovery and unpause criteria are reviewed by governance and security leads | PENDING | Signed recovery criteria review | Governance/multisig lead | P1 |

---

## Explicit No-Go Conditions

Launch must not proceed if any of the following are true:

- `forge build` fails on the exact launch commit.
- `forge test` fails, or critical targeted scenario/invariant/fuzz tests fail.
- `script/VerifyDeployment.s.sol` fails against the final configured stack.
- Ownership handoff is missing, incomplete, or leaves an unintended deployer owner.
- Any required oracle feed is stale, zero, unavailable, unverified, future-dated, incorrectly scaled, or points to an unexpected source.
- Insurance fund balance is below the approved launch threshold.
- Required monitoring dashboards or `P0`/`P1` alerts are missing, untested, or not routed to operators.
- Any Critical or High audit issue is unresolved.
- Any required production role assignment is missing, unresolved, or mismatched against the manifest and `ROLE_MATRIX.md`.
- Staging rehearsal failed, is incomplete, or has unresolved `P0`/`P1` issues.
- Launch caps are not configured for every launch option series and perp market.
- Emergency pause, close-only, and recovery controls have not been tested.
- Mainnet manifest still contains unresolved placeholders for required addresses, roles, caps, feeds, or verification state.
- Active products are enabled before deployment verification, ownership handoff, monitoring readiness, and final sign-off.

---

## Final Sign-Off Table

All final signers must mark `GO` before mainnet activation.

| Role | Status | Name / Entity | Evidence Reviewed | Signature / Approval Reference | Timestamp |
| --- | --- | --- | --- | --- | --- |
| Protocol lead | PENDING | TODO_PROTOCOL_LEAD | Code readiness, tests, protocol invariants, launch commit | TODO_SIGNATURE_OR_TX_OR_TICKET | TODO_TIMESTAMP |
| Security lead | PENDING | TODO_SECURITY_LEAD | Audit closure, invariant tests, incident drills, no-go conditions | TODO_SIGNATURE_OR_TX_OR_TICKET | TODO_TIMESTAMP |
| Ops lead | PENDING | TODO_OPS_LEAD | Deployment plan, monitoring, runbook, staging rehearsal, incident response | TODO_SIGNATURE_OR_TX_OR_TICKET | TODO_TIMESTAMP |
| Governance/multisig lead | PENDING | TODO_GOVERNANCE_MULTISIG_LEAD | Ownership handoff, timelock roles, signers, final approvals | TODO_SIGNATURE_OR_TX_OR_TICKET | TODO_TIMESTAMP |
| Market/liquidity lead | PENDING | TODO_MARKET_LIQUIDITY_LEAD | Market-maker readiness, liquidity plan, launch caps, matching handoff | TODO_SIGNATURE_OR_TX_OR_TICKET | TODO_TIMESTAMP |

---

## Final Decision

| Field | Value |
| --- | --- |
| Target environment | TODO_TARGET_ENVIRONMENT |
| Manifest hash | TODO_MANIFEST_HASH |
| Launch commit | TODO_LAUNCH_COMMIT |
| Final decision | PENDING |
| Decision timestamp | TODO_TIMESTAMP |
| Activation transaction plan reference | TODO_ACTIVATION_PLAN_REFERENCE |
