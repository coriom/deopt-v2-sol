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
