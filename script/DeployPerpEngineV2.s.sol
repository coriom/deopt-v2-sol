// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpEngine} from "../src/perp/PerpEngine.sol";

/// @title DeployPerpEngineV2
/// @notice Safe-by-default deployment preflight for a fresh, FeesManagerV2-compatible PerpEngine
///         on Base Sepolia (V2F-D).
/// @dev
///  V2F-C confirmed:
///   - the live PerpEngine at `0xB36395b67D0798ADA981731c9Fa5239F4362b53B` does not expose the V2
///     fee surface (`feesManagerV2()` / `useFeesManagerV2()`);
///   - the new V2F-C PerpEngine bytecode is 23,794 runtime bytes, below the EIP-170 limit;
///   - the new bytecode links the external library `PerpEngineSeizureLib`. Foundry's `new` syntax
///     auto-deploys and links that library before constructing the engine. Its address shows up in
///     the broadcast log and must be recorded in the deployment manifest.
///
///  This script:
///   - aborts unless `DEPLOY_PERP_ENGINE_V2_CONFIRM=true`;
///   - never enables `useFeesManagerV2` (the constructor leaves it `false` and this script does not
///     flip it; `FeesManagerV2` wiring is the exclusive responsibility of
///     `script/WireFeesManagerV2Perp.s.sol`);
///   - never touches the live PerpMatchingEngine, PerpRiskModule, CollateralVault, InsuranceFund,
///     or any other external dependent. Rewiring is the exclusive responsibility of
///     `script/RewirePerpEngineV2.s.sol`, and only after Strategy A drain invariants are met on
///     the old engine;
///   - never prints the private key (only the derived deployer address);
///   - aborts if any required address is `address(0)` or has no code on the target chain.
///
///  Required env when `DEPLOY_PERP_ENGINE_V2_CONFIRM=true`:
///    - `DEPLOYER_PRIVATE_KEY`
///    - `INITIAL_OWNER` (optional, defaults to deployer)
///    - `INITIAL_GUARDIAN` (optional, defaults to initialOwner)
///    - `PERP_MARKET_REGISTRY`
///    - `COLLATERAL_VAULT`
///    - `ORACLE_ROUTER`
///    - `PERP_MATCHING_ENGINE`
///    - `PERP_RISK_MODULE`
///    - `INSURANCE_FUND`
///    - `FEES_MANAGER_V1`
///    - `COLLATERAL_SEIZER` (optional, skipped if zero)
contract DeployPerpEngineV2 is Script {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    struct DeployInputs {
        address deployer;
        address initialOwner;
        address initialGuardian;
        address perpMarketRegistry;
        address collateralVault;
        address oracleRouter;
        address perpMatchingEngine;
        address perpRiskModule;
        address insuranceFund;
        address feesManagerV1;
        address collateralSeizer;
        bool deployConfirmed;
    }

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error InitialOwnerUnset();
    error InitialGuardianUnset();
    error PerpMarketRegistryUnset();
    error CollateralVaultUnset();
    error OracleRouterUnset();
    error PerpMatchingEngineUnset();
    error PerpRiskModuleUnset();
    error InsuranceFundUnset();
    error FeesManagerV1Unset();
    error NoCodeAt(string name, address target);

    error PostDeployOwnerMismatch(address expected, address actual);
    error PostDeployUseFeesManagerV2NotFalse();
    error PostDeployFeesManagerV2NotZero();
    error PostDeployMatchingEngineMismatch(address expected, address actual);
    error PostDeployRiskModuleMismatch(address expected, address actual);
    error PostDeployInsuranceFundMismatch(address expected, address actual);
    error PostDeployFeesManagerV1Mismatch(address expected, address actual);

    /*//////////////////////////////////////////////////////////////
                                   RUN
    //////////////////////////////////////////////////////////////*/

    function run() external returns (address newPerpEngine) {
        DeployInputs memory inputs = _readInputs();
        _validateInputs(inputs);
        _logSanitizedConfig(inputs);

        if (!inputs.deployConfirmed) {
            console2.log("DEPLOY_PERP_ENGINE_V2_CONFIRM is not set to true; aborting deployment.");
            console2.log("This was a sanitized preflight only. No contract was deployed.");
            return address(0);
        }

        newPerpEngine = _broadcastDeployAndWire(inputs);
        _verifyPostDeployState(newPerpEngine, inputs);
        return newPerpEngine;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _readInputs() internal view returns (DeployInputs memory inputs) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        inputs.deployer = vm.addr(deployerPk);
        inputs.initialOwner = vm.envOr("INITIAL_OWNER", inputs.deployer);
        inputs.initialGuardian = vm.envOr("INITIAL_GUARDIAN", inputs.initialOwner);

        inputs.perpMarketRegistry = _envAddressOrZero("PERP_MARKET_REGISTRY");
        inputs.collateralVault = _envAddressOrZero("COLLATERAL_VAULT");
        inputs.oracleRouter = _envAddressOrZero("ORACLE_ROUTER");
        inputs.perpMatchingEngine = _envAddressOrZero("PERP_MATCHING_ENGINE");
        inputs.perpRiskModule = _envAddressOrZero("PERP_RISK_MODULE");
        inputs.insuranceFund = _envAddressOrZero("INSURANCE_FUND");
        inputs.feesManagerV1 = _envAddressOrZero("FEES_MANAGER_V1");
        inputs.collateralSeizer = _envAddressOrZero("COLLATERAL_SEIZER");

        inputs.deployConfirmed = vm.envOr("DEPLOY_PERP_ENGINE_V2_CONFIRM", false);
    }

    function _validateInputs(DeployInputs memory inputs) internal view {
        if (inputs.initialOwner == address(0)) revert InitialOwnerUnset();
        if (inputs.initialGuardian == address(0)) revert InitialGuardianUnset();
        if (inputs.perpMarketRegistry == address(0)) revert PerpMarketRegistryUnset();
        if (inputs.collateralVault == address(0)) revert CollateralVaultUnset();
        if (inputs.oracleRouter == address(0)) revert OracleRouterUnset();
        if (inputs.perpMatchingEngine == address(0)) revert PerpMatchingEngineUnset();
        if (inputs.perpRiskModule == address(0)) revert PerpRiskModuleUnset();
        if (inputs.insuranceFund == address(0)) revert InsuranceFundUnset();
        if (inputs.feesManagerV1 == address(0)) revert FeesManagerV1Unset();

        _requireCode("PERP_MARKET_REGISTRY", inputs.perpMarketRegistry);
        _requireCode("COLLATERAL_VAULT", inputs.collateralVault);
        _requireCode("ORACLE_ROUTER", inputs.oracleRouter);
        _requireCode("PERP_MATCHING_ENGINE", inputs.perpMatchingEngine);
        _requireCode("PERP_RISK_MODULE", inputs.perpRiskModule);
        _requireCode("INSURANCE_FUND", inputs.insuranceFund);
        _requireCode("FEES_MANAGER_V1", inputs.feesManagerV1);

        if (inputs.collateralSeizer != address(0)) {
            _requireCode("COLLATERAL_SEIZER", inputs.collateralSeizer);
        }
    }

    function _broadcastDeployAndWire(DeployInputs memory inputs) internal returns (address newPerpEngine) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerPk);

        // Foundry auto-deploys the linked `PerpEngineSeizureLib` before this `new` call and
        // patches the placeholder. The library address is visible in the broadcast log and
        // must be recorded in the deployment manifest.
        PerpEngine engine =
            new PerpEngine(inputs.initialOwner, inputs.perpMarketRegistry, inputs.collateralVault, inputs.oracleRouter);

        // Internal wiring only. Mirrors WireCore._wireEngines for the perp branch, minus
        // FeesManagerV2 — V2 wiring/enable is gated behind separate confirmation flags in
        // `script/WireFeesManagerV2Perp.s.sol` and stays off here.
        engine.setGuardian(inputs.initialGuardian);
        engine.setMatchingEngine(inputs.perpMatchingEngine);
        engine.setRiskModule(inputs.perpRiskModule);
        engine.setInsuranceFund(inputs.insuranceFund);
        engine.setFeesManager(inputs.feesManagerV1);

        if (inputs.collateralSeizer != address(0)) {
            engine.setCollateralSeizer(inputs.collateralSeizer);
        }

        vm.stopBroadcast();

        newPerpEngine = address(engine);
    }

    function _verifyPostDeployState(address newPerpEngine, DeployInputs memory inputs) internal view {
        PerpEngine engine = PerpEngine(newPerpEngine);

        if (engine.owner() != inputs.initialOwner) {
            revert PostDeployOwnerMismatch(inputs.initialOwner, engine.owner());
        }

        // Hard invariant: V2 fees stay disabled and unconfigured on every deploy.
        if (engine.useFeesManagerV2()) revert PostDeployUseFeesManagerV2NotFalse();
        if (address(engine.feesManagerV2()) != address(0)) revert PostDeployFeesManagerV2NotZero();

        if (engine.matchingEngine() != inputs.perpMatchingEngine) {
            revert PostDeployMatchingEngineMismatch(inputs.perpMatchingEngine, engine.matchingEngine());
        }
        if (engine.riskModule() != inputs.perpRiskModule) {
            revert PostDeployRiskModuleMismatch(inputs.perpRiskModule, engine.riskModule());
        }
        if (engine.insuranceFund() != inputs.insuranceFund) {
            revert PostDeployInsuranceFundMismatch(inputs.insuranceFund, engine.insuranceFund());
        }
        if (address(engine.feesManager()) != inputs.feesManagerV1) {
            revert PostDeployFeesManagerV1Mismatch(inputs.feesManagerV1, address(engine.feesManager()));
        }

        console2.log("PerpEngineV2 deployed (FeesManagerV2-compatible bytecode, V2 still disabled)");
        console2.log("PerpEngineV2 address", newPerpEngine);
        console2.log(" runtime bytecode (bytes)", newPerpEngine.code.length);
        console2.log(" owner()", engine.owner());
        console2.log(" guardian()", engine.guardian());
        console2.log(" matchingEngine()", engine.matchingEngine());
        console2.log(" riskModule()", engine.riskModule());
        console2.log(" insuranceFund()", engine.insuranceFund());
        console2.log(" feesManager() [V1]", address(engine.feesManager()));
        console2.log(" feesManagerV2() [V2]", address(engine.feesManagerV2()));
        console2.log(" useFeesManagerV2()", engine.useFeesManagerV2());
        console2.log(" collateralSeizer()", engine.collateralSeizer());
        console2.log(
            "NOTE: PerpEngineSeizureLib was auto-deployed and linked by Foundry. Check the broadcast log for its address and add it to the deployment manifest."
        );
    }

    function _logSanitizedConfig(DeployInputs memory inputs) internal view {
        console2.log("PerpEngineV2 deployment preflight V2F-D");
        console2.log("chainId", block.chainid);
        console2.log("deployer (sanitized, no key)", inputs.deployer);
        console2.log("initialOwner", inputs.initialOwner);
        console2.log("initialGuardian", inputs.initialGuardian);
        console2.log("perpMarketRegistry", inputs.perpMarketRegistry);
        console2.log("collateralVault", inputs.collateralVault);
        console2.log("oracleRouter", inputs.oracleRouter);
        console2.log("perpMatchingEngine", inputs.perpMatchingEngine);
        console2.log("perpRiskModule", inputs.perpRiskModule);
        console2.log("insuranceFund", inputs.insuranceFund);
        console2.log("feesManagerV1", inputs.feesManagerV1);
        console2.log("collateralSeizer", inputs.collateralSeizer);
        console2.log("DEPLOY_PERP_ENGINE_V2_CONFIRM", inputs.deployConfirmed);
    }

    function _requireCode(string memory name, address target) internal view {
        if (target.code.length == 0) revert NoCodeAt(name, target);
    }

    function _envAddressOrZero(string memory name) internal view returns (address) {
        if (!vm.envExists(name)) return address(0);
        return vm.envAddress(name);
    }
}
