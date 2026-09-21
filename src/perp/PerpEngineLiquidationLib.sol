// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {ICollateralSeizer} from "../liquidation/ICollateralSeizer.sol";
import {PerpEngineSeizureLib} from "./PerpEngineSeizureLib.sol";
import {PerpEngineTypes} from "./PerpEngineTypes.sol";
import {IPerpRiskModule} from "./PerpEngineStorage.sol";

// Minimal insurance-backstop interface (mirrors the one declared inline
// in PerpEngineTradingV2). Kept file-level so it can be referenced from
// within the library.
interface IInsuranceFundPerpBackstopV2Local {
    function coverVaultShortfall(address token, address toAccount, uint256 requestedAmount)
        external
        returns (uint256 paidAmount);
}

/// @title PerpEngineLiquidationLib
/// @notice External library hosting the cold-path liquidation orchestration
///         primitives for `PerpEngineV2`.
///
/// @dev
///  PERPS_V2_ENGINE_SIZE_REDUCTION_B_COLD_PATH_EXTRACT_V1 §5-§9 —
///  Liquidation is a permissionless-but-uncommon path relative to `applyTrade`.
///  Extracting the seize/shortfall/insurance orchestration and the pure
///  liquidation math to an `external` library (deployed once, invoked via
///  DELEGATECALL) removes ~1-2 KB from `PerpEngineV2` runtime bytecode while
///  preserving:
///
///    - byte-for-byte call sequence into `CollateralVault.transferBetweenAccounts`
///      and `IInsuranceFundPerpBackstopV2.coverVaultShortfall`;
///    - event topic0 (events emitted from delegatecall context = engine address);
///    - error selectors (declared here with the same names/params as the engine
///      previously used, producing identical selectors);
///    - migration/pause/onlyMigrationSealed guarding (still applied by the
///      engine's outer `liquidate` wrapper BEFORE any library call);
///    - storage-slot layout (this library holds NO storage; every mutation is
///      to caller-context state via the engine wrapper).
///
///  Boundary: this library does NOT read or write engine storage directly.
///  Reads and writes to `_positions`, `_marketStates`, `_residualBadDebtBase`,
///  `traderMarkets`, `_updateMarketOpenInterest`, and `_applyRealizedCashflow`
///  remain in the engine wrapper so hot-path invariants and the V2 clearing-
///  account settlement primitive stay single-source-of-truth.
///
///  The seize helpers here (`seizePenaltyToLiquidator`, `resolveShortfall`,
///  `tryCoverInsurance`) invoke `CollateralVault.transferBetweenAccounts`,
///  which is `onlyMarginEngine`-guarded on the vault side. Under DELEGATECALL,
///  `msg.sender` at the vault call site is the ENGINE address (not this
///  library), so the vault authorization check continues to pass exactly as
///  it did pre-refactor.
library PerpEngineLiquidationLib {
    // ────────────────────────────────────────────────────────────
    // Constants (mirror engine)
    // ────────────────────────────────────────────────────────────
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_1E8 = 1e8;
    uint256 internal constant FUNDING_SCALE_1E18 = 1e18;

    // ────────────────────────────────────────────────────────────
    // Errors (mirror engine selectors for stable observability)
    // ────────────────────────────────────────────────────────────
    error InsuranceFundNotSet();
    error InsuranceFundCoverageFailed();
    error LiquidationCloseFactorZero();
    error LiquidationParamsInvalid();
    error LiquidationNothingToDo();
    error LiquidationPriceInvalid();
    error LiquidationPenaltyTooLarge();
    error SizeTooLarge();
    error SizeZero();
    error PriceZero();
    error MathOverflow();
    error QuantityMinNotAllowed();
    error CastOverflow();
    error SignedMathOverflow();

    // ────────────────────────────────────────────────────────────
    // Events (emitted from engine's storage context under DELEGATECALL)
    // ────────────────────────────────────────────────────────────
    event LiquidationShortfall(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint256 penaltyTargetBase,
        uint256 seizedPenaltyBase,
        uint256 shortfallBase
    );

    event LiquidationInsuranceCoverage(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint256 requestedBase,
        uint256 paidBase
    );

    event LiquidationBadDebtRecorded(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint256 residualBase
    );

    /// @notice PERPS_V2_ENGINE_SIZE_REDUCTION_C_FINAL_IMPLEMENTATION_V1 §15 —
    ///         mirrored from `PerpEngineTypes` so the library can emit
    ///         under DELEGATECALL with byte-identical topic0.
    event Liquidation(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint128 sizeClosed1e8,
        uint256 liqPrice1e8,
        uint256 totalPenaltyPaidBase
    );

    event LiquidationResolved(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint128 sizeClosed1e8,
        uint256 liqPrice1e8,
        uint256 closedNotionalBase,
        uint256 penaltyTargetBase,
        uint256 seizedPenaltyBase,
        uint256 insurancePaidBase,
        uint256 residualShortfallBase,
        uint256 totalPenaltyPaidBase
    );

    event LiquidationPenaltyPaid(
        address indexed liquidator,
        address indexed trader,
        uint256 indexed marketId,
        uint256 totalPenaltyPaidBase
    );

    /// @notice Compute output for the full clip+leg orchestration.
    struct ClipAndLegResult {
        PerpEngineTypes.Position newTraderPos;
        PerpEngineTypes.Position newLiqPos;
        int256 traderRealizedPnl1e8;
        uint128 sizeClosed1e8;
        uint256 liqPrice1e8;
    }

    struct SeizeCtx {
        CollateralVault vault;
        ICollateralSeizer seizer;
        IOracle oracle;
        address baseToken;
        address settlementAsset;
    }

    /// @notice Seize penalty from trader collateral into liquidator's Vault balance.
    /// @dev
    ///   Two-stage seize:
    ///     1. Multi-asset collateral-seizer plan (if configured).
    ///     2. Direct settlement-asset skim from trader Vault balance to
    ///        liquidator, up to the remaining penalty.
    ///   Returns the total base-token-denominated penalty actually seized.
    function seizePenaltyToLiquidator(
        SeizeCtx memory ctx,
        address trader,
        address liquidator,
        uint256 penaltyBase
    ) external returns (uint256 paidPenaltyBase) {
        if (penaltyBase == 0) return 0;

        paidPenaltyBase = PerpEngineSeizureLib.trySeizeViaPlan(
            ctx.seizer, ctx.vault, trader, liquidator, penaltyBase
        );
        if (paidPenaltyBase >= penaltyBase) {
            return penaltyBase;
        }

        uint256 remainingBase = penaltyBase - paidPenaltyBase;

        // Best-effort sync of yield-bearing balance (mirrors engine helper).
        // If the vault does not implement or errors, ignore — same semantics
        // as `_syncVaultBestEffort`.
        (bool okSync,) = address(ctx.vault).call(
            abi.encodeWithSignature("syncAccountFor(address,address)", trader, ctx.settlementAsset)
        );
        okSync;

        uint256 penaltyNative = _penaltySettlementNative(ctx, remainingBase);
        if (penaltyNative == 0) return paidPenaltyBase;

        uint256 traderBal = ctx.vault.balances(trader, ctx.settlementAsset);
        uint256 paidNative = penaltyNative <= traderBal ? penaltyNative : traderBal;
        if (paidNative == 0) return paidPenaltyBase;

        ctx.vault.transferBetweenAccounts(ctx.settlementAsset, trader, liquidator, paidNative);

        if (ctx.settlementAsset == ctx.baseToken) {
            return paidPenaltyBase + paidNative;
        }

        uint256 extraBase = PerpEngineSeizureLib.settlementNativeToBase(
            ctx.vault, ctx.oracle, ctx.baseToken, ctx.settlementAsset, paidNative
        );
        paidPenaltyBase += extraBase;

        if (paidPenaltyBase > penaltyBase) {
            paidPenaltyBase = penaltyBase;
        }
    }

    /// @notice Attempt to cover remaining shortfall from insurance fund.
    function tryCoverInsurance(
        address insuranceFund,
        address baseToken,
        address liquidator,
        uint256 requestedBase
    ) external returns (uint256 paidBase) {
        if (requestedBase == 0) return 0;
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();

        try IInsuranceFundPerpBackstopV2Local(insuranceFund).coverVaultShortfall(
            baseToken, liquidator, requestedBase
        ) returns (uint256 paid) {
            paidBase = paid <= requestedBase ? paid : requestedBase;
        } catch {
            revert InsuranceFundCoverageFailed();
        }
    }

    /// @notice Resolve outstanding penalty shortfall via insurance + residual bad debt.
    /// @dev
    ///  Emits `LiquidationShortfall` / `LiquidationInsuranceCoverage` /
    ///  `LiquidationBadDebtRecorded` mirroring the engine's pre-extraction
    ///  event surface. Under DELEGATECALL these events fire from the engine
    ///  address, so indexers observe no behavioral change.
    ///
    ///  Returns the full breakdown so the engine can call `_recordResidualBadDebt`
    ///  when `residualShortfallBase != 0`.
    function resolveShortfall(
        address insuranceFund,
        address baseToken,
        address liquidator,
        address trader,
        uint256 marketId,
        uint256 penaltyTargetBase,
        uint256 seizedPenaltyBase
    ) external returns (PerpEngineTypes.LiquidationResolution memory res) {
        res.penaltyTargetBase = penaltyTargetBase;
        res.seizedPenaltyBase = seizedPenaltyBase;

        uint256 remainingAfterSeizure = _remainingShortfall(penaltyTargetBase, seizedPenaltyBase);
        if (remainingAfterSeizure == 0) return res;

        emit LiquidationShortfall(
            liquidator, trader, marketId, penaltyTargetBase, seizedPenaltyBase, remainingAfterSeizure
        );

        uint256 insurancePaid = _tryCoverInsuranceInline(insuranceFund, baseToken, liquidator, remainingAfterSeizure);
        res.insurancePaidBase = insurancePaid;

        if (insurancePaid != 0) {
            emit LiquidationInsuranceCoverage(liquidator, trader, marketId, remainingAfterSeizure, insurancePaid);
        }

        uint256 residual = _remainingShortfall(remainingAfterSeizure, insurancePaid);
        res.residualShortfallBase = residual;

        if (residual != 0) {
            emit LiquidationBadDebtRecorded(liquidator, trader, marketId, residual);
        }
    }

    // ────────────────────────────────────────────────────────────
    // Internal helpers (library-local; not part of external ABI)
    // ────────────────────────────────────────────────────────────

    function _remainingShortfall(uint256 target, uint256 covered) internal pure returns (uint256) {
        return covered >= target ? 0 : target - covered;
    }

    function _tryCoverInsuranceInline(
        address insuranceFund,
        address baseToken,
        address liquidator,
        uint256 requestedBase
    ) internal returns (uint256 paidBase) {
        if (requestedBase == 0) return 0;
        if (insuranceFund == address(0)) revert InsuranceFundNotSet();

        try IInsuranceFundPerpBackstopV2Local(insuranceFund).coverVaultShortfall(
            baseToken, liquidator, requestedBase
        ) returns (uint256 paid) {
            paidBase = paid <= requestedBase ? paid : requestedBase;
        } catch {
            revert InsuranceFundCoverageFailed();
        }
    }

    function _penaltySettlementNative(SeizeCtx memory ctx, uint256 penaltyBase)
        internal
        view
        returns (uint256 penaltyNative)
    {
        if (penaltyBase == 0) return 0;
        if (ctx.settlementAsset == ctx.baseToken) return penaltyBase;

        (uint256 px, bool ok) = PerpEngineSeizureLib.tryGetMarkPrice1e8FromPair(
            ctx.oracle, ctx.settlementAsset, ctx.baseToken
        );
        if (!ok || px == 0) revert PerpEngineSeizureLib.OraclePriceUnavailable();

        penaltyNative = PerpEngineSeizureLib.baseValueToTokenAmount(
            ctx.vault, ctx.baseToken, ctx.settlementAsset, penaltyBase, px
        );
    }

    // ============================================================
    // PERPS_V2_ENGINE_SIZE_REDUCTION_C — full liquidation extraction
    // ============================================================
    //
    // §5-§9: three new external entrypoints move the remaining cold-path
    // liquidation logic out of `PerpEngineV2` runtime bytecode:
    //   - `isTraderLiquidatable(...)` — pure predicate
    //   - `computeClipAndLeg(...)`    — pure position math (dup of engine helpers)
    //   - `checkImprovedAndEmit(...)` — improvement check + 3 final events
    //
    // All storage writes (positions, indexing, OI, residual bad debt,
    // realized cashflow via clearing account) remain in the engine
    // wrapper per §8. This library only computes and emits.

    /// @notice Pure predicate: is this trader eligible for liquidation?
    /// @dev Mirrors `_isTraderLiquidatable` in the engine byte-for-byte.
    function isTraderLiquidatable(IPerpRiskModule.AccountRisk memory r)
        external
        pure
        returns (bool)
    {
        if (r.maintenanceMarginBase == 0) return false;
        if (r.equityBase <= 0) return true;
        return _marginRatioBpsFromState(r.equityBase, r.maintenanceMarginBase) < BPS;
    }

    /// @notice Compute liquidation clip on trader position + liquidator leg.
    /// @dev
    ///  Pure math. Mirrors the pre-refactor engine helpers
    ///  `_liquidationPrice1e8FromMark`, `_boundedLiquidationSize1e8`,
    ///  `_liquidationClip`, `_applyLiquidationLegToLiquidator` byte-for-byte
    ///  and returns the delta needed for the engine to write into
    ///  `_positions` and update indexing/OI via canonical helpers.
    function computeClipAndLeg(
        PerpEngineTypes.Position memory oldTraderPos,
        PerpEngineTypes.Position memory oldLiqPos,
        uint128 requestedCloseSize1e8,
        uint256 markPrice1e8,
        int256 currentCumulativeFundingRate1e18,
        uint256 closeFactorBps,
        uint256 priceSpreadBps
    ) external pure returns (ClipAndLegResult memory r) {
        if (oldTraderPos.size1e8 == 0) revert LiquidationNothingToDo();

        r.liqPrice1e8 = _liqPriceFromMark(oldTraderPos.size1e8, markPrice1e8, priceSpreadBps);

        uint128 executed =
            _boundedLiquidationSize1e8(oldTraderPos.size1e8, requestedCloseSize1e8, closeFactorBps);
        if (executed == 0) revert LiquidationNothingToDo();
        r.sizeClosed1e8 = executed;

        int256 deltaForTrader = oldTraderPos.size1e8 > 0
            ? -_toInt256(uint256(executed))
            : _toInt256(uint256(executed));

        (r.newTraderPos, r.traderRealizedPnl1e8) =
            _computeNextPosition(oldTraderPos, deltaForTrader, r.liqPrice1e8, currentCumulativeFundingRate1e18);

        bool traderWasLong = oldTraderPos.size1e8 > 0;
        int256 deltaForLiquidator = traderWasLong
            ? _toInt256(uint256(executed))
            : -_toInt256(uint256(executed));

        int256 ignoredRealized;
        (r.newLiqPos, ignoredRealized) =
            _computeNextPosition(oldLiqPos, deltaForLiquidator, r.liqPrice1e8, currentCumulativeFundingRate1e18);
        ignoredRealized;
    }

    /// @notice Combined cold-path liquidation post-write orchestration:
    ///         seize + insurance shortfall + improvement check + 3 terminal events.
    /// @dev
    ///   PERPS_V2_ENGINE_SIZE_REDUCTION_C_FINAL_IMPLEMENTATION_V1 §10 —
    ///   Consolidates what was previously 3 separate DELEGATECALL boundaries
    ///   into ONE, shedding marshalling overhead from the engine wrapper.
    ///   Returns the resolution + `improved` flag so the engine can:
    ///     (a) record residual bad debt if `resolution.residualShortfallBase != 0`;
    ///     (b) revert with `LiquidationNotImproving()` if `!improved`.
    function finalizeLiquidation(
        SeizeCtx memory ctx,
        address insuranceFund,
        address liquidator,
        address trader,
        uint256 marketId,
        uint128 sizeClosed1e8,
        uint256 liqPrice1e8,
        uint256 closedNotionalBase,
        uint256 penaltyBase,
        IPerpRiskModule.AccountRisk memory riskBefore,
        IPerpRiskModule.AccountRisk memory riskAfter,
        uint256 minImprovementBps
    )
        external
        returns (PerpEngineTypes.LiquidationResolution memory resolution, bool improved)
    {
        uint256 seizedPenaltyBase = _seizeInline(ctx, trader, liquidator, penaltyBase);

        resolution = _resolveInline(
            insuranceFund, ctx.baseToken, liquidator, trader, marketId, penaltyBase, seizedPenaltyBase
        );

        improved = _liquidationImproved(
            riskBefore.equityBase,
            riskBefore.maintenanceMarginBase,
            riskAfter.equityBase,
            riskAfter.maintenanceMarginBase,
            minImprovementBps
        );

        if (improved) {
            uint256 totalPenaltyPaidBase = resolution.seizedPenaltyBase + resolution.insurancePaidBase;
            emit Liquidation(liquidator, trader, marketId, sizeClosed1e8, liqPrice1e8, totalPenaltyPaidBase);
            emit LiquidationResolved(
                liquidator,
                trader,
                marketId,
                sizeClosed1e8,
                liqPrice1e8,
                closedNotionalBase,
                penaltyBase,
                resolution.seizedPenaltyBase,
                resolution.insurancePaidBase,
                resolution.residualShortfallBase,
                totalPenaltyPaidBase
            );
            emit LiquidationPenaltyPaid(liquidator, trader, marketId, totalPenaltyPaidBase);
        }
    }

    /// Internal seize logic (mirrors external `seizePenaltyToLiquidator`) — inlined here
    /// so `finalizeLiquidation` executes without a nested delegatecall.
    function _seizeInline(SeizeCtx memory ctx, address trader, address liquidator, uint256 penaltyBase)
        internal
        returns (uint256 paidPenaltyBase)
    {
        if (penaltyBase == 0) return 0;

        paidPenaltyBase = PerpEngineSeizureLib.trySeizeViaPlan(
            ctx.seizer, ctx.vault, trader, liquidator, penaltyBase
        );
        if (paidPenaltyBase >= penaltyBase) return penaltyBase;

        uint256 remainingBase = penaltyBase - paidPenaltyBase;
        (bool okSync,) = address(ctx.vault).call(
            abi.encodeWithSignature("syncAccountFor(address,address)", trader, ctx.settlementAsset)
        );
        okSync;

        uint256 penaltyNative = _penaltySettlementNative(ctx, remainingBase);
        if (penaltyNative == 0) return paidPenaltyBase;

        uint256 traderBal = ctx.vault.balances(trader, ctx.settlementAsset);
        uint256 paidNative = penaltyNative <= traderBal ? penaltyNative : traderBal;
        if (paidNative == 0) return paidPenaltyBase;

        ctx.vault.transferBetweenAccounts(ctx.settlementAsset, trader, liquidator, paidNative);

        if (ctx.settlementAsset == ctx.baseToken) return paidPenaltyBase + paidNative;

        uint256 extraBase = PerpEngineSeizureLib.settlementNativeToBase(
            ctx.vault, ctx.oracle, ctx.baseToken, ctx.settlementAsset, paidNative
        );
        paidPenaltyBase += extraBase;
        if (paidPenaltyBase > penaltyBase) paidPenaltyBase = penaltyBase;
    }

    /// Internal shortfall resolution (mirrors external `resolveShortfall`) — inlined
    /// to keep `finalizeLiquidation` a single delegatecall entry.
    function _resolveInline(
        address insuranceFund,
        address baseToken,
        address liquidator,
        address trader,
        uint256 marketId,
        uint256 penaltyTargetBase,
        uint256 seizedPenaltyBase
    ) internal returns (PerpEngineTypes.LiquidationResolution memory res) {
        res.penaltyTargetBase = penaltyTargetBase;
        res.seizedPenaltyBase = seizedPenaltyBase;

        uint256 remainingAfterSeizure = _remainingShortfall(penaltyTargetBase, seizedPenaltyBase);
        if (remainingAfterSeizure == 0) return res;

        emit LiquidationShortfall(
            liquidator, trader, marketId, penaltyTargetBase, seizedPenaltyBase, remainingAfterSeizure
        );

        uint256 insurancePaid = _tryCoverInsuranceInline(insuranceFund, baseToken, liquidator, remainingAfterSeizure);
        res.insurancePaidBase = insurancePaid;
        if (insurancePaid != 0) {
            emit LiquidationInsuranceCoverage(liquidator, trader, marketId, remainingAfterSeizure, insurancePaid);
        }

        uint256 residual = _remainingShortfall(remainingAfterSeizure, insurancePaid);
        res.residualShortfallBase = residual;
        if (residual != 0) {
            emit LiquidationBadDebtRecorded(liquidator, trader, marketId, residual);
        }
    }

    // -------- LEGACY EXTERNAL API (kept for backwards compat / smaller callers)

    /// @notice DEPRECATED: use `finalizeLiquidation` for combined path.
    function checkImprovedAndEmit(
        IPerpRiskModule.AccountRisk memory riskBefore,
        IPerpRiskModule.AccountRisk memory riskAfter,
        uint256 minImprovementBps,
        address liquidator,
        address trader,
        uint256 marketId,
        uint128 sizeClosed1e8,
        uint256 liqPrice1e8,
        uint256 closedNotionalBase,
        uint256 penaltyBase,
        PerpEngineTypes.LiquidationResolution memory resolution
    ) external returns (bool improved) {
        improved = _liquidationImproved(
            riskBefore.equityBase,
            riskBefore.maintenanceMarginBase,
            riskAfter.equityBase,
            riskAfter.maintenanceMarginBase,
            minImprovementBps
        );
        if (!improved) return false;

        uint256 totalPenaltyPaidBase = resolution.seizedPenaltyBase + resolution.insurancePaidBase;

        emit Liquidation(liquidator, trader, marketId, sizeClosed1e8, liqPrice1e8, totalPenaltyPaidBase);
        emit LiquidationResolved(
            liquidator,
            trader,
            marketId,
            sizeClosed1e8,
            liqPrice1e8,
            closedNotionalBase,
            penaltyBase,
            resolution.seizedPenaltyBase,
            resolution.insurancePaidBase,
            resolution.residualShortfallBase,
            totalPenaltyPaidBase
        );
        emit LiquidationPenaltyPaid(liquidator, trader, marketId, totalPenaltyPaidBase);
    }

    // ────────────────────────────────────────────────────────────
    // Duplicated pure math (mirrors PerpEngineTypes/Storage helpers)
    // — kept `internal` so the library inlines them; no call overhead
    // ────────────────────────────────────────────────────────────

    function _liqPriceFromMark(int256 liquidatedPositionSize1e8, uint256 markPrice1e8, uint256 spreadBps)
        internal
        pure
        returns (uint256 liqPrice1e8)
    {
        if (markPrice1e8 == 0) revert LiquidationPriceInvalid();
        if (spreadBps > BPS) revert LiquidationParamsInvalid();
        if (liquidatedPositionSize1e8 == 0) revert LiquidationNothingToDo();

        if (liquidatedPositionSize1e8 > 0) {
            liqPrice1e8 = (markPrice1e8 * (BPS - spreadBps)) / BPS;
        } else {
            liqPrice1e8 = (markPrice1e8 * (BPS + spreadBps)) / BPS;
        }

        if (liqPrice1e8 == 0) revert LiquidationPriceInvalid();
    }

    function _boundedLiquidationSize1e8(
        int256 positionSize1e8,
        uint128 requestedCloseSize1e8,
        uint256 closeFactorBps
    ) internal pure returns (uint128 executedCloseSize1e8) {
        uint128 maxClose = _maxLiquidatableSize1e8(positionSize1e8, closeFactorBps);
        if (maxClose == 0) return 0;
        if (requestedCloseSize1e8 == 0) return maxClose;
        return requestedCloseSize1e8 < maxClose ? requestedCloseSize1e8 : maxClose;
    }

    function _maxLiquidatableSize1e8(int256 positionSize1e8, uint256 closeFactorBps)
        internal
        pure
        returns (uint128 maxCloseSize1e8)
    {
        if (closeFactorBps == 0) revert LiquidationCloseFactorZero();
        if (closeFactorBps > BPS) revert LiquidationParamsInvalid();

        uint256 absSize = _absInt256(positionSize1e8);
        if (absSize == 0) return 0;

        uint256 raw = (absSize * closeFactorBps) / BPS;
        if (raw == 0) raw = 1;

        if (raw > uint256(type(uint128).max)) revert SizeTooLarge();
        return uint128(raw);
    }

    function _marginRatioBpsFromState(int256 equityBase, uint256 maintenanceMarginBase)
        internal
        pure
        returns (uint256)
    {
        if (maintenanceMarginBase == 0) return type(uint256).max;
        if (equityBase <= 0) return 0;
        return (uint256(equityBase) * BPS) / maintenanceMarginBase;
    }

    function _liquidationImproved(
        int256 equityBeforeBase,
        uint256 maintenanceMarginBeforeBase,
        int256 equityAfterBase,
        uint256 maintenanceMarginAfterBase,
        uint256 minImprovementBps
    ) internal pure returns (bool) {
        uint256 beforeRatio = _marginRatioBpsFromState(equityBeforeBase, maintenanceMarginBeforeBase);
        uint256 afterRatio = _marginRatioBpsFromState(equityAfterBase, maintenanceMarginAfterBase);

        if (equityBeforeBase > 0) {
            return afterRatio >= beforeRatio + minImprovementBps;
        }
        // Was insolvent → strictly improving means becoming solvent with the required cushion.
        return equityAfterBase > 0 && afterRatio >= minImprovementBps;
    }

    // -------- position transition math (mirrors PerpEngineStorage) --------

    function _computeNextPosition(
        PerpEngineTypes.Position memory oldPos,
        int256 deltaSize1e8,
        uint256 executionPrice1e8,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (PerpEngineTypes.Position memory nextPos, int256 realizedPnl1e8) {
        int256 oldSize = oldPos.size1e8;
        int256 oldOpenNotional = oldPos.openNotional1e8;

        if (deltaSize1e8 == 0) revert SizeZero();
        if (executionPrice1e8 == 0) revert PriceZero();

        int256 newSize = _checkedAddInt256(oldSize, deltaSize1e8);
        nextPos.size1e8 = newSize;

        if (oldSize == 0 || _sameSignNonZero(oldSize, deltaSize1e8)) {
            nextPos.openNotional1e8 =
                _checkedAddInt256(oldOpenNotional, _signedMarkValue1e8(deltaSize1e8, executionPrice1e8));

            if (oldSize == 0) {
                nextPos.lastCumulativeFundingRate1e18 = currentCumulativeFundingRate1e18;
            } else {
                nextPos.lastCumulativeFundingRate1e18 =
                    _carryForwardFundingCheckpointForIncrease(oldPos, newSize, currentCumulativeFundingRate1e18);
            }

            return (nextPos, 0);
        }

        uint256 absOld = _absInt256(oldSize);
        uint256 absDelta = _absInt256(deltaSize1e8);
        uint256 closeAbs = absOld < absDelta ? absOld : absDelta;

        int256 closeSizeSigned = oldSize > 0 ? _toInt256(closeAbs) : -_toInt256(closeAbs);

        int256 removedBasis1e8 = (oldOpenNotional * _toInt256(closeAbs)) / _toInt256(absOld);
        int256 closedMarkValue1e8 = _signedMarkValue1e8(closeSizeSigned, executionPrice1e8);
        int256 closedFunding1e8 = _closedFundingPortion1e8(oldPos, closeAbs, currentCumulativeFundingRate1e18);

        realizedPnl1e8 = _checkedSubInt256(_checkedSubInt256(closedMarkValue1e8, removedBasis1e8), closedFunding1e8);

        if (newSize == 0) {
            nextPos.openNotional1e8 = 0;
            nextPos.lastCumulativeFundingRate1e18 = 0;
            return (nextPos, realizedPnl1e8);
        }

        if (_sameSignNonZero(oldSize, newSize)) {
            nextPos.openNotional1e8 = _checkedSubInt256(oldOpenNotional, removedBasis1e8);
            nextPos.lastCumulativeFundingRate1e18 = oldPos.lastCumulativeFundingRate1e18;
            return (nextPos, realizedPnl1e8);
        }

        nextPos.openNotional1e8 = _signedMarkValue1e8(newSize, executionPrice1e8);
        nextPos.lastCumulativeFundingRate1e18 = currentCumulativeFundingRate1e18;
    }

    function _closedFundingPortion1e8(
        PerpEngineTypes.Position memory oldPos,
        uint256 closeAbs,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 closedFunding1e8) {
        if (oldPos.size1e8 == 0 || closeAbs == 0) return 0;

        uint256 absOld = _absInt256(oldPos.size1e8);
        int256 totalAccruedFunding1e8 = _accruedFundingOnPosition(oldPos, currentCumulativeFundingRate1e18);

        closedFunding1e8 = (totalAccruedFunding1e8 * _toInt256(closeAbs)) / _toInt256(absOld);
    }

    function _carryForwardFundingCheckpointForIncrease(
        PerpEngineTypes.Position memory oldPos,
        int256 newSize1e8,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 nextCheckpoint1e18) {
        if (oldPos.size1e8 == 0) return currentCumulativeFundingRate1e18;

        int256 accruedFunding1e8 = _accruedFundingOnPosition(oldPos, currentCumulativeFundingRate1e18);
        if (accruedFunding1e8 == 0) return currentCumulativeFundingRate1e18;

        int256 deltaRate1e18 = (accruedFunding1e8 * _toInt256(FUNDING_SCALE_1E18)) / newSize1e8;
        nextCheckpoint1e18 = currentCumulativeFundingRate1e18 - deltaRate1e18;
    }

    function _accruedFundingOnPosition(
        PerpEngineTypes.Position memory oldPos,
        int256 currentCumulativeFundingRate1e18
    ) internal pure returns (int256 funding1e8) {
        if (oldPos.size1e8 == 0) return 0;
        return _fundingPayment1e8(
            oldPos.size1e8, currentCumulativeFundingRate1e18, oldPos.lastCumulativeFundingRate1e18
        );
    }

    function _fundingPayment1e8(int256 size1e8, int256 cumulativeFundingNow1e18, int256 cumulativeFundingLast1e18)
        internal
        pure
        returns (int256 payment1e8)
    {
        int256 delta = _checkedSubInt256(cumulativeFundingNow1e18, cumulativeFundingLast1e18);

        if (size1e8 == 0 || delta == 0) return 0;

        uint256 absSize = _absInt256(size1e8);
        uint256 absDelta = _absInt256(delta);

        uint256 absPayment = _mulChecked(absSize, absDelta) / FUNDING_SCALE_1E18;
        int256 absPaymentSigned = _toInt256(absPayment);

        bool sameSign = (size1e8 >= 0 && delta >= 0) || (size1e8 < 0 && delta < 0);
        payment1e8 = sameSign ? absPaymentSigned : -absPaymentSigned;
    }

    function _signedMarkValue1e8(int256 size1e8, uint256 price1e8) internal pure returns (int256 value1e8) {
        if (price1e8 == 0) revert PriceZero();

        uint256 absSize = _absInt256(size1e8);
        uint256 absValue = _mulChecked(absSize, price1e8) / PRICE_1E8;
        int256 absValueSigned = _toInt256(absValue);

        value1e8 = size1e8 >= 0 ? absValueSigned : -absValueSigned;
    }

    // -------- basic checked arithmetic --------

    function _absInt256(int256 x) internal pure returns (uint256) {
        if (x == type(int256).min) revert QuantityMinNotAllowed();
        return uint256(x >= 0 ? x : -x);
    }

    function _toInt256(uint256 x) internal pure returns (int256 y) {
        if (x > uint256(type(int256).max)) revert CastOverflow();
        y = int256(x);
    }

    function _sameSignNonZero(int256 a, int256 b) internal pure returns (bool) {
        return (a > 0 && b > 0) || (a < 0 && b < 0);
    }

    function _checkedAddInt256(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a + b;
        }
        if (b > 0 && r < a) revert SignedMathOverflow();
        if (b < 0 && r > a) revert SignedMathOverflow();
        if (r == type(int256).min) revert QuantityMinNotAllowed();
    }

    function _checkedSubInt256(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a - b;
        }
        if (b > 0 && r > a) revert SignedMathOverflow();
        if (b < 0 && r < a) revert SignedMathOverflow();
        if (r == type(int256).min) revert QuantityMinNotAllowed();
    }

    function _mulChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0 || b == 0) return 0;
        c = a * b;
        if (c / a != b) revert MathOverflow();
    }
}
