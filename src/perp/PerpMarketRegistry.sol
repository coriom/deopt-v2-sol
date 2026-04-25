// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PerpMarketRegistry
/// @notice Central registry for DeOpt v2 perpetual markets.
/// @dev
///  Responsibilities:
///   - define perp markets (no expiry)
///   - store market risk / liquidation / funding / oracle configuration
///   - NOT handle positions, runtime funding accrual, or user margin
///
///  Conventions:
///   - prices in 1e8
///   - position sizing in size1e8 (1e8 = 1 underlying)
///   - position / OI caps expressed in 1e8 underlying units
///   - ratios suffixed `Bps` are in basis points
///
///  Architecture:
///   - PerpEngine reads this registry
///   - CollateralVault / OracleRouter / FeesManager stay shared
///   - oracle may be:
///       * address(0) => use PerpEngine global oracle
///       * non-zero   => per-market override
///
///  Emergency layer:
///   - guardian distinct from owner
///   - legacy global pause
///   - granular pauses:
///       * creationPaused => blocks market creation
///       * configPaused   => blocks admin/config updates
contract PerpMarketRegistry {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant PRICE_SCALE = 1e8;
    uint256 public constant BPS = 10_000;

    uint32 public constant MAX_FUNDING_INTERVAL = 7 days;
    uint32 public constant MAX_CLAMP_BPS = 5_000; // 50%
    uint32 public constant MAX_MARGIN_BPS = 100_000; // 1000% defensive upper bound
    uint32 public constant MIN_INITIAL_MARGIN_BPS = 1;
    uint32 public constant MIN_MAINTENANCE_MARGIN_BPS = 1;

    uint32 public constant MAX_LIQUIDATION_ORACLE_DELAY = 3600;
    uint32 public constant MIN_CLOSE_FACTOR_BPS = 1;
    uint32 public constant MAX_CLOSE_FACTOR_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct Market {
        address underlying;
        address settlementAsset;
        address oracle; // optional market-specific oracle override
        bytes32 symbol; // ex: "BTC-PERP"
        bool exists;
        bool isActive;
        bool isCloseOnly;
    }

    struct RiskConfig {
        uint32 initialMarginBps; // ex: 1000 = 10%
        uint32 maintenanceMarginBps; // ex: 500 = 5%
        uint32 liquidationPenaltyBps; // penalty target
        uint128 maxPositionSize1e8; // max abs size per account
        uint128 maxOpenInterest1e8; // cap total OI
        bool reduceOnlyDuringCloseOnly; // safety switch for engine
    }

    /// @notice Per-market liquidation policy.
    /// @dev
    ///  - closeFactorBps controls max clip size per liquidation
    ///  - priceSpreadBps applies adverse execution vs mark
    ///  - minImprovementBps avoids grief / decorative liquidations
    ///  - oracleMaxDelay is the local liquidation staleness guard
    struct LiquidationConfig {
        uint32 closeFactorBps;
        uint32 priceSpreadBps;
        uint32 minImprovementBps;
        uint32 oracleMaxDelay;
    }

    struct FundingConfig {
        bool isEnabled;
        uint32 fundingInterval; // seconds
        uint32 maxFundingRateBps; // abs cap per interval
        uint32 maxSkewFundingBps; // extra model cap for skew-based funding
        uint32 oracleClampBps; // clamp mark/index divergence
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error EmptySymbol();
    error MarketAlreadyExists();
    error UnknownMarket();
    error NotAuthorized();
    error GuardianNotAuthorized();

    error SettlementAssetNotAllowed();
    error InvalidMarketParams();

    error InvalidRiskConfig();
    error InvalidLiquidationConfig();
    error InvalidFundingConfig();

    error CreationPaused();
    error ConfigPausedError();
    error RegistryPaused();

    error OwnershipTransferNotInitiated();

    error IndexOutOfBounds();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event GuardianSet(address indexed oldGuardian, address indexed newGuardian);

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    event GlobalPauseSet(bool isPaused);
    event CreationPauseSet(bool isPaused);
    event ConfigPauseSet(bool isPaused);
    event EmergencyModeUpdated(bool creationPaused, bool configPaused);

    event MarketCreatorSet(address indexed account, bool isAllowed);
    event SettlementAssetConfigured(address indexed asset, bool isAllowed);

    event MarketCreated(
        uint256 indexed marketId,
        address indexed underlying,
        address indexed settlementAsset,
        address oracle,
        bytes32 symbol
    );

    event MarketStatusUpdated(uint256 indexed marketId, bool isActive, bool isCloseOnly);
    event MarketOracleSet(uint256 indexed marketId, address indexed oldOracle, address indexed newOracle);

    event RiskConfigSet(
        uint256 indexed marketId,
        uint32 initialMarginBps,
        uint32 maintenanceMarginBps,
        uint32 liquidationPenaltyBps,
        uint128 maxPositionSize1e8,
        uint128 maxOpenInterest1e8,
        bool reduceOnlyDuringCloseOnly
    );

    event LiquidationConfigSet(
        uint256 indexed marketId,
        uint32 closeFactorBps,
        uint32 priceSpreadBps,
        uint32 minImprovementBps,
        uint32 oracleMaxDelay
    );

    event FundingConfigSet(
        uint256 indexed marketId,
        bool isEnabled,
        uint32 fundingInterval,
        uint32 maxFundingRateBps,
        uint32 maxSkewFundingBps,
        uint32 oracleClampBps
    );

    event MarketMetadataSet(uint256 indexed marketId, bytes32 metadata);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => Market) private _markets;
    mapping(uint256 => RiskConfig) private _riskConfigs;
    mapping(uint256 => LiquidationConfig) private _liquidationConfigs;
    mapping(uint256 => FundingConfig) private _fundingConfigs;

    uint256[] private _allMarketIds;
    mapping(address => uint256[]) private _marketsByUnderlying;

    mapping(bytes32 => uint256) public marketIdByKey;
    mapping(uint256 => bytes32) public marketMetadata;

    address public owner;
    address public pendingOwner;
    address public guardian;

    bool public paused;
    bool public creationPaused;
    bool public configPaused;

    mapping(address => bool) public isMarketCreator;
    mapping(address => bool) public isSettlementAssetAllowed;

    uint256 public nextMarketId = 1;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && msg.sender != guardian) revert GuardianNotAuthorized();
        _;
    }

    modifier onlyMarketCreator() {
        if (!isMarketCreator[msg.sender]) revert NotAuthorized();
        _;
    }

    modifier whenCreationNotPaused() {
        if (_isCreationPaused()) revert CreationPaused();
        _;
    }

    modifier whenConfigNotPaused() {
        if (_isConfigPaused()) revert ConfigPausedError();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner) {
        if (_owner == address(0)) revert ZeroAddress();

        owner = _owner;
        isMarketCreator[_owner] = true;

        emit OwnershipTransferred(address(0), _owner);
        emit MarketCreatorSet(_owner, true);
        emit EmergencyModeUpdated(false, false);
    }

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
        }
    }

    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
            emit GlobalPauseSet(false);
        }
    }

    function pauseCreation() external onlyGuardianOrOwner {
        if (!creationPaused) {
            creationPaused = true;
            emit CreationPauseSet(true);
            emit EmergencyModeUpdated(creationPaused, configPaused);
        }
    }

    function unpauseCreation() external onlyOwner {
        if (creationPaused) {
            creationPaused = false;
            emit CreationPauseSet(false);
            emit EmergencyModeUpdated(creationPaused, configPaused);
        }
    }

    function pauseConfig() external onlyGuardianOrOwner {
        if (!configPaused) {
            configPaused = true;
            emit ConfigPauseSet(true);
            emit EmergencyModeUpdated(creationPaused, configPaused);
        }
    }

    function unpauseConfig() external onlyOwner {
        if (configPaused) {
            configPaused = false;
            emit ConfigPauseSet(false);
            emit EmergencyModeUpdated(creationPaused, configPaused);
        }
    }

    function setEmergencyModes(bool creationPaused_, bool configPaused_) external onlyGuardianOrOwner {
        _setEmergencyModes(creationPaused_, configPaused_);
    }

    function clearEmergencyModes() external onlyOwner {
        _setEmergencyModes(false, false);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    function setMarketCreator(address account, bool allowed) external onlyOwner whenConfigNotPaused {
        if (account == address(0)) revert ZeroAddress();
        isMarketCreator[account] = allowed;
        emit MarketCreatorSet(account, allowed);
    }

    function setSettlementAssetAllowed(address asset, bool allowed) external onlyOwner whenConfigNotPaused {
        if (asset == address(0)) revert ZeroAddress();
        isSettlementAssetAllowed[asset] = allowed;
        emit SettlementAssetConfigured(asset, allowed);
    }

    function setMarketOracle(uint256 marketId, address oracle_) external onlyOwner whenConfigNotPaused {
        Market storage m = _markets[marketId];
        if (!m.exists) revert UnknownMarket();

        address oldOracle = m.oracle;
        m.oracle = oracle_;

        emit MarketOracleSet(marketId, oldOracle, oracle_);
    }

    function setMarketStatus(uint256 marketId, bool isActive, bool isCloseOnly) external onlyOwner whenConfigNotPaused {
        Market storage m = _markets[marketId];
        if (!m.exists) revert UnknownMarket();

        m.isActive = isActive;
        m.isCloseOnly = isCloseOnly;

        emit MarketStatusUpdated(marketId, isActive, isCloseOnly);
    }

    function setRiskConfig(uint256 marketId, RiskConfig calldata cfg) external onlyOwner whenConfigNotPaused {
        if (!_markets[marketId].exists) revert UnknownMarket();
        _validateRiskConfig(cfg);

        _riskConfigs[marketId] = cfg;

        emit RiskConfigSet(
            marketId,
            cfg.initialMarginBps,
            cfg.maintenanceMarginBps,
            cfg.liquidationPenaltyBps,
            cfg.maxPositionSize1e8,
            cfg.maxOpenInterest1e8,
            cfg.reduceOnlyDuringCloseOnly
        );
    }

    function setLiquidationConfig(uint256 marketId, LiquidationConfig calldata cfg)
        external
        onlyOwner
        whenConfigNotPaused
    {
        if (!_markets[marketId].exists) revert UnknownMarket();
        _validateLiquidationConfig(cfg);

        _liquidationConfigs[marketId] = cfg;

        emit LiquidationConfigSet(
            marketId,
            cfg.closeFactorBps,
            cfg.priceSpreadBps,
            cfg.minImprovementBps,
            cfg.oracleMaxDelay
        );
    }

    function setFundingConfig(uint256 marketId, FundingConfig calldata cfg) external onlyOwner whenConfigNotPaused {
        if (!_markets[marketId].exists) revert UnknownMarket();
        _validateFundingConfig(cfg);

        _fundingConfigs[marketId] = cfg;

        emit FundingConfigSet(
            marketId,
            cfg.isEnabled,
            cfg.fundingInterval,
            cfg.maxFundingRateBps,
            cfg.maxSkewFundingBps,
            cfg.oracleClampBps
        );
    }

    function setMarketMetadata(uint256 marketId, bytes32 metadata) external onlyOwner whenConfigNotPaused {
        if (!_markets[marketId].exists) revert UnknownMarket();
        marketMetadata[marketId] = metadata;
        emit MarketMetadataSet(marketId, metadata);
    }

    /*//////////////////////////////////////////////////////////////
                            MARKET CREATION
    //////////////////////////////////////////////////////////////*/

    function createMarket(
        address underlying,
        address settlementAsset,
        address oracle_,
        bytes32 symbol,
        RiskConfig calldata riskCfg,
        LiquidationConfig calldata liquidationCfg,
        FundingConfig calldata fundingCfg
    ) external onlyMarketCreator whenCreationNotPaused returns (uint256 marketId) {
        _validateMarketParams(underlying, settlementAsset, symbol);
        if (!isSettlementAssetAllowed[settlementAsset]) revert SettlementAssetNotAllowed();

        _validateRiskConfig(riskCfg);
        _validateLiquidationConfig(liquidationCfg);
        _validateFundingConfig(fundingCfg);

        bytes32 key = _marketKey(underlying, settlementAsset, symbol);
        if (marketIdByKey[key] != 0) revert MarketAlreadyExists();

        marketId = nextMarketId;
        nextMarketId = marketId + 1;

        _markets[marketId] = Market({
            underlying: underlying,
            settlementAsset: settlementAsset,
            oracle: oracle_,
            symbol: symbol,
            exists: true,
            isActive: true,
            isCloseOnly: false
        });

        _riskConfigs[marketId] = riskCfg;
        _liquidationConfigs[marketId] = liquidationCfg;
        _fundingConfigs[marketId] = fundingCfg;

        marketIdByKey[key] = marketId;
        _allMarketIds.push(marketId);
        _marketsByUnderlying[underlying].push(marketId);

        emit MarketCreated(marketId, underlying, settlementAsset, oracle_, symbol);

        emit RiskConfigSet(
            marketId,
            riskCfg.initialMarginBps,
            riskCfg.maintenanceMarginBps,
            riskCfg.liquidationPenaltyBps,
            riskCfg.maxPositionSize1e8,
            riskCfg.maxOpenInterest1e8,
            riskCfg.reduceOnlyDuringCloseOnly
        );

        emit LiquidationConfigSet(
            marketId,
            liquidationCfg.closeFactorBps,
            liquidationCfg.priceSpreadBps,
            liquidationCfg.minImprovementBps,
            liquidationCfg.oracleMaxDelay
        );

        emit FundingConfigSet(
            marketId,
            fundingCfg.isEnabled,
            fundingCfg.fundingInterval,
            fundingCfg.maxFundingRateBps,
            fundingCfg.maxSkewFundingBps,
            fundingCfg.oracleClampBps
        );
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    function getMarket(uint256 marketId) external view returns (Market memory) {
        Market memory m = _markets[marketId];
        if (!m.exists) revert UnknownMarket();
        return m;
    }

    function getMarketIfExists(uint256 marketId) external view returns (Market memory market_, bool exists) {
        market_ = _markets[marketId];
        return (market_, market_.exists);
    }

    function marketExists(uint256 marketId) external view returns (bool) {
        return _markets[marketId].exists;
    }

    function isMarketActive(uint256 marketId) external view returns (bool) {
        Market memory m = _markets[marketId];
        if (!m.exists) revert UnknownMarket();
        return m.isActive;
    }

    function isMarketCloseOnly(uint256 marketId) external view returns (bool) {
        Market memory m = _markets[marketId];
        if (!m.exists) revert UnknownMarket();
        return m.isCloseOnly;
    }

    function getRiskConfig(uint256 marketId) external view returns (RiskConfig memory cfg) {
        if (!_markets[marketId].exists) revert UnknownMarket();
        return _riskConfigs[marketId];
    }

    function getLiquidationConfig(uint256 marketId) external view returns (LiquidationConfig memory cfg) {
        if (!_markets[marketId].exists) revert UnknownMarket();
        return _liquidationConfigs[marketId];
    }

    function getFundingConfig(uint256 marketId) external view returns (FundingConfig memory cfg) {
        if (!_markets[marketId].exists) revert UnknownMarket();
        return _fundingConfigs[marketId];
    }

    function getMarketConfigs(uint256 marketId)
        external
        view
        returns (
            Market memory market_,
            RiskConfig memory riskCfg,
            LiquidationConfig memory liquidationCfg,
            FundingConfig memory fundingCfg
        )
    {
        market_ = _markets[marketId];
        if (!market_.exists) revert UnknownMarket();
        riskCfg = _riskConfigs[marketId];
        liquidationCfg = _liquidationConfigs[marketId];
        fundingCfg = _fundingConfigs[marketId];
    }

    function totalMarkets() external view returns (uint256) {
        return _allMarketIds.length;
    }

    function marketAt(uint256 index) external view returns (uint256) {
        if (index >= _allMarketIds.length) revert IndexOutOfBounds();
        return _allMarketIds[index];
    }

    function getAllMarketIds() external view returns (uint256[] memory) {
        return _allMarketIds;
    }

    function getAllMarketIdsSlice(uint256 start, uint256 end) external view returns (uint256[] memory slice) {
        uint256 len = _allMarketIds.length;
        if (start > len) start = len;
        if (end > len) end = len;
        if (end < start) end = start;

        uint256 outLen = end - start;
        slice = new uint256[](outLen);

        for (uint256 i = 0; i < outLen; i++) {
            slice[i] = _allMarketIds[start + i];
        }
    }

    function getMarketsByUnderlying(address underlying) external view returns (uint256[] memory) {
        return _marketsByUnderlying[underlying];
    }

    function getMarketsByUnderlyingSlice(address underlying, uint256 start, uint256 end)
        external
        view
        returns (uint256[] memory slice)
    {
        uint256[] memory allIds = _marketsByUnderlying[underlying];
        uint256 len = allIds.length;

        if (start > len) start = len;
        if (end > len) end = len;
        if (end < start) end = start;

        uint256 outLen = end - start;
        slice = new uint256[](outLen);

        for (uint256 i = 0; i < outLen; i++) {
            slice[i] = allIds[start + i];
        }
    }

    function getActiveMarketsByUnderlying(address underlying) external view returns (uint256[] memory activeIds) {
        uint256[] memory allIds = _marketsByUnderlying[underlying];
        uint256 len = allIds.length;

        uint256 count;
        for (uint256 i = 0; i < len; i++) {
            Market memory m = _markets[allIds[i]];
            if (m.exists && m.isActive) count++;
        }

        activeIds = new uint256[](count);
        uint256 j;
        for (uint256 i = 0; i < len; i++) {
            Market memory m = _markets[allIds[i]];
            if (m.exists && m.isActive) {
                activeIds[j++] = allIds[i];
            }
        }
    }

    function computeMarketKey(address underlying, address settlementAsset, bytes32 symbol)
        external
        pure
        returns (bytes32)
    {
        return _marketKey(underlying, settlementAsset, symbol);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL VALIDATION / HELPERS
    //////////////////////////////////////////////////////////////*/

    function _marketKey(address underlying, address settlementAsset, bytes32 symbol) internal pure returns (bytes32) {
        return keccak256(abi.encode(underlying, settlementAsset, symbol));
    }

    function _validateMarketParams(address underlying, address settlementAsset, bytes32 symbol) internal pure {
        if (underlying == address(0) || settlementAsset == address(0)) revert ZeroAddress();
        if (symbol == bytes32(0)) revert EmptySymbol();
        if (underlying == settlementAsset) revert InvalidMarketParams();
    }

    function _validateRiskConfig(RiskConfig calldata cfg) internal pure {
        if (cfg.initialMarginBps < MIN_INITIAL_MARGIN_BPS) revert InvalidRiskConfig();
        if (cfg.maintenanceMarginBps < MIN_MAINTENANCE_MARGIN_BPS) revert InvalidRiskConfig();

        if (cfg.initialMarginBps > MAX_MARGIN_BPS) revert InvalidRiskConfig();
        if (cfg.maintenanceMarginBps > MAX_MARGIN_BPS) revert InvalidRiskConfig();

        if (cfg.maintenanceMarginBps >= cfg.initialMarginBps) revert InvalidRiskConfig();
        if (cfg.liquidationPenaltyBps > BPS) revert InvalidRiskConfig();

        if (cfg.maxPositionSize1e8 == 0) revert InvalidRiskConfig();
        if (cfg.maxOpenInterest1e8 == 0) revert InvalidRiskConfig();

        if (cfg.maxOpenInterest1e8 < cfg.maxPositionSize1e8) revert InvalidRiskConfig();
    }

    function _validateLiquidationConfig(LiquidationConfig calldata cfg) internal pure {
        if (cfg.closeFactorBps < MIN_CLOSE_FACTOR_BPS) revert InvalidLiquidationConfig();
        if (cfg.closeFactorBps > MAX_CLOSE_FACTOR_BPS) revert InvalidLiquidationConfig();
        if (cfg.priceSpreadBps > BPS) revert InvalidLiquidationConfig();
        if (cfg.minImprovementBps > BPS) revert InvalidLiquidationConfig();
        if (cfg.oracleMaxDelay > MAX_LIQUIDATION_ORACLE_DELAY) revert InvalidLiquidationConfig();
    }

    function _validateFundingConfig(FundingConfig calldata cfg) internal pure {
        if (!cfg.isEnabled) {
            if (cfg.fundingInterval != 0) revert InvalidFundingConfig();
            if (cfg.maxFundingRateBps != 0) revert InvalidFundingConfig();
            if (cfg.maxSkewFundingBps != 0) revert InvalidFundingConfig();
            if (cfg.oracleClampBps != 0) revert InvalidFundingConfig();
            return;
        }

        if (cfg.fundingInterval == 0 || cfg.fundingInterval > MAX_FUNDING_INTERVAL) {
            revert InvalidFundingConfig();
        }

        if (cfg.maxFundingRateBps > BPS) revert InvalidFundingConfig();
        if (cfg.maxSkewFundingBps > BPS) revert InvalidFundingConfig();
        if (cfg.oracleClampBps > MAX_CLAMP_BPS) revert InvalidFundingConfig();
    }

    function _isCreationPaused() internal view returns (bool) {
        return paused || creationPaused;
    }

    function _isConfigPaused() internal view returns (bool) {
        return paused || configPaused;
    }

    function _setGuardian(address guardian_) internal {
        address old = guardian;
        guardian = guardian_;
        emit GuardianSet(old, guardian_);
    }

    function _setEmergencyModes(bool creationPaused_, bool configPaused_) internal {
        if (creationPaused != creationPaused_) {
            creationPaused = creationPaused_;
            emit CreationPauseSet(creationPaused_);
        }

        if (configPaused != configPaused_) {
            configPaused = configPaused_;
            emit ConfigPauseSet(configPaused_);
        }

        emit EmergencyModeUpdated(creationPaused_, configPaused_);
    }
}
