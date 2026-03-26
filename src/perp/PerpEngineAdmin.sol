// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";
import {ICollateralSeizer} from "../liquidation/ICollateralSeizer.sol";

import "./PerpEngineStorage.sol";

/// @title PerpEngineAdmin
/// @notice Owner / guardian / config / emergency surface for the perpetual engine.
abstract contract PerpEngineAdmin is PerpEngineStorage {
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

        address old = owner;
        owner = po;
        pendingOwner = address(0);

        emit OwnershipTransferred(old, po);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();

        address old = owner;
        owner = address(0);

        emit OwnershipTransferred(old, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        _setGuardian(guardian_);
    }

    function clearGuardian() external onlyOwner {
        _setGuardian(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
            emit GlobalPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
            emit GlobalPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        GRANULAR EMERGENCY CONTROLS
    //////////////////////////////////////////////////////////////*/

    function pauseTrading() external onlyGuardianOrOwner {
        if (!tradingPaused) {
            tradingPaused = true;
            emit TradingPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function unpauseTrading() external onlyOwner {
        if (tradingPaused) {
            tradingPaused = false;
            emit TradingPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function pauseLiquidation() external onlyGuardianOrOwner {
        if (!liquidationPaused) {
            liquidationPaused = true;
            emit LiquidationPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function unpauseLiquidation() external onlyOwner {
        if (liquidationPaused) {
            liquidationPaused = false;
            emit LiquidationPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function pauseFunding() external onlyGuardianOrOwner {
        if (!fundingPaused) {
            fundingPaused = true;
            emit FundingPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function unpauseFunding() external onlyOwner {
        if (fundingPaused) {
            fundingPaused = false;
            emit FundingPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function pauseCollateralOps() external onlyGuardianOrOwner {
        if (!collateralOpsPaused) {
            collateralOpsPaused = true;
            emit CollateralOpsPauseSet(true);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function unpauseCollateralOps() external onlyOwner {
        if (collateralOpsPaused) {
            collateralOpsPaused = false;
            emit CollateralOpsPauseSet(false);
            emit EmergencyModeUpdated(tradingPaused, liquidationPaused, fundingPaused, collateralOpsPaused);
        }
    }

    function setEmergencyModes(
        bool tradingPaused_,
        bool liquidationPaused_,
        bool fundingPaused_,
        bool collateralOpsPaused_
    ) external onlyGuardianOrOwner {
        _setEmergencyModes(tradingPaused_, liquidationPaused_, fundingPaused_, collateralOpsPaused_);
    }

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

    function setOracle(address oracle_) external onlyOwner {
        if (oracle_ == address(0)) revert ZeroAddress();
        _oracle = IOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function setRiskModule(address riskModule_) external onlyOwner {
        if (riskModule_ == address(0)) revert ZeroAddress();
        _riskModule = IPerpRiskModule(riskModule_);
        emit RiskModuleSet(riskModule_);
    }

    function setCollateralSeizer(address collateralSeizer_) external onlyOwner {
        if (collateralSeizer_ == address(0)) revert ZeroAddress();
        address old = address(_collateralSeizer);
        _collateralSeizer = ICollateralSeizer(collateralSeizer_);
        emit CollateralSeizerSet(old, collateralSeizer_);
    }

    function clearCollateralSeizer() external onlyOwner {
        address old = address(_collateralSeizer);
        _collateralSeizer = ICollateralSeizer(address(0));
        emit CollateralSeizerSet(old, address(0));
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

    function setFeesManager(address feesManager_) external onlyOwner {
        if (feesManager_ == address(0)) revert ZeroAddress();
        feesManager = IFeesManager(feesManager_);
        emit FeesManagerSet(feesManager_);
    }

    function clearFeesManager() external onlyOwner {
        feesManager = IFeesManager(address(0));
        emit FeesManagerSet(address(0));
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(old, feeRecipient_);
    }

    function clearFeeRecipient() external onlyOwner {
        address old = feeRecipient;
        feeRecipient = address(0);
        emit FeeRecipientSet(old, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        LIQUIDATION CONFIG
    //////////////////////////////////////////////////////////////*/

    function setLiquidationParams(
        uint256 liquidationCloseFactorBps_,
        uint256 liquidationPenaltyBps_,
        uint256 liquidationPriceSpreadBps_,
        uint256 minLiquidationImprovementBps_
    ) external onlyOwner {
        _validateLiquidationParams(
            liquidationCloseFactorBps_,
            liquidationPenaltyBps_,
            liquidationPriceSpreadBps_,
            minLiquidationImprovementBps_
        );

        liquidationCloseFactorBps = liquidationCloseFactorBps_;
        liquidationPenaltyBps = liquidationPenaltyBps_;
        liquidationPriceSpreadBps = liquidationPriceSpreadBps_;
        minLiquidationImprovementBps = minLiquidationImprovementBps_;
    }

    function setLiquidationCloseFactorBps(uint256 newCloseFactorBps) external onlyOwner {
        _validateLiquidationParams(
            newCloseFactorBps,
            liquidationPenaltyBps,
            liquidationPriceSpreadBps,
            minLiquidationImprovementBps
        );
        liquidationCloseFactorBps = newCloseFactorBps;
    }

    function setLiquidationPenaltyBps(uint256 newPenaltyBps) external onlyOwner {
        _validateLiquidationParams(
            liquidationCloseFactorBps,
            newPenaltyBps,
            liquidationPriceSpreadBps,
            minLiquidationImprovementBps
        );
        liquidationPenaltyBps = newPenaltyBps;
    }

    function setLiquidationPriceSpreadBps(uint256 newSpreadBps) external onlyOwner {
        _validateLiquidationParams(
            liquidationCloseFactorBps,
            liquidationPenaltyBps,
            newSpreadBps,
            minLiquidationImprovementBps
        );
        liquidationPriceSpreadBps = newSpreadBps;
    }

    function setMinLiquidationImprovementBps(uint256 newMinImprovementBps) external onlyOwner {
        _validateLiquidationParams(
            liquidationCloseFactorBps,
            liquidationPenaltyBps,
            liquidationPriceSpreadBps,
            newMinImprovementBps
        );
        minLiquidationImprovementBps = newMinImprovementBps;
    }

    /*//////////////////////////////////////////////////////////////
                        BAD DEBT ADMIN SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Manually records additional residual bad debt on an account.
    /// @dev Emergency/governance tool. Prefer protocol-native liquidation path whenever possible.
    function recordResidualBadDebt(address trader, uint256 amountBase) external onlyOwner {
        if (trader == address(0)) revert ZeroAddress();
        if (amountBase == 0) revert AmountZero();

        _recordResidualBadDebt(trader, amountBase);
    }

    /// @notice Reduces residual bad debt on an account by up to `amountBase`.
    /// @dev Returns the actual amount reduced.
    function reduceResidualBadDebt(address trader, uint256 amountBase)
        external
        onlyOwner
        returns (uint256 reducedBase)
    {
        if (trader == address(0)) revert ZeroAddress();
        if (amountBase == 0) revert AmountZero();

        reducedBase = _reduceResidualBadDebt(trader, amountBase);
    }

    /// @notice Clears all recorded residual bad debt for an account.
    /// @dev Returns the amount cleared.
    function clearResidualBadDebt(address trader) external onlyOwner returns (uint256 clearedBase) {
        if (trader == address(0)) revert ZeroAddress();

        clearedBase = _clearResidualBadDebt(trader);
    }

    /*//////////////////////////////////////////////////////////////
                            REGISTRY / VAULT TARGETS
    //////////////////////////////////////////////////////////////*/

    function setMarketRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        _marketRegistry = PerpMarketRegistry(registry_);
    }

    function setCollateralVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        _collateralVault = CollateralVault(vault_);
    }
}