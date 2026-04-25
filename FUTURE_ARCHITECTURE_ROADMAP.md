# FUTURE_ARCHITECTURE_ROADMAP.md

## Purpose

This document finalizes the future architecture roadmap for DeOpt v2.

It is a planning artifact only. It does not change v1 protocol code, deployment scripts, parameters, ownership, economics, storage layout, or launch readiness gates.

The roadmap separates:

- what belongs in the v1 launch scope
- what belongs in post-v1 expansion
- what is explicitly deferred architecture work

Future architecture work must remain additive, separately reviewed, separately tested, and separately audited before production use.

---

## Scope Boundary

### V1 Launch Scope

The v1 launch scope is the current production-readiness target:

- European vanilla options through `OptionProductRegistry` and `MarginEngine`
- ETH/BTC option underlyings and launch-approved option series
- Perpetual markets through `PerpMarketRegistry` and `PerpEngine`
- Unified collateral through `CollateralVault`
- Base collateral accounting in native base-collateral units, with USDC as the initial base-collateral assumption unless changed by a controlled migration
- Current `RiskModule` and `PerpRiskModule` risk paths
- Current liquidation, collateral seizure, insurance coverage, residual bad debt, fee, oracle, matching, governance, and timelock flows
- Deployment manifests, deployment scripts, verification scripts, runbooks, monitoring, staging rehearsal, audit preparation, and final launch checklist
- Launch hardening, emergency controls, readiness validation, and observability required to make the existing v1 system safely operable

V1 launch work must preserve the existing protocol invariants:

- prices normalized to `1e8`
- BPS values normalized to `10_000`
- contract size convention of `1e8 = 1 underlying unit`
- base-native accounting for `...Base` values
- conservative collateral, liquidation, oracle, insurance, and governance behavior

### Post-V1 Expansion Scope

Post-v1 expansion covers architecture that may be needed after the initial system is launched, monitored, audited, and operationally proven:

- generalized product registry
- product and risk adapters
- futures and additional product engines
- structured and custom products
- contextual fees and fee routing
- collateral policy registry and collateral risk domains
- portfolio margin and correlation offsets
- generalized execution router
- governance module registry and typed governance adapters
- standardized observability and indexing contracts, schemas, and conformance checks

These items are not v1 launch blockers unless a launch readiness document explicitly reclassifies a specific readiness validator or policy document as launch-critical.

### Explicitly Deferred Architecture Work

The following architecture work is deferred from v1:

- replacing the current option and perp registries with a generalized product registry
- replacing current option and perp engines with adapter-driven engines
- adding a futures engine
- adding structured, exotic, basket, spread, or custom payoff products
- introducing contextual per-product, per-account, per-market, or order-type fee logic
- adding fee rebates, routing splits, or treasury allocation policies beyond the v1 surfaces
- replacing current collateral configuration with a generalized collateral policy registry
- introducing multiple collateral risk domains or multi-base collateral books
- enabling portfolio margin or correlation offsets
- replacing current matching engines with a generalized execution router
- replacing current governance helpers with a dynamic module registry
- changing existing v1 storage layout, unit semantics, or economic assumptions to support future features

Deferred work must not be smuggled into v1 launch hardening. If any deferred feature becomes necessary, it must be promoted through a new scoped design, implementation plan, test plan, and audit review.

---

## Architecture Principles For Future Work

- Preserve v1 interfaces as compatibility surfaces until a deliberate migration is approved.
- Prefer additive adapters and registries over in-place rewrites of launched modules.
- Keep unit semantics explicit in every new interface.
- Treat risk, oracle, collateral, liquidation, and insurance integrations as fail-closed by default.
- Keep new product engines isolated until their risk contribution, settlement, liquidation, fees, and monitoring are proven.
- Require deployment manifests and readiness validators for every new architecture surface.
- Require monitoring and event/indexing commitments before activating new products.
- Require governance proposals to include post-state validation evidence for material configuration changes.

---

## Future Architecture Tracks

### Generalized Product Registry

