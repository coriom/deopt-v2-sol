// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {CollateralVault} from "../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../src/core/InsuranceFund.sol";
import {FeesManager} from "../src/fees/FeesManager.sol";
import {CollateralSeizer} from "../src/liquidation/CollateralSeizer.sol";
import {MatchingEngine} from "../src/matching/MatchingEngine.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";
import {OracleRouter} from "../src/oracle/OracleRouter.sol";
import {MarginEngine} from "../src/margin/MarginEngine.sol";
import {PerpEngine} from "../src/perp/PerpEngine.sol";
import {PerpRiskModule} from "../src/perp/PerpRiskModule.sol";
import {RiskModule} from "../src/risk/RiskModule.sol";

/// @notice Second-pass core wiring script for an already deployed DeOpt v2 core stack.
/// @dev This script wires dependencies only. It does not configure collateral, feeds, markets, series, or parameters.
contract WireCore is Script {
    struct CoreAddresses {
        address collateralVault;
        address riskModule;
        address marginEngine;
        address perpEngine;
        address perpRiskModule;
        address oracleRouter;
        address collateralSeizer;
        address feesManager;
        address insuranceFund;
        address matchingEngine;
        address perpMatchingEngine;
    }

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address caller = vm.addr(deployerPrivateKey);
        address guardian = vm.envOr("INITIAL_GUARDIAN", caller);
        if (guardian == address(0)) revert("guardian zero");

        CoreAddresses memory addrs = _readAddresses();
        _requireDeployed(addrs);

        vm.startBroadcast(deployerPrivateKey);

        _wireVault(addrs);
        _wireRisk(addrs, guardian);
        _wireEngines(addrs, guardian);
        _wirePerpRisk(addrs, guardian);
        _wireCollateralSeizer(addrs);
        _wireInsurance(addrs, guardian);
        _wireMatching(addrs, guardian);
        _wireOperationalGuardians(addrs, guardian);

        vm.stopBroadcast();

        _logInputs(caller, guardian);
        _logAddresses(addrs);
    }

    function _readAddresses() internal view returns (CoreAddresses memory addrs) {
        addrs.collateralVault = vm.envAddress("COLLATERAL_VAULT");
        addrs.riskModule = vm.envAddress("RISK_MODULE");
        addrs.marginEngine = vm.envAddress("MARGIN_ENGINE");
        addrs.perpEngine = vm.envAddress("PERP_ENGINE");
        addrs.perpRiskModule = vm.envAddress("PERP_RISK_MODULE");
        addrs.oracleRouter = vm.envAddress("ORACLE_ROUTER");
        addrs.collateralSeizer = vm.envAddress("COLLATERAL_SEIZER");
        addrs.feesManager = vm.envAddress("FEES_MANAGER");
        addrs.insuranceFund = vm.envAddress("INSURANCE_FUND");
        addrs.matchingEngine = vm.envAddress("MATCHING_ENGINE");
        addrs.perpMatchingEngine = vm.envAddress("PERP_MATCHING_ENGINE");
    }

    function _requireDeployed(CoreAddresses memory addrs) internal view {
        _requireContract("COLLATERAL_VAULT", addrs.collateralVault);
        _requireContract("RISK_MODULE", addrs.riskModule);
        _requireContract("MARGIN_ENGINE", addrs.marginEngine);
        _requireContract("PERP_ENGINE", addrs.perpEngine);
        _requireContract("PERP_RISK_MODULE", addrs.perpRiskModule);
        _requireContract("ORACLE_ROUTER", addrs.oracleRouter);
        _requireContract("COLLATERAL_SEIZER", addrs.collateralSeizer);
        _requireContract("FEES_MANAGER", addrs.feesManager);
        _requireContract("INSURANCE_FUND", addrs.insuranceFund);
        _requireContract("MATCHING_ENGINE", addrs.matchingEngine);
        _requireContract("PERP_MATCHING_ENGINE", addrs.perpMatchingEngine);
    }

    function _requireContract(string memory name, address target) internal view {
        if (target == address(0)) revert(string.concat(name, " zero"));
        if (target.code.length == 0) revert(string.concat(name, " no code"));
    }

    function _wireVault(CoreAddresses memory addrs) internal {
        CollateralVault vault = CollateralVault(addrs.collateralVault);

        vault.setRiskModule(addrs.riskModule);
        vault.setMarginEngine(addrs.marginEngine);
        vault.setAuthorizedEngine(addrs.perpEngine, true);
        vault.setAuthorizedEngine(addrs.insuranceFund, true);
    }

    function _wireRisk(CoreAddresses memory addrs, address guardian) internal {
        RiskModule risk = RiskModule(addrs.riskModule);

        risk.setGuardian(guardian);
        risk.setMarginEngine(addrs.marginEngine);
        risk.setOracle(addrs.oracleRouter);
        risk.setPerpRiskModule(addrs.perpRiskModule);
        risk.setPerpEngine(addrs.perpEngine);
    }

    function _wireEngines(CoreAddresses memory addrs, address guardian) internal {
        MarginEngine margin = MarginEngine(addrs.marginEngine);
        margin.setGuardian(guardian);
        margin.setMatchingEngine(addrs.matchingEngine);
        margin.setOracle(addrs.oracleRouter);
        margin.setRiskModule(addrs.riskModule);
        margin.setInsuranceFund(addrs.insuranceFund);
        margin.setFeesManager(addrs.feesManager);

        PerpEngine perp = PerpEngine(addrs.perpEngine);
        perp.setGuardian(guardian);
        perp.setMatchingEngine(addrs.perpMatchingEngine);
        perp.setCollateralVault(addrs.collateralVault);
        perp.setOracle(addrs.oracleRouter);
        perp.setRiskModule(addrs.perpRiskModule);
        perp.setCollateralSeizer(addrs.collateralSeizer);
        perp.setInsuranceFund(addrs.insuranceFund);
        perp.setFeesManager(addrs.feesManager);
    }

    function _wirePerpRisk(CoreAddresses memory addrs, address guardian) internal {
        PerpRiskModule perpRisk = PerpRiskModule(addrs.perpRiskModule);

        perpRisk.setGuardian(guardian);
        perpRisk.setVault(addrs.collateralVault);
        perpRisk.setOracle(addrs.oracleRouter);
        perpRisk.setPerpEngine(addrs.perpEngine);
    }

    function _wireCollateralSeizer(CoreAddresses memory addrs) internal {
        CollateralSeizer seizer = CollateralSeizer(addrs.collateralSeizer);

        seizer.setVault(addrs.collateralVault);
        seizer.setOracle(addrs.oracleRouter);
        seizer.setRiskModule(addrs.riskModule);
    }

    function _wireInsurance(CoreAddresses memory addrs, address guardian) internal {
        InsuranceFund fund = InsuranceFund(addrs.insuranceFund);

        fund.setGuardian(guardian);
        fund.setBackstopCaller(addrs.marginEngine, true);
        fund.setBackstopCaller(addrs.perpEngine, true);
    }

    function _wireMatching(CoreAddresses memory addrs, address guardian) internal {
        MatchingEngine matching = MatchingEngine(addrs.matchingEngine);
        matching.setGuardian(guardian);
        matching.setMarginEngine(addrs.marginEngine);

        PerpMatchingEngine perpMatching = PerpMatchingEngine(addrs.perpMatchingEngine);
        perpMatching.setGuardian(guardian);
        perpMatching.setEngine(addrs.perpEngine);
    }

    function _wireOperationalGuardians(CoreAddresses memory addrs, address guardian) internal {
        CollateralVault(addrs.collateralVault).setGuardian(guardian);
        OracleRouter(addrs.oracleRouter).setGuardian(guardian);
        FeesManager(addrs.feesManager).setGuardian(guardian);
    }

    function _logInputs(address caller, address guardian) internal view {
        console2.log("DeOpt v2 core wiring");
        console2.log("chainId", block.chainid);
        console2.log("caller", caller);
        console2.log("guardian", guardian);
    }

    function _logAddresses(CoreAddresses memory addrs) internal pure {
        console2.log("CollateralVault", addrs.collateralVault);
        console2.log("RiskModule", addrs.riskModule);
        console2.log("MarginEngine", addrs.marginEngine);
        console2.log("PerpEngine", addrs.perpEngine);
        console2.log("PerpRiskModule", addrs.perpRiskModule);
        console2.log("OracleRouter", addrs.oracleRouter);
        console2.log("CollateralSeizer", addrs.collateralSeizer);
        console2.log("FeesManager", addrs.feesManager);
        console2.log("InsuranceFund", addrs.insuranceFund);
        console2.log("MatchingEngine", addrs.matchingEngine);
        console2.log("PerpMatchingEngine", addrs.perpMatchingEngine);
    }
}
