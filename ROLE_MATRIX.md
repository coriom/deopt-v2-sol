# ROLE_MATRIX.md

## Purpose

This document defines the production role matrix for DeOpt v2.

It is the operational reference for:

- assigning privileged accounts before launch
- separating governance, emergency, execution, settlement, oracle, treasury, and deployment duties
- validating role handoff after deployment
- monitoring privileged actions
- rotating compromised or obsolete role holders

This file is not the on-chain source of truth. The on-chain source of truth remains contract storage and emitted events.

---

## Role Design Principles

- Production module ownership should end at `ProtocolTimelock`, a governance-controlled multisig, or an explicitly approved timelock-controlled multisig pattern.
- No production module should remain owned by the deployer after handoff.
- Guardian powers are for bounded incident response, not routine configuration.
- Matching executors are operational trade ingress accounts only; they must not hold governance or treasury power.
- Insurance backstop callers should be protocol engines or explicitly approved modules only.
- Fee recipients and treasury accounts must be distinct from emergency responders and matching executors.
- Oracle/feed administration must be monitored as a critical price integrity role.
- All role changes must be event-monitored and recorded in the deployment manifest for the target environment.

---

## Role Definitions

### Deployer

- Purpose: Deploy initial contracts, run deterministic deployment/configuration scripts, and start ownership handoff.
- Controlled Modules: Temporarily owns newly deployed modules until `TransferOwnerships.s.sol` and `AcceptOwnerships.s.sol` complete.
- Allowed Actions: Deploy contracts, run initial wiring/configuration, set bootstrap guardians, configure initial roles, initiate ownership transfers.
- Forbidden Actions: Retain production ownership after handoff, activate mainnet trading before verification and governance handoff, bypass documented deployment order.
- Recommended Holder: Local: developer EOA. Testnet: deployment EOA or deployer Safe. Mainnet: dedicated deployment Safe or tightly controlled deployer EOA used only for deployment.
- Operational Risk If Compromised: Malicious or incorrect deployment, bad dependency wiring, wrong owner/guardian assignment, unsafe market activation during bootstrap.
- Rotation Procedure: Stop deployment, revoke or abandon affected deployer, redeploy if ownership was not safely transferred, verify no production module remains owned by old deployer.
- Monitoring Alerts Required: Contract deployments, ownership transfer starts, unexpected owner still equal to deployer, role grants from deployer after handoff, activation before verification.

### Final Owner / Timelock

- Purpose: Own sensitive protocol modules after handoff and enforce delayed execution of governance changes.
- Controlled Modules: Expected final owner for `CollateralVault`, `RiskModule`, `OptionProductRegistry`, `MarginEngine`, `PerpMarketRegistry`, `PerpEngine`, `PerpRiskModule`, `CollateralSeizer`, `FeesManager`, `InsuranceFund`, `MatchingEngine`, `PerpMatchingEngine`, `OracleRouter`, `ProtocolTimelock`, and `RiskGovernor` as configured.
- Allowed Actions: Execute queued parameter changes, configure roles, unpause modules, rotate guardians, update risk/oracle/fees/collateral/market settings after governance delay.
- Forbidden Actions: Execute unqueued sensitive actions, skip the timelock delay, set zero or unmanaged critical owners, activate products without required sanity checks.
- Recommended Holder: Local: deployer or local timelock. Testnet: timelock owned by test multisig. Mainnet: `ProtocolTimelock` controlled by production multisig/governance.
- Operational Risk If Compromised: Full protocol configuration control, market/risk/oracle manipulation, unauthorized treasury and role changes.
- Rotation Procedure: Queue transfer to replacement owner, wait full delay, execute, accept ownership where two-step ownership is used, verify old owner and pending owner are cleared.
- Monitoring Alerts Required: `OwnershipTransferStarted`, `OwnershipTransferred`, `MinDelaySet`, `TransactionQueued`, `TransactionExecuted`, unpause events, owner set to EOA or zero.

### Multisig

- Purpose: Human-controlled approval layer for production governance, treasury, and high-impact operations.
- Controlled Modules: Should control timelock owner/final governance owner and may hold treasury or fee recipient accounts.
- Allowed Actions: Approve governance proposals, sign timelock ownership actions, approve treasury movement, rotate high-risk roles.
- Forbidden Actions: Directly operate matching execution, act as routine oracle updater, act as hot guardian unless explicitly designed as an emergency Safe.
- Recommended Holder: Local: optional developer Safe. Testnet: test multisig. Mainnet: production Safe with signer quorum, signer separation, and documented recovery path.
- Operational Risk If Compromised: Capture of governance owner, treasury loss, malicious role rotation, delayed but severe protocol parameter changes.
- Rotation Procedure: Rotate Safe signers per Safe policy, queue any required on-chain owner updates, verify threshold and signer set offchain and onchain.
- Monitoring Alerts Required: Safe signer/threshold changes, outgoing treasury transfers, timelock ownership changes, large or unusual queued governance actions.

