// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {IFeesManager} from "../fees/IFeesManager.sol";
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

    function clearRiskModule() external onlyOwner {
        _riskModule = IPerpRiskModule(address(0));
        emit RiskModuleSet(address(0));
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

    function setFeesManager(address feesManager_) external onlyOwner {
        if (feesManager_ == address(0)) revert ZeroAddress();
        feesManager = IFeesManager(feesManager_);
        emit FeesManagerSet(feesManager_);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(old, feeRecipient_);
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

    /*//////////////////////////////////////////////////////////////
                        LEGACY COMPATIBILITY ALIASES
    //////////////////////////////////////////////////////////////*/

    /// @dev Backward-compatible alias. Semantically this now sets fallback defaults.
    function setLiquidationParams(
        uint256 liquidationCloseFactorBps_,
        uint256 liquidationPenaltyBps_,
        uint256 liquidationPriceSpreadBps_,
        uint256 minLiquidationImprovementBps_
    ) external onlyOwner {
        _setLiquidationFallbackParams(
            liquidationCloseFactorBps_,
            liquidationPenaltyBps_,
            liquidationPriceSpreadBps_,
            minLiquidationImprovementBps_,
            liquidationOracleMaxDelay
        );
    }

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

        liquidationCloseFactorBps = closeFactorBps;
        liquidationPenaltyBps = penaltyBps;
        liquidationPriceSpreadBps = priceSpreadBps;
        minLiquidationImprovementBps = minImprovementBps;
        liquidationOracleMaxDelay = oracleMaxDelay;
    }

    /*//////////////////////////////////////////////////////////////
                        BAD DEBT ADMIN SURFACE
    //////////////////////////////////////////////////////////////*/

    /// @notice Manually records additional residual bad debt on an account.
    /// @dev Emergency / governance tool. Prefer protocol-native liquidation path whenever possible.
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

    /// @notice Repays residual bad debt in base-token units by moving vault collateral from `payer` to protocol recipient.
    /// @dev
    ///  - repayment asset is strictly the protocol base collateral token
    ///  - recipient priority is defined in storage helper:
    ///      1. insuranceFund
    ///      2. feeRecipient
    ///  - effective repayment is bounded by:
    ///      * requestedAmountBase
    ///      * outstanding debt
    ///      * payer base-token vault balance
    function repayResidualBadDebt(address payer, address trader, uint256 requestedAmountBase)
        external
        onlyOwner
        returns (BadDebtRepayment memory repayment)
    {
        if (payer == address(0) || trader == address(0)) revert ZeroAddress();
        if (requestedAmountBase == 0) revert AmountZero();

        address recipient = _resolvedBadDebtRepaymentRecipient();
        if (recipient == address(0)) revert InsuranceFundNotSet();

        address baseToken = _baseCollateralToken();

        _syncVaultBestEffort(payer, baseToken);
        if (payer != recipient) {
            _syncVaultBestEffort(recipient, baseToken);
        }

        repayment.requestedBase = requestedAmountBase;
        repayment.outstandingBase = _residualBadDebtOf(trader);

        if (repayment.outstandingBase == 0) {
            emit ResidualBadDebtRepaid(payer, trader, recipient, requestedAmountBase, 0, 0);
            return repayment;
        }

        uint256 payerBal = _collateralVault.balances(payer, baseToken);

        uint256 cappedToDebt =
            requestedAmountBase < repayment.outstandingBase ? requestedAmountBase : repayment.outstandingBase;

        repayment.repaidBase = payerBal < cappedToDebt ? payerBal : cappedToDebt;

        if (repayment.repaidBase != 0) {
            _collateralVault.transferBetweenAccounts(baseToken, payer, recipient, repayment.repaidBase);
            _reduceResidualBadDebt(trader, repayment.repaidBase);
        }

        repayment.remainingBase = _residualBadDebtOf(trader);

        emit ResidualBadDebtRepaid(
            payer, trader, recipient, requestedAmountBase, repayment.repaidBase, repayment.remainingBase
        );
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
