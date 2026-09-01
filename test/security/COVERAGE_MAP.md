# PERPS-PRICING-AND-EXECUTION-SAFETY-CORE-V1 — Security Matrix Coverage Map

Maps each of the 15 attack scenarios from the milestone security matrix to at
least one direct test. Coverage spans two repositories:

- **Solidity** (this repo, `~/DEOPT/deopt-v2-sol`) — on-chain guards.
- **Backend Rust** (`~/DEOPT/deopt-v2-backend`) — internal matching engine
  and market-order walker.

Perps remains **NON-LIVE** and fail-closed at the public-route boundary. These
tests validate the safety guards independently of activation state.

## Coverage Table (milestone scenarios)

| # | Scenario | Repo | Test File | Test Name(s) | Status |
|---|----------|------|-----------|--------------|--------|
| 1 | Colluding buyer/seller execute FAR above index | sol | `test/security/PerpCollusionExecutionPriceAttack.t.sol` | `testCollusionExecutionPriceFarAboveIndexRevertsOnDirectApplyTrade`, `testCollusionExecutionPriceFarAboveIndexRevertsThroughFullMatchingFlow`, `testFuzz_collusionAnyPriceOutsideBandReverts` | Covered |
| 2 | Colluding buyer/seller execute FAR below index | sol | `test/security/PerpCollusionExecutionPriceAttack.t.sol` | `testCollusionExecutionPriceFarBelowIndexRevertsOnDirectApplyTrade`, `testCollusionExecutionPriceFarBelowIndexRevertsThroughFullMatchingFlow`, `testFuzz_collusionAnyPriceOutsideBandReverts` | Covered |
| 3 | Stale oracle — trade must revert through the protocol guard | sol | `test/perp/PerpEngineExecutionPriceGuard.t.sol` + `test/scenario/system/OracleFailureFlow.t.sol` | `testOracleStalenessBeyondMaxDelayPropagatesRevert`, `testStaleOraclePriceCausesProtectedLiquidationPathToRevert` | Covered |
| 4 | Unavailable oracle (`ok=false` or `px=0`) — trade must revert | sol | `test/perp/PerpEngineExecutionPriceGuard.t.sol` + `test/scenario/system/OracleFailureFlow.t.sol` | `testOracleUnavailableRevertsWithDedicatedError`, `testOracleReturningZeroPriceRevertsWithDedicatedError`, `testUnconfiguredMarketRejectsTradesFailClosed`, `testUnavailableOraclePathCausesProtectedOperationToFailSafely` | Covered |
| 5 | User Buy above `maxExecutionPrice` — reverts with `BuyerBoundExceeded` | sol | `test/matching/PerpMatchingEngineUserBounds.t.sol` | `testBuyerBoundExecAboveBoundReverts`, `testBothBoundsExecAboveBuyerRevertsBuyerFirst`, `testImpossibleRangeBuyerCheckFiresFirst` | Covered |
| 6 | User Sell below `minExecutionPrice` — reverts with `SellerBoundViolated` | sol | `test/matching/PerpMatchingEngineUserBounds.t.sol` | `testSellerBoundExecBelowBoundReverts`, `testBothBoundsExecBelowSellerRevertsSeller` | Covered |
| 7 | Protocol bound tighter than user bound — protocol wins downstream | sol | `test/security/PerpDoubleBoundInteraction.t.sol` | `testProtocolBoundTighterThanUserBoundBlocksBuyExecution`, `testProtocolBoundTighterThanUserBoundBlocksSellExecution`, `testProtocolBoundTighterThanUserBoundInsideBothPasses` | Covered |
| 8 | User bound tighter than protocol bound — user wins upstream | sol | `test/security/PerpDoubleBoundInteraction.t.sol` | `testUserBoundTighterThanProtocolBoundBlocksBuyExecution`, `testUserBoundTighterThanProtocolBoundBlocksSellExecution`, `testUserBoundTighterThanProtocolBoundInsideBothPasses` | Covered |
| 9 | Market order exhausts allowed liquidity — walker cancels remainder | backend | `tests/perps_execution_tests.rs` | `scenario_9_market_order_exhausts_allowed_liquidity` | Covered |
| 10 | Market order stops at user's slippage boundary | backend | `tests/perps_execution_tests.rs` | `scenario_10_market_order_stops_at_user_slippage_boundary` | Covered |
| 11 | Partial market fill — walker fills what exists, cancels rest | backend | `tests/perps_execution_tests.rs` | `scenario_11_market_order_partial_fill` | Covered |
| 12 | No acceptable liquidity within user bound — zero fills, no fabricated position | backend | `tests/perps_execution_tests.rs` | `scenario_12_market_order_no_acceptable_liquidity` | Covered |
| 13 | Funding premium manipulation via compromised keeper — cap absorbs magnitude | sol | `test/security/PerpFundingKeeperCompromiseAttack.t.sol` (+ `test/perp/PerpEngineFundingV2.t.sol`) | `testCompromisedKeeperCannotBleedFasterThanCap`, `testCompromisedKeeperCannotBleedFasterThanCapOnNegativeSpike`, `testCompromisedKeeperModerateSpikeStillClampedToCap`, `testCompromisedKeeperSustainedAttackBoundedByNCap`, `testFuzz_compromisedKeeperAnyAboveCapSpikeBoundedByCap`, `testCapClampsFundingRate`, `testFuzz_manipulationBoundedByCap` | Covered |
| 14 | Funding rate cap enforced under any premium | sol | `test/perp/PerpEngineFundingV2.t.sol` | `testCapClampsFundingRate`, `testFuzz_manipulationBoundedByCap`, `testDeadbandSuppressesPremiumBelowThreshold` | Covered |
| 15 | Oracle deviation failure — solo-primary blocking + dual-source deviation | sol | `test/oracle/OracleRouterDualSourceInvariant.t.sol` | 14 invariant tests (solo-primary bootstrap blocking, deviation guard, safe-mode transitions) | Covered |

## Summary

- **Total milestone scenarios**: 15
- **Covered**: 15
- **Gaps**: 0

All 15 attack scenarios have at least one direct test that reproduces the
attack (or attempt) and asserts the expected fail-closed outcome. Perps
activation state is not touched by any of these tests.

## Complementary security coverage (additional attack scenarios)

These are additional Solidity-side attack tests not enumerated in the
milestone's 15-scenario matrix but that fall out naturally from the V2 signed
`PerpTrade` architecture (Part B) and belong to the same security posture:

| Extra | Scenario | Test File | Test Name(s) |
|-------|----------|-----------|--------------|
| E-A | Tampered `executionPrice1e8` after signing — sig verify rejects | `test/matching/PerpMatchingEngineUserBounds.t.sol` | `testBothBoundsZeroTamperedExecutionPriceRejectedAsInvalidSignature` |
| E-B | Replay of legacy V1 signature against V2 typehash — rejected | `test/matching/PerpMatchingEngineUserBounds.t.sol` | `testLegacyV1SignaturesRejectedByV2Engine` |
| E-C | Impossible price range (buyer.max < seller.min) — deterministic revert order | `test/matching/PerpMatchingEngineUserBounds.t.sol` | `testImpossibleRangeBuyerCheckFiresFirst` |
| E-D | Missing / never-seeded / stale keeper impact-mid — funding fail-closed to 0 (no revert) | `test/perp/PerpEngineFundingV2.t.sol` | `testKeeperSampleStaleFailsClosedToZero`, `testKeeperNeverSeededProducesZeroRate` |

## Test Files by Scenario

Solidity:
- `test/security/PerpCollusionExecutionPriceAttack.t.sol` — Scenarios 1, 2 (5 tests)
- `test/security/PerpDoubleBoundInteraction.t.sol` — Scenarios 7, 8 (6 tests)
- `test/security/PerpFundingKeeperCompromiseAttack.t.sol` — Scenario 13 (5 tests)
- `test/matching/PerpMatchingEngineUserBounds.t.sol` — Scenarios 5, 6 + Extras E-A, E-B, E-C
- `test/perp/PerpEngineExecutionPriceGuard.t.sol` — Scenarios 3, 4
- `test/perp/PerpEngineFundingV2.t.sol` — Scenario 13 (complementary), 14 + Extra E-D
- `test/scenario/system/OracleFailureFlow.t.sol` — Scenarios 3, 4
- `test/oracle/OracleRouterDualSourceInvariant.t.sol` — Scenario 15

Backend (Rust):
- `tests/perps_execution_tests.rs` (section H) — Scenarios 9, 10, 11, 12 (4 tests)

## Non-Live Guarantee

None of the tests in this suite flip an `isEnabled` or activation flag on any
production market. All security assertions run on isolated test-created
markets or existing test infrastructure. The public-route disable that keeps
Perps NON-LIVE is verified elsewhere.