### Governor

- Purpose: Provide typed governance helpers and proposal flow into `ProtocolTimelock`.
- Controlled Modules: `RiskGovernor` and the configured target module pointers it can queue operations for.
- Allowed Actions: Queue typed governance operations, queue generic timelock operations where needed, cancel through guardian/owner paths where supported.
- Forbidden Actions: Execute immediately without timelock, replace timelock semantics, queue malformed or unreviewed operations, act as matching or treasury hot account.
- Recommended Holder: Local: deployer or local test owner. Testnet: test governance Safe. Mainnet: governance Safe or governance process account with timelock proposer authorization.
- Operational Risk If Compromised: Malicious proposals can be queued; risk is delayed by timelock but operational response is required before execution.
- Rotation Procedure: Transfer `RiskGovernor` ownership through two-step ownership, update `ProtocolTimelock` proposer authorization, verify old governor/proposer cannot queue.
- Monitoring Alerts Required: Governor ownership changes, target updates, `TransactionQueued` from governor, unusual calldata targets, cancellation events.

### Proposer

- Purpose: Queue timelock operations for future execution.
- Controlled Modules: `ProtocolTimelock` queueing surface.
- Allowed Actions: Queue reviewed operations with eta respecting `minDelay`.
- Forbidden Actions: Execute operations unless separately authorized as executor, queue emergency bypasses, queue unreviewed target calls.
- Recommended Holder: Local: deployer or local governor. Testnet: `RiskGovernor` plus test governance Safe. Mainnet: `RiskGovernor` and approved governance Safe only.
- Operational Risk If Compromised: Attackers can queue malicious changes; timelock delay gives responders time to cancel if monitored.
- Rotation Procedure: Timelock owner calls `setProposer(old, false)` and `setProposer(new, true)` through governance, then confirms queue attempts from old proposer fail.
- Monitoring Alerts Required: `ProposerSet`, all `TransactionQueued`, eta too near policy threshold, unknown proposer address.

### Executor

- Purpose: Execute already queued and ready timelock operations.
- Controlled Modules: `ProtocolTimelock` execution surface.
- Allowed Actions: Execute queued operations after eta and before grace expiry.
- Forbidden Actions: Queue operations unless separately a proposer, execute stale/unreviewed operations, execute with unexpected native value.
- Recommended Holder: Local: deployer. Testnet: test executor bot or Safe. Mainnet: production executor bot/Safe; permissionless execution only if explicitly approved by governance policy.
- Operational Risk If Compromised: Ready malicious or stale operations may be executed if queued; executor cannot create new queued operations by itself.
- Rotation Procedure: Timelock owner calls `setExecutor(old, false)` and `setExecutor(new, true)`, then verifies execution authorization.
- Monitoring Alerts Required: `ExecutorSet`, `TransactionExecuted`, failed execution attempts, execution by unknown address, operations near grace expiry.

### Guardian

- Purpose: Bounded emergency control for pausing, close-only modes, queue cancellation, and incident containment.
- Controlled Modules: Guardian-enabled modules including vault, registries, engines, risk modules, oracle router, fees manager, insurance fund, matching engines, timelock, and governor where configured.
- Allowed Actions: Pause protected surfaces, set emergency modes where allowed, cancel timelock transactions where allowed, set close-only emergency flags where allowed.
- Forbidden Actions: Unpause unless also owner, change economic parameters, change owners, grant broad roles, move treasury funds unless separately authorized.
- Recommended Holder: Local: deployer or local guardian. Testnet: operational incident Safe. Mainnet: dedicated emergency Safe or constrained incident-response account distinct from governance and matching executors.
- Operational Risk If Compromised: Denial of service through pauses or canceled queued operations; generally cannot directly steal funds or change economics without owner power.
- Rotation Procedure: Owner/timelock calls `setGuardian(new)` or `clearGuardian`, verifies old guardian cannot pause/cancel, updates manifests and incident runbooks.
- Monitoring Alerts Required: `GuardianSet`, all pause/unpause events, emergency mode updates, close-only changes, timelock cancellations.

### Settlement Operator

