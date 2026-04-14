# SPEC.md

## System Overview

DeOpt v2 is a modular derivatives protocol composed of:

- Options engine (calls/puts)
- Perpetual engine
- Unified collateral system
- Risk and margin module
- Oracle router
- Liquidation engine
- Insurance fund
- Matching engine (off-chain → on-chain execution)
- Fee system
- Governance layer

---

## Architecture

### Core Modules

#### 1. CollateralVault
- Holds user balances
- Supports multiple tokens
- Handles yield integration
- Internal accounting:
  - balances[user][token]
- Must sync yield before reads

---

#### 2. RiskModule
- Computes:
  - equityBase
  - initialMarginBase
  - maintenanceMarginBase
- Applies haircuts
- Converts all values into base collateral units

---

#### 3. MarginEngine
- Validates positions
- Enforces margin requirements
- Interfaces with RiskModule

---

#### 4. PerpEngine
- Manages perpetual positions
- Tracks:
  - size
  - entry price
  - funding
  - realized PnL

Submodules:
- Storage
- Trading
- Views
- Admin

---

#### 5. Option Engine
- European options only
- Supports call and put
- Uses:
  - strike (1e8)
  - expiry
  - contract size (1e8)

---

#### 6. OracleRouter
- Aggregates price feeds:
  - Chainlink
  - Pyth
  - fallback sources
- Enforces:
  - staleness
  - deviation checks
- Returns normalized price (1e8)

---

#### 7. Liquidation Engine (CollateralSeizer)
- Seizes collateral when margin violation
- Applies:
  - haircut
  - liquidation spread
- Computes seizure in base value
- Transfers via CollateralVault

---

#### 8. InsuranceFund
- Acts as system backstop
- Receives penalties
- Covers bad debt

---

#### 9. Matching Engine
- Off-chain orderbook
- On-chain settlement
- Deterministic execution

---

#### 10. Fees System

Targets:
- % of premium (options)
- % of notional (perps)

Future:
- volume-based fee tiers
- fee routing to treasury

---

## Data Flow

1. User deposits collateral → CollateralVault
2. User opens position → PerpEngine / OptionEngine
3. Margin checked → MarginEngine → RiskModule
4. Prices fetched → OracleRouter
5. If undercollateralized → Liquidation Engine
6. Shortfall → InsuranceFund

---

## Invariants

### Financial

- No creation/destruction of value
- PnL must net to zero across participants (excluding fees)
- Liquidation must reduce system risk

### Accounting

- Vault balances must reflect real state
- No phantom equity
- Yield and principal must be separable but consistent

### Safety

- No overflow/underflow
- No unsafe casts
- No stale oracle usage

---

## Constraints

- Base chain deployment
- USDC as base collateral
- ETH/BTC as initial underlyings

---

## Non-Goals (for now)

- American options
- Cross-chain settlement
- Advanced structured products

---

## Evolution

Future extensions:

- Cross-margin across products
- Dynamic risk parameters
- Advanced fee tiers
- DAO governance control

---

## Agent Behavior Requirements

Any agent modifying this system must:

1. Respect all invariants
2. Minimize diff size
3. Explain economic impact before modifying logic
4. Never introduce ambiguity in units or flows
5. Validate after each change

---

## Objective

Deliver a robust, scalable, and auditable on-chain derivatives protocol.