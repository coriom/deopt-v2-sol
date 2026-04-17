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
