// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";
import {PerpEngine} from "../src/perp/PerpEngine.sol";
import {PerpMarketRegistry} from "../src/perp/PerpMarketRegistry.sol";
import {IPriceSource} from "../src/oracle/IPriceSource.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";

/// @notice Fourth-pass market, underlying, and oracle configuration script.
/// @dev Configures ETH/BTC oracle feeds, options underlyings/series, and perp markets only.
contract ConfigureMarkets is Script {
    uint256 internal constant BPS = 10_000;
    uint128 internal constant OPTION_CONTRACT_SIZE_1E8 = 1e8;
    string internal constant DELIM = ",";

    struct CoreAddresses {
        address oracleRouter;
        address optionProductRegistry;
        address marginEngine;
        address perpMarketRegistry;
        address perpEngine;
        address baseCollateralToken;
        address ethUnderlying;
        address btcUnderlying;
    }

    struct FeedParams {
        address primarySource;
        address secondarySource;
        uint32 maxDelay;
        uint16 maxDeviationBps;
        bool isActive;
    }

    struct OptionUnderlyingParams {
        address oracle;
        uint64 spotShockDownBps;
        uint64 spotShockUpBps;
        uint64 volShockDownBps;
        uint64 volShockUpBps;
        bool isEnabled;
        uint128 baseMaintenanceMarginPerContractBase;
        uint32 imFactorBps;
        uint32 oracleDownMmMultiplierBps;
    }

    struct OptionSeriesParams {
        uint256[] expiries;
        uint256[] strikes1e8;
        bool[] isCalls;
        bool[] isEuropean;
        bool[] registryActive;
        uint256[] activationStates;
        uint256[] shortOpenInterestCaps;
    }

    struct PerpParams {
        string symbol;
        address oracle;
        bool registryActive;
        bool closeOnly;
        uint256 engineActivationState;
        uint256 launchOpenInterestCap1e8;
        uint32 initialMarginBps;
        uint32 maintenanceMarginBps;
        uint32 liquidationPenaltyBps;
        uint128 maxPositionSize1e8;
        uint128 maxOpenInterest1e8;
        bool reduceOnlyDuringCloseOnly;
        uint32 liquidationCloseFactorBps;
        uint32 liquidationPriceSpreadBps;
        uint32 minLiquidationImprovementBps;
        uint32 liquidationOracleMaxDelay;
        bool fundingEnabled;
        uint32 fundingInterval;
        uint32 maxFundingRateBps;
        uint32 maxSkewFundingBps;
        uint32 oracleClampBps;
    }

    function run() external {
        uint256 deployerPrivateKey = _envUint("DEPLOYER_PRIVATE_KEY");
        address caller = vm.addr(deployerPrivateKey);

        CoreAddresses memory addrs = _readCoreAddresses();
        _requireDeployed(addrs);

        FeedParams memory ethFeed = _readFeedParams("ETH_USDC");
        FeedParams memory btcFeed = _readFeedParams("BTC_USDC");

        OptionUnderlyingParams memory ethOption = _readOptionUnderlyingParams("ETH_OPTION");
        OptionUnderlyingParams memory btcOption = _readOptionUnderlyingParams("BTC_OPTION");
        OptionSeriesParams memory ethSeries = _readOptionSeriesParams("ETH_OPTION_SERIES");
        OptionSeriesParams memory btcSeries = _readOptionSeriesParams("BTC_OPTION_SERIES");

        PerpParams memory ethPerp = _readPerpParams("ETH_PERP");
        PerpParams memory btcPerp = _readPerpParams("BTC_PERP");

        uint32 routerMaxDelay = _toUint32(_envUint("ORACLE_ROUTER_MAX_DELAY"), "ORACLE_ROUTER_MAX_DELAY");

        vm.startBroadcast(deployerPrivateKey);

        OracleRouter router = OracleRouter(addrs.oracleRouter);
        router.setMaxOracleDelay(routerMaxDelay);
        _configureFeed(router, addrs.ethUnderlying, addrs.baseCollateralToken, ethFeed);
        _configureFeed(router, addrs.btcUnderlying, addrs.baseCollateralToken, btcFeed);

        OptionProductRegistry optionRegistry = OptionProductRegistry(addrs.optionProductRegistry);
        optionRegistry.setSettlementAssetAllowed(addrs.baseCollateralToken, true);
        _configureOptionUnderlying(optionRegistry, addrs.ethUnderlying, ethOption);
        _configureOptionUnderlying(optionRegistry, addrs.btcUnderlying, btcOption);
        _configureOptionSeries(
            optionRegistry, MarginEngine(addrs.marginEngine), addrs.ethUnderlying, addrs.baseCollateralToken, ethSeries
        );
        _configureOptionSeries(
            optionRegistry, MarginEngine(addrs.marginEngine), addrs.btcUnderlying, addrs.baseCollateralToken, btcSeries
        );

        PerpMarketRegistry perpRegistry = PerpMarketRegistry(addrs.perpMarketRegistry);
        perpRegistry.setSettlementAssetAllowed(addrs.baseCollateralToken, true);
        uint256 ethMarketId = _configurePerpMarket(
            perpRegistry, PerpEngine(addrs.perpEngine), addrs.ethUnderlying, addrs.baseCollateralToken, ethPerp
        );
        uint256 btcMarketId = _configurePerpMarket(
            perpRegistry, PerpEngine(addrs.perpEngine), addrs.btcUnderlying, addrs.baseCollateralToken, btcPerp
        );

        vm.stopBroadcast();

        _logConfiguration(caller, addrs, ethSeries.expiries.length, btcSeries.expiries.length, ethMarketId, btcMarketId);
    }

    function _readCoreAddresses() internal view returns (CoreAddresses memory addrs) {
        addrs.oracleRouter = _envAddress("ORACLE_ROUTER");
        addrs.optionProductRegistry = _envAddress("OPTION_PRODUCT_REGISTRY");
        addrs.marginEngine = _envAddress("MARGIN_ENGINE");
        addrs.perpMarketRegistry = _envAddress("PERP_MARKET_REGISTRY");
        addrs.perpEngine = _envAddress("PERP_ENGINE");
        addrs.baseCollateralToken = _envAddress("BASE_COLLATERAL_TOKEN");
        addrs.ethUnderlying = _envAddress("ETH_UNDERLYING");
        addrs.btcUnderlying = _envAddress("BTC_UNDERLYING");
    }

    function _readFeedParams(string memory prefix) internal view returns (FeedParams memory params) {
        params.primarySource = _envAddress(string.concat(prefix, "_PRIMARY_SOURCE"));
        params.secondarySource = _envAddress(string.concat(prefix, "_SECONDARY_SOURCE"));
        params.maxDelay = _toUint32(_envUint(string.concat(prefix, "_MAX_DELAY")), string.concat(prefix, "_MAX_DELAY"));
        params.maxDeviationBps = _toUint16(
            _envUint(string.concat(prefix, "_MAX_DEVIATION_BPS")), string.concat(prefix, "_MAX_DEVIATION_BPS")
        );
        params.isActive = _envBool(string.concat(prefix, "_FEED_ACTIVE"));

        _requireContract(string.concat(prefix, "_PRIMARY_SOURCE"), params.primarySource);
        if (params.secondarySource != address(0)) {
            _requireContract(string.concat(prefix, "_SECONDARY_SOURCE"), params.secondarySource);
        }
        if (params.maxDeviationBps > BPS) revert(string.concat(prefix, " deviation > bps"));
    }

    function _readOptionUnderlyingParams(string memory prefix)
        internal
        view
        returns (OptionUnderlyingParams memory params)
    {
        params.oracle = _envAddress(string.concat(prefix, "_ORACLE"));
        params.spotShockDownBps = _toUint64(
            _envUint(string.concat(prefix, "_SPOT_SHOCK_DOWN_BPS")), string.concat(prefix, "_SPOT_SHOCK_DOWN_BPS")
        );
        params.spotShockUpBps = _toUint64(
            _envUint(string.concat(prefix, "_SPOT_SHOCK_UP_BPS")), string.concat(prefix, "_SPOT_SHOCK_UP_BPS")
        );
        params.volShockDownBps = _toUint64(
            _envUint(string.concat(prefix, "_VOL_SHOCK_DOWN_BPS")), string.concat(prefix, "_VOL_SHOCK_DOWN_BPS")
        );
        params.volShockUpBps =
            _toUint64(_envUint(string.concat(prefix, "_VOL_SHOCK_UP_BPS")), string.concat(prefix, "_VOL_SHOCK_UP_BPS"));
        params.isEnabled = _envBool(string.concat(prefix, "_UNDERLYING_ENABLED"));
        params.baseMaintenanceMarginPerContractBase = _toUint128(
            _envUint(string.concat(prefix, "_BASE_MM_PER_CONTRACT_BASE")),
            string.concat(prefix, "_BASE_MM_PER_CONTRACT_BASE")
        );
        params.imFactorBps =
            _toUint32(_envUint(string.concat(prefix, "_IM_FACTOR_BPS")), string.concat(prefix, "_IM_FACTOR_BPS"));
        params.oracleDownMmMultiplierBps = _toUint32(
            _envUint(string.concat(prefix, "_ORACLE_DOWN_MM_MULTIPLIER_BPS")),
            string.concat(prefix, "_ORACLE_DOWN_MM_MULTIPLIER_BPS")
        );

        if (params.oracle != address(0)) _requireContract(string.concat(prefix, "_ORACLE"), params.oracle);
        if (params.baseMaintenanceMarginPerContractBase == 0) revert(string.concat(prefix, " base MM zero"));
        if (params.imFactorBps < BPS) revert(string.concat(prefix, " IM < bps"));
        if (params.oracleDownMmMultiplierBps < BPS) revert(string.concat(prefix, " oracle-down MM < bps"));
    }

    function _readOptionSeriesParams(string memory prefix) internal view returns (OptionSeriesParams memory params) {
        params.expiries = _envUintArray(string.concat(prefix, "_EXPIRIES"));
        params.strikes1e8 = _envUintArray(string.concat(prefix, "_STRIKES_1E8"));
        params.isCalls = _envBoolArray(string.concat(prefix, "_IS_CALLS"));
        params.isEuropean = _envBoolArray(string.concat(prefix, "_IS_EUROPEAN"));
        params.registryActive = _envBoolArray(string.concat(prefix, "_REGISTRY_ACTIVE"));
        params.activationStates = _envUintArray(string.concat(prefix, "_ACTIVATION_STATES"));
        params.shortOpenInterestCaps = _envUintArray(string.concat(prefix, "_SHORT_OI_CAPS"));

        uint256 len = params.expiries.length;
        if (len == 0) revert(string.concat(prefix, " empty"));
        _requireLength(string.concat(prefix, "_STRIKES_1E8"), params.strikes1e8.length, len);
        _requireLength(string.concat(prefix, "_IS_CALLS"), params.isCalls.length, len);
        _requireLength(string.concat(prefix, "_IS_EUROPEAN"), params.isEuropean.length, len);
        _requireLength(string.concat(prefix, "_REGISTRY_ACTIVE"), params.registryActive.length, len);
        _requireLength(string.concat(prefix, "_ACTIVATION_STATES"), params.activationStates.length, len);
        _requireLength(string.concat(prefix, "_SHORT_OI_CAPS"), params.shortOpenInterestCaps.length, len);

        for (uint256 i = 0; i < len; i++) {
            if (params.expiries[i] <= block.timestamp) revert(string.concat(prefix, " expiry in past"));
            if (params.strikes1e8[i] == 0) revert(string.concat(prefix, " strike zero"));
            if (params.activationStates[i] > 2) revert(string.concat(prefix, " activation state invalid"));
        }
    }

    function _readPerpParams(string memory prefix) internal view returns (PerpParams memory params) {
        params.symbol = _envString(string.concat(prefix, "_SYMBOL"));
        if (_toBytes32(params.symbol) == bytes32(0)) revert(string.concat(prefix, " symbol empty"));
        params.oracle = _envAddress(string.concat(prefix, "_ORACLE"));
        params.registryActive = _envBool(string.concat(prefix, "_REGISTRY_ACTIVE"));
        params.closeOnly = _envBool(string.concat(prefix, "_CLOSE_ONLY"));
        params.engineActivationState = _envUint(string.concat(prefix, "_ENGINE_ACTIVATION_STATE"));
        params.launchOpenInterestCap1e8 = _envUint(string.concat(prefix, "_LAUNCH_OI_CAP_1E8"));
        params.initialMarginBps = _toUint32(
            _envUint(string.concat(prefix, "_INITIAL_MARGIN_BPS")), string.concat(prefix, "_INITIAL_MARGIN_BPS")
        );
        params.maintenanceMarginBps = _toUint32(
            _envUint(string.concat(prefix, "_MAINTENANCE_MARGIN_BPS")), string.concat(prefix, "_MAINTENANCE_MARGIN_BPS")
        );
        params.liquidationPenaltyBps = _toUint32(
            _envUint(string.concat(prefix, "_LIQUIDATION_PENALTY_BPS")),
            string.concat(prefix, "_LIQUIDATION_PENALTY_BPS")
        );
        params.maxPositionSize1e8 = _toUint128(
            _envUint(string.concat(prefix, "_MAX_POSITION_SIZE_1E8")), string.concat(prefix, "_MAX_POSITION_SIZE_1E8")
        );
        params.maxOpenInterest1e8 = _toUint128(
            _envUint(string.concat(prefix, "_MAX_OPEN_INTEREST_1E8")), string.concat(prefix, "_MAX_OPEN_INTEREST_1E8")
        );
        params.reduceOnlyDuringCloseOnly = _envBool(string.concat(prefix, "_REDUCE_ONLY_DURING_CLOSE_ONLY"));
        params.liquidationCloseFactorBps = _toUint32(
            _envUint(string.concat(prefix, "_LIQUIDATION_CLOSE_FACTOR_BPS")),
            string.concat(prefix, "_LIQUIDATION_CLOSE_FACTOR_BPS")
        );
        params.liquidationPriceSpreadBps = _toUint32(
            _envUint(string.concat(prefix, "_LIQUIDATION_PRICE_SPREAD_BPS")),
            string.concat(prefix, "_LIQUIDATION_PRICE_SPREAD_BPS")
        );
        params.minLiquidationImprovementBps = _toUint32(
            _envUint(string.concat(prefix, "_MIN_LIQUIDATION_IMPROVEMENT_BPS")),
            string.concat(prefix, "_MIN_LIQUIDATION_IMPROVEMENT_BPS")
        );
        params.liquidationOracleMaxDelay = _toUint32(
            _envUint(string.concat(prefix, "_LIQUIDATION_ORACLE_MAX_DELAY")),
            string.concat(prefix, "_LIQUIDATION_ORACLE_MAX_DELAY")
        );
        params.fundingEnabled = _envBool(string.concat(prefix, "_FUNDING_ENABLED"));
        params.fundingInterval =
            _toUint32(_envUint(string.concat(prefix, "_FUNDING_INTERVAL")), string.concat(prefix, "_FUNDING_INTERVAL"));
        params.maxFundingRateBps = _toUint32(
            _envUint(string.concat(prefix, "_MAX_FUNDING_RATE_BPS")), string.concat(prefix, "_MAX_FUNDING_RATE_BPS")
        );
        params.maxSkewFundingBps = _toUint32(
            _envUint(string.concat(prefix, "_MAX_SKEW_FUNDING_BPS")), string.concat(prefix, "_MAX_SKEW_FUNDING_BPS")
        );
        params.oracleClampBps =
            _toUint32(_envUint(string.concat(prefix, "_ORACLE_CLAMP_BPS")), string.concat(prefix, "_ORACLE_CLAMP_BPS"));

        if (params.oracle != address(0)) _requireContract(string.concat(prefix, "_ORACLE"), params.oracle);
        if (params.engineActivationState > 2) revert(string.concat(prefix, " activation state invalid"));
    }

    function _configureFeed(OracleRouter router, address underlying, address baseToken, FeedParams memory params)
        internal
    {
        router.setFeed(
            underlying,
            baseToken,
            IPriceSource(params.primarySource),
            IPriceSource(params.secondarySource),
            params.maxDelay,
            params.maxDeviationBps,
            params.isActive
        );
    }

    function _configureOptionUnderlying(
        OptionProductRegistry registry,
        address underlying,
        OptionUnderlyingParams memory params
    ) internal {
        registry.setUnderlyingRiskProfile(
            underlying,
            OptionProductRegistry.UnderlyingConfig({
                oracle: params.oracle,
                spotShockDownBps: params.spotShockDownBps,
                spotShockUpBps: params.spotShockUpBps,
                volShockDownBps: params.volShockDownBps,
                volShockUpBps: params.volShockUpBps,
                isEnabled: params.isEnabled
            }),
            OptionProductRegistry.OptionRiskConfig({
                baseMaintenanceMarginPerContract: params.baseMaintenanceMarginPerContractBase,
                imFactorBps: params.imFactorBps,
                oracleDownMmMultiplierBps: params.oracleDownMmMultiplierBps,
                isConfigured: true
            })
        );
    }

    function _configureOptionSeries(
        OptionProductRegistry registry,
        MarginEngine marginEngine,
        address underlying,
        address settlementAsset,
        OptionSeriesParams memory params
    ) internal {
        uint256 len = params.expiries.length;

        for (uint256 i = 0; i < len; i++) {
            uint64 expiry = _toUint64(params.expiries[i], "option expiry");
            uint64 strike = _toUint64(params.strikes1e8[i], "option strike");

            uint256 optionId = registry.computeOptionId(
                underlying,
                settlementAsset,
                expiry,
                strike,
                OPTION_CONTRACT_SIZE_1E8,
                params.isCalls[i],
                params.isEuropean[i]
            );

            if (!registry.seriesExists(optionId)) {
                uint256 createdId = registry.createSeries(
                    underlying, settlementAsset, expiry, strike, params.isCalls[i], params.isEuropean[i]
                );
                if (createdId != optionId) revert("option id mismatch");
            }

            registry.setSeriesActive(optionId, params.registryActive[i]);
            marginEngine.setSeriesShortOpenInterestCap(optionId, params.shortOpenInterestCaps[i]);
            marginEngine.setSeriesActivationState(
                optionId, _toUint8(params.activationStates[i], "series activation state")
            );
        }
    }

    function _configurePerpMarket(
        PerpMarketRegistry registry,
        PerpEngine engine,
        address underlying,
        address settlementAsset,
        PerpParams memory params
    ) internal returns (uint256 marketId) {
        bytes32 symbol = _toBytes32(params.symbol);
        PerpMarketRegistry.RiskConfig memory riskCfg = PerpMarketRegistry.RiskConfig({
            initialMarginBps: params.initialMarginBps,
            maintenanceMarginBps: params.maintenanceMarginBps,
            liquidationPenaltyBps: params.liquidationPenaltyBps,
            maxPositionSize1e8: params.maxPositionSize1e8,
            maxOpenInterest1e8: params.maxOpenInterest1e8,
            reduceOnlyDuringCloseOnly: params.reduceOnlyDuringCloseOnly
        });
        PerpMarketRegistry.LiquidationConfig memory liquidationCfg = PerpMarketRegistry.LiquidationConfig({
            closeFactorBps: params.liquidationCloseFactorBps,
            priceSpreadBps: params.liquidationPriceSpreadBps,
            minImprovementBps: params.minLiquidationImprovementBps,
            oracleMaxDelay: params.liquidationOracleMaxDelay
        });
        PerpMarketRegistry.FundingConfig memory fundingCfg = PerpMarketRegistry.FundingConfig({
            isEnabled: params.fundingEnabled,
            fundingInterval: params.fundingInterval,
            maxFundingRateBps: params.maxFundingRateBps,
            maxSkewFundingBps: params.maxSkewFundingBps,
            oracleClampBps: params.oracleClampBps
        });

        bytes32 key = registry.computeMarketKey(underlying, settlementAsset, symbol);
        marketId = registry.marketIdByKey(key);
        if (marketId == 0) {
            marketId = registry.createMarket(
                underlying, settlementAsset, params.oracle, symbol, riskCfg, liquidationCfg, fundingCfg
            );
        } else {
            registry.setMarketOracle(marketId, params.oracle);
            registry.setRiskConfig(marketId, riskCfg);
            registry.setLiquidationConfig(marketId, liquidationCfg);
            registry.setFundingConfig(marketId, fundingCfg);
        }

        registry.setMarketStatus(marketId, params.registryActive, params.closeOnly);
        engine.setLaunchOpenInterestCap(marketId, params.launchOpenInterestCap1e8);
        engine.setMarketActivationState(marketId, _toUint8(params.engineActivationState, "market activation state"));
    }

    function _requireDeployed(CoreAddresses memory addrs) internal view {
        _requireContract("ORACLE_ROUTER", addrs.oracleRouter);
        _requireContract("OPTION_PRODUCT_REGISTRY", addrs.optionProductRegistry);
        _requireContract("MARGIN_ENGINE", addrs.marginEngine);
        _requireContract("PERP_MARKET_REGISTRY", addrs.perpMarketRegistry);
        _requireContract("PERP_ENGINE", addrs.perpEngine);
        if (addrs.baseCollateralToken == address(0)) revert("BASE_COLLATERAL_TOKEN zero");
        if (addrs.ethUnderlying == address(0)) revert("ETH_UNDERLYING zero");
        if (addrs.btcUnderlying == address(0)) revert("BTC_UNDERLYING zero");
        if (addrs.ethUnderlying == addrs.baseCollateralToken) revert("ETH underlying equals base");
        if (addrs.btcUnderlying == addrs.baseCollateralToken) revert("BTC underlying equals base");
        if (addrs.ethUnderlying == addrs.btcUnderlying) revert("duplicate underlyings");
    }

    function _requireContract(string memory name, address target) internal view {
        if (target == address(0)) revert(string.concat(name, " zero"));
        if (target.code.length == 0) revert(string.concat(name, " no code"));
    }

    function _envAddress(string memory name) internal view returns (address value) {
        _requireEnv(name);
        value = vm.envAddress(name);
    }

    function _envBool(string memory name) internal view returns (bool value) {
        _requireEnv(name);
        value = vm.envBool(name);
    }

    function _envString(string memory name) internal view returns (string memory value) {
        _requireEnv(name);
        value = vm.envString(name);
    }

    function _envUint(string memory name) internal view returns (uint256 value) {
        _requireEnv(name);
        value = vm.envUint(name);
    }

    function _envUintArray(string memory name) internal view returns (uint256[] memory values) {
        _requireEnv(name);
        values = vm.envUint(name, DELIM);
    }

    function _envBoolArray(string memory name) internal view returns (bool[] memory values) {
        _requireEnv(name);
        values = vm.envBool(name, DELIM);
    }

    function _requireEnv(string memory name) internal view {
        if (!vm.envExists(name)) revert(string.concat("missing env: ", name));
    }

    function _requireLength(string memory name, uint256 actual, uint256 expected) internal pure {
        if (actual != expected) revert(string.concat(name, " length mismatch"));
    }

    function _toBytes32(string memory value) internal pure returns (bytes32 result) {
        bytes memory raw = bytes(value);
        if (raw.length == 0) return bytes32(0);
        if (raw.length > 32) revert("symbol too long");
        assembly {
            result := mload(add(raw, 32))
        }
    }

    function _toUint8(uint256 value, string memory label) internal pure returns (uint8) {
        if (value > type(uint8).max) revert(string.concat(label, " uint8 overflow"));
        return SafeCast.toUint8(value);
    }

    function _toUint16(uint256 value, string memory label) internal pure returns (uint16) {
        if (value > type(uint16).max) revert(string.concat(label, " uint16 overflow"));
        return SafeCast.toUint16(value);
    }

    function _toUint32(uint256 value, string memory label) internal pure returns (uint32) {
        if (value > type(uint32).max) revert(string.concat(label, " uint32 overflow"));
        return SafeCast.toUint32(value);
    }

    function _toUint64(uint256 value, string memory label) internal pure returns (uint64) {
        if (value > type(uint64).max) revert(string.concat(label, " uint64 overflow"));
        return SafeCast.toUint64(value);
    }

    function _toUint128(uint256 value, string memory label) internal pure returns (uint128) {
        if (value > type(uint128).max) revert(string.concat(label, " uint128 overflow"));
        return SafeCast.toUint128(value);
    }

    function _logConfiguration(
        address caller,
        CoreAddresses memory addrs,
        uint256 ethSeriesCount,
        uint256 btcSeriesCount,
        uint256 ethMarketId,
        uint256 btcMarketId
    ) internal view {
        console2.log("DeOpt v2 market configuration");
        console2.log("chainId", block.chainid);
        console2.log("caller", caller);
        console2.log("oracleRouter", addrs.oracleRouter);
        console2.log("baseCollateralToken", addrs.baseCollateralToken);
        console2.log("ethUnderlying", addrs.ethUnderlying);
        console2.log("btcUnderlying", addrs.btcUnderlying);
        console2.log("ethOptionSeriesConfigured", ethSeriesCount);
        console2.log("btcOptionSeriesConfigured", btcSeriesCount);
        console2.log("ethPerpMarketId", ethMarketId);
        console2.log("btcPerpMarketId", btcMarketId);
    }
}
