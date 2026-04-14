// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////
                        GOVERNANCE INTERFACES
//////////////////////////////////////////////////////////////*/

interface IRiskModuleGov {
    function setGuardian(address guardian_) external;
    function clearGuardian() external;

    function pause() external;
    function unpause() external;

    function pauseRiskChecks() external;
    function unpauseRiskChecks() external;

    function pauseCollateralValuation() external;
    function unpauseCollateralValuation() external;

    function pauseWithdrawPreviews() external;
    function unpauseWithdrawPreviews() external;

    function setEmergencyModes(
        bool riskChecksPaused_,
        bool collateralValuationPaused_,
        bool withdrawPreviewPaused_
    ) external;

    function clearEmergencyModes() external;

    function setMarginEngine(address _marginEngine) external;
    function setOracle(address _oracle) external;
    function setMaxOracleDelay(uint256 _maxOracleDelay) external;
    function setOracleDownMmMultiplier(uint256 _multiplierBps) external;
    function setRiskParams(address _baseToken, uint256 _baseMMPerContract, uint256 _imFactorBps) external;
    function setCollateralConfig(address token, uint64 weightBps, bool isEnabled) external;
    function syncCollateralTokensFromVault() external returns (uint256 added);
}

interface IMarginEngineGov {
    function setGuardian(address guardian_) external;
    function clearGuardian() external;

    function pause() external;
    function unpause() external;

    function pauseTrading() external;
    function unpauseTrading() external;

    function pauseLiquidation() external;
    function unpauseLiquidation() external;

    function pauseSettlement() external;
    function unpauseSettlement() external;

    function pauseCollateralOps() external;
    function unpauseCollateralOps() external;

    function setEmergencyModes(
        bool tradingPaused_,
        bool liquidationPaused_,
        bool settlementPaused_,
        bool collateralOpsPaused_
    ) external;

    function clearEmergencyModes() external;

    function setMatchingEngine(address matchingEngine_) external;
    function clearMatchingEngine() external;

    function setOracle(address oracle_) external;
    function setRiskModule(address riskModule_) external;
    function clearRiskModule() external;

    function setInsuranceFund(address insuranceFund_) external;
    function clearInsuranceFund() external;

    function setFeesManager(address feesManager_) external;
    function clearFeesManager() external;

    function setFeeRecipient(address feeRecipient_) external;
    function clearFeeRecipient() external;

    function setRiskParams(address baseToken_, uint256 baseMMPerContract_, uint256 imFactorBps_) external;
    function syncRiskParamsFromRiskModule() external;

    function setLiquidationParams(uint256 liquidationThresholdBps_, uint256 liquidationPenaltyBps_) external;
    function setLiquidationHardenParams(uint256 closeFactorBps_, uint256 minImprovementBps_) external;
    function setLiquidationPricingParams(uint256 liquidationPriceSpreadBps_, uint256 minLiqPriceBpsOfIntrinsic_)
        external;
    function setLiquidationOracleMaxDelay(uint32 delay_) external;
}

interface IOracleRouterGov {
    function setGuardian(address guardian_) external;
    function clearGuardian() external;

    function pause() external;
    function unpause() external;

    function pauseReads() external;
    function unpauseReads() external;

    function pauseConfig() external;
    function unpauseConfig() external;

    function setEmergencyModes(bool readPaused_, bool configPaused_) external;
    function clearEmergencyModes() external;

    function setFeed(
        address baseAsset,
        address quoteAsset,
        address primarySource,
        address secondarySource,
        uint32 maxDelay,
        uint16 maxDeviationBps,
        bool isActive
    ) external;

    function setFeedStatus(address baseAsset, address quoteAsset, bool isActive) external;
    function clearFeed(address baseAsset, address quoteAsset) external;
    function setMaxOracleDelay(uint32 _delay) external;
}

interface IFeesManagerGov {
    function setGuardian(address newGuardian) external;
    function clearGuardian() external;

    function pause() external;
    function unpause() external;

    function pauseConfig() external;
    function unpauseConfig() external;

    function pauseClaims() external;
    function unpauseClaims() external;

    function setEmergencyModes(bool configPaused_, bool claimsPaused_) external;
    function clearEmergencyModes() external;

    function setFeeBpsCap(uint16 newCap) external;
    function setDefaultFees(
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps
    ) external;
    function setMerkleRoot(bytes32 newRoot) external;
    function setMerkleRootWithEpoch(bytes32 newRoot, uint64 newEpoch) external;
    function setOverride(
        address trader,
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint64 expiry,
        bool enabled
    ) external;
    function disableOverride(address trader) external;
}

interface IOptionProductRegistryGov {
    struct UnderlyingConfig {
        address oracle;
        uint64 spotShockDownBps;
        uint64 spotShockUpBps;
        uint64 volShockDownBps;
        uint64 volShockUpBps;
        bool isEnabled;
    }

    function setSeriesCreator(address account, bool allowed) external;
    function setSettlementOperator(address account) external;
    function setUnderlyingConfig(address underlying, UnderlyingConfig calldata cfg) external;
    function setSettlementAssetAllowed(address asset, bool allowed) external;
    function setMinExpiryDelay(uint256 _minExpiryDelay) external;
    function setSettlementFinalityDelay(uint256 _delay) external;
    function setSeriesActive(uint256 optionId, bool isActive) external;
    function setSeriesMetadata(uint256 optionId, bytes32 metadata) external;
}