| Field | Detail |
| --- | --- |
| Goal | Create a protocol-level registry that can represent options, perps, futures, structured products, and future product families under a common lifecycle and metadata model. |
| Motivation | Current product registration is split between `OptionProductRegistry` and `PerpMarketRegistry`. That is safer for v1, but future engines would otherwise duplicate lifecycle, activation, cap, metadata, monitoring, and governance conventions. |
| Affected Current Modules | `OptionProductRegistry`, `PerpMarketRegistry`, `MarginEngine`, `PerpEngine`, `RiskModule`, `PerpRiskModule`, matching engines, deployment manifests, monitoring/indexing. |
| Why Deferred From V1 | V1 only needs explicit ETH/BTC option series and bounded perp markets. A generalized registry would increase launch complexity and expand the audit surface without improving immediate launch safety. |
| Proposed Implementation Direction | Add a future `ProductRegistry` keyed by `productType` and `productId`, with engine address, risk adapter, fee policy, collateral policy, lifecycle state, cap policy, settlement policy, and metadata schema fields. Keep current option/perp registries as canonical v1 surfaces and expose compatibility adapters later. |
| Complexity | High. |
| Dependency Order | After Phase 2 readiness validators and before futures or structured products. |

### Product / Risk Adapter Architecture

| Field | Detail |
| --- | --- |
| Goal | Separate product-specific payoff, exposure, settlement, and margin logic from shared collateral, governance, monitoring, and portfolio aggregation surfaces. |
| Motivation | Current unified risk aggregation is fixed around options plus one perp risk module. Future engines need standardized risk contributions without silently omitting unavailable product risk. |
| Affected Current Modules | `RiskModule`, `PerpRiskModule`, `MarginEngine`, `PerpEngine`, `OptionProductRegistry`, `PerpMarketRegistry`, `OracleRouter`, matching engines. |
| Why Deferred From V1 | Fixed v1 risk paths are easier to audit and operate. Adapter dispatch adds permission, availability, unit, upgrade, and failover risks that are not required for initial launch. |
| Proposed Implementation Direction | Define `IProductAdapter` and `IRiskAdapter` interfaces for lifecycle, exposure, equity delta, initial margin, maintenance margin, funding, settlement, liquidation preview, and status flags. Start with read-only adapters and conformance tests before any state-mutating adapter path is enabled. |
| Complexity | High. |
| Dependency Order | After Phase 2 policy documentation; before generalized execution, futures, structured products, and portfolio margin. |

### Futures Engine

| Field | Detail |
| --- | --- |
| Goal | Add dated futures markets with explicit expiry, settlement, margin, and lifecycle behavior. |
| Motivation | Futures are a natural expansion path beyond perps and options, but they have distinct expiry, basis, settlement, funding, and liquidation requirements. |
| Affected Current Modules | `PerpEngine`, `PerpMarketRegistry`, `RiskModule`, `PerpRiskModule`, `OracleRouter`, `FeesManager`, `InsuranceFund`, `CollateralSeizer`, monitoring/indexing. |
| Why Deferred From V1 | Futures introduce new product economics and settlement paths. They should not be added before v1 options/perps are deployed, monitored, and audited. |
| Proposed Implementation Direction | Add an isolated `FuturesEngine` and `FuturesMarketRegistry` or register futures through the generalized product registry once available. Reuse vault, oracle, fees, insurance, and governance surfaces through adapters instead of modifying `PerpEngine` in place. |
| Complexity | High. |
| Dependency Order | After product/risk adapter interfaces; before structured products that depend on futures exposure. |

### Structured / Custom Products

| Field | Detail |
| --- | --- |
| Goal | Support controlled custom payoff products, such as spreads, baskets, digitals, barriers, or structured institutional products. |
| Motivation | Institutional derivatives often require non-vanilla product terms. Supporting them safely requires explicit payoff, margin, settlement, and monitoring models. |
| Affected Current Modules | `OptionProductRegistry`, `MarginEngine`, `RiskModule`, `OracleRouter`, `CollateralVault`, `FeesManager`, `InsuranceFund`, matching engines, governance, monitoring/indexing. |
| Why Deferred From V1 | V1 option assumptions are intentionally bounded around European vanilla series. Custom payoff products can create unbounded or non-monotonic risk if introduced without a mature adapter and risk framework. |
| Proposed Implementation Direction | Add whitelisted payoff adapters with typed metadata, static risk declarations, scenario-based margin tests, conservative launch caps, and explicit settlement formulas. Do not loosen the v1 option contract-size invariant in place. |
| Complexity | Very high. |
| Dependency Order | After generalized product registry, product/risk adapters, observability standard, and risk-domain planning. |

### Contextual Fee System