- Purpose: Operate option settlement proposal/finalization when an explicit operator is configured.
- Controlled Modules: `OptionProductRegistry` settlement surface.
- Allowed Actions: Propose settlement prices, finalize settlement after finality delay, cancel settlement proposal where contract permissions allow.
- Forbidden Actions: Create markets, change risk params, change oracle feeds, settle before expiry/finality, submit unverified prices.
- Recommended Holder: Local: developer EOA. Testnet: test settlement operator. Mainnet: settlement Safe or constrained operator backed by documented price verification workflow.
- Operational Risk If Compromised: Incorrect option settlement price proposal/finalization can cause direct economic loss or bad-debt paths.
- Rotation Procedure: Owner/timelock calls `setSettlementOperator(new)`, verifies old operator cannot propose/finalize, updates settlement runbook.
- Monitoring Alerts Required: `SettlementOperatorSet`, settlement price proposed/finalized/canceled, settlement action before expected schedule, price deviation from oracle/reference.

### Matching Executor

- Purpose: Submit offchain matched trades to on-chain matching engines after signature and nonce checks.
- Controlled Modules: `MatchingEngine` and `PerpMatchingEngine` executor allowlists.
- Allowed Actions: Call trade execution/batch execution functions on matching engines for valid signed trades.
- Forbidden Actions: Own protocol modules, configure engines, bypass signatures, reuse nonces, execute while matching is paused.
- Recommended Holder: Local: developer EOA. Testnet: test matching service account. Mainnet: production matching service hot account with minimal funds and no governance authority.
- Operational Risk If Compromised: Can censor or submit valid signed orders; cannot forge signatures but can affect orderflow and timing.
- Rotation Procedure: Owner/timelock calls `setExecutor(old, false)` and `setExecutor(new, true)` on both matching engines, rotates service credentials, invalidates old infrastructure.
- Monitoring Alerts Required: `ExecutorSet`, matching pause events, unusual trade volume, nonce cancellation spikes, submissions from unknown executors.

### Insurance Operator

- Purpose: Manage operational funding, withdrawals, token allowlists, and optional yield operations for `InsuranceFund` where authorized.
- Controlled Modules: `InsuranceFund` operator surface.
- Allowed Actions: Fund insurance, deposit/withdraw allowed tokens through vault paths, sync/move allowed assets according to fund permissions.
- Forbidden Actions: Add backstop callers unless owner, change ownership/guardian, cover unapproved shortfalls, move non-allowed tokens, bypass pause flags.
- Recommended Holder: Local: deployer. Testnet: test treasury operator. Mainnet: treasury operations Safe distinct from governance and guardian.
- Operational Risk If Compromised: Mismanaged insurance liquidity, unauthorized treasury operations within allowed operator scope, reduced backstop availability.
- Rotation Procedure: Owner/timelock calls `setOperator(old, false)` and `setOperator(new, true)`, reconciles balances and revokes offchain credentials.
- Monitoring Alerts Required: `OperatorSet`, fund/withdraw events, yield movement events, token allowlist changes, low insurance balance.

### Insurance Backstop Caller

- Purpose: Consume bounded insurance coverage for explicit protocol shortfall flows.
- Controlled Modules: `InsuranceFund` backstop payout entry points.
- Allowed Actions: Authorized engines may request bounded vault shortfall coverage during settlement/liquidation flows.
- Forbidden Actions: EOA or unapproved module access, discretionary payouts, coverage requests outside engine accounting paths.
- Recommended Holder: Local: `MarginEngine` and `PerpEngine`. Testnet: deployed `MarginEngine` and `PerpEngine`. Mainnet: only canonical deployed engines or explicitly approved modules.
- Operational Risk If Compromised: If a caller module is compromised or incorrectly authorized, insurance balances can be drained up to available balances.
- Rotation Procedure: Owner/timelock calls `setBackstopCaller(old, false)` and `setBackstopCaller(new, true)`, verifies old caller fails, reconciles fund balance.
- Monitoring Alerts Required: `BackstopCallerSet`, `VaultBackstopPaid`, coverage amount above threshold, repeated coverage for same account/market, backstop caller not in manifest.

### Oracle / Feed Admin

- Purpose: Configure price sources, feed status, staleness limits, deviation thresholds, and feed ownership where applicable.
- Controlled Modules: `OracleRouter`, `ChainlinkPriceSource`, `PythPriceSource`, `PeggedStablePriceSource`, `MockPriceSource` in non-production, and feed source owner surfaces.
- Allowed Actions: Configure feeds, activate/deactivate feeds, set oracle delay/deviation limits, rotate price source ownership.
- Forbidden Actions: Use mock sources on mainnet, accept unnormalized prices, disable staleness checks, silently fallback without explicit config, hold unrelated treasury or matching privileges.
- Recommended Holder: Local: deployer or local oracle admin. Testnet: test oracle admin Safe. Mainnet: timelock/governance for router config; dedicated oracle operations Safe only if explicitly approved.
- Operational Risk If Compromised: Price manipulation, stale or invalid prices accepted, liquidation/settlement/risk corruption.
- Rotation Procedure: Transfer price source ownership where applicable, queue router admin updates through timelock, verify feed configs and prices against manifests.
- Monitoring Alerts Required: Feed set/clear events, read/config pause events, `GuardianSet`, source ownership changes, stale prices, zero prices, future timestamps, high deviation.

