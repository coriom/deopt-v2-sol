// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";
import {IFeesManagerV2} from "../fees/IFeesManagerV2.sol";
import {ICollateralSeizer} from "../liquidation/ICollateralSeizer.sol";

import "./PerpEngineStorage.sol";

/// @title PerpEngineAdmin
/// @notice Owner / guardian / config / emergency surface for the perpetual engine.
/// @dev
///  Responsibilities:
///   - 2-step ownership
///   - guardian management
///   - legacy + granular pause controls
///   - dependency wiring
///   - fallback liquidation defaults
///   - bad debt admin surface
///
///  Canonical architecture:
///   - per-market liquidation policy lives in PerpMarketRegistry
///   - engine-level liquidation params are only legacy fallback defaults
///   - runtime execution should read effective params through storage helpers
///     that resolve market config first, then fallback globals
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

    /*//////////////////////////////////////////////////////////////
                                GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        _setGuardian(guardian_);
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

    function setMarketActivationState(uint256 marketId, uint8 state) external onlyOwner {
        _requireMarketExists(marketId);
        if (state > MARKET_ACTIVATION_INACTIVE) revert InvalidActivationState();

        uint8 oldState = marketActivationState[marketId];
        if (oldState == state) return;

        marketActivationState[marketId] = state;
        emit MarketActivationStateSet(marketId, oldState, state);
    }

    function setMarketEmergencyCloseOnly(uint256 marketId, bool closeOnly) external onlyGuardianOrOwner {
        _requireMarketExists(marketId);

        bool oldCloseOnly = marketEmergencyCloseOnly[marketId];
        if (oldCloseOnly == closeOnly) return;

        marketEmergencyCloseOnly[marketId] = closeOnly;
        emit MarketEmergencyCloseOnlySet(marketId, oldCloseOnly, closeOnly);
        emit MarketEmergencyCloseOnlyUpdated(msg.sender, marketId, oldCloseOnly, closeOnly);
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    function setMatchingEngine(address matchingEngine_) external onlyOwner {
        if (matchingEngine_ == address(0)) revert ZeroAddress();
        matchingEngine = matchingEngine_;
        emit MatchingEngineSet(matchingEngine_);
    }

    /// @notice Governance setter for the trusted impact-mid keeper address.
    /// @dev
    ///  PERPS-FUNDING-V2: only `impactMidSource` may call
    ///  `PerpEngineTrading.updateImpactMid`. The keeper publishes the off-chain
    ///  orderbook TWAP mid used by the funding premium computation. Zero-address
    ///  is rejected — to disable the keeper channel governance MUST rotate to a
    ///  no-op EOA (or leave `FundingConfig.isEnabled=false`, which short-circuits
    ///  before any keeper read).
    function setImpactMidSource(address source) external onlyOwner {
        if (source == address(0)) revert InvalidImpactMidSource();
        address old = impactMidSource;
        impactMidSource = source;
        emit ImpactMidSourceSet(old, source);
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

    /// @notice Set optional signed-ppm perp fee manager.
    /// @dev V1 remains active until `setUseFeesManagerV2(true)` is called.
    function setFeesManagerV2(address feesManagerV2_) external onlyOwner {
        if (feesManagerV2_ == address(0)) revert ZeroAddress();
        feesManagerV2 = IFeesManagerV2(feesManagerV2_);
        emit FeesManagerV2Set(feesManagerV2_);
    }

    /// @notice Selects whether perp execution uses V1 or V2 fees.
    /// @dev Enabling V2 with no configured V2 manager is forbidden.
    function setUseFeesManagerV2(bool enabled) external onlyOwner {
        if (enabled && address(feesManagerV2) == address(0)) revert ZeroAddress();
        useFeesManagerV2 = enabled;
        emit FeesManagerV2EnabledSet(enabled);
    }

    /// @notice Sets an optional engine-level launch cap for effective market open interest.
    /// @dev `cap1e8 == 0` disables the cap. Lowering below current OI only blocks further OI increases.
    function setLaunchOpenInterestCap(uint256 marketId, uint256 cap1e8) external onlyOwner {
        _requireMarketExists(marketId);

        uint256 oldCap = launchOpenInterestCap1e8[marketId];
        launchOpenInterestCap1e8[marketId] = cap1e8;

        emit LaunchOpenInterestCapSet(marketId, oldCap, cap1e8);
    }

    /*//////////////////////////////////////////////////////////////
                    LIQUIDATION FALLBACK DEFAULTS
    //////////////////////////////////////////////////////////////*/

    function _setLiquidationFallbackParams(
        uint256 closeFactorBps,
        uint256 penaltyBps,
        uint256 priceSpreadBps,
        uint256 minImprovementBps,
        uint32 oracleMaxDelay
    ) internal {
        _validateLiquidationParams(
            closeFactorBps, penaltyBps, priceSpreadBps, minImprovementBps, uint256(oracleMaxDelay)
        );

        _liquidationCloseFactorBps = closeFactorBps;
        _liquidationPenaltyBps = penaltyBps;
        _liquidationPriceSpreadBps = priceSpreadBps;
        _minLiquidationImprovementBps = minImprovementBps;
        _liquidationOracleMaxDelay = oracleMaxDelay;
    }

    /*//////////////////////////////////////////////////////////////
                            REGISTRY / VAULT TARGETS
    //////////////////////////////////////////////////////////////*/

    function setCollateralVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        _collateralVault = CollateralVault(vault_);
    }
}