| Field | Detail |
| --- | --- |
| Goal | Allow fee policies to depend on product, market, account, role, notional, premium, order type, liquidity program, or risk context. |
| Motivation | Current fee logic is trader/tier/role oriented. Future market structures may need per-market fees, settlement fees, liquidation fees, launch incentives, negotiated institutional schedules, or risk-based fees. |
| Affected Current Modules | `FeesManager`, `MarginEngine`, `PerpEngine`, matching engines, deployment manifests, monitoring, treasury reporting. |
| Why Deferred From V1 | Simple v1 fee logic is more deterministic and auditable. Contextual fees add economic policy complexity and more ways for configuration drift to occur. |
| Proposed Implementation Direction | Add an `IFeePolicy` or versioned fee quote adapter that receives product type, market or series ID, account, role, notional, premium, order context, and policy ID. Keep hard protocol-level caps in `FeesManager` or a successor policy guard. |
| Complexity | Medium. |
| Dependency Order | After canonical fee policy documentation; before fee routing and rebates. |

### Fee Routing / Rebates / Treasury Splits

| Field | Detail |
| --- | --- |
| Goal | Route protocol fees to treasury, insurance, market-maker rebates, referral programs, backstop providers, or product-specific destinations. |
| Motivation | Future economics may require revenue sharing, insurance funding, maker rebates, and treasury accounting that cannot be represented by a single fee recipient. |
| Affected Current Modules | `FeesManager`, `MarginEngine`, `PerpEngine`, `InsuranceFund`, `CollateralVault`, matching engines, monitoring, deployment manifests. |
| Why Deferred From V1 | Fee routing changes accounting and operational reporting. V1 should launch with a simpler recipient model unless a specific route is required and audited. |
| Proposed Implementation Direction | Add route tables keyed by fee policy ID or product ID. Emit explicit fee route events. Prefer pull-based rebate claims for complex distributions. Keep settlement values in base-native or settlement-native units without silent netting. |
| Complexity | Medium to high. |
| Dependency Order | After contextual fee policy and treasury policy documentation. |

### Collateral Policy Registry

| Field | Detail |
| --- | --- |
| Goal | Establish a canonical source for collateral eligibility, decimals, weights, caps, launch activation, seize policy, and product or risk-domain overrides. |
| Motivation | Collateral policy is currently distributed across vault and risk modules. That is manageable for v1 with deployment checks, but future expansion needs one auditable policy graph. |
| Affected Current Modules | `CollateralVault`, `RiskModule`, `PerpRiskModule`, `CollateralSeizer`, `InsuranceFund`, deployment manifests, monitoring. |
| Why Deferred From V1 | V1 can enforce synchronization through manifests, scripts, and verification. Replacing policy ownership before launch would increase audit and migration risk. |
| Proposed Implementation Direction | Start with a read-only `CollateralPolicyRegistry` or policy lens that reconciles current module state. Later, evolve it into the canonical policy source consumed by risk and liquidation modules. |
| Complexity | Medium. |
| Dependency Order | Phase 2 readiness validators first; then collateral policy registry; then collateral risk domains. |

### Collateral Risk Domains

| Field | Detail |
| --- | --- |
| Goal | Isolate collateral, settlement, risk, caps, and insurance by domain, product family, base asset, or institutional book. |
| Motivation | Future products may require different collateral universes, settlement numeraires, liquidation paths, or insurance pools. A single global base collateral model is safer for v1 but less flexible for expansion. |
| Affected Current Modules | `CollateralVault`, `RiskModule`, `PerpRiskModule`, `MarginEngine`, `PerpEngine`, `CollateralSeizer`, `InsuranceFund`, deployment manifests. |
| Why Deferred From V1 | Multi-domain collateral creates accounting, liquidation, and migration complexity. V1 should keep a single base collateral model and explicit launch-active collateral controls. |
| Proposed Implementation Direction | Add domain IDs with base asset, collateral set, risk adapters, caps, seizer policy, and insurance pool configuration. Keep cross-domain netting disabled until portfolio margin is explicitly designed and audited. |
| Complexity | High. |
| Dependency Order | After collateral policy registry; before portfolio margin and institutional configuration. |

### Portfolio Margin / Correlation Offsets

