// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {FeesManager} from "../src/fees/FeesManager.sol";
import {CollateralSeizer} from "../src/liquidation/CollateralSeizer.sol";
import {MatchingEngine} from "../src/matching/MatchingEngine.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";
import {PerpEngine} from "../src/perp/PerpEngine.sol";
import {PerpMarketRegistry} from "../src/perp/PerpMarketRegistry.sol";
import {PerpRiskModule} from "../src/perp/PerpRiskModule.sol";
import {RiskModule} from "../src/risk/RiskModule.sol";

/// @notice Fifth-pass read-only post-deployment verifier for a configured DeOpt v2 deployment.
/// @dev Reads all expectations from env vars and reverts loudly on missing envs or mismatches.
contract VerifyDeployment is Script {
    uint128 internal constant OPTION_CONTRACT_SIZE_1E8 = 1e8;
    string internal constant DELIM = ",";

    struct CoreAddresses {
        address collateralVault;
        address oracleRouter;
        address optionProductRegistry;
        address marginEngine;
        address riskModule;
        address perpMarketRegistry;
        address perpEngine;
        address perpRiskModule;
        address collateralSeizer;
        address feesManager;
        address insuranceFund;
        address matchingEngine;
        address perpMatchingEngine;
        address protocolTimelock;
        address riskGovernor;
        address baseCollateralToken;
        address ethUnderlying;
        address btcUnderlying;
    }

    struct CoreParams {
        uint8 baseDecimals;
        uint256 baseMaintenanceMarginPerContractBase;
        uint256 imFactorBps;
        uint256 oracleDownMmMultiplierBps;
        uint256 riskMaxOracleDelay;
        uint256 perpRiskMaxOracleDelay;
        bool collateralRestrictionMode;
        uint32 oracleRouterMaxDelay;
        uint16 feeBpsCap;
        uint16 makerNotionalFeeBps;
        uint16 makerPremiumCapBps;
        uint16 takerNotionalFeeBps;
        uint16 takerPremiumCapBps;
    }

    struct CollateralParams {
        address[] tokens;
        uint256[] decimals;
        uint256[] vaultFactorsBps;
        uint256[] riskWeightsBps;
        uint256[] depositCaps;
        bool[] launchActive;
        bool[] riskEnabled;
        bool[] insuranceAllowed;
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

    function run() external view {
        CoreAddresses memory addrs = _readCoreAddresses();
        CoreParams memory core = _readCoreParams();
        CollateralParams memory collateral = _readCollateralParams();

        FeedParams memory ethFeed = _readFeedParams("ETH_USDC");
        FeedParams memory btcFeed = _readFeedParams("BTC_USDC");
        OptionUnderlyingParams memory ethOption = _readOptionUnderlyingParams("ETH_OPTION");
        OptionUnderlyingParams memory btcOption = _readOptionUnderlyingParams("BTC_OPTION");
        OptionSeriesParams memory ethSeries = _readOptionSeriesParams("ETH_OPTION_SERIES");
        OptionSeriesParams memory btcSeries = _readOptionSeriesParams("BTC_OPTION_SERIES");
        PerpParams memory ethPerp = _readPerpParams("ETH_PERP");
        PerpParams memory btcPerp = _readPerpParams("BTC_PERP");

        _verifyBytecode(addrs);
        _verifyWiring(addrs);
        _verifyCollateral(addrs, core, collateral);
        _verifyOracle(addrs, core, ethFeed, btcFeed);
        _verifyOptions(addrs, ethOption, btcOption, ethSeries, btcSeries);
        _verifyPerps(addrs, ethPerp, btcPerp, ethFeed, btcFeed);
        _verifyFeesAndInsurance(addrs, core, collateral);

        console2.log("DeOpt v2 deployment verification OK");
        console2.log("chainId", block.chainid);
        console2.log("collateralVault", addrs.collateralVault);
        console2.log("ethOptionSeriesVerified", ethSeries.expiries.length);
        console2.log("btcOptionSeriesVerified", btcSeries.expiries.length);
    }

    function _readCoreAddresses() internal view returns (CoreAddresses memory addrs) {
        addrs.collateralVault = _envAddress("COLLATERAL_VAULT");
        addrs.oracleRouter = _envAddress("ORACLE_ROUTER");
        addrs.optionProductRegistry = _envAddress("OPTION_PRODUCT_REGISTRY");
        addrs.marginEngine = _envAddress("MARGIN_ENGINE");
        addrs.riskModule = _envAddress("RISK_MODULE");
        addrs.perpMarketRegistry = _envAddress("PERP_MARKET_REGISTRY");
        addrs.perpEngine = _envAddress("PERP_ENGINE");
        addrs.perpRiskModule = _envAddress("PERP_RISK_MODULE");
        addrs.collateralSeizer = _envAddress("COLLATERAL_SEIZER");
        addrs.feesManager = _envAddress("FEES_MANAGER");
        addrs.insuranceFund = _envAddress("INSURANCE_FUND");
        addrs.matchingEngine = _envAddress("MATCHING_ENGINE");
        addrs.perpMatchingEngine = _envAddress("PERP_MATCHING_ENGINE");
        addrs.protocolTimelock = _envAddress("PROTOCOL_TIMELOCK");
        addrs.riskGovernor = _envAddress("RISK_GOVERNOR");
        addrs.baseCollateralToken = _envAddress("BASE_COLLATERAL_TOKEN");
        addrs.ethUnderlying = _envAddress("ETH_UNDERLYING");
        addrs.btcUnderlying = _envAddress("BTC_UNDERLYING");
    }

    function _readCoreParams() internal view returns (CoreParams memory params) {
        params.baseDecimals = _toUint8(_envUint("BASE_COLLATERAL_DECIMALS"), "BASE_COLLATERAL_DECIMALS");
        params.baseMaintenanceMarginPerContractBase =
            _envUint("BASE_MAINTENANCE_MARGIN_PER_CONTRACT_BASE");
        params.imFactorBps = _envUint("IM_FACTOR_BPS");
        params.oracleDownMmMultiplierBps = _envUint("ORACLE_DOWN_MM_MULTIPLIER_BPS");
        params.riskMaxOracleDelay = _envUint("RISK_MAX_ORACLE_DELAY");
        params.perpRiskMaxOracleDelay = _envUint("PERP_RISK_MAX_ORACLE_DELAY");
        params.collateralRestrictionMode = _envBool("COLLATERAL_RESTRICTION_MODE");
        params.oracleRouterMaxDelay = _toUint32(_envUint("ORACLE_ROUTER_MAX_DELAY"), "ORACLE_ROUTER_MAX_DELAY");
        params.feeBpsCap = _toUint16(_envUint("FEE_BPS_CAP"), "FEE_BPS_CAP");
        params.makerNotionalFeeBps =
            _toUint16(_envUint("DEFAULT_MAKER_NOTIONAL_FEE_BPS"), "DEFAULT_MAKER_NOTIONAL_FEE_BPS");
        params.makerPremiumCapBps =
            _toUint16(_envUint("DEFAULT_MAKER_PREMIUM_CAP_BPS"), "DEFAULT_MAKER_PREMIUM_CAP_BPS");
        params.takerNotionalFeeBps =
            _toUint16(_envUint("DEFAULT_TAKER_NOTIONAL_FEE_BPS"), "DEFAULT_TAKER_NOTIONAL_FEE_BPS");
        params.takerPremiumCapBps =
            _toUint16(_envUint("DEFAULT_TAKER_PREMIUM_CAP_BPS"), "DEFAULT_TAKER_PREMIUM_CAP_BPS");
    }

    function _readCollateralParams() internal view returns (CollateralParams memory params) {
        params.tokens = _envAddressArray("COLLATERAL_TOKENS");
        params.decimals = _envUintArray("COLLATERAL_DECIMALS");
        params.vaultFactorsBps = _envUintArray("COLLATERAL_FACTORS_BPS");
        params.riskWeightsBps = _envUintArray("COLLATERAL_WEIGHTS_BPS");
        params.depositCaps = _envUintArray("COLLATERAL_DEPOSIT_CAPS");
        params.launchActive = _envBoolArray("COLLATERAL_LAUNCH_ACTIVE");
        params.riskEnabled = _envBoolArray("COLLATERAL_RISK_ENABLED");
        params.insuranceAllowed = _envBoolArray("INSURANCE_TOKEN_ALLOWED");

        uint256 len = params.tokens.length;
        if (len == 0) revert("COLLATERAL_TOKENS empty");
        _requireLength("COLLATERAL_DECIMALS", params.decimals.length, len);
        _requireLength("COLLATERAL_FACTORS_BPS", params.vaultFactorsBps.length, len);
        _requireLength("COLLATERAL_WEIGHTS_BPS", params.riskWeightsBps.length, len);
        _requireLength("COLLATERAL_DEPOSIT_CAPS", params.depositCaps.length, len);
        _requireLength("COLLATERAL_LAUNCH_ACTIVE", params.launchActive.length, len);
        _requireLength("COLLATERAL_RISK_ENABLED", params.riskEnabled.length, len);
        _requireLength("INSURANCE_TOKEN_ALLOWED", params.insuranceAllowed.length, len);
    }

    function _readFeedParams(string memory prefix) internal view returns (FeedParams memory params) {
        params.primarySource = _envAddress(string.concat(prefix, "_PRIMARY_SOURCE"));
        params.secondarySource = _envAddress(string.concat(prefix, "_SECONDARY_SOURCE"));
        params.maxDelay = _toUint32(_envUint(string.concat(prefix, "_MAX_DELAY")), string.concat(prefix, "_MAX_DELAY"));
        params.maxDeviationBps = _toUint16(
            _envUint(string.concat(prefix, "_MAX_DEVIATION_BPS")), string.concat(prefix, "_MAX_DEVIATION_BPS")
        );
        params.isActive = _envBool(string.concat(prefix, "_FEED_ACTIVE"));
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
    }

    function _readPerpParams(string memory prefix) internal view returns (PerpParams memory params) {
        params.symbol = _envString(string.concat(prefix, "_SYMBOL"));
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
    }

    function _verifyBytecode(CoreAddresses memory addrs) internal view {
        _requireContract("COLLATERAL_VAULT", addrs.collateralVault);
        _requireContract("ORACLE_ROUTER", addrs.oracleRouter);
        _requireContract("OPTION_PRODUCT_REGISTRY", addrs.optionProductRegistry);
        _requireContract("MARGIN_ENGINE", addrs.marginEngine);
        _requireContract("RISK_MODULE", addrs.riskModule);
        _requireContract("PERP_MARKET_REGISTRY", addrs.perpMarketRegistry);
        _requireContract("PERP_ENGINE", addrs.perpEngine);
        _requireContract("PERP_RISK_MODULE", addrs.perpRiskModule);
        _requireContract("COLLATERAL_SEIZER", addrs.collateralSeizer);
        _requireContract("FEES_MANAGER", addrs.feesManager);
        _requireContract("INSURANCE_FUND", addrs.insuranceFund);
        _requireContract("MATCHING_ENGINE", addrs.matchingEngine);
        _requireContract("PERP_MATCHING_ENGINE", addrs.perpMatchingEngine);
        _requireContract("PROTOCOL_TIMELOCK", addrs.protocolTimelock);
        _requireContract("RISK_GOVERNOR", addrs.riskGovernor);
    }

    function _verifyWiring(CoreAddresses memory addrs) internal view {
        CollateralVault vault = CollateralVault(addrs.collateralVault);
        RiskModule risk = RiskModule(addrs.riskModule);
        MarginEngine margin = MarginEngine(addrs.marginEngine);
        PerpEngine perp = PerpEngine(addrs.perpEngine);
        PerpRiskModule perpRisk = PerpRiskModule(addrs.perpRiskModule);
        CollateralSeizer seizer = CollateralSeizer(addrs.collateralSeizer);
        InsuranceFund fund = InsuranceFund(addrs.insuranceFund);

        _assertAddress("vault.riskModule", address(vault.riskModule()), addrs.riskModule);
        _assertAddress("vault.primaryMarginEngine", vault.getPrimaryMarginEngine(), addrs.marginEngine);
        _assertBool("vault margin authorized", vault.isEngineAuthorized(addrs.marginEngine), true);
        _assertBool("vault perp authorized", vault.isEngineAuthorized(addrs.perpEngine), true);
        _assertBool("vault insurance authorized", vault.isEngineAuthorized(addrs.insuranceFund), true);

        _assertAddress("risk.collateralVault", address(risk.collateralVault()), addrs.collateralVault);
        _assertAddress("risk.optionRegistry", address(risk.optionRegistry()), addrs.optionProductRegistry);
        _assertAddress("risk.marginEngine", address(risk.marginEngine()), addrs.marginEngine);
        _assertAddress("risk.oracle", address(risk.oracle()), addrs.oracleRouter);
        _assertAddress("risk.perpRiskModule", address(risk.perpRiskModule()), addrs.perpRiskModule);
        _assertAddress("risk.perpEngine", risk.perpEngine(), addrs.perpEngine);

        _assertAddress("margin.collateralVault", margin.collateralVault(), addrs.collateralVault);
        _assertAddress("margin.oracle", margin.oracle(), addrs.oracleRouter);
        _assertAddress("margin.riskModule", margin.riskModule(), addrs.riskModule);
        _assertAddress("margin.matchingEngine", margin.matchingEngine(), addrs.matchingEngine);
        _assertAddress("margin.insuranceFund", margin.insuranceFund(), addrs.insuranceFund);
        _assertAddress("margin.feesManager", address(margin.feesManager()), addrs.feesManager);

        _assertAddress("perp.marketRegistry", perp.marketRegistry(), addrs.perpMarketRegistry);
        _assertAddress("perp.collateralVault", perp.collateralVault(), addrs.collateralVault);
        _assertAddress("perp.oracle", perp.oracle(), addrs.oracleRouter);
        _assertAddress("perp.riskModule", perp.riskModule(), addrs.perpRiskModule);
        _assertAddress("perp.collateralSeizer", perp.collateralSeizer(), addrs.collateralSeizer);
        _assertAddress("perp.matchingEngine", perp.matchingEngine(), addrs.perpMatchingEngine);
        _assertAddress("perp.insuranceFund", perp.insuranceFund(), addrs.insuranceFund);
        _assertAddress("perp.feesManager", address(perp.feesManager()), addrs.feesManager);

        _assertAddress("perpRisk.vault", address(perpRisk.collateralVault()), addrs.collateralVault);
        _assertAddress("perpRisk.oracle", address(perpRisk.oracle()), addrs.oracleRouter);
        _assertAddress("perpRisk.perpEngine", address(perpRisk.perpEngine()), addrs.perpEngine);

        _assertAddress("seizer.vault", address(seizer.collateralVault()), addrs.collateralVault);
        _assertAddress("seizer.oracle", address(seizer.oracle()), addrs.oracleRouter);
        _assertAddress("seizer.riskModule", address(seizer.riskModule()), addrs.riskModule);

        _assertAddress("insurance.vault", address(fund.collateralVault()), addrs.collateralVault);
        _assertBool("insurance margin backstop", fund.isBackstopCaller(addrs.marginEngine), true);
        _assertBool("insurance perp backstop", fund.isBackstopCaller(addrs.perpEngine), true);
        _assertAddress("matching.marginEngine", address(MatchingEngine(addrs.matchingEngine).marginEngine()), addrs.marginEngine);
        _assertAddress(
            "perpMatching.perpEngine", address(PerpMatchingEngine(addrs.perpMatchingEngine).perpEngine()), addrs.perpEngine
        );
    }

    function _verifyCollateral(
        CoreAddresses memory addrs,
        CoreParams memory core,
        CollateralParams memory collateral
    ) internal view {
        CollateralVault vault = CollateralVault(addrs.collateralVault);
        RiskModule risk = RiskModule(addrs.riskModule);
        PerpRiskModule perpRisk = PerpRiskModule(addrs.perpRiskModule);

        _assertAddress("risk.baseCollateralToken", risk.baseCollateralToken(), addrs.baseCollateralToken);
        _assertUint("risk.baseMM", risk.baseMaintenanceMarginPerContract(), core.baseMaintenanceMarginPerContractBase);
        _assertUint("risk.imFactorBps", risk.imFactorBps(), core.imFactorBps);
        _assertUint("risk.oracleDownMmMultiplierBps", risk.oracleDownMmMultiplierBps(), core.oracleDownMmMultiplierBps);
        _assertUint("risk.maxOracleDelay", risk.maxOracleDelay(), core.riskMaxOracleDelay);
        _assertAddress("perpRisk.baseCollateralToken", perpRisk.baseCollateralToken(), addrs.baseCollateralToken);
        _assertUint("perpRisk.maxOracleDelay", perpRisk.maxOracleDelay(), core.perpRiskMaxOracleDelay);
        _assertBool("vault.collateralRestrictionMode", vault.collateralRestrictionMode(), core.collateralRestrictionMode);

        _assertBool("vault has base token", _contains(vault.getCollateralTokens(), addrs.baseCollateralToken), true);
        _assertBool("risk has base token", _contains(risk.getCollateralTokens(), addrs.baseCollateralToken), true);

        for (uint256 i = 0; i < collateral.tokens.length; i++) {
            address token = collateral.tokens[i];
            if (token == address(0)) revert("collateral token zero");
            CollateralVault.CollateralTokenConfig memory vaultCfg = vault.getCollateralConfig(token);
            _assertBool("vault collateral supported", vaultCfg.isSupported, true);
            _assertUint("vault collateral decimals", vaultCfg.decimals, collateral.decimals[i]);
            _assertUint("vault collateral factor", vaultCfg.collateralFactorBps, collateral.vaultFactorsBps[i]);
            _assertUint("vault token deposit cap", vault.tokenDepositCap(token), collateral.depositCaps[i]);
            _assertBool("vault launch-active collateral", vault.launchActiveCollateral(token), collateral.launchActive[i]);
            _assertBool("vault collateral token listed", _contains(vault.getCollateralTokens(), token), true);

            (uint64 weightBps, bool isEnabled) = risk.collateralConfigs(token);
            _assertUint("risk collateral weight", weightBps, collateral.riskWeightsBps[i]);
            _assertBool("risk collateral enabled", isEnabled, collateral.riskEnabled[i]);
            _assertBool("risk collateral token listed", _contains(risk.getCollateralTokens(), token), true);
        }
    }

    function _verifyOracle(
        CoreAddresses memory addrs,
        CoreParams memory core,
        FeedParams memory ethFeed,
        FeedParams memory btcFeed
    ) internal view {
        OracleRouter router = OracleRouter(addrs.oracleRouter);
        _assertUint("oracleRouter.maxOracleDelay", router.maxOracleDelay(), core.oracleRouterMaxDelay);
        _verifyFeed("ETH_USDC", router, addrs.ethUnderlying, addrs.baseCollateralToken, ethFeed);
        _verifyFeed("BTC_USDC", router, addrs.btcUnderlying, addrs.baseCollateralToken, btcFeed);
    }

    function _verifyFeed(
        string memory label,
        OracleRouter router,
        address underlying,
        address baseToken,
        FeedParams memory expected
    ) internal view {
        if (expected.primarySource != address(0)) _requireContract(string.concat(label, "_PRIMARY_SOURCE"), expected.primarySource);
        if (expected.secondarySource != address(0)) {
            _requireContract(string.concat(label, "_SECONDARY_SOURCE"), expected.secondarySource);
        }

        OracleRouter.FeedConfig memory cfg = router.getFeed(underlying, baseToken);
        _assertAddress(string.concat(label, " primary"), address(cfg.primarySource), expected.primarySource);
        _assertAddress(string.concat(label, " secondary"), address(cfg.secondarySource), expected.secondarySource);
        _assertUint(string.concat(label, " maxDelay"), cfg.maxDelay, expected.maxDelay);
        _assertUint(string.concat(label, " maxDeviationBps"), cfg.maxDeviationBps, expected.maxDeviationBps);
        _assertBool(string.concat(label, " active"), cfg.isActive, expected.isActive);

        if (expected.isActive && (expected.primarySource != address(0) || expected.secondarySource != address(0))) {
            (uint256 price,, bool ok) = router.getPriceSafe(underlying, baseToken);
            if (!ok) revert(string.concat(label, " price unavailable"));
            if (price == 0) revert(string.concat(label, " normalized price zero"));
        }
    }

    function _verifyOptions(
        CoreAddresses memory addrs,
        OptionUnderlyingParams memory ethOption,
        OptionUnderlyingParams memory btcOption,
        OptionSeriesParams memory ethSeries,
        OptionSeriesParams memory btcSeries
    ) internal view {
        OptionProductRegistry registry = OptionProductRegistry(addrs.optionProductRegistry);
        MarginEngine margin = MarginEngine(addrs.marginEngine);

        _assertBool(
            "option settlement asset allowed",
            registry.isSettlementAssetAllowed(addrs.baseCollateralToken),
            true
        );
        _verifyOptionUnderlying("ETH_OPTION", registry, addrs.ethUnderlying, ethOption);
        _verifyOptionUnderlying("BTC_OPTION", registry, addrs.btcUnderlying, btcOption);
        _verifyOptionSeries(registry, margin, addrs.ethUnderlying, addrs.baseCollateralToken, ethSeries);
        _verifyOptionSeries(registry, margin, addrs.btcUnderlying, addrs.baseCollateralToken, btcSeries);
    }

    function _verifyOptionUnderlying(
        string memory label,
        OptionProductRegistry registry,
        address underlying,
        OptionUnderlyingParams memory expected
    ) internal view {
        OptionProductRegistry.UnderlyingConfig memory cfg = registry.getUnderlyingConfig(underlying);
        OptionProductRegistry.OptionRiskConfig memory riskCfg = registry.getOptionRiskConfig(underlying);

        _assertAddress(string.concat(label, " oracle"), cfg.oracle, expected.oracle);
        _assertUint(string.concat(label, " spotShockDownBps"), cfg.spotShockDownBps, expected.spotShockDownBps);
        _assertUint(string.concat(label, " spotShockUpBps"), cfg.spotShockUpBps, expected.spotShockUpBps);
        _assertUint(string.concat(label, " volShockDownBps"), cfg.volShockDownBps, expected.volShockDownBps);
        _assertUint(string.concat(label, " volShockUpBps"), cfg.volShockUpBps, expected.volShockUpBps);
        _assertBool(string.concat(label, " enabled"), cfg.isEnabled, expected.isEnabled);
        _assertUint(
            string.concat(label, " baseMM"),
            riskCfg.baseMaintenanceMarginPerContract,
            expected.baseMaintenanceMarginPerContractBase
        );
        _assertUint(string.concat(label, " imFactorBps"), riskCfg.imFactorBps, expected.imFactorBps);
        _assertUint(
            string.concat(label, " oracleDownMmMultiplierBps"),
            riskCfg.oracleDownMmMultiplierBps,
            expected.oracleDownMmMultiplierBps
        );
        _assertBool(string.concat(label, " risk configured"), riskCfg.isConfigured, true);
    }

    function _verifyOptionSeries(
        OptionProductRegistry registry,
        MarginEngine margin,
        address underlying,
        address settlementAsset,
        OptionSeriesParams memory expected
    ) internal view {
        for (uint256 i = 0; i < expected.expiries.length; i++) {
            uint64 expiry = _toUint64(expected.expiries[i], "option expiry");
            uint64 strike = _toUint64(expected.strikes1e8[i], "option strike");
            uint256 optionId = registry.computeOptionId(
                underlying,
                settlementAsset,
                expiry,
                strike,
                OPTION_CONTRACT_SIZE_1E8,
                expected.isCalls[i],
                expected.isEuropean[i]
            );

            if (!registry.seriesExists(optionId)) revert("option series missing");
            OptionProductRegistry.OptionSeries memory s = registry.getSeries(optionId);
            _assertAddress("option series underlying", s.underlying, underlying);
            _assertAddress("option series settlement", s.settlementAsset, settlementAsset);
            _assertUint("option series expiry", s.expiry, expiry);
            _assertUint("option series strike", s.strike, strike);
            _assertUint("option series contractSize1e8", s.contractSize1e8, OPTION_CONTRACT_SIZE_1E8);
            _assertBool("option series isCall", s.isCall, expected.isCalls[i]);
            _assertBool("option series isEuropean", s.isEuropean, expected.isEuropean[i]);
            _assertBool("option series registry active", s.isActive, expected.registryActive[i]);
            _assertUint("option series activation state", margin.seriesActivationState(optionId), expected.activationStates[i]);
            _assertUint(
                "option series short OI cap", margin.seriesShortOpenInterestCap(optionId), expected.shortOpenInterestCaps[i]
            );
        }
    }

    function _verifyPerps(
        CoreAddresses memory addrs,
        PerpParams memory ethPerp,
        PerpParams memory btcPerp,
        FeedParams memory ethFeed,
        FeedParams memory btcFeed
    ) internal view {
        PerpMarketRegistry registry = PerpMarketRegistry(addrs.perpMarketRegistry);
        PerpEngine engine = PerpEngine(addrs.perpEngine);

        _assertBool("perp settlement asset allowed", registry.isSettlementAssetAllowed(addrs.baseCollateralToken), true);
        _verifyPerpMarket(registry, engine, addrs.ethUnderlying, addrs.baseCollateralToken, ethPerp, ethFeed);
        _verifyPerpMarket(registry, engine, addrs.btcUnderlying, addrs.baseCollateralToken, btcPerp, btcFeed);
    }

    function _verifyPerpMarket(
        PerpMarketRegistry registry,
        PerpEngine engine,
        address underlying,
        address settlementAsset,
        PerpParams memory expected,
        FeedParams memory feed
    ) internal view {
        bytes32 symbol = _toBytes32(expected.symbol);
        bytes32 key = registry.computeMarketKey(underlying, settlementAsset, symbol);
        uint256 marketId = registry.marketIdByKey(key);
        if (marketId == 0) revert("perp market missing");

        PerpMarketRegistry.Market memory market = registry.getMarket(marketId);
        _assertAddress("perp underlying", market.underlying, underlying);
        _assertAddress("perp settlement", market.settlementAsset, settlementAsset);
        _assertAddress("perp oracle", market.oracle, expected.oracle);
        _assertBytes32("perp symbol", market.symbol, symbol);
        _assertBool("perp registry active", market.isActive, expected.registryActive);
        _assertBool("perp close-only", market.isCloseOnly, expected.closeOnly);

        PerpMarketRegistry.RiskConfig memory riskCfg = registry.getRiskConfig(marketId);
        _assertUint("perp initial margin", riskCfg.initialMarginBps, expected.initialMarginBps);
        _assertUint("perp maintenance margin", riskCfg.maintenanceMarginBps, expected.maintenanceMarginBps);
        _assertUint("perp liquidation penalty", riskCfg.liquidationPenaltyBps, expected.liquidationPenaltyBps);
        _assertUint("perp max position", riskCfg.maxPositionSize1e8, expected.maxPositionSize1e8);
        _assertUint("perp max OI", riskCfg.maxOpenInterest1e8, expected.maxOpenInterest1e8);
        _assertBool("perp reduce-only during close-only", riskCfg.reduceOnlyDuringCloseOnly, expected.reduceOnlyDuringCloseOnly);

        PerpMarketRegistry.LiquidationConfig memory liquidationCfg = registry.getLiquidationConfig(marketId);
        _assertUint("perp close factor", liquidationCfg.closeFactorBps, expected.liquidationCloseFactorBps);
        _assertUint("perp liquidation spread", liquidationCfg.priceSpreadBps, expected.liquidationPriceSpreadBps);
        _assertUint("perp min liquidation improvement", liquidationCfg.minImprovementBps, expected.minLiquidationImprovementBps);
        _assertUint("perp liquidation oracle delay", liquidationCfg.oracleMaxDelay, expected.liquidationOracleMaxDelay);

        PerpMarketRegistry.FundingConfig memory fundingCfg = registry.getFundingConfig(marketId);
        _assertBool("perp funding enabled", fundingCfg.isEnabled, expected.fundingEnabled);
        _assertUint("perp funding interval", fundingCfg.fundingInterval, expected.fundingInterval);
        _assertUint("perp max funding rate", fundingCfg.maxFundingRateBps, expected.maxFundingRateBps);
        _assertUint("perp max skew funding", fundingCfg.maxSkewFundingBps, expected.maxSkewFundingBps);
        _assertUint("perp oracle clamp", fundingCfg.oracleClampBps, expected.oracleClampBps);

        _assertUint("perp launch OI cap", engine.launchOpenInterestCap1e8(marketId), expected.launchOpenInterestCap1e8);
        _assertUint("perp activation state", engine.marketActivationState(marketId), expected.engineActivationState);

        if (feed.isActive && (feed.primarySource != address(0) || feed.secondarySource != address(0))) {
            uint256 markPrice = engine.getMarkPrice(marketId);
            if (markPrice == 0) revert("perp mark price zero");
        }
    }

    function _verifyFeesAndInsurance(
        CoreAddresses memory addrs,
        CoreParams memory core,
        CollateralParams memory collateral
    ) internal view {
        FeesManager fees = FeesManager(addrs.feesManager);
        InsuranceFund fund = InsuranceFund(addrs.insuranceFund);

        _assertUint("fees cap", fees.feeBpsCap(), core.feeBpsCap);
        _assertUint("fees maker notional", fees.defaultMakerNotionalFeeBps(), core.makerNotionalFeeBps);
        _assertUint("fees maker premium cap", fees.defaultMakerPremiumCapBps(), core.makerPremiumCapBps);
        _assertUint("fees taker notional", fees.defaultTakerNotionalFeeBps(), core.takerNotionalFeeBps);
        _assertUint("fees taker premium cap", fees.defaultTakerPremiumCapBps(), core.takerPremiumCapBps);

        for (uint256 i = 0; i < collateral.tokens.length; i++) {
            _assertBool("insurance token allowed", fund.isTokenAllowed(collateral.tokens[i]), collateral.insuranceAllowed[i]);
            _assertBool("insurance usable token", fund.isUsableToken(collateral.tokens[i]), collateral.insuranceAllowed[i]);
        }
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

    function _envAddressArray(string memory name) internal view returns (address[] memory values) {
        _requireEnv(name);
        values = vm.envAddress(name, DELIM);
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

    function _requireContract(string memory name, address target) internal view {
        if (target == address(0)) revert(string.concat(name, " zero"));
        if (target.code.length == 0) revert(string.concat(name, " no code"));
    }

    function _requireLength(string memory name, uint256 actual, uint256 expected) internal pure {
        if (actual != expected) revert(string.concat(name, " length mismatch"));
    }

    function _contains(address[] memory values, address needle) internal pure returns (bool) {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == needle) return true;
        }
        return false;
    }

    function _assertAddress(string memory label, address actual, address expected) internal pure {
        if (actual != expected) revert(string.concat(label, " mismatch"));
    }

    function _assertBool(string memory label, bool actual, bool expected) internal pure {
        if (actual != expected) revert(string.concat(label, " mismatch"));
    }

    function _assertBytes32(string memory label, bytes32 actual, bytes32 expected) internal pure {
        if (actual != expected) revert(string.concat(label, " mismatch"));
    }

    function _assertUint(string memory label, uint256 actual, uint256 expected) internal pure {
        if (actual != expected) revert(string.concat(label, " mismatch"));
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
}
