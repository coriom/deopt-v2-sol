# DeOpt v2

DeOpt v2 is a decentralized derivatives protocol for options and perpetual markets. It is built around unified collateral, explicit risk accounting, conservative liquidation, bounded insurance coverage, fee routing, oracle routing, offchain matching with onchain execution, and governance/timelock controls.

The repository is in protocol-finalization mode. Production launch requires completed deployment rehearsal, monitoring, runbooks, external audit, and final go/no-go approval.

---

## Protocol Overview

DeOpt v2 combines:

- Options: European option series managed by `OptionProductRegistry` and traded through `MarginEngine`.
- Perps: Perpetual markets managed by `PerpMarketRegistry` and traded through `PerpEngine`.
- Unified collateral: `CollateralVault` holds user collateral and supports engine-authorized internal accounting flows.
- Risk engine: `RiskModule` and `PerpRiskModule` calculate collateral value, equity, initial margin, maintenance margin, free collateral, and withdrawal safety in base-collateral units.
- Liquidation: `MarginEngine`, `PerpEngine`, and `CollateralSeizer` resolve unsafe accounts through conservative close, penalty, seizure, insurance, and bad-debt paths.
- Insurance: `InsuranceFund` provides bounded backstop coverage for approved shortfall callers.
- Governance: `ProtocolTimelock` and `RiskGovernor` coordinate delayed parameter changes, ownership handoff, role management, and emergency controls.

Core unit conventions:

- Oracle prices use `1e8` normalization.
- Contract size uses `1e8 = 1 underlying unit`.
- BPS values use `10_000 = 100%`.
- `...Base` values are denominated in native base-collateral units.
- Initial base collateral assumption is USDC with 6 decimals unless a controlled migration changes it.

---

## Architecture Overview

### Core Modules

| Area | Modules |
| --- | --- |
| Collateral | `src/collateral/CollateralVault*.sol`, `src/yield/*.sol` |
| Risk | `src/risk/RiskModule*.sol`, `src/perp/PerpRiskModule.sol` |
| Options | `src/OptionProductRegistry.sol`, `src/margin/MarginEngine*.sol` |
| Perps | `src/perp/PerpMarketRegistry.sol`, `src/perp/PerpEngine*.sol` |
| Liquidation | `src/liquidation/CollateralSeizer.sol` |
| Oracle | `src/oracle/OracleRouter.sol`, `src/oracle/*PriceSource.sol` |
| Insurance | `src/core/InsuranceFund.sol` |
| Fees | `src/fees/FeesManager.sol` |
| Matching | `src/matching/MatchingEngine.sol`, `src/matching/PerpMatchingEngine.sol` |
| Governance | `src/gouvernance/ProtocolTimelock.sol`, `src/gouvernance/RiskGovernor*.sol` |

### Deployment Scripts

Deployment is intentionally staged:

1. `script/DeployCore.s.sol`
2. `script/WireCore.s.sol`
3. `script/ConfigureCore.s.sol`
4. `script/ConfigureMarkets.s.sol`
5. `script/VerifyDeployment.s.sol`
6. `script/TransferOwnerships.s.sol`
7. `script/AcceptOwnerships.s.sol`

Deployment environment templates live in:

- `deployments/local.template.json`
- `deployments/testnet.template.json`
- `deployments/mainnet.template.json`

### Docs Map

| Document | Purpose |
| --- | --- |
| `SPEC.md` | System overview, goals, modules, flows, constraints |
| `ARCHITECTURE_MAP.md` | Module boundaries, dependencies, authority/value flow |
| `INVARIANTS.md` | Hard invariants and baseline economic parameters |
| `PARAMETERS.md` | Human-readable target parameter baseline |
| `TEST_MATRIX.md` | Required unit, scenario, invariant, fuzz, and launch test scope |
| `DEPLOYMENT_PLAN.md` | Canonical deployment order and post-deploy checks |
| `LOCAL_REHEARSAL.md` | Exact local Anvil rehearsal flow and helper scripts |
| `ROLE_MATRIX.md` | Production role model, permissions, rotation, monitoring |
| `MONITORING_SPEC.md` | Critical events, dashboards, alerts, indexing requirements |
| `RUNBOOK.md` | Launch, incident, governance, insurance, rollback procedures |
| `STAGING_REHEARSAL.md` | Production-like rehearsal plan and evidence requirements |
| `AUDIT_PREP.md` | Audit scope, invariants, high-risk review areas, reproducibility |
| `FINAL_LAUNCH_CHECKLIST.md` | Final go/no-go launch checklist and sign-off table |
| `PROGRESS.md` | Auditable implementation and validation history |