interface ICollateralVaultGov {
    function setMarginEngine(address _marginEngine) external;
    function setRiskModule(address _riskModule) external;
    function setCollateralToken(address token, bool isSupported, uint8 decimals, uint16 collateralFactorBps) external;
    function setTokenStrategy(address token, address adapter) external;
}

interface IInsuranceFundGov {
    function setGuardian(address newGuardian) external;
    function clearGuardian() external;

    function pause() external;
    function unpause() external;

    function pauseFunding() external;
    function unpauseFunding() external;

    function pauseWithdraws() external;
    function unpauseWithdraws() external;

    function pauseYieldOps() external;
    function unpauseYieldOps() external;

    function setEmergencyModes(bool fundingPaused_, bool withdrawPaused_, bool yieldOpsPaused_) external;
    function clearEmergencyModes() external;

    function setOperator(address operator, bool allowed) external;
    function setTokenAllowed(address token, bool allowed) external;
    function setBackstopCaller(address caller, bool allowed) external;
}

/*//////////////////////////////////////////////////////////////
                        PERP GOVERNANCE
//////////////////////////////////////////////////////////////*/

interface IPerpMarketRegistryGov {
    struct RiskConfig {
        uint32 initialMarginBps;
        uint32 maintenanceMarginBps;
        uint32 liquidationPenaltyBps;
        uint128 maxPositionSize1e8;
        uint128 maxOpenInterest1e8;
        bool reduceOnlyDuringCloseOnly;
    }

    struct FundingConfig {
        bool isEnabled;
        uint32 fundingInterval;
        uint32 maxFundingRateBps;
        uint32 maxSkewFundingBps;
        uint32 oracleClampBps;
    }

    function setGuardian(address guardian_) external;
    function clearGuardian() external;

    function pause() external;
    function unpause() external;

    function pauseCreation() external;
    function unpauseCreation() external;

    function pauseConfig() external;
    function unpauseConfig() external;

    function setEmergencyModes(bool creationPaused_, bool configPaused_) external;
    function clearEmergencyModes() external;

    function setMarketCreator(address account, bool allowed) external;
    function setSettlementAssetAllowed(address asset, bool allowed) external;
    function setMarketOracle(uint256 marketId, address oracle_) external;
    function setMarketStatus(uint256 marketId, bool isActive, bool isCloseOnly) external;
    function setRiskConfig(uint256 marketId, RiskConfig calldata cfg) external;
    function setFundingConfig(uint256 marketId, FundingConfig calldata cfg) external;
    function setMarketMetadata(uint256 marketId, bytes32 metadata) external;
}

interface IPerpEngineGov {
    function setGuardian(address guardian_) external;
    function clearGuardian() external;

    function pause() external;
    function unpause() external;

    function pauseTrading() external;
    function unpauseTrading() external;

    function pauseLiquidation() external;
    function unpauseLiquidation() external;

    function pauseFunding() external;
    function unpauseFunding() external;

    function pauseCollateralOps() external;
    function unpauseCollateralOps() external;

    function setEmergencyModes(
        bool tradingPaused_,
        bool liquidationPaused_,
        bool fundingPaused_,
        bool collateralOpsPaused_
    ) external;

    function clearEmergencyModes() external;

    function setMatchingEngine(address matchingEngine_) external;
    function setOracle(address oracle_) external;
    function setRiskModule(address riskModule_) external;

    function setCollateralSeizer(address collateralSeizer_) external;
    function clearCollateralSeizer() external;

    function setInsuranceFund(address insuranceFund_) external;
    function clearInsuranceFund() external;

    function setFeesManager(address feesManager_) external;
    function clearFeesManager() external;

    function setFeeRecipient(address feeRecipient_) external;
    function clearFeeRecipient() external;

    function setMarketRegistry(address registry_) external;
    function setCollateralVault(address vault_) external;

    function setLiquidationParams(
        uint256 liquidationCloseFactorBps_,
        uint256 liquidationPenaltyBps_,
        uint256 liquidationPriceSpreadBps_,
        uint256 minLiquidationImprovementBps_
    ) external;

    function setLiquidationCloseFactorBps(uint256 newCloseFactorBps) external;
    function setLiquidationPenaltyBps(uint256 newPenaltyBps) external;
    function setLiquidationPriceSpreadBps(uint256 newSpreadBps) external;
    function setMinLiquidationImprovementBps(uint256 newMinImprovementBps) external;

    function recordResidualBadDebt(address trader, uint256 amountBase) external;
    function reduceResidualBadDebt(address trader, uint256 amountBase) external returns (uint256 reducedBase);
    function clearResidualBadDebt(address trader) external returns (uint256 clearedBase);

    function repayResidualBadDebt(address payer, address trader, uint256 requestedAmountBase)
        external
        returns (
            uint256 requestedBaseValue,
            uint256 outstandingBaseValue,
            uint256 repaidBaseValue,
            uint256 remainingBaseValue
        );
}