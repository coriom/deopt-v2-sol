// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRiskModule} from "../risk/IRiskModule.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";

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

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();

        address oldOwner = owner;
        owner = address(0);

        emit OwnershipTransferred(oldOwner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the emergency guardian.
    /// @dev Guardian is expected to be an operational actor, distinct from governance / timelock owner.
    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        _setGuardian(guardian_);
    }

    /// @notice Clears the emergency guardian.
    function clearGuardian() external onlyOwner {
        _setGuardian(address(0));
    }

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
        if (!tradingPaused) {
            tradingPaused = true;
            emit TradingPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
        }
    }

    function unpauseTrading() external onlyOwner {
        if (tradingPaused) {
            tradingPaused = false;
            emit TradingPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
        }
    }

    /// @notice Emergency freeze of liquidation only.
    function pauseLiquidation() external onlyGuardianOrOwner {
        if (!liquidationPaused) {
            liquidationPaused = true;
            emit LiquidationPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
        }
    }

    function unpauseLiquidation() external onlyOwner {
        if (liquidationPaused) {
            liquidationPaused = false;
            emit LiquidationPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
        }
    }

    /// @notice Emergency freeze of settlement only.
    function pauseSettlement() external onlyGuardianOrOwner {
        if (!settlementPaused) {
            settlementPaused = true;
            emit SettlementPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
        }
    }

    function unpauseSettlement() external onlyOwner {
        if (settlementPaused) {
            settlementPaused = false;
            emit SettlementPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
        }
    }

    /// @notice Emergency freeze of collateral ops only.
    /// @dev Blocks deposit/withdraw wrappers but preserves the possibility of selectively keeping other protocol flows alive.
    function pauseCollateralOps() external onlyGuardianOrOwner {
        if (!collateralOpsPaused) {
            collateralOpsPaused = true;
            emit CollateralOpsPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
        }
    }

    function unpauseCollateralOps() external onlyOwner {
        if (collateralOpsPaused) {
            collateralOpsPaused = false;
            emit CollateralOpsPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, settlementPaused, collateralOpsPaused);
        }
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

    /// @notice Owner-only recovery helper to clear all granular flags in one tx.
    function clearEmergencyModes() external onlyOwner {
        _setEmergencyModes(false, false, false, false);
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    function setMatchingEngine(address matchingEngine_) external onlyOwner {
        if (matchingEngine_ == address(0)) revert ZeroAddress();
        matchingEngine = matchingEngine_;
        emit MatchingEngineSet(matchingEngine_);
    }

    function clearMatchingEngine() external onlyOwner {
        matchingEngine = address(0);
        emit MatchingEngineSet(address(0));
    }

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

    function clearRiskModule() external onlyOwner {
        _riskModule = IRiskModule(address(0));
        emit RiskModuleSet(address(0));
    }

    function setInsuranceFund(address insuranceFund_) external onlyOwner {
        if (insuranceFund_ == address(0)) revert ZeroAddress();
        address old = insuranceFund;
        insuranceFund = insuranceFund_;
        emit InsuranceFundSet(old, insuranceFund_);
    }

    function clearInsuranceFund() external onlyOwner {
        address old = insuranceFund;
        insuranceFund = address(0);
        emit InsuranceFundSet(old, address(0));
    }

    /// @notice Set hybrid fees manager.
    /// @dev FeesManager is read-only from MarginEngine perspective; fee transfers still happen via CollateralVault.
    function setFeesManager(address feesManager_) external onlyOwner {
        if (feesManager_ == address(0)) revert ZeroAddress();
        feesManager = IFeesManager(feesManager_);
        emit FeesManagerSet(feesManager_);
    }

    function clearFeesManager() external onlyOwner {
        feesManager = IFeesManager(address(0));
        emit FeesManagerSet(address(0));
    }

    /// @notice Explicit fee recipient.
    /// @dev If unset, integration code may fallback to insuranceFund.
    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(old, feeRecipient_);
    }

    /// @notice Clear explicit fee recipient and fallback to insuranceFund if integration uses it.
    function clearFeeRecipient() external onlyOwner {
        address old = feeRecipient;
        feeRecipient = address(0);
        emit FeeRecipientSet(old, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          RISK PARAMS CACHE
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure le cache risk params côté MarginEngine, en vérifiant qu'ils matchent RiskModule.
    /// @dev Source of truth = RiskModule.
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