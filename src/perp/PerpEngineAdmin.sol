// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../oracle/IOracle.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";

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

    /// @notice Sets the emergency guardian.
    /// @dev Guardian is expected to be an operational actor, distinct from governance/timelock owner.
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
    /// @dev Guardian or owner may trigger emergency freeze.
    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
            emit GlobalPauseSet(true);
        }
    }

    /// @notice Clears legacy global pause.
    /// @dev Owner only.
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

    function setInsuranceFund(address insuranceFund_) external onlyOwner {
        if (insuranceFund_ == address(0)) revert ZeroAddress();
        address old = insuranceFund;
        insuranceFund = insuranceFund_;
        emit InsuranceFundSet(old, insuranceFund_);
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

    /// @notice Explicit fee recipient.
    /// @dev If unset, integration code may fallback to insuranceFund.
    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(old, feeRecipient_);
    }

    /// @notice Clear explicit fee recipient and fallback to insuranceFund if the integration uses it.
    function clearFeeRecipient() external onlyOwner {
        address old = feeRecipient;
        feeRecipient = address(0);
        emit FeeRecipientSet(old, address(0));
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