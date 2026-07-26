// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ISubaccountRegistry} from "../../../src/hybrid-v2/interfaces/ISubaccountRegistry.sol";
import {ICollateralVault} from "../../../src/hybrid-v2/interfaces/ICollateralVault.sol";
import {IOptionsPositionsLedger} from "../../../src/hybrid-v2/interfaces/IOptionsPositionsLedger.sol";
import {IPerpsPositionsLedger} from "../../../src/hybrid-v2/interfaces/IPerpsPositionsLedger.sol";
import {IRiskModule} from "../../../src/hybrid-v2/interfaces/IRiskModule.sol";
import {IReplayProtected} from "../../../src/hybrid-v2/interfaces/IReplayProtected.sol";
import {IEscapeController} from "../../../src/hybrid-v2/interfaces/IEscapeController.sol";
import {IRecoveryFinalizer} from "../../../src/hybrid-v2/interfaces/IRecoveryFinalizer.sol";
import {IFallbackOracle} from "../../../src/hybrid-v2/interfaces/IFallbackOracle.sol";
import {IRecoveryView} from "../../../src/hybrid-v2/interfaces/IRecoveryView.sol";

import {PositionTypes, LiquidationStatus} from "../../../src/hybrid-v2/libraries/PositionTypes.sol";
import {
    RecoveryState,
    RecoveryScope,
    FinalizationStatus,
    FallbackSource
} from "../../../src/hybrid-v2/libraries/RecoveryTypes.sol";

/// @title InterfacesCompileTest
/// @notice Verifies every WP-01 interface is importable + selector-addressable.
/// @dev No state, no economic behavior. Compile-time integration guard.
contract InterfacesCompileTest is Test {
    function test_allInterfaceSelectorsExposed() external pure {
        // If any of these references fails to resolve, the compiler rejects the
        // whole file. The test body itself only asserts the selectors are
        // non-zero (they are, by construction).
        assertNonZero(ISubaccountRegistry.registerNext.selector);
        assertNonZero(ISubaccountRegistry.subKeyOf.selector);
        assertNonZero(ISubaccountRegistry.registerLazyDefault.selector);

        assertNonZero(ICollateralVault.deposit.selector);
        assertNonZero(ICollateralVault.withdraw.selector);
        assertNonZero(ICollateralVault.internalTransfer.selector);
        assertNonZero(ICollateralVault.withdrawFor.selector);
        assertNonZero(ICollateralVault.applyLock.selector);
        assertNonZero(ICollateralVault.applyUnlock.selector);
        assertNonZero(ICollateralVault.applyFeeDebit.selector);
        assertNonZero(ICollateralVault.applyRebateCredit.selector);
        assertNonZero(ICollateralVault.applyLiquidationDebit.selector);
        assertNonZero(ICollateralVault.applySettlementCreditDebit.selector);
        assertNonZero(ICollateralVault.guardianRevokeEngine.selector);
        assertNonZero(ICollateralVault.governanceReleaseOrphanedLock.selector);

        assertNonZero(IOptionsPositionsLedger.applyFill.selector);
        assertNonZero(IOptionsPositionsLedger.applyExercise.selector);
        assertNonZero(IOptionsPositionsLedger.applySettlement.selector);
        assertNonZero(IOptionsPositionsLedger.applyLiquidation.selector);
        assertNonZero(IOptionsPositionsLedger.positionOf.selector);

        assertNonZero(IPerpsPositionsLedger.applyPerpFill.selector);
        assertNonZero(IPerpsPositionsLedger.applyFundingIndex.selector);
        assertNonZero(IPerpsPositionsLedger.applyPerpLiquidation.selector);
        assertNonZero(IPerpsPositionsLedger.positionOf.selector);

        assertNonZero(IRiskModule.marginRequirement.selector);
        assertNonZero(IRiskModule.availableMargin.selector);
        assertNonZero(IRiskModule.marginHealthy.selector);
        assertNonZero(IRiskModule.withdrawalAllowed.selector);
        assertNonZero(IRiskModule.transferAllowed.selector);
        assertNonZero(IRiskModule.liquidationStatus.selector);
        assertNonZero(IRiskModule.supportsCanonicalStorageVersion.selector);

        assertNonZero(IReplayProtected.nonces.selector);
        assertNonZero(IReplayProtected.cancelNextNonce.selector);
        assertNonZero(IReplayProtected.cancelNoncesUpTo.selector);
        assertNonZero(IReplayProtected.isIntentConsumed.selector);

        assertNonZero(IEscapeController.activateRecovery.selector);
        assertNonZero(IEscapeController.activateRecoveryAllSubaccounts.selector);
        assertNonZero(IEscapeController.cancelRecovery.selector);
        assertNonZero(IEscapeController.reserveRecoveryWithdrawal.selector);
        assertNonZero(IEscapeController.escapeWithdraw.selector);
        assertNonZero(IEscapeController.escapeWithdrawBatch.selector);
        assertNonZero(IEscapeController.invalidateIntents.selector);
        assertNonZero(IEscapeController.invalidateAllIntents.selector);
        assertNonZero(IEscapeController.pauseRecovery.selector);
        assertNonZero(IEscapeController.unpauseRecovery.selector);
        assertNonZero(IEscapeController.recoveryStateOf.selector);
        assertNonZero(IEscapeController.effectiveRecoveryEpoch.selector);

        assertNonZero(IRecoveryFinalizer.requestFallbackFinalization.selector);
        assertNonZero(IRecoveryFinalizer.disputeFallbackFinalization.selector);
        assertNonZero(IRecoveryFinalizer.finalizeFallbackSettlement.selector);
        assertNonZero(IRecoveryFinalizer.queueEmergencyPrice.selector);
        assertNonZero(IRecoveryFinalizer.cancelEmergencyPrice.selector);

        assertNonZero(IFallbackOracle.fallbackPrice.selector);
        assertNonZero(IFallbackOracle.twapPrice.selector);

        assertNonZero(IRecoveryView.recoveryWithdrawableOf.selector);
        assertNonZero(IRecoveryView.recoveryWithdrawableFallback.selector);
        assertNonZero(IRecoveryView.unresolvedObligationsOf.selector);
        assertNonZero(IRecoveryView.settlementReserveOf.selector);
        assertNonZero(IRecoveryView.liquidationReserveOf.selector);
        assertNonZero(IRecoveryView.supportedTokensOf.selector);
        assertNonZero(IRecoveryView.perpsRecoveryReserveOf.selector);
    }

    function test_sharedStructsInstantiable() external pure {
        PositionTypes.OptionPosition memory opt = PositionTypes.OptionPosition({
            longQuantity1e8: 100,
            shortQuantity1e8: 0,
            premiumBasis1e8: 42,
            shortPremiumRecv1e8: 0,
            lastFillBlock: 1,
            settlementState: 0,
            exerciseState: 0
        });
        assertEq(opt.longQuantity1e8, uint128(100));

        PositionTypes.PerpPosition memory perp = PositionTypes.PerpPosition({
            sizeSigned1e8: int128(500),
            costBasisSigned1e18: int128(0),
            fundingSnapshotSigned1e18: int128(0),
            realizedPnl1e18: int128(0),
            lastMutationBlock: 1,
            liquidationState: 0
        });
        assertEq(perp.sizeSigned1e8, int128(500));
    }

    function test_sharedEnumsInstantiable() external pure {
        LiquidationStatus liq = LiquidationStatus.HEALTHY;
        assertEq(uint256(liq), 0);

        RecoveryState rs = RecoveryState.NORMAL;
        assertEq(uint256(rs), 0);
        assertEq(uint256(RecoveryState.MIGRATED), 7);

        RecoveryScope rsc = RecoveryScope.OWNER;
        assertEq(uint256(rsc), 1);

        FinalizationStatus fs = FinalizationStatus.FINALIZED;
        assertEq(uint256(fs), 3);

        FallbackSource fbs = FallbackSource.GOVERNANCE_BOUNDED;
        assertEq(uint256(fbs), 3);
    }

    /* --------------------------- helpers --------------------------- */

    function assertNonZero(bytes4 selector) internal pure {
        assertTrue(selector != bytes4(0), "selector must not be zero");
    }
}
