# ABI Freeze Artefact — v2-product-freeze-rc1

**Generated:** 2026-06-10
**Source commit:** `d133e2c` (HEAD of `main` at generation)
**Foundry version:** project-pinned (see `foundry.lock`)
**Source command:** ABIs extracted from existing `out/<Contract>.sol/<Contract>.json` files produced by `forge build` against the source commit.

## Status

- **NOT MAINNET DEPLOYED.** This freeze is testnet-beta scope only.
- **NOT AUDITED.** External audit deferred until product-complete freeze (M-P7 of `~/DEOPT/deopt-v2-backend/docs/NEXT_PRODUCT_MILESTONES.md`).
- **TESTNET / BETA ONLY.** Do not deposit real funds against any deployment derived from this freeze.
- **LOCAL TAG ONLY.** This freeze is anchored by the local git tag `v2-product-freeze-rc1`. The tag is not pushed to any remote in this milestone.

## Intended downstream consumers

- **Backend** (`~/DEOPT/deopt-v2-backend/`):
  - `src/options/event_indexer.rs` — consumes `OptionMatchingEngine.OptionTradeExecuted` + `OptionRfqTradeExecuted` + `MarginEngine.AccountSettled` + `OptionProductRegistry.SeriesCreated` + `CollateralVault.Deposited`/`Withdrawn` + `ProtocolFeeVault.FeeRecorded`.
  - `src/options/service.rs` — consumes `OptionMatchingEngine` + `MarginEngine` ABI for calldata construction.
  - `src/fees/onchain_summary.rs` — consumes `FeesManagerV2.quoteFee` + `ProtocolFeeVault` views.
  - `src/api/routes.rs` — read-only routes consume contract views.
- **Frontend** (`~/DEOPT/deopt-v2-frontend/`):
  - Trading UI (M-P3 wires) — consumes view functions for option chain rendering, position display, fee preview, account state.
  - Wallet-side EIP-712 envelopes — derived from `OptionMatchingEngine` typed-data hash domain.

## Files in this directory

| File | Purpose |
|---|---|
| `README.md` | This file. |
| `<Contract>.abi.json` | Per-contract ABI + method identifiers + metadata (1 per product-facing contract). |
| `selectors.txt` | Sortable list `<Contract> <selector> <signature>` for every external/public function in scope. 458 lines covering 10 contracts. |
| `storage-layouts.txt` | `forge inspect <Contract> storageLayout` output for every core contract (storage-layout pin). Any future change MUST diff against this snapshot. |
| `freeze-manifest.json` | Machine-readable summary: contract list + selector counts + source commit + tag name. |

## In-scope contracts (10)

1. `OptionProductRegistry` — products + series creation + settlement-price proposals.
2. `OptionMatchingEngine` — orderbook + RFQ trade execution; EIP-712 nonce + signature surface.
3. `MarginEngine` — positions, account settlement, liquidation hook, fees integration.
4. `CollateralVault` + `CollateralVaultViews` — deposits / withdrawals / balances / yield strategy preview.
5. `FeesManagerV2` — signed-ppm fee + RFQ discount preview (`quoteFee`).
6. `ProtocolFeeVault` — fee/rebate accounting; revenue receiver.
7. `OracleRouter` — pluggable price-source router.
8. `MarginEngineLens` — UI-facing aggregated views (account state, settlement preview, liquidation preview, trade-fee preview).
9. `InsuranceFund` — independent balance counter.
10. `RiskModule` — risk/margin computation surface.

## Out-of-scope (NOT_APPLICABLE_AT_LAUNCH per Q-CD-6)

- `PerpEngine*`, `PerpMatchingEngine`, `PerpMarketRegistry`, `PerpRiskModule`, `PerpEngineLens` — perp surface deferred.

## Out-of-scope (test-only)

- `MockPriceSource` — mainnet path excludes this.

## Regeneration command

To regenerate this freeze artefact from a different commit:

```
cd ~/DEOPT/deopt-v2-sol
git checkout <commit>
forge build
mkdir -p abis/freeze-v2-<new-tag>
# extraction script: scripts/extract_freeze_abis.py (operator may keep this offline)
```

The extraction logic is documented in `SOL_BACKEND_FRONTEND_ABI_HANDOFF.md`.

## Storage-layout pin contract

Any future PR that modifies any contract listed in §"In-scope contracts" MUST:

1. Re-run `forge inspect <Contract> storageLayout`.
2. Diff against `storage-layouts.txt`.
3. Fail PR review if any existing slot moves (additive-only is acceptable for any contract using upgrade-safe gap variables; this codebase has no proxies, so a slot-move is a hard incompatibility for any state-preserving migration).

## Cross-links

- `~/DEOPT/deopt-v2-sol/docs/SOL_PRODUCT_SCOPE_FREEZE_RESULT.md`
- `~/DEOPT/deopt-v2-sol/docs/SOL_BACKEND_FRONTEND_ABI_HANDOFF.md`
- `~/DEOPT/deopt-v2-backend/docs/PRODUCT_READINESS_ROADMAP.md`
- `~/DEOPT/deopt-v2-backend/docs/NEXT_PRODUCT_MILESTONES.md`

**End of ABI freeze artefact README.**