| Field | Detail |
| --- | --- |
| Goal | Support margin offsets across related products, underlyings, expiries, and hedged portfolios while preserving protocol solvency. |
| Motivation | Conservative additive margin is safer for v1 but capital-inefficient for complex portfolios. Institutional usage may require portfolio-level stress models and governed correlation assumptions. |
| Affected Current Modules | `RiskModule`, `PerpRiskModule`, `MarginEngine`, `PerpEngine`, future engines, `OracleRouter`, `CollateralVault`, `CollateralSeizer`, `InsuranceFund`, monitoring. |
| Why Deferred From V1 | Portfolio margin is one of the highest-risk economic changes. It requires mature observability, scenario testing, invariant testing, and external audit. |
| Proposed Implementation Direction | Add a versioned portfolio risk engine with conservative stress scenarios, correlation matrices, product eligibility, account eligibility, hard offset caps, degraded-mode behavior, and liquidation previews matching state-mutating paths. Disable offsets during stale or degraded oracle conditions. |
| Complexity | Very high. |
| Dependency Order | After product/risk adapters, collateral risk domains, observability standard, and futures/new-product coverage. |

### Generalized Execution Router

| Field | Detail |
| --- | --- |
| Goal | Provide one execution ingress layer for options, perps, futures, structured products, RFQ, block trades, and multi-leg execution. |
| Motivation | Current option and perp matching engines duplicate nonce, executor, signature, pause, and forwarding logic. More products would multiply this operational surface. |
| Affected Current Modules | `MatchingEngine`, `PerpMatchingEngine`, `MarginEngine`, `PerpEngine`, future product engines, governance, monitoring/indexing. |
| Why Deferred From V1 | Separate matching engines reduce v1 blast radius and make product-specific execution easier to audit. A generalized router introduces domain-separation and replay-protection risks. |
| Proposed Implementation Direction | Add an `ExecutionRouter` with versioned EIP-712 domains, product adapters, per-product nonce scopes, executor allowlists, close-only and pause checks, dry-run validation, and explicit execution events. Keep current matching engines as v1 compatibility routes until migration is proven. |
| Complexity | High. |
| Dependency Order | After generalized product registry and adapter interfaces; before multi-leg structured products. |

### Governance Module Registry / Typed Adapters

| Field | Detail |
| --- | --- |
| Goal | Make governance operations for new modules readable, typed, and discoverable without requiring hard-coded governor changes for every new engine. |
| Motivation | Current `RiskGovernor` helpers are explicit for known v1 modules. Future modules can use generic timelock calls, but generic opaque calldata increases operational risk. |
| Affected Current Modules | `ProtocolTimelock`, `RiskGovernor`, module admin surfaces, deployment manifests, role matrix, monitoring. |
| Why Deferred From V1 | V1 governance should remain explicit and auditable. A dynamic registry should not be introduced before the fixed governance model is rehearsed and handed off safely. |
| Proposed Implementation Direction | Add a governed module registry keyed by module type and module ID. Pair it with typed governance adapters that expose proposal metadata, calldata validation, dependency checks, and post-state verification requirements. Preserve generic timelock execution as the fallback authority. |
| Complexity | Medium to high. |
| Dependency Order | After readiness validators and canonical policy documentation; before large-scale product/module expansion. |

### Observability / Indexing Standard

| Field | Detail |
| --- | --- |
| Goal | Define a common event, view, manifest, and indexing standard for protocol modules and future adapters. |
| Motivation | Current monitoring specs define production requirements, but future engines need consistent product IDs, policy IDs, account fields, asset fields, base-value equivalents, lifecycle events, and readiness views. |
| Affected Current Modules | All core modules, future adapters, deployment manifests, `MONITORING_SPEC.md`, `RUNBOOK.md`, indexers, dashboards, alerting. |
| Why Deferred From V1 | V1 monitoring can be implemented with the current fixed product taxonomy. A formal dynamic standard depends on the adapter and product-registry shape. |
| Proposed Implementation Direction | Define an event catalog, required adapter view interface, manifest schema versions, dashboard schema, indexer conformance tests, chain reorg handling, alert deduplication, and deployment-readiness ingestion rules. Add standard fields for `productType`, `productId`, `marketId`, `policyId`, `account`, `asset`, `amount`, and `baseValue` where applicable. |
| Complexity | Medium. |
| Dependency Order | Start in Phase 2 as documentation and offchain standard; finalize with adapter interfaces in Phase 3. |

---

## Phased Roadmap

### Phase 1: V1 Launch Hardening

Goal:
Finalize and launch the current v1 architecture safely.

Scope:

