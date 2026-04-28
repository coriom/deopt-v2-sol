# Contract Size Reduction Plan

## Objective

Diagnose the minimum safe contract-size reduction required for real network deployment under the EIP-170 deployed bytecode limit of 24,576 bytes.

This began as a diagnosis and recommendation. The MarginEngine v1 size-reduction block has now been implemented.

## MarginEngine V1 Extraction Update

- Date: 2026-04-28
- Scope: `MarginEngine` only
- New read-only lens: `src/lens/MarginEngineLens.sol`
- `MarginEngine` runtime size after extraction/config hardening: 24,401 bytes
- `MarginEngine` EIP-170 margin after extraction/config hardening: +175 bytes
- `MarginEngineLens` runtime size: 17,771 bytes
- Remaining known blocker: `PerpEngine` runtime size is 35,656 bytes, still +11,080 bytes above EIP-170 and intentionally out of scope for this block.

Moved out of the `MarginEngine` core:

- rich account state diagnostics
- account settlement preview
- detailed settlement preview
- options liquidation preview
- protocol settlement accounting slice
- trade fee preview

The lens is optional read-only infrastructure and is not required by `DeployCore`.

## PerpEngine V1 Extraction Update

- Date: 2026-04-28
- Scope: `PerpEngine` only
- New read-only lens: `src/lens/PerpEngineLens.sol`
- `PerpEngine` runtime size after funding-regression fix and final compaction: 24,511 bytes
- `PerpEngine` EIP-170 margin after funding-regression fix and final compaction: +65 bytes
- `PerpEngineLens` runtime size: 18,325 bytes
- Remaining size note: the deployment blocker is cleared, but `PerpEngine` still has only 65 bytes of headroom and should be treated as frozen for nonessential ABI growth.

Follow-up funding regression fix:

- Cause: during the size-reduction block, `_fundingRatePerInterval1e18` was reduced to oracle validation plus an unconditional zero return. That disabled positive/negative premium funding deltas, funding caps, and accrued funding on open positions.
- Fix: restored mark/index price reads, premium calculation, deadband application, max-rate cap, elapsed-time scaling through `_fundingRateDelta1e18`, and persistence through the existing `updateFunding` storage path.
- Size headroom was preserved by trimming small nonessential admin/read convenience surfaces from the core rather than moving any state-changing funding logic to the lens.
- Validation: `PerpEngineFunding`, `PerpEngine`, `PerpEngineLiquidation`, perp liquidation scenarios, bad-debt scenario, perp fuzz tests, `forge build --sizes`, and full `forge test` all pass.

Moved out of the `PerpEngine` core:

- perp account status and liquidation-state diagnostics
- residual bad debt repayment preview and repayment-recipient view
- liquidation fallback/effective policy views
- insurance coverage preview
- basic and detailed liquidation previews
- position notional/direction helpers
- account PnL and exposure breakdowns
- account risk/free-collateral/margin-ratio passthroughs
- market open-interest and skew helpers
- detailed liquidation preview helper chain

The lens is optional read-only infrastructure and is not required by `DeployCore`.

## Exact Offenders

`DeployCore` deploys the core contracts in this order:

| Deployment index | DeployCore field | Contract | Runtime size | EIP-170 margin |
|---:|---|---|---:|---:|
| 0 | `collateralVault` | `CollateralVault` | 16,076 | +8,500 |
| 1 | `oracleRouter` | `OracleRouter` | 7,093 | +17,483 |
| 2 | `optionProductRegistry` | `OptionProductRegistry` | 16,995 | +7,581 |
| 3 | `marginEngine` | `MarginEngine` | 36,234 | -11,658 |
| 4 | `riskModule` | `RiskModule` | 18,642 | +5,934 |
| 5 | `perpMarketRegistry` | `PerpMarketRegistry` | 12,827 | +11,749 |
| 6 | `perpEngine` | `PerpEngine` | 24,511 | +65 |
| 7 | `perpRiskModule` | `PerpRiskModule` | 10,008 | +14,568 |
| 8 | `collateralSeizer` | `CollateralSeizer` | 6,547 | +18,029 |
| 9 | `feesManager` | `FeesManager` | 7,957 | +16,619 |
| 10 | `insuranceFund` | `InsuranceFund` | 10,175 | +14,401 |
| 11 | `matchingEngine` | `MatchingEngine` | 7,211 | +17,365 |
| 12 | `perpMatchingEngine` | `PerpMatchingEngine` | 7,500 | +17,076 |
| 13 | `protocolTimelock` | `ProtocolTimelock` | 4,340 | +20,236 |
| 14 | `riskGovernor` | `RiskGovernor` | 19,798 | +4,778 |

Therefore:

- `Unknown3` is `MarginEngine`.
- `Unknown6` is `PerpEngine`.

Both originally exceeded EIP-170 by about 11.6 KB. `MarginEngine` and `PerpEngine` are now below the limit after the v1 lens extraction blocks, though `PerpEngine` has only minimal headroom.

## Root Cause

The two oversized contracts are not oversized because of constructor logic. They are oversized because each final engine facade inherits a broad combined surface:

