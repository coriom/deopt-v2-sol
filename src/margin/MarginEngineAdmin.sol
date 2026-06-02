// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IRiskModule} from "../risk/IRiskModule.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";
import {IFeesManagerV2} from "../fees/IFeesManagerV2.sol";

import {MarginEngineStorage} from "./MarginEngineStorage.sol";

/// @title MarginEngineAdmin
/// @notice Owner / guardian configuration & emergency surface for MarginEngine.
/// @dev
///  Responsibilities:
///   - 2-step ownership
///   - guardian management
///   - legacy + granular pause controls
///   - dependency wiring
///   - local cache of risk params expected to match RiskModule
///   - liquidation parameter configuration
///
///  Architectural note:
///   - this layer is admin/state-changing only
///   - read aggregation should live in MarginEngineViews
///
///  Canonical conventions:
///   - `baseMaintenanceMarginPerContract` is denominated in native units of `baseCollateralToken`
///   - `imFactorBps`, `liquidationThresholdBps`, `liquidationPenaltyBps`,
///     `liquidationCloseFactorBps`, `minLiquidationImprovementBps`,
///     `liquidationPriceSpreadBps`, `minLiquidationPriceBpsOfIntrinsic`
///     are expressed in basis points
abstract contract MarginEngineAdmin is MarginEngineStorage {
    /*//////////////////////////////////////////////////////////////
                            OWNERSHIP (2-step)
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotAuthorized();

        address oldOwner = owner;
        owner = po;
        pendingOwner = address(0);

        emit OwnershipTransferred(oldOwner, po);
    }

    // V2G-P size remediation: `cancelOwnershipTransfer` and `renounceOwnership`
    // removed — 0 callers in the codebase, and the V2G-Y ownership migration
    // plan uses only the two-step `transferOwnership` / `acceptOwnership` pair.
    // To abort a pending transfer call `transferOwnership(currentOwner)` (or
    // overwrite with a different new owner); to retire control entirely the
    // operator can transfer to a burn address that has no key holder.

    /*//////////////////////////////////////////////////////////////
                              GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the emergency guardian.
    /// @dev Guardian is expected to be an operational actor, distinct from governance / timelock owner.
    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        _setGuardian(guardian_);
    }

    // V2G-P size remediation: `clearGuardian` removed — never called in
    // production. The intended posture for "no guardian" is to either
    // never call `setGuardian` after deploy, or to rotate to a fresh
    // guardian via another `setGuardian(newAddr)` call. Saved bytecode
    // to keep MarginEngine under the EIP-170 24,576-byte limit.

    /*//////////////////////////////////////////////////////////////
                               PAUSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Legacy global pause.
    /// @dev Freezes all major protocol flows through the legacy flag.
    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
            emit GlobalPauseSet(true);
        }
    }

    /// @notice Clears legacy global pause.
    /// @dev Owner only, so guardian can escalate but not fully normalize alone.
    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
            emit GlobalPauseSet(false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        GRANULAR EMERGENCY CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency freeze of trading only.
    function pauseTrading() external onlyGuardianOrOwner {
        _setSinglePause(0, true);
    }

    function unpauseTrading() external onlyOwner {
        _setSinglePause(0, false);
    }

    /// @notice Emergency freeze of liquidation only.
    function pauseLiquidation() external onlyGuardianOrOwner {
        _setSinglePause(1, true);
    }

    function unpauseLiquidation() external onlyOwner {
        _setSinglePause(1, false);
    }

    /// @notice Emergency freeze of settlement only.
    function pauseSettlement() external onlyGuardianOrOwner {
        _setSinglePause(2, true);
    }

    function unpauseSettlement() external onlyOwner {
        _setSinglePause(2, false);
    }

    /// @notice Emergency freeze of collateral ops only.
    /// @dev Blocks deposit/withdraw wrappers but preserves the possibility of selectively keeping other protocol flows alive.
    function pauseCollateralOps() external onlyGuardianOrOwner {
        _setSinglePause(3, true);
    }

    function unpauseCollateralOps() external onlyOwner {
        _setSinglePause(3, false);
    }

    /// @notice Sets all granular emergency flags at once.
    /// @dev Useful for incident response playbooks.
    function setEmergencyModes(
        bool tradingPaused_,
        bool liquidationPaused_,
        bool settlementPaused_,
        bool collateralOpsPaused_
    ) external onlyGuardianOrOwner {
        _setEmergencyModes(tradingPaused_, liquidationPaused_, settlementPaused_, collateralOpsPaused_);
    }

    // V2G-P size remediation: `clearEmergencyModes` removed — 0 callers; the
    // operator can call `setEmergencyModes(false, false, false, false)` for the
    // same effect.

    function setSeriesEmergencyCloseOnly(uint256 optionId, bool closeOnly) external onlyGuardianOrOwner {
        _optionRegistry.getSeries(optionId);

        bool oldCloseOnly = seriesEmergencyCloseOnly[optionId];
        if (oldCloseOnly == closeOnly) return;

        seriesEmergencyCloseOnly[optionId] = closeOnly;
        emit SeriesEmergencyCloseOnlySet(optionId, oldCloseOnly, closeOnly);
        emit SeriesEmergencyCloseOnlyUpdated(msg.sender, optionId, oldCloseOnly, closeOnly);
    }

    function setSeriesActivationState(uint256 optionId, uint8 state) external onlyOwner {
        _optionRegistry.getSeries(optionId);
        if (state > SERIES_ACTIVATION_INACTIVE) revert InvalidActivationState();

        uint8 oldState = seriesActivationState[optionId];
        if (oldState == state) return;

        seriesActivationState[optionId] = state;
        emit SeriesActivationStateSet(optionId, oldState, state);
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    function setMatchingEngine(address matchingEngine_) external onlyOwner {
        if (matchingEngine_ == address(0)) revert ZeroAddress();
        matchingEngine = matchingEngine_;
        emit MatchingEngineSet(matchingEngine_);
    }

    // V2G-P size remediation: `clearMatchingEngine` removed (no callers).
    // The intended way to rotate the matching engine is `setMatchingEngine(newAddr)`.

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        _oracle = IOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function setRiskModule(address riskModule_) external onlyOwner {
        if (riskModule_ == address(0)) revert ZeroAddress();
        _riskModule = IRiskModule(riskModule_);
        emit RiskModuleSet(riskModule_);
    }

    // V2G-P size remediation: `clearRiskModule` removed (no callers).

    function setInsuranceFund(address insuranceFund_) external onlyOwner {
        if (insuranceFund_ == address(0)) revert ZeroAddress();
        address old = insuranceFund;
        insuranceFund = insuranceFund_;
        emit InsuranceFundSet(old, insuranceFund_);
    }

    // V2G-P size remediation: `clearInsuranceFund` removed (no callers).

    /// @notice Set hybrid fees manager.
    /// @dev FeesManager is read-only from MarginEngine perspective; fee transfers still happen via CollateralVault.
    function setFeesManager(address feesManager_) external onlyOwner {
        if (feesManager_ == address(0)) revert ZeroAddress();
        feesManager = IFeesManager(feesManager_);
        emit FeesManagerSet(feesManager_);
    }

    // V2G-P size remediation: `clearFeesManager` removed (no callers).

    /// @notice Set optional signed-ppm options fee manager.
    /// @dev V1 remains active until `setUseFeesManagerV2(true)` is called.
    function setFeesManagerV2(address feesManagerV2_) external onlyOwner {
        if (feesManagerV2_ == address(0)) revert ZeroAddress();
        feesManagerV2 = IFeesManagerV2(feesManagerV2_);
        emit FeesManagerV2Set(feesManagerV2_);
    }

    /// @notice Selects whether option execution uses V1 or V2 fees.
    /// @dev Enabling V2 with no configured V2 manager is forbidden.
    function setUseFeesManagerV2(bool enabled) external onlyOwner {
        if (enabled && address(feesManagerV2) == address(0)) revert ZeroAddress();
        useFeesManagerV2 = enabled;
        emit FeesManagerV2EnabledSet(enabled);
    }

    /// @notice Explicit fee recipient.
    /// @dev If unset, integration code may fallback to insuranceFund.
    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(old, feeRecipient_);
    }

    /// @notice Sets an optional launch-safety cap for aggregate short contracts on one option series.
    /// @dev `cap == 0` disables the cap. Existing over-cap exposure may only be reduced by trade.
    function setSeriesShortOpenInterestCap(uint256 optionId, uint256 cap) external onlyOwner {
        _optionRegistry.getSeries(optionId);

        uint256 oldCap = seriesShortOpenInterestCap[optionId];
        seriesShortOpenInterestCap[optionId] = cap;

        emit SeriesShortOpenInterestCapSet(optionId, oldCap, cap);
    }

    // V2G-P size remediation: `clearFeeRecipient` removed (no callers).

    /*//////////////////////////////////////////////////////////////
                          RISK PARAMS CACHE
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure the local options-side risk cache, while enforcing consistency with RiskModule.
    /// @dev
    ///  Source of truth = RiskModule.
    ///
    ///  Canonical conventions:
    ///   - `baseToken_` = unified protocol risk numeraire
    ///   - `baseMMPerContract_` = native units of `baseToken_`
    ///   - `imFactorBps_` = basis points
    function setRiskParams(address baseToken_, uint256 baseMMPerContract_, uint256 imFactorBps_) external onlyOwner {
        if (baseToken_ == address(0)) revert ZeroAddress();
        if (baseMMPerContract_ == 0) revert InvalidLiquidationParams();
        if (imFactorBps_ < BPS) revert InvalidLiquidationParams();
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();

        if (_riskModule.baseCollateralToken() != baseToken_) revert RiskParamsMismatch();
        if (_riskModule.baseMaintenanceMarginPerContract() != baseMMPerContract_) revert RiskParamsMismatch();
        if (_riskModule.imFactorBps() != imFactorBps_) revert RiskParamsMismatch();

        _requireSettlementAssetConfigured(baseToken_);

        baseCollateralToken = baseToken_;
        baseMaintenanceMarginPerContract = baseMMPerContract_;
        imFactorBps = imFactorBps_;

        emit RiskParamsSet(baseToken_, baseMMPerContract_, imFactorBps_);
    }

    /// @notice Re-check the locally cached risk params against the current RiskModule.
    function syncRiskParamsFromRiskModule() external onlyOwner {
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();

        address baseToken_ = _riskModule.baseCollateralToken();
        uint256 baseMMPerContract_ = _riskModule.baseMaintenanceMarginPerContract();
        uint256 imFactorBps_ = _riskModule.imFactorBps();

        if (baseToken_ == address(0)) revert ZeroAddress();
        if (baseMMPerContract_ == 0) revert RiskParamsMismatch();
        if (imFactorBps_ < BPS) revert RiskParamsMismatch();

        _requireSettlementAssetConfigured(baseToken_);

        baseCollateralToken = baseToken_;
        baseMaintenanceMarginPerContract = baseMMPerContract_;
        imFactorBps = imFactorBps_;

        emit RiskParamsSet(baseToken_, baseMMPerContract_, imFactorBps_);
    }

    /*//////////////////////////////////////////////////////////////
                         LIQUIDATION PARAMS
    //////////////////////////////////////////////////////////////*/

    function setLiquidationParams(uint256 liquidationThresholdBps_, uint256 liquidationPenaltyBps_) external onlyOwner {
        if (liquidationThresholdBps_ < BPS) revert InvalidLiquidationParams();
        if (liquidationPenaltyBps_ > BPS) revert InvalidLiquidationParams();

        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationPenaltyBps = liquidationPenaltyBps_;

        emit LiquidationParamsSet(liquidationThresholdBps_, liquidationPenaltyBps_);
    }

    function setLiquidationHardenParams(uint256 closeFactorBps_, uint256 minImprovementBps_) external onlyOwner {
        if (closeFactorBps_ == 0) revert LiquidationCloseFactorZero();
        if (closeFactorBps_ > BPS) revert InvalidLiquidationParams();

        liquidationCloseFactorBps = closeFactorBps_;
        minLiquidationImprovementBps = minImprovementBps_;

        emit LiquidationHardenParamsSet(closeFactorBps_, minImprovementBps_);
    }

    function setLiquidationPricingParams(uint256 liquidationPriceSpreadBps_, uint256 minLiqPriceBpsOfIntrinsic_)
        external
        onlyOwner
    {
        if (liquidationPriceSpreadBps_ > BPS) revert LiquidationPricingParamsInvalid();
        if (minLiqPriceBpsOfIntrinsic_ > BPS) revert LiquidationPricingParamsInvalid();

        liquidationPriceSpreadBps = liquidationPriceSpreadBps_;
        minLiquidationPriceBpsOfIntrinsic = minLiqPriceBpsOfIntrinsic_;

        emit LiquidationPricingParamsSet(liquidationPriceSpreadBps_, minLiqPriceBpsOfIntrinsic_);
    }

    /// @notice Set max oracle staleness allowed in liquidation paths. 0 disables staleness enforcement.
    function setLiquidationOracleMaxDelay(uint32 delay_) external onlyOwner {
        if (delay_ > 3600) revert LiquidationPricingParamsInvalid();
        uint32 old = liquidationOracleMaxDelay;
        liquidationOracleMaxDelay = delay_;
        emit LiquidationOracleMaxDelaySet(old, delay_);
    }
}