- Complete launch readiness gates in `FINAL_LAUNCH_CHECKLIST.md`.
- Complete staging rehearsal evidence in `STAGING_REHEARSAL.md`.
- Complete audit preparation and audit closure in `AUDIT_PREP.md`.
- Keep deployment manifests, role matrix, monitoring, runbook, and launch caps reconciled.
- Preserve current option/perp product boundaries.
- Preserve current risk, collateral, oracle, liquidation, insurance, fee, matching, and governance semantics.

Exit criteria:

- `forge build` and required test suites pass on the launch commit.
- `VerifyDeployment.s.sol` passes against the final configured deployment.
- Ownership handoff, monitoring, emergency controls, insurance funding, oracle checks, staging rehearsal, audit closure, and final sign-off are complete.

### Phase 2: Readiness Validators And Canonical Policy Documentation

Goal:
Make the current configuration graph and policy sources machine-readable and auditable before adding new architecture surfaces.

Scope:

- Document canonical sources of truth for collateral, risk, fee, oracle, liquidation, insurance, lifecycle, and governance policy.
- Add or standardize offchain and script-level readiness validators.
- Produce policy documentation for collateral weights, deposit caps, launch activation, market OI caps, fee caps, oracle freshness, insurance thresholds, and emergency states.
- Standardize manifest and monitoring ingestion expectations.

Exit criteria:

- Operators can prove whether a deployment is wired, configured, owned, monitored, and launch-ready without manual interpretation.
- Configuration drift between manifests, role matrix, and onchain state produces actionable alerts.

### Phase 3: Adapter Interfaces

Goal:
Define stable interfaces for future products without replacing v1 engines.

Scope:

- Define product, risk, fee, collateral, execution, governance, and observability adapter interfaces.
- Build read-only adapters around v1 options and perps for compatibility testing.
- Add conformance tests for units, status flags, staleness, fail-closed behavior, lifecycle mapping, and indexer fields.
- Keep state-mutating adapter execution disabled until interfaces are reviewed and audited.

Exit criteria:

- A future product engine can report lifecycle, exposure, risk contribution, fee context, settlement preview, liquidation preview, and monitoring metadata through standard interfaces.
- Existing v1 products remain accessible through compatibility surfaces.

### Phase 4: Futures / New Product Engine

Goal:
Add the first new product engine as an isolated expansion, proving the adapter model before broader product generalization.

Scope:

- Implement futures or another approved product engine behind adapter interfaces.
- Reuse vault, oracle, fees, insurance, and governance through explicit adapters.
- Add product-specific tests, scenario tests, invariant tests, deployment rehearsal, monitoring dashboards, runbook procedures, and audit scope.
- Launch with restrictive caps and isolated activation states.

Exit criteria:

- The new engine can be deployed, configured, monitored, paused, liquidated or settled, and governed without weakening v1 options/perps.
- Risk contribution and liquidation/settlement previews match state-mutating behavior under tests and rehearsal.

### Phase 5: Portfolio Margin And Institutional Configuration

Goal:
Introduce advanced capital efficiency and institutional configuration only after product coverage, risk domains, and monitoring are mature.

Scope:

- Add collateral risk domains and controlled account/product eligibility.
- Add portfolio margin models with conservative stress scenarios and governed correlation assumptions.
- Add contextual fee policies, fee routing, treasury splits, and rebate programs where approved.
- Add institutional readiness artifacts, monitoring, risk dashboards, audit package, and governance controls.

Exit criteria:

- Portfolio margin can be disabled or capped by account, product, domain, and oracle state.
- Correlation offsets, collateral domains, and fee routing are observable, auditable, and covered by incident runbooks.
- External audit is complete for all new economic and governance surfaces.

---

## Non-Goals Before V1 Launch

- No Solidity architecture rewrite.
- No storage-layout migration.
- No generalized product registry.
- No adapter-driven execution path.
- No futures engine.
- No structured product support.
- No portfolio margin.
- No multi-base collateral or collateral risk domains.
- No contextual fee routing or rebates.
- No dynamic governance module registry.
- No deployment activation before final checklist and audit gates are satisfied.

---

## Review Requirements For Future Phases

Each future phase must include:

- explicit design document
- invariant impact analysis
- storage-layout review
- unit and integration test plan
- scenario and invariant test plan for economic changes
- deployment and rollback plan
- monitoring and alert update
- role and governance update
- staged rehearsal
- external audit scope update

No future architecture feature should be merged into a production path solely because it appears in this roadmap.
