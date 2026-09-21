// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {ICollateralSeizer} from "../liquidation/ICollateralSeizer.sol";
import {PerpEngineSeizureLib} from "./PerpEngineSeizureLib.sol";
import {PerpEngineTypes} from "./PerpEngineTypes.sol";

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
    // Errors (mirror engine selectors for stable observability)
    // ────────────────────────────────────────────────────────────
    error InsuranceFundNotSet();
    error InsuranceFundCoverageFailed();

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
}
