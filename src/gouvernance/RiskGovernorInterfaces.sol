// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*//////////////////////////////////////////////////////////////
                        GOVERNANCE INTERFACES
//////////////////////////////////////////////////////////////*/

interface IRiskModuleGov {
    function setOracle(address _oracle) external;
    function setMarginEngine(address _marginEngine) external;
    function setMaxOracleDelay(uint256 _maxOracleDelay) external;
    function setOracleDownMmMultiplier(uint256 _multiplierBps) external;
    function setRiskParams(address _baseToken, uint256 _baseMMPerContract, uint256 _imFactorBps) external;
    function setCollateralConfig(address token, uint64 weightBps, bool isEnabled) external;
}

interface IMarginEngineGov {
    function setOracle(address oracle_) external;
    function setRiskModule(address riskModule_) external;
    function setInsuranceFund(address insuranceFund_) external;
    function setFeesManager(address feesManager_) external;
    function setFeeRecipient(address feeRecipient_) external;
    function clearFeeRecipient() external;
    function setRiskParams(address baseToken_, uint256 baseMMPerContract_, uint256 imFactorBps_) external;
    function setLiquidationParams(uint256 liquidationThresholdBps_, uint256 liquidationPenaltyBps_) external;
    function setLiquidationHardenParams(uint256 closeFactorBps_, uint256 minImprovementBps_) external;
    function setLiquidationPricingParams(uint256 liquidationPriceSpreadBps_, uint256 minLiqPriceBpsOfIntrinsic_) external;
    function setLiquidationOracleMaxDelay(uint32 delay_) external;
}

interface IOracleRouterGov {
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
    function setOperator(address operator, bool allowed) external;
    function setTokenAllowed(address token, bool allowed) external;
}
