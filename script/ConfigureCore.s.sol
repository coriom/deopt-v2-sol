// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {FeesManager} from "../src/fees/FeesManager.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";
import {PerpMarketRegistry} from "../src/perp/PerpMarketRegistry.sol";
import {PerpRiskModule} from "../src/perp/PerpRiskModule.sol";
import {RiskModule} from "../src/risk/RiskModule.sol";

/// @notice Third-pass core configuration script for a wired DeOpt v2 deployment.
/// @dev Configures collateral/risk/fee/insurance launch defaults only. It does not create products or transfer ownership.
contract ConfigureCore is Script {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant DEFAULT_BASE_MM_UNITS = 10;
    uint256 internal constant MAX_POW10_EXP = 77;
    string internal constant DELIM = ",";

    struct CoreAddresses {
        address collateralVault;
        address riskModule;
        address perpRiskModule;
        address marginEngine;
        address optionProductRegistry;
        address perpMarketRegistry;
        address feesManager;
        address insuranceFund;
    }

    struct CoreParams {
        address baseToken;
        uint8 baseDecimals;
        uint256 baseMaintenanceMarginPerContractBase;
        uint256 imFactorBps;
        uint256 oracleDownMmMultiplierBps;
        uint256 riskMaxOracleDelay;
        uint256 perpRiskMaxOracleDelay;
        bool collateralRestrictionMode;
        bool allowAllCollateralAsSettlementAssets;
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

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address caller = vm.addr(deployerPrivateKey);

        CoreAddresses memory addrs = _readAddresses();
        _requireDeployed(addrs);

        CoreParams memory params = _readCoreParams();
        CollateralParams memory collateral = _readCollateralParams(params);

        vm.startBroadcast(deployerPrivateKey);

        _configureVault(addrs.collateralVault, params, collateral);
        _configureRisk(addrs.riskModule, addrs.perpRiskModule, params, collateral);
        _configureRegistries(addrs.optionProductRegistry, addrs.perpMarketRegistry, params, collateral);
        _configureMarginEngine(addrs.marginEngine, params);
        _configureFees(addrs.feesManager, params);
        _configureInsurance(addrs.insuranceFund, collateral);

        vm.stopBroadcast();

        _logConfiguration(caller, params, collateral);
    }

    function _readAddresses() internal view returns (CoreAddresses memory addrs) {
        addrs.collateralVault = vm.envAddress("COLLATERAL_VAULT");
        addrs.riskModule = vm.envAddress("RISK_MODULE");
        addrs.perpRiskModule = vm.envAddress("PERP_RISK_MODULE");
        addrs.marginEngine = vm.envAddress("MARGIN_ENGINE");
        addrs.optionProductRegistry = vm.envAddress("OPTION_PRODUCT_REGISTRY");
        addrs.perpMarketRegistry = vm.envAddress("PERP_MARKET_REGISTRY");
        addrs.feesManager = vm.envAddress("FEES_MANAGER");
        addrs.insuranceFund = vm.envAddress("INSURANCE_FUND");
    }

    function _readCoreParams() internal view returns (CoreParams memory params) {
        params.baseToken = vm.envAddress("BASE_COLLATERAL_TOKEN");
        params.baseDecimals = _toUint8(vm.envOr("BASE_COLLATERAL_DECIMALS", uint256(6)), "base decimals");
        if (uint256(params.baseDecimals) > MAX_POW10_EXP) revert("base decimals too large");
        params.baseMaintenanceMarginPerContractBase = vm.envOr(
            "BASE_MAINTENANCE_MARGIN_PER_CONTRACT_BASE",
            DEFAULT_BASE_MM_UNITS * (10 ** uint256(params.baseDecimals))
        );
        params.imFactorBps = vm.envOr("IM_FACTOR_BPS", uint256(12_000));
        params.oracleDownMmMultiplierBps = vm.envOr("ORACLE_DOWN_MM_MULTIPLIER_BPS", uint256(20_000));
        params.riskMaxOracleDelay = vm.envOr("RISK_MAX_ORACLE_DELAY", uint256(600));
        params.perpRiskMaxOracleDelay = vm.envOr("PERP_RISK_MAX_ORACLE_DELAY", uint256(600));
        params.collateralRestrictionMode = vm.envOr("COLLATERAL_RESTRICTION_MODE", true);
        params.allowAllCollateralAsSettlementAssets = vm.envOr("ALLOW_COLLATERAL_AS_SETTLEMENT_ASSETS", false);
        params.feeBpsCap = _toUint16(vm.envOr("FEE_BPS_CAP", uint256(100)), "fee cap");
        params.makerNotionalFeeBps = _toUint16(vm.envOr("DEFAULT_MAKER_NOTIONAL_FEE_BPS", uint256(2)), "maker notional fee");
        params.makerPremiumCapBps = _toUint16(vm.envOr("DEFAULT_MAKER_PREMIUM_CAP_BPS", uint256(4)), "maker premium cap");
        params.takerNotionalFeeBps = _toUint16(vm.envOr("DEFAULT_TAKER_NOTIONAL_FEE_BPS", uint256(5)), "taker notional fee");
        params.takerPremiumCapBps = _toUint16(vm.envOr("DEFAULT_TAKER_PREMIUM_CAP_BPS", uint256(6)), "taker premium cap");

        if (params.baseToken == address(0)) revert("base token zero");
        if (params.baseDecimals == 0) revert("base decimals zero");
        if (params.imFactorBps < BPS) revert("im factor too low");
    }

    function _readCollateralParams(CoreParams memory params)
        internal
        view
        returns (CollateralParams memory collateral)
    {
        collateral.tokens = _envAddressArrayOr("COLLATERAL_TOKENS");
        if (collateral.tokens.length == 0) {
            collateral.tokens = new address[](1);
            collateral.tokens[0] = params.baseToken;
        }
        _requireIncludesBase(collateral.tokens, params.baseToken);

        uint256 len = collateral.tokens.length;
        collateral.decimals = _readUintArray("COLLATERAL_DECIMALS", len, _baseOnlyArray(len, params.baseDecimals));
        collateral.riskWeightsBps = _readUintArray("COLLATERAL_WEIGHTS_BPS", len, _baseOnlyArray(len, BPS));
        collateral.vaultFactorsBps =
            _readUintArray("COLLATERAL_FACTORS_BPS", len, collateral.riskWeightsBps);
        collateral.depositCaps = _readUintArray("COLLATERAL_DEPOSIT_CAPS", len, new uint256[](len));
        collateral.launchActive = _readBoolArray("COLLATERAL_LAUNCH_ACTIVE", len, _baseOnlyBoolArray(len));
        collateral.riskEnabled = _readBoolArray("COLLATERAL_RISK_ENABLED", len, _allTrueBoolArray(len));
        collateral.insuranceAllowed = _readBoolArray("INSURANCE_TOKEN_ALLOWED", len, _allTrueBoolArray(len));

        for (uint256 i = 0; i < len; i++) {
            address token = collateral.tokens[i];
            if (token == address(0)) revert("collateral token zero");
            if (collateral.decimals[i] == 0) revert("collateral decimals zero");
            if (collateral.decimals[i] > MAX_POW10_EXP) revert("collateral decimals too large");
            if (collateral.vaultFactorsBps[i] > BPS) revert("vault factor > bps");
            if (collateral.riskWeightsBps[i] > BPS) revert("risk weight > bps");

            if (token == params.baseToken) {
                if (collateral.decimals[i] != uint256(params.baseDecimals)) revert("base decimals mismatch");
                if (collateral.vaultFactorsBps[i] != BPS) revert("base vault factor must be 100%");
                if (collateral.riskWeightsBps[i] != BPS) revert("base risk weight must be 100%");
                if (!collateral.riskEnabled[i]) revert("base risk disabled");
                if (!collateral.launchActive[i]) revert("base launch inactive");
            }
        }
    }

    function _configureVault(address vault_, CoreParams memory params, CollateralParams memory collateral) internal {
        CollateralVault vault = CollateralVault(vault_);
        uint256 len = collateral.tokens.length;

        for (uint256 i = 0; i < len; i++) {
            vault.setCollateralToken(
                collateral.tokens[i],
                true,
                _toUint8(collateral.decimals[i], "collateral decimals"),
                _toUint16(collateral.vaultFactorsBps[i], "vault factor")
            );
            vault.setTokenDepositCap(collateral.tokens[i], collateral.depositCaps[i]);
            vault.setLaunchActiveCollateral(collateral.tokens[i], collateral.launchActive[i]);
        }

        vault.setCollateralRestrictionMode(params.collateralRestrictionMode);
    }

    function _configureRisk(
        address riskModule_,
        address perpRiskModule_,
        CoreParams memory params,
        CollateralParams memory collateral
    ) internal {
        RiskModule risk = RiskModule(riskModule_);
        risk.setRiskParams(params.baseToken, params.baseMaintenanceMarginPerContractBase, params.imFactorBps);
        risk.setOracleDownMmMultiplier(params.oracleDownMmMultiplierBps);
        risk.setMaxOracleDelay(params.riskMaxOracleDelay);

        uint256 len = collateral.tokens.length;
        for (uint256 i = 0; i < len; i++) {
            risk.setCollateralConfig(
                collateral.tokens[i],
                _toUint64(collateral.riskWeightsBps[i], "risk weight"),
                collateral.riskEnabled[i]
            );
        }
        risk.syncCollateralTokensFromVault();

        PerpRiskModule perpRisk = PerpRiskModule(perpRiskModule_);
        perpRisk.setBaseCollateralToken(params.baseToken);
        perpRisk.setMaxOracleDelay(params.perpRiskMaxOracleDelay);
    }

    function _configureRegistries(
        address optionRegistry_,
        address perpRegistry_,
        CoreParams memory params,
        CollateralParams memory collateral
    ) internal {
        OptionProductRegistry optionRegistry = OptionProductRegistry(optionRegistry_);
        PerpMarketRegistry perpRegistry = PerpMarketRegistry(perpRegistry_);

        optionRegistry.setSettlementAssetAllowed(params.baseToken, true);
        perpRegistry.setSettlementAssetAllowed(params.baseToken, true);

        if (!params.allowAllCollateralAsSettlementAssets) return;

        uint256 len = collateral.tokens.length;
        for (uint256 i = 0; i < len; i++) {
            optionRegistry.setSettlementAssetAllowed(collateral.tokens[i], true);
            perpRegistry.setSettlementAssetAllowed(collateral.tokens[i], true);
        }
    }

    function _configureMarginEngine(address marginEngine_, CoreParams memory params) internal {
        MarginEngine(marginEngine_).setRiskParams(
            params.baseToken,
            params.baseMaintenanceMarginPerContractBase,
            params.imFactorBps
        );
    }

    function _configureFees(address feesManager_, CoreParams memory params) internal {
        FeesManager fees = FeesManager(feesManager_);
        fees.setFeeBpsCap(params.feeBpsCap);
        fees.setDefaultFees(
            params.makerNotionalFeeBps,
            params.makerPremiumCapBps,
            params.takerNotionalFeeBps,
            params.takerPremiumCapBps
        );
    }

    function _configureInsurance(address insuranceFund_, CollateralParams memory collateral) internal {
        InsuranceFund fund = InsuranceFund(insuranceFund_);
        uint256 len = collateral.tokens.length;

        for (uint256 i = 0; i < len; i++) {
            fund.setTokenAllowed(collateral.tokens[i], collateral.insuranceAllowed[i]);
        }

        address[] memory operators = _envAddressArrayOr("INSURANCE_OPERATORS");
        for (uint256 i = 0; i < operators.length; i++) {
            if (operators[i] == address(0)) revert("insurance operator zero");
            fund.setOperator(operators[i], true);
        }
    }

    function _requireDeployed(CoreAddresses memory addrs) internal view {
        _requireContract("COLLATERAL_VAULT", addrs.collateralVault);
        _requireContract("RISK_MODULE", addrs.riskModule);
        _requireContract("PERP_RISK_MODULE", addrs.perpRiskModule);
        _requireContract("MARGIN_ENGINE", addrs.marginEngine);
        _requireContract("OPTION_PRODUCT_REGISTRY", addrs.optionProductRegistry);
        _requireContract("PERP_MARKET_REGISTRY", addrs.perpMarketRegistry);
        _requireContract("FEES_MANAGER", addrs.feesManager);
        _requireContract("INSURANCE_FUND", addrs.insuranceFund);
    }

    function _requireContract(string memory name, address target) internal view {
        if (target == address(0)) revert(string.concat(name, " zero"));
        if (target.code.length == 0) revert(string.concat(name, " no code"));
    }

    function _envAddressArrayOr(string memory name) internal view returns (address[] memory value) {
        if (!vm.envExists(name)) return new address[](0);
        return vm.envAddress(name, DELIM);
    }

    function _envUintArrayOr(string memory name) internal view returns (uint256[] memory value) {
        if (!vm.envExists(name)) return new uint256[](0);
        return vm.envUint(name, DELIM);
    }

    function _envBoolArrayOr(string memory name) internal view returns (bool[] memory value) {
        if (!vm.envExists(name)) return new bool[](0);
        return vm.envBool(name, DELIM);
    }

    function _readUintArray(string memory name, uint256 expectedLen, uint256[] memory defaults)
        internal
        view
        returns (uint256[] memory values)
    {
        values = _envUintArrayOr(name);
        if (values.length == 0) return defaults;
        if (values.length != expectedLen) revert(string.concat(name, " length mismatch"));
    }

    function _readBoolArray(string memory name, uint256 expectedLen, bool[] memory defaults)
        internal
        view
        returns (bool[] memory values)
    {
        values = _envBoolArrayOr(name);
        if (values.length == 0) return defaults;
        if (values.length != expectedLen) revert(string.concat(name, " length mismatch"));
    }

    function _baseOnlyArray(uint256 len, uint256 baseValue) internal pure returns (uint256[] memory values) {
        values = new uint256[](len);
        if (len != 0) values[0] = baseValue;
    }

    function _baseOnlyBoolArray(uint256 len) internal pure returns (bool[] memory values) {
        values = new bool[](len);
        if (len != 0) values[0] = true;
    }

    function _allTrueBoolArray(uint256 len) internal pure returns (bool[] memory values) {
        values = new bool[](len);
        for (uint256 i = 0; i < len; i++) {
            values[i] = true;
        }
    }

    function _requireIncludesBase(address[] memory tokens, address baseToken) internal pure {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == baseToken) return;
        }
        revert("collateral tokens omit base");
    }

    function _toUint8(uint256 value, string memory label) internal pure returns (uint8) {
        if (value > type(uint8).max) revert(string.concat(label, " uint8 overflow"));
        return uint8(value);
    }

    function _toUint16(uint256 value, string memory label) internal pure returns (uint16) {
        if (value > type(uint16).max) revert(string.concat(label, " uint16 overflow"));
        return uint16(value);
    }

    function _toUint64(uint256 value, string memory label) internal pure returns (uint64) {
        if (value > type(uint64).max) revert(string.concat(label, " uint64 overflow"));
        return uint64(value);
    }

    function _logConfiguration(
        address caller,
        CoreParams memory params,
        CollateralParams memory collateral
    ) internal view {
        console2.log("DeOpt v2 core configuration");
        console2.log("chainId", block.chainid);
        console2.log("caller", caller);
        console2.log("baseCollateralToken", params.baseToken);
        console2.log("baseDecimals", params.baseDecimals);
        console2.log("baseMaintenanceMarginPerContractBase", params.baseMaintenanceMarginPerContractBase);
        console2.log("imFactorBps", params.imFactorBps);
        console2.log("oracleDownMmMultiplierBps", params.oracleDownMmMultiplierBps);
        console2.log("collateralRestrictionMode", params.collateralRestrictionMode);
        console2.log("configuredCollateralTokens", collateral.tokens.length);
    }
}
