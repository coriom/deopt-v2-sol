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