### Fee Recipient / Treasury

- Purpose: Receive protocol fees and hold treasury/insurance-related funds according to fee routing.
- Controlled Modules: Fee recipient addresses on `MarginEngine` and `PerpEngine`, treasury Safe, optional insurance fund account.
- Allowed Actions: Receive fees, manage treasury assets under approved policy, fund insurance as approved.
- Forbidden Actions: Execute trades as matching executor, hold guardian power by default, change fee policy unless also governance, commingle user funds.
- Recommended Holder: Local: developer account or local treasury. Testnet: test treasury Safe. Mainnet: production treasury Safe, optionally insurance fund if chosen as explicit fee sink.
- Operational Risk If Compromised: Loss or diversion of protocol revenue; if also insurance-funded, reduced backstop capacity.
- Rotation Procedure: Owner/timelock updates engine fee recipients and treasury Safe signers, verifies old recipient receives no new fees, reconciles balances.
- Monitoring Alerts Required: `FeeRecipientSet`, large fee flows, recipient set to EOA/zero where not intended, treasury transfers, insurance fund fallback fee routing.

### Emergency Responder

- Purpose: Execute the operational incident runbook using guardian, multisig, and monitoring workflows.
- Controlled Modules: No separate mandatory on-chain role unless also assigned guardian, proposer, or multisig signer.
- Allowed Actions: Trigger approved guardian pauses, coordinate cancellation of malicious queued operations, notify operators, collect incident evidence.
- Forbidden Actions: Make unilateral economic changes, unpause without owner/governance authorization, rotate ownership without governance process, operate matching or oracle feeds unless separately assigned.
- Recommended Holder: Local: developer. Testnet: protocol operations team. Mainnet: documented incident-response team with access to guardian Safe and monitoring.
- Operational Risk If Compromised: False incident actions, unnecessary downtime, delayed response, poor coordination during real incidents.
- Rotation Procedure: Rotate Safe signers and offchain credentials, update incident contacts/runbooks/manifests, verify guardian access boundaries.
- Monitoring Alerts Required: All emergency events, missed alert acknowledgments, prolonged pause state, queue cancellations, failed responder transactions.

---

## Module To Role Mapping

| Module | Owner / Final Authority | Emergency Role | Operational Roles | Treasury / Value Role | Monitoring Events |
|---|---|---|---|---|---|
| `CollateralVault` | Final owner / timelock | Guardian, emergency responder | Deployer during bootstrap | None directly; holds user balances | Ownership, guardian, pause, collateral config, engine authorization |
| `RiskModule` | Final owner / timelock, governor through timelock | Guardian | Deployer during bootstrap | None | Ownership, guardian, pause, risk params, collateral weights, dependency setters |
| `OptionProductRegistry` | Final owner / timelock, governor through timelock | Guardian | Series creator, settlement operator | None | Ownership, guardian, series creator, settlement operator, series/config/settlement events |
| `MarginEngine` | Final owner / timelock, governor through timelock | Guardian | Matching engine as authorized trade ingress | Fee recipient / treasury, insurance backstop caller integration | Ownership, guardian, pause, activation state, fee recipient, dependency setters, settlement/liquidation |
| `PerpMarketRegistry` | Final owner / timelock, governor through timelock | Guardian | Market creator | None | Ownership, guardian, market creator, market status, risk/funding/liquidation config |
| `PerpEngine` | Final owner / timelock, governor through timelock | Guardian | Perp matching engine as authorized trade ingress | Fee recipient / treasury, insurance backstop caller integration | Ownership, guardian, pause, close-only, activation state, fee recipient, residual debt, liquidation |
| `PerpRiskModule` | Final owner / timelock, governor through timelock | Guardian | None | None | Ownership, guardian, pause, oracle/vault/base config |
| `CollateralSeizer` | Final owner / timelock, governor through timelock | None unless owner-managed incident action | None | None | Ownership, oracle/vault/risk config, seize config |
| `FeesManager` | Final owner / timelock, governor through timelock | Guardian | None | Fee recipient / treasury consumes quoted/routed fees through engines | Ownership, guardian, pause, fee cap/defaults, merkle root, overrides |
| `InsuranceFund` | Final owner / timelock, governor through timelock | Guardian | Insurance operator, insurance backstop caller | Treasury / insurance reserve | Ownership, guardian, operator, token allowed, backstop caller, funding, withdrawal, payout |
| `MatchingEngine` | Final owner / timelock | Guardian | Matching executor | None | Ownership, guardian, executor, pause, engine pointer, trade submission, nonce cancellation |
| `PerpMatchingEngine` | Final owner / timelock | Guardian | Matching executor | None | Ownership, guardian, executor, pause, engine pointer, trade submission, nonce cancellation |
| `OracleRouter` | Final owner / timelock, governor through timelock | Guardian, oracle/feed admin through owner-governed config | Oracle/feed admin | None | Ownership, guardian, feed set/clear, max delay, pause reads/config |
| Price sources | Final owner / timelock or oracle/feed admin owner per environment | Oracle/feed admin | Oracle/feed admin | None | Ownership transfer, source config updates, price update events where available |
| `ProtocolTimelock` | Multisig/final governance owner | Guardian, emergency responder | Proposer, executor | May forward native value if queued | Ownership, guardian, proposer, executor, min delay, queued/canceled/executed |
| `RiskGovernor` | Multisig/final governance owner | Guardian for cancellation/queue helper controls where applicable | Governor, proposer via timelock authorization | None | Ownership, guardian, target updates, queued operations |

---

## Pre-Launch Role Checklist

- Deployment manifest for target environment lists every core contract address.
- Deployer address is documented and expected to be temporary.
- Final owner, timelock owner, risk governor owner, and governance owner are documented.
- Timelock `minDelay` matches launch policy and is within contract bounds.
- At least one approved proposer is configured; `RiskGovernor` is included where intended.
- At least one approved executor is configured.
- Guardian address is explicit and distinct from matching executors.
- Guardian can pause required modules in rehearsal.
- Owner/governance can unpause required modules in rehearsal.
- Option settlement operator is set or intentionally disabled.
- Series creators and market creators are restricted to approved accounts.
- Matching executors are configured on both matching engines and hold no governance role.
- Insurance operators are configured and distinct from matching executors.
- Insurance backstop callers are only canonical engines or approved modules.
- Oracle router feeds, price source owners, staleness limits, deviation limits, and active flags are documented.
- Fee recipient / treasury address is nonzero where required and controlled by the approved treasury holder.
- Emergency responder runbook exists and references actual guardian/multisig contacts.
- No mainnet manifest uses mock price sources.
- No mainnet role placeholder remains unresolved.
- `VerifyDeployment.s.sol` role and dependency checks pass for the deployed stack.
- Trading remains inactive or restricted until role handoff and post-deploy checks pass.

---

## Post-Handoff Ownership Checklist

- Every core module owner equals the expected final owner or timelock-controlled owner.
- No core module owner equals the deployer.
- Pending owner is cleared on every two-step ownable module.
- `ProtocolTimelock` owner is the expected final governance owner.
- `RiskGovernor` owner is the expected final governance owner.
- Timelock proposers match the approved manifest.
- Timelock executors match the approved manifest.
- Timelock guardian matches the approved incident-response holder.
- Module guardians match the approved manifest.
- Matching executor allowlists match the approved manifest.
- Insurance operator allowlist matches the approved manifest.
- Insurance backstop caller allowlist contains only approved engines/modules.
- Price source ownership has been transferred or explicitly documented where one-step ownership is used.
- Fee recipient / treasury addresses on engines match the approved manifest.
- Owner-only unpause authority is held by final owner/governance, not deployer.
- A harmless governance queue/cancel/execute rehearsal has passed in non-production or staging.
- Monitoring is live for role events before product activation.
- Role matrix, deployment manifest, and runbooks reflect the final on-chain state.

---

## Minimum Alert Set

- Ownership transfer started, accepted, canceled, or renounced.
- Guardian changed, cleared, or used to pause.
- Timelock proposer/executor changed.
- Timelock transaction queued, canceled, executed, stale, or failed.
- Oracle feed configured, cleared, paused, stale, zero, future-dated, or deviating above policy.
- Matching executor changed or unexpected executor submission detected.
- Settlement operator changed or settlement price proposed/finalized.
- Insurance operator or backstop caller changed.
- Insurance payout exceeds threshold or repeats for same account/market.
- Fee recipient changed.
- Product activation, close-only, restricted, or pause state changed.
- Any privileged role set to zero address unless explicitly documented as disablement.
- Any privileged role set to an address not present in the deployment manifest.