- storage and low-level accounting helpers
- admin and emergency controls
- trading paths
- liquidation paths
- settlement paths
- rich diagnostics
- read-only previews
- account/market breakdown views
- backward-compatible aliases

Current ABI breadth:

| Contract | External functions | View/pure functions | Stateful functions | Events | Errors |
|---|---:|---:|---:|---:|---:|
| `MarginEngine` | 105 | 61 | 44 | 40 | 51 |
| `PerpEngine` | 126 | 72 | 54 | 35 | 54 |

The largest safe extraction candidates are view-heavy and diagnostic. They do not need to live in the state-mutating engine bytecode.

## Main Contributors

### MarginEngine

Relevant inheritance:

`MarginEngine -> MarginEngineOps -> MarginEngineViews -> MarginEngineTrading -> MarginEngineAdmin -> MarginEngineStorage -> MarginEngineTypes`

Primary size contributors:

- `src/margin/MarginEngineViews.sol`
  - rich settlement preview types and helpers: `DetailedSettlementPreview`, `_previewPerContractPayoff`, `_previewAccountSettlementPnl`, `_previewSettlementResolution`, `_previewSettlementAmountBase`, `_previewRiskAfterSettlement`
  - account/risk wrappers: `getAccountRisk`, `getFreeCollateral`, `getMarginRatioBps`, `getAccountState`
  - rich options liquidation preview: `previewLiquidation`
  - settlement diagnostics: `getSeriesSettlementState`, `getSeriesSettlementProposalState`, `previewAccountSettlement`, `previewDetailedSettlement`
  - protocol settlement aggregation: `getProtocolSettlementAccountingSlice`
  - fee/config/oracle diagnostics: `previewTradeFees`, `getLiquidationConfigView`, `getRiskCacheView`, `getUnderlyingSpot`

- `src/margin/MarginEngineOps.sol`
  - state-changing option settlement: `_settleAccount`, `settleAccount`, `settleAccounts`
  - state-changing options liquidation: `liquidate`
  - these are not safe first-pass extraction targets because they mutate positions, settlement flags, vault balances, and settlement accounting.

- `src/margin/MarginEngineAdmin.sol`
  - broad owner/guardian/config surface and launch controls
  - lower priority than view extraction because these are operational safety surfaces.

### PerpEngine

Relevant inheritance:

`PerpEngine -> PerpEngineTrading -> PerpEngineViews -> PerpEngineAdmin -> PerpEngineStorage -> PerpEngineTypes`

Primary size contributors:

- `src/perp/PerpEngineViews.sol`
  - account status/readiness diagnostics: `getPerpSolvencyState`, `getPerpAccountStatus`, `getPerpLiquidationState`
  - bad debt repayment preview: `previewResidualBadDebtRepayment`
  - liquidation policy/config views: `getLiquidationFallbackParams`, `getEffectiveLiquidationParams`, `getLiquidationParams`
  - insurance preview: `previewInsuranceCoverage`
  - liquidation previews: `previewLiquidation`, `previewDetailedLiquidation`
  - detailed liquidation helper chain: `_getLiquidationMarkPrice1e8`, `_previewSeizerPenaltyCoverage`, `_previewSettlementAssetBalanceAfterRealized`, `_previewSettlementAssetPenaltyCoverage`, `_previewInsuranceCoverageBase`
  - account aggregation: `getAccountUnrealizedPnl`, `getAccountFunding`, `getAccountNetPnl`, `getAccountPnlBreakdown`, `getAccountExposureBreakdown`
  - market metrics: `getMarketOpenInterest`, `getMarketSkew`

- `src/perp/PerpEngineTrading.sol`
  - state-changing funding, trade application, liquidation, collateral seizure, insurance coverage, and residual bad debt flows
  - these should remain in core for v1 unless a later measured pass proves view extraction is insufficient.

- `src/perp/PerpEngineAdmin.sol`
  - emergency controls, dependency wiring, fallback liquidation aliases, residual bad debt admin
  - some alias/admin consolidation could reduce size, but it is a second-choice lever because it can break existing scripts/tests and operator expectations.

## Minimum Safe V1 Plan

### Block 1: Add Lens Contracts And Move Rich Views

Add two read-only helper contracts:

- `MarginEngineLens`
- `PerpEngineLens`

These contracts should hold no protocol accounting storage and should mutate no protocol state. They should read existing core state through public getters and narrow interfaces to:

- engines
- registries
- vault
- oracle
- risk modules
- collateral seizer
- fees manager

Recommended `MarginEngine` extraction:

- Move to `MarginEngineLens`:
  - `getAccountRisk`
  - `getFreeCollateral`
  - `previewWithdrawImpact`
  - `getMarginRatioBps`
  - `getAccountState`
  - external `previewLiquidation`
  - `getSeriesSettlementAccounting`
  - `getSeriesSettlementState`
  - `getSeriesSettlementProposalState`
  - `isAccountSettledForSeries`
  - `previewAccountSettlement`
  - `previewDetailedSettlement`
  - `getProtocolSettlementAccountingSlice`
  - `getResolvedFeeRecipient`
  - `previewTradeFees`
  - `getLiquidationConfigView`
  - `getRiskCacheView`
  - `getUnderlyingSpot`

