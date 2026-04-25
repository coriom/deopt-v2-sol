
---

## `SPEC.md`

```md
# SPEC.md

## System Overview

DeOpt v2 is a modular on-chain derivatives protocol composed of:

- options engine (calls / puts)
- perpetual engine
- unified collateral system
- unified risk and margin module
- oracle router
- liquidation engine
- insurance fund
- matching engine (off-chain matching → on-chain execution)
- fee system
- governance / timelock layer

The protocol is designed to support production-grade derivatives infrastructure with explicit accounting, conservative liquidation, bounded governance, and a shared collateral base.

---

## System Goals

DeOpt v2 aims to provide:

- shared collateral across products
- coherent protocol-wide risk measurement
- conservative liquidation and shortfall handling
- explicit bad-debt accounting
- auditable parameter governance
- scalable modularity across options and perps
- production-oriented operational safety

---

## Architecture

### Core Modules

#### 1. CollateralVault
Responsibilities:
- holds user balances
- supports multiple collateral tokens
- supports yield integration
- handles internal account-to-account transfers
- acts as the common balance layer for protocol modules

Internal accounting:
- `balances[user][token]`

Key constraints:
- yield must be synced before reads where required
- token support and decimals must remain explicit
- authorized engine interactions must remain controlled

---

#### 2. RiskModule
Responsibilities:
- computes:
  - `equityBase`
  - `initialMarginBase`
  - `maintenanceMarginBase`
  - free collateral
  - withdraw previews
  - decomposed collateral/product state
- applies collateral haircuts
- converts all values into base collateral units
- serves as the unified protocol risk surface

Key constraints:
- all core outputs must remain expressed in base units
- collateral valuation must remain conservative
- oracle usage must remain explicit and safe
- options and perp contributions must remain composable without unit ambiguity

---

#### 3. MarginEngine
Responsibilities:
- manages option positions
- validates option-side position transitions
- enforces option-side margin requirements
- interfaces with RiskModule
- performs option settlement and liquidation flows
- tracks open option series per trader

Key constraints:
- active series indexing must remain coherent
- total short exposure must remain coherent
- settlement must be explicit and single-use where intended
- option lifecycle must remain bounded and auditable

---

#### 4. PerpEngine
Responsibilities:
- manages perpetual positions
- tracks:
  - size
  - entry/basis state
  - funding
  - realized PnL
  - residual bad debt
- executes trade application and liquidation logic
- integrates fee routing and insurance shortfall handling

Submodules:
- storage
- trading
- views
- admin

Key constraints:
- open interest must remain coherent
- realized/unrealized accounting must remain consistent
- funding must remain bounded and inspectable
- bad-debt gating must remain explicit

---

#### 5. Option Product Layer
Current scope:
- European options only
- call and put support
- strike normalized to `1e8`
- expiry-based lifecycle
- contract size normalized to `1e8 = 1 underlying`

Components:
- `OptionProductRegistry`
- option settlement configuration
- per-underlying option risk policy

Key constraints:
- contract size assumptions must remain explicit
- strike/settlement scaling must remain 1e8
- settlement policy must remain auditable

---

#### 6. OracleRouter
Responsibilities:
- aggregates price feeds such as:
  - Chainlink
  - Pyth
  - fallback / secondary sources
- enforces:
  - staleness checks
  - deviation checks
  - conservative failure handling
- returns normalized price in `1e8`

Key constraints:
- no silent unsafe fallback
- stale/future/invalid prices must be rejected or handled conservatively
- all consumers must rely on explicit normalization assumptions

---

#### 7. Liquidation Engine (CollateralSeizer)
Responsibilities:
- computes conservative seizure plans when margin is violated
- applies:
  - haircut
  - liquidation spread
- computes effective value in base units
- leaves execution to calling engines via `CollateralVault`

Key constraints:
- planner must remain conservative
- no implicit transfer side effects
- effective seized value must remain bounded by real balances and configured discounts

---

#### 8. InsuranceFund
Responsibilities:
- acts as system backstop
- receives or holds treasury / reserve assets
- covers shortfalls when authorized modules request bounded payout
- optionally participates in yield/vault paths

Key constraints:
- payout must never exceed available balance
- token allowlist must remain explicit
- backstop usage must remain authorized and auditable

---

#### 9. Matching Engine
Responsibilities:
- off-chain orderbook / matching path
- deterministic on-chain settlement / application
- routes matched trades into engines

Key constraints:
- execution semantics must remain deterministic
- no hidden accounting outside engine state transitions

---

#### 10. Fees System
Responsibilities:
- computes and routes fees for:
  - options
  - perps
- supports:
  - defaults
  - caps
  - overrides
  - tiering / merkle-claim based policy

Key constraints:
- fee routing must remain explicit
- caps must remain enforceable
- quotes must remain economically coherent

---

#### 11. Governance Layer
Components:
- `ProtocolTimelock`
- `RiskGovernor`
- governance interfaces for critical modules

Responsibilities:
- parameter updates
- emergency control coordination
- bounded delayed execution of sensitive actions

Key constraints:
- timelock semantics must remain explicit
- guardian powers must remain bounded
- queue/cancel/execute must remain auditable

---

## Data Flow

Canonical high-level flow:

1. user deposits collateral → `CollateralVault`
2. user opens or updates position → `PerpEngine` / `MarginEngine`
3. margin and solvency checked → `RiskModule`
4. prices fetched → `OracleRouter`
5. if undercollateralized → liquidation path triggered
6. shortfall resolved via:
   - collateral seizure
   - insurance fund
   - residual bad debt if necessary

---

## Accounting Model

### Base Numeraire
The protocol uses a central base collateral numeraire for risk calculations.

All core risk quantities suffixed `...Base` must be denominated in native units of this base collateral token.

### Token-Native Amounts
All token balances and transfers remain denominated in native token units.

### Normalized Price Space
All normalized price-based quantities suffixed `...1e8` must remain scaled to `1e8`.

### Ratios
All ratios suffixed `...Bps` must remain in basis points using scale `10_000`.

---

## Invariants

### Financial

- No creation or destruction of value through accounting mistakes.
- PnL must net correctly across participants, excluding explicit fees and explicit shortfall paths.
- Liquidation must reduce or explicitly account for system risk.
- Insurance usage must remain bounded and explicit.
- Residual bad debt must never appear silently.

### Accounting

- Vault balances must reflect real state.
- No phantom equity.
- Yield and principal must remain separable but coherent.
- Open position indexes must remain coherent with actual live positions.
- Open interest aggregates must remain coherent with live perp positions.

### Safety

- No overflow / underflow.
- No unsafe casts.
- No stale oracle usage where guarded paths require freshness.
- No hidden unit changes.
- No implicit economic fallback without explicit logic.

### Governance

- Sensitive actions must remain timelockable where intended.
- Emergency actions must remain bounded.
- Role semantics must remain explicit.

---

## Constraints

### Deployment
- Base chain target deployment

### Initial Market Scope
- USDC as base collateral
- ETH and BTC as initial underlyings

### Initial Product Scope
- European options only
- Perps on bounded initial market set

---

## Non-Goals (for now)

- American options
- cross-chain settlement
- advanced structured products
- uncontrolled governance surface expansion
- broad product sprawl before launch-hardening

---

## Evolution Path

Potential future extensions:

- richer cross-margin across products
- dynamic / adaptive risk parameters
- more advanced fee tiers
- richer market segmentation
- DAO governance expansion
- broader collateral universe
- more advanced observability and portfolio views

These extensions must preserve unit discipline and explicit economic accounting.

---

## Production-Readiness Requirements

A production-ready DeOpt v2 requires not only correct core contracts, but also:

- deterministic deployment and wiring
- explicit environment configuration
- bounded launch controls
- emergency operating procedures
- monitoring / observability support
- rehearsal on staging/testnet
- external audit

---

## Finalization Phase

After core implementation and validation, the next protocol phase is controlled finalization.

This phase focuses on:

- bounded launch controls
- emergency control granularity
- preview / reporting surfaces
- operationally useful protocol hooks
- deployment/bootstrap readiness

Rules:
- incremental only
- smallest safe patch
- test-backed changes only
- no broad unrelated refactors

---

## Agent Behavior Requirements

Any agent modifying this system must:

1. respect all invariants
2. minimize diff size
3. explain economic impact before modifying logic
4. never introduce ambiguity in units or flows
5. validate after each change
6. prioritize production-readiness improvements over cosmetic cleanup
7. keep launch-safety and operability in mind when proposing protocol changes

---

## Objective

Deliver a robust, scalable, auditable, and production-ready on-chain derivatives protocol.