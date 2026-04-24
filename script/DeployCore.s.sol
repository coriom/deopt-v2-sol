// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {FeesManager} from "../src/fees/FeesManager.sol";
import {ProtocolTimelock} from "../src/gouvernance/ProtocolTimelock.sol";
import {RiskGovernor} from "../src/gouvernance/RiskGovernor.sol";
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

/// @notice First-pass core deployment script for DeOpt v2.
/// @dev This script deploys contracts only. Post-deploy wiring/configuration is intentionally deferred.
contract DeployCore is Script {
    struct CoreDeployments {
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
    }

    uint256 internal constant DEFAULT_TIMELOCK_MIN_DELAY = 2 days;

    function run() external returns (CoreDeployments memory deployments) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address initialOwner = vm.envOr("INITIAL_OWNER", deployer);
        address initialGuardian = vm.envOr("INITIAL_GUARDIAN", initialOwner);
        address baseCollateralToken = vm.envAddress("BASE_COLLATERAL_TOKEN");
        uint256 timelockMinDelay = vm.envOr("TIMELOCK_MIN_DELAY", DEFAULT_TIMELOCK_MIN_DELAY);

        uint16 makerNotionalFeeBps = _envUint16("DEFAULT_MAKER_NOTIONAL_FEE_BPS", 2);
        uint16 makerPremiumCapBps = _envUint16("DEFAULT_MAKER_PREMIUM_CAP_BPS", 4);
        uint16 takerNotionalFeeBps = _envUint16("DEFAULT_TAKER_NOTIONAL_FEE_BPS", 5);
        uint16 takerPremiumCapBps = _envUint16("DEFAULT_TAKER_PREMIUM_CAP_BPS", 6);
        uint16 feeBpsCap = _envUint16("FEE_BPS_CAP", 100);

        vm.startBroadcast(deployerPrivateKey);

        deployments.collateralVault = address(new CollateralVault(initialOwner));
        deployments.oracleRouter = address(new OracleRouter(initialOwner));

        // RiskModule requires registry and margin engine constructor dependencies, so deploy them first.
        deployments.optionProductRegistry = address(new OptionProductRegistry(initialOwner));
        deployments.marginEngine = address(
            new MarginEngine(
                initialOwner,
                deployments.optionProductRegistry,
                deployments.collateralVault,
                deployments.oracleRouter
            )
        );
        deployments.riskModule = address(
            new RiskModule(
                initialOwner,
                deployments.collateralVault,
                deployments.optionProductRegistry,
                deployments.marginEngine,
                deployments.oracleRouter
            )
        );

        deployments.perpMarketRegistry = address(new PerpMarketRegistry(initialOwner));
        deployments.perpEngine = address(
            new PerpEngine(
                initialOwner,
                deployments.perpMarketRegistry,
                deployments.collateralVault,
                deployments.oracleRouter
            )
        );
        deployments.perpRiskModule = address(
            new PerpRiskModule(
                initialOwner,
                deployments.collateralVault,
                deployments.perpEngine,
                deployments.oracleRouter,
                baseCollateralToken
            )
        );
        deployments.collateralSeizer = address(
            new CollateralSeizer(
                initialOwner,
                deployments.collateralVault,
                deployments.oracleRouter,
                deployments.riskModule
            )
        );

        deployments.feesManager = address(
            new FeesManager(
                initialOwner,
                makerNotionalFeeBps,
                makerPremiumCapBps,
                takerNotionalFeeBps,
                takerPremiumCapBps,
                feeBpsCap
            )
        );
        deployments.insuranceFund = address(new InsuranceFund(initialOwner, deployments.collateralVault));

        deployments.matchingEngine = address(new MatchingEngine(initialOwner, deployments.marginEngine));
        deployments.perpMatchingEngine = address(new PerpMatchingEngine(initialOwner, deployments.perpEngine));

        deployments.protocolTimelock =
            address(new ProtocolTimelock(initialOwner, initialGuardian, timelockMinDelay));
        deployments.riskGovernor = address(
            new RiskGovernor(
                initialOwner,
                initialGuardian,
                deployments.protocolTimelock,
                deployments.riskModule,
                deployments.marginEngine,
                deployments.oracleRouter,
                deployments.feesManager,
                deployments.optionProductRegistry,
                deployments.collateralVault,
                deployments.insuranceFund,
                deployments.perpMarketRegistry,
                deployments.perpEngine
            )
        );

        vm.stopBroadcast();

        _logInputs(deployer, initialOwner, initialGuardian, baseCollateralToken, timelockMinDelay);
        _logDeployments(deployments);
    }

    function _envUint16(string memory name, uint16 defaultValue) internal view returns (uint16) {
        uint256 value = vm.envOr(name, uint256(defaultValue));
        require(value <= type(uint16).max, "uint16 env overflow");
        return uint16(value);
    }

    function _logInputs(
        address deployer,
        address initialOwner,
        address initialGuardian,
        address baseCollateralToken,
        uint256 timelockMinDelay
    ) internal view {
        console2.log("DeOpt v2 core deployment");
        console2.log("chainId", block.chainid);
        console2.log("deployer", deployer);
        console2.log("initialOwner", initialOwner);
        console2.log("initialGuardian", initialGuardian);
        console2.log("baseCollateralToken", baseCollateralToken);
        console2.log("timelockMinDelay", timelockMinDelay);
    }

    function _logDeployments(CoreDeployments memory deployments) internal pure {
        console2.log("CollateralVault", deployments.collateralVault);
        console2.log("OracleRouter", deployments.oracleRouter);
        console2.log("OptionProductRegistry", deployments.optionProductRegistry);
        console2.log("MarginEngine", deployments.marginEngine);
        console2.log("RiskModule", deployments.riskModule);
        console2.log("PerpMarketRegistry", deployments.perpMarketRegistry);
        console2.log("PerpEngine", deployments.perpEngine);
        console2.log("PerpRiskModule", deployments.perpRiskModule);
        console2.log("CollateralSeizer", deployments.collateralSeizer);
        console2.log("FeesManager", deployments.feesManager);
        console2.log("InsuranceFund", deployments.insuranceFund);
        console2.log("MatchingEngine", deployments.matchingEngine);
        console2.log("PerpMatchingEngine", deployments.perpMatchingEngine);
        console2.log("ProtocolTimelock", deployments.protocolTimelock);
        console2.log("RiskGovernor", deployments.riskGovernor);
    }
}