- Keep in `MarginEngine`:
  - state-changing `applyTrade`, collateral wrapper, settlement, and liquidation functions
  - `IMarginEngineState` methods required by `RiskModule`:
    - `totalShortContracts`
    - `positions`
    - `getTraderSeries`
    - `getTraderSeriesLength`
    - `getTraderSeriesSlice`
    - `optionRegistry`
    - `collateralVault`
    - `oracle`
    - `riskModule`
    - `getPositionQuantity`
    - `isOpenSeries`
  - a small internal or public liquidation-status helper only if still required by state-changing liquidation.

Recommended `PerpEngine` extraction:

- Move to `PerpEngineLens`:
  - dependency reads not needed by other protocol modules
  - `getPerpSolvencyState`
  - `getPerpAccountStatus`
  - `getPerpLiquidationState`
  - `previewResidualBadDebtRepayment`
  - `getBadDebtRepaymentRecipient`
  - `getMarket`
  - `getLiquidationConfig`
  - `getFundingConfig`
  - `getLiquidationFallbackParams`
  - `getEffectiveLiquidationParams`
  - `getLiquidationParams`
  - `previewInsuranceCoverage`
  - `previewLiquidation`
  - `previewDetailedLiquidation`
  - `getPositionNotional1e8`
  - `getPositionDirection`
  - `getAccountPnlBreakdown`
  - `getAccountExposureBreakdown`
  - `getMarketOpenInterest`
  - `getMarketSkew`

- Keep in `PerpEngine`:
  - state-changing `applyTrade`, `updateFunding`, `liquidate`, bad debt mutation/repayment, and admin/emergency functions
  - core risk-module read methods required by `PerpRiskModule`:
    - `getTraderMarketsLength`
    - `getTraderMarketsSlice`
    - `getPositionSize`
    - `getMarkPrice`
    - `getRiskConfig`
    - `getUnrealizedPnl`
    - `getPositionFundingAccrued`
    - `getSettlementAsset`
    - `getResidualBadDebt`
  - `positions` and `marketState` if scripts/tests/operators depend on them directly.
  - `getAccountNetPnl` and `getAccountFunding` unless `RiskModule` unified views are explicitly rewired to read the lens instead.

This block is the lowest-risk path because it does not change storage layout, position accounting, margin math, funding math, liquidation execution, settlement execution, oracle scaling, or collateral transfers.

### Block 2: Rebuild And Recheck Sizes

After Block 1:

1. Run `forge build`.
2. Run `forge build --sizes`.
3. Confirm every `DeployCore` contract is below 24,576 bytes with deployment headroom.
4. Run targeted tests:
   - `forge test --match-path test/unit/margin/MarginEngine.t.sol`
   - `forge test --match-path test/unit/perp/PerpEngine.t.sol`
   - `forge test --match-path test/unit/perp/PerpEngineFunding.t.sol`
   - `forge test --match-path test/unit/perp/PerpEngineLiquidation.t.sol`
   - any tests updated to call the new lenses for moved views.

### Block 3: Only If Lens Extraction Is Insufficient

If either engine still exceeds the limit after Block 1, use the next smallest non-economic levers:

1. Remove or relocate backward-compatible diagnostic/admin aliases that duplicate canonical functions.
2. Move additional read-only market/account metrics to lenses.
3. Avoid extracting settlement, funding, trade, liquidation, collateral transfer, or bad debt mutation logic unless the measured size gap remains material after all read-only extraction.

## Invariants Preserved By The Recommended Plan

- No storage layout changes in the deployed-style engines.
- No inheritance-order change required for stateful core logic beyond removing view-only inheritance once equivalent lens reads exist.
- No protocol economics change.
- No unit scaling change.
- No margin, liquidation, settlement, funding, fee, collateral, or oracle semantics change.
- State-mutating paths remain in the same core contracts.
- Lens outputs must be tested against current engine outputs before removal from the core surface.

## Deferred V2 Architecture Notes

The following may become useful after v1 launch, but are not recommended for the current size fix:

- Product adapters for generalized derivatives.
- Subaccounts and portfolio-margin account domains.
- A generalized execution engine.
- Larger protocol module registries.
- More aggressive product/risk adapter boundaries.
- Diamond/EIP-2535.
- App-chain migration.

## Explicit Non-Goals

- Do not migrate to Diamond/EIP-2535 for v1.
- Do not introduce an app-chain for v1.
- Do not redesign around subaccounts for v1.
- Do not redesign around product adapters for v1.
- Do not change protocol economics.
- Do not change storage layout.
- Do not change unit scaling.
- Do not change liquidation, margin, settlement, funding, or collateral semantics.

## Validation Performed For This Diagnosis

- Read repository instructions and architecture docs.
- Inspected `DeployCore` deployment order.
- Inspected all `src/` contracts at file/function level, with extra focus on `MarginEngine` and `PerpEngine` inheritance stacks.
- Ran `forge build --sizes`.
  - Normal compilation artifacts were current.
  - The size command reports the two expected EIP-170 failures: `MarginEngine` and `PerpEngine`.