---

## Developer Quickstart

### Install Dependencies

Install Foundry:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Clone and enter the repository:

```bash
git clone <repo-url>
cd deoptv2
```

Install or update Foundry dependencies if needed:

```bash
forge install
```

### Build

```bash
forge build
```

### Test

Run the full test suite:

```bash
forge test
```

Targeted test examples:

```bash
forge test --match-path test/unit/vault/CollateralVault.t.sol
forge test --match-path test/unit/risk/RiskModule.t.sol
forge test --match-path test/unit/margin/MarginEngine.t.sol
forge test --match-path test/unit/perp/PerpEngine.t.sol
forge test --match-path test/unit/perp/PerpEngineLiquidation.t.sol
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

---

## Deployment Flow

Use a filled manifest derived from `deployments/` and follow the exact staged sequence. Do not activate markets during deploy, wire, or handoff.
For local Anvil rehearsal, use `LOCAL_REHEARSAL.md`.

```bash
forge script script/DeployCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/WireCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/ConfigureCore.s.sol --rpc-url $RPC_URL --broadcast
forge script script/ConfigureMarkets.s.sol --rpc-url $RPC_URL --broadcast
forge script script/VerifyDeployment.s.sol --rpc-url $RPC_URL
forge script script/TransferOwnerships.s.sol --rpc-url $RPC_URL --broadcast
forge script script/AcceptOwnerships.s.sol --rpc-url $RPC_URL --broadcast
```

High-level sequence:

1. `DeployCore`: deploy the core protocol stack and print addresses.
2. `WireCore`: wire dependencies across vault, risk, engines, oracle, insurance, fees, seizer, and matching.
3. `ConfigureCore`: configure collateral, risk, fee, insurance, and base settlement surfaces.
4. `ConfigureMarkets`: configure oracle feeds, option underlyings/series, perp markets, launch caps, and activation states.
5. `VerifyDeployment`: read-only verification of bytecode, wiring, config, roles, markets, caps, and sanity checks.
6. `TransferOwnerships`: initiate ownership handoff and configure guardians, timelock roles, matching executors, and optional source owners.
7. `AcceptOwnerships`: finalize ownership handoff and verify final owners/pending owners.

Activation must happen only after verification, ownership handoff, role checks, monitoring readiness, insurance readiness, staging evidence, audit closure, and final sign-off.

---

## Production Readiness

Mainnet readiness is not determined by a successful compile alone. Before production activation, operators must complete and reconcile:

- `ROLE_MATRIX.md`
- `MONITORING_SPEC.md`
- `RUNBOOK.md`
- `STAGING_REHEARSAL.md`
- `AUDIT_PREP.md`
- `FINAL_LAUNCH_CHECKLIST.md`

Minimum launch gates include:

- `forge build` and `forge test` pass on the exact launch commit.
- `VerifyDeployment.s.sol` passes against the final configured deployment.
- Ownership is transferred and accepted by the expected final owner/timelock.
- Oracle feeds are fresh, nonzero, normalized to `1e8`, and monitored.
- Insurance is funded above the approved launch threshold.
- Launch caps, collateral caps, pause/close-only controls, and monitoring alerts are configured and tested.
- Staging rehearsal passes with required artifacts.
- External audit is complete with no unresolved Critical or High issues.
- Final sign-off in `FINAL_LAUNCH_CHECKLIST.md` is complete.

---

## Security Notice

This repository should not be treated as production-deployed or mainnet-ready unless the final launch checklist, staging rehearsal, monitoring setup, role handoff, and audit closure are complete.

An external audit is required before mainnet deployment or activation. Any deployment using unresolved placeholders, unverified oracle feeds, incomplete ownership handoff, missing monitoring alerts, unfunded insurance, unresolved Critical/High audit findings, or untested emergency controls is a no-go for production activation.

Report security issues privately to the repository maintainers or the designated security contact once published.
