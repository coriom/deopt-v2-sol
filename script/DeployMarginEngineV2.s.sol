// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {MarginEngine} from "../src/margin/MarginEngine.sol";

/// @title DeployMarginEngineV2
/// @notice Safe-by-default deployment preflight for a fresh, FeesManagerV2-compatible MarginEngine
///         on Base Sepolia (V2D-L).
/// @dev
///  V2D-K confirmed the live MarginEngine at `0x6c5665de…5b5F8` is non-upgradeable and predates V2D-D.
///  This script deploys a new MarginEngine from the current `src/margin/MarginEngine.sol` build (which
///  includes V2D-D storage, getters, and setters) and runs the same owner-only internal wiring sequence
///  that `script/WireCore.s.sol` already uses for a fresh deployment, but does NOT touch any external
///  dependent (CollateralVault, RiskModule, MatchingEngine, OptionMatchingEngine, InsuranceFund, or
///  RiskGovernor). External rewiring is the exclusive responsibility of
///  `script/RewireMarginEngineV2.s.sol`.
///
///  Hard rules enforced at runtime:
///    - aborts unless `DEPLOY_MARGIN_ENGINE_V2_CONFIRM=true`;
///    - never enables `useFeesManagerV2` (the constructor leaves it `false` and this script does not flip it);
///    - never touches `FeesManagerV2`, perps, or any external dependent;
///    - never prints the private key (only the derived deployer address);
///    - aborts if any required address is `address(0)` or has no code on the target chain.
contract DeployMarginEngineV2 is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct DeployInputs {
        address deployer;
        address initialOwner;
        address initialGuardian;
        address optionProductRegistry;
        address collateralVault;
        address oracleRouter;
        address feesManagerV1;
        address insuranceFund;
        address riskModule;
        address optionMatchingEngine;
        uint256 liquidationThresholdBps;
        uint256 liquidationPenaltyBps;
        uint256 liquidationCloseFactorBps;
        uint256 minLiquidationImprovementBps;
        uint256 liquidationPriceSpreadBps;
        uint256 minLiquidationPriceBpsOfIntrinsic;
        uint32 liquidationOracleMaxDelay;
        bool deployConfirmed;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error InitialOwnerUnset();
    error InitialGuardianUnset();
    error OptionProductRegistryUnset();
    error CollateralVaultUnset();
    error OracleRouterUnset();
    error FeesManagerV1Unset();
    error InsuranceFundUnset();
    error RiskModuleUnset();
    error OptionMatchingEngineUnset();
    error NoCodeAt(string name, address target);
    error PostDeployOwnerMismatch(address expected, address actual);
    error PostDeployUseFeesManagerV2NotFalse();
    error PostDeployFeesManagerV2NotZero();

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external returns (address newMarginEngine) {
        DeployInputs memory inputs = _readInputs();
        _validateInputs(inputs);
        _logSanitizedConfig(inputs);

        if (!inputs.deployConfirmed) {
            console2.log("DEPLOY_MARGIN_ENGINE_V2_CONFIRM is not set to true; aborting deployment.");
            console2.log("This was a sanitized preflight only. No contract was deployed.");
            return address(0);
        }

        newMarginEngine = _broadcastDeployAndWire(inputs);
        _verifyPostDeployState(newMarginEngine, inputs);
        return newMarginEngine;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (DeployInputs memory inputs) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.deployer = vm.addr(deployerPk);
        inputs.initialOwner = vm.envOr("INITIAL_OWNER", inputs.deployer);
        inputs.initialGuardian = vm.envOr("INITIAL_GUARDIAN", inputs.initialOwner);

        inputs.optionProductRegistry = _envAddressOrZero("OPTION_PRODUCT_REGISTRY");
        inputs.collateralVault = _envAddressOrZero("COLLATERAL_VAULT");
        inputs.oracleRouter = _envAddressOrZero("ORACLE_ROUTER");
        inputs.feesManagerV1 = _envAddressOrZero("FEES_MANAGER_V1");
        inputs.insuranceFund = _envAddressOrZero("INSURANCE_FUND");
        inputs.riskModule = _envAddressOrZero("RISK_MODULE");
        inputs.optionMatchingEngine = _envAddressOrZero("OPTION_MATCHING_ENGINE");

        // Liquidation params default to the values WireCore/ConfigureCore use unless overridden.
        inputs.liquidationThresholdBps = vm.envOr("LIQUIDATION_THRESHOLD_BPS", uint256(10_050));
        inputs.liquidationPenaltyBps = vm.envOr("LIQUIDATION_PENALTY_BPS", uint256(500));
        inputs.liquidationCloseFactorBps = vm.envOr("LIQUIDATION_CLOSE_FACTOR_BPS", uint256(10_000));
        inputs.minLiquidationImprovementBps = vm.envOr("MIN_LIQUIDATION_IMPROVEMENT_BPS", uint256(1));
        inputs.liquidationPriceSpreadBps = vm.envOr("LIQUIDATION_PRICE_SPREAD_BPS", uint256(0));
        inputs.minLiquidationPriceBpsOfIntrinsic = vm.envOr("MIN_LIQUIDATION_PRICE_BPS_OF_INTRINSIC", uint256(0));
        inputs.liquidationOracleMaxDelay = uint32(vm.envOr("LIQUIDATION_ORACLE_MAX_DELAY", uint256(600)));

        inputs.deployConfirmed = vm.envOr("DEPLOY_MARGIN_ENGINE_V2_CONFIRM", false);
    }

    function _validateInputs(DeployInputs memory inputs) internal view {
        if (inputs.initialOwner == address(0)) revert InitialOwnerUnset();
        if (inputs.initialGuardian == address(0)) revert InitialGuardianUnset();
        if (inputs.optionProductRegistry == address(0)) revert OptionProductRegistryUnset();
        if (inputs.collateralVault == address(0)) revert CollateralVaultUnset();
        if (inputs.oracleRouter == address(0)) revert OracleRouterUnset();
        if (inputs.feesManagerV1 == address(0)) revert FeesManagerV1Unset();
        if (inputs.insuranceFund == address(0)) revert InsuranceFundUnset();
        if (inputs.riskModule == address(0)) revert RiskModuleUnset();
        if (inputs.optionMatchingEngine == address(0)) revert OptionMatchingEngineUnset();

        _requireCode("OPTION_PRODUCT_REGISTRY", inputs.optionProductRegistry);
        _requireCode("COLLATERAL_VAULT", inputs.collateralVault);
        _requireCode("ORACLE_ROUTER", inputs.oracleRouter);
        _requireCode("FEES_MANAGER_V1", inputs.feesManagerV1);
        _requireCode("INSURANCE_FUND", inputs.insuranceFund);
        _requireCode("RISK_MODULE", inputs.riskModule);
        _requireCode("OPTION_MATCHING_ENGINE", inputs.optionMatchingEngine);
    }

    function _broadcastDeployAndWire(DeployInputs memory inputs) internal returns (address newMarginEngine) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        // Constructor: owner / option product registry / collateral vault / oracle.
        MarginEngine engine = new MarginEngine(
            inputs.initialOwner, inputs.optionProductRegistry, inputs.collateralVault, inputs.oracleRouter
        );

        // Internal wiring only. Must match WireCore._wireEngines so the new engine is functionally
        // equivalent to a fresh DeployCore + WireCore output, minus FeesManagerV2.
        engine.setGuardian(inputs.initialGuardian);
        engine.setMatchingEngine(inputs.optionMatchingEngine);
        engine.setRiskModule(inputs.riskModule);
        engine.setInsuranceFund(inputs.insuranceFund);
        engine.setFeesManager(inputs.feesManagerV1);
        engine.syncRiskParamsFromRiskModule();
        engine.setLiquidationParams(inputs.liquidationThresholdBps, inputs.liquidationPenaltyBps);
        engine.setLiquidationHardenParams(inputs.liquidationCloseFactorBps, inputs.minLiquidationImprovementBps);
        engine.setLiquidationPricingParams(inputs.liquidationPriceSpreadBps, inputs.minLiquidationPriceBpsOfIntrinsic);
        engine.setLiquidationOracleMaxDelay(inputs.liquidationOracleMaxDelay);

        vm.stopBroadcast();

        newMarginEngine = address(engine);
    }

    function _verifyPostDeployState(address newMarginEngine, DeployInputs memory inputs) internal view {
        MarginEngine engine = MarginEngine(newMarginEngine);

        if (engine.owner() != inputs.initialOwner) {
            revert PostDeployOwnerMismatch(inputs.initialOwner, engine.owner());
        }
        if (engine.useFeesManagerV2()) revert PostDeployUseFeesManagerV2NotFalse();
        if (address(engine.feesManagerV2()) != address(0)) revert PostDeployFeesManagerV2NotZero();

        console2.log("MarginEngineV2 deployed (FeesManagerV2-compatible bytecode, V2 still disabled)");
        console2.log("MarginEngineV2 address", newMarginEngine);
        console2.log(" owner()", engine.owner());
        console2.log(" guardian()", engine.guardian());
        console2.log(" feesManager() [V1]", address(engine.feesManager()));
        console2.log(" feesManagerV2() [V2]", address(engine.feesManagerV2()));
        console2.log(" useFeesManagerV2()", engine.useFeesManagerV2());
        console2.log(" matchingEngine()", engine.matchingEngine());
        console2.log(" insuranceFund()", engine.insuranceFund());
    }

    function _logSanitizedConfig(DeployInputs memory inputs) internal view {
        console2.log("MarginEngineV2 deployment preflight V2D-L");
        console2.log("chainId", block.chainid);
        console2.log("deployer (sanitized, no key)", inputs.deployer);
        console2.log("initialOwner", inputs.initialOwner);
        console2.log("initialGuardian", inputs.initialGuardian);
        console2.log("optionProductRegistry", inputs.optionProductRegistry);
        console2.log("collateralVault", inputs.collateralVault);
        console2.log("oracleRouter", inputs.oracleRouter);
        console2.log("feesManagerV1", inputs.feesManagerV1);
        console2.log("insuranceFund", inputs.insuranceFund);
        console2.log("riskModule", inputs.riskModule);
        console2.log("optionMatchingEngine", inputs.optionMatchingEngine);
        console2.log("liquidationThresholdBps", inputs.liquidationThresholdBps);
        console2.log("liquidationPenaltyBps", inputs.liquidationPenaltyBps);
        console2.log("DEPLOY_MARGIN_ENGINE_V2_CONFIRM", inputs.deployConfirmed);
    }

    function _requireCode(string memory name, address target) internal view {
        if (target.code.length == 0) revert NoCodeAt(name, target);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
