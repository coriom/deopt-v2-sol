// contracts/margin/MarginEngineAdmin.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRiskModule} from "../risk/IRiskModule.sol";
import {IOracle} from "../oracle/IOracle.sol";

import {MarginEngineStorage} from "./MarginEngineStorage.sol";

/// @notice Owner-only configuration & admin surface
/// @dev Assumes constants/errors/events are declared in MarginEngineTypes (via MarginEngineStorage).
abstract contract MarginEngineAdmin is MarginEngineStorage {
    /*//////////////////////////////////////////////////////////////
                              OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                               PAUSE
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
        }
    }

    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
        }
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
        _riskModule = IRiskModule(riskModule_);
        emit RiskModuleSet(riskModule_);
    }

    function setInsuranceFund(address insuranceFund_) external onlyOwner {
        if (insuranceFund_ == address(0)) revert ZeroAddress();
        address old = insuranceFund;
        insuranceFund = insuranceFund_;
        emit InsuranceFundSet(old, insuranceFund_);
    }

    /*//////////////////////////////////////////////////////////////
                          RISK PARAMS CACHE
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure le cache risk params côté MarginEngine, en vérifiant qu'ils MATCHENT RiskModule.
    /// @dev Source of truth = RiskModule.
    function setRiskParams(address baseToken_, uint256 baseMMPerContract_, uint256 imFactorBps_) external onlyOwner {
        if (baseToken_ == address(0)) revert ZeroAddress();
        if (imFactorBps_ < BPS) revert InvalidLiquidationParams(); // IM factor must be >= 100%
        if (address(_riskModule) == address(0)) revert RiskModuleNotSet();

        _IRiskModuleParams rp = _IRiskModuleParams(address(_riskModule));

        if (rp.baseCollateralToken() != baseToken_) revert RiskParamsMismatch();
        if (rp.baseMaintenanceMarginPerContract() != baseMMPerContract_) revert RiskParamsMismatch();
        if (rp.imFactorBps() != imFactorBps_) revert RiskParamsMismatch();

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
