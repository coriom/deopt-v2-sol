// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ProtocolTimelock} from "../src/gouvernance/ProtocolTimelock.sol";

interface IAcceptableOwnable {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

/// @notice Seventh-pass ownership acceptance and final governance handoff verifier.
/// @dev Finalizes pending two-step transfers only. It does not change protocol parameters or market state.
contract AcceptOwnerships is Script {
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
    }

    struct ExpectedOwners {
        address protocolOwner;
        address timelockOwner;
        address riskGovernorOwner;
        address finalGovernanceOwner;
        address deployer;
        address[] priceSources;
        address[] priceSourceOwners;
    }

    struct AcceptContext {
        ProtocolTimelock timelock;
        uint256 timelockExecutorPrivateKey;
        uint256 timelockAcceptEta;
        bool hasTimelockExecutorPrivateKey;
        bool hasTimelockAcceptEta;
    }

    function run() external {
        CoreAddresses memory addrs = _readCoreAddresses();
        _requireDeployed(addrs);

        ExpectedOwners memory owners = _readExpectedOwners();
        _validateExpectedOwners(owners);

        AcceptContext memory ctx = _readAcceptContext(addrs.protocolTimelock);

        _acceptProtocolModules(addrs, owners, ctx);
        _acceptGovernanceModules(addrs, owners, ctx);
        _acceptPriceSources(owners.priceSources, owners.priceSourceOwners, owners, ctx);

        _verifyProtocolModules(addrs, owners);
        _verifyGovernanceModules(addrs, owners);
        _verifyPriceSources(owners.priceSources, owners.priceSourceOwners, owners.deployer);

        _logOwnershipSummary(addrs, owners);
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
    }

    function _readExpectedOwners() internal view returns (ExpectedOwners memory owners) {
        owners.protocolOwner = _envAddress("GOVERNANCE_OWNER");
        owners.finalGovernanceOwner = _envAddress("FINAL_GOVERNANCE_OWNER");
        owners.timelockOwner = _envAddressOr("TIMELOCK_OWNER", owners.finalGovernanceOwner);
        owners.riskGovernorOwner = _envAddressOr("RISK_GOVERNOR_OWNER", owners.finalGovernanceOwner);
        owners.deployer = _envAddress("DEPLOYER_ADDRESS");
        owners.priceSources = _envAddressArrayOr("PRICE_SOURCES");
        owners.priceSourceOwners = _envAddressArrayOr("PRICE_SOURCE_OWNERS");
    }

    function _readAcceptContext(address timelock_) internal view returns (AcceptContext memory ctx) {
        ctx.timelock = ProtocolTimelock(payable(timelock_));
        ctx.hasTimelockExecutorPrivateKey = vm.envExists("TIMELOCK_EXECUTOR_PRIVATE_KEY");
        if (ctx.hasTimelockExecutorPrivateKey) {
            ctx.timelockExecutorPrivateKey = vm.envUint("TIMELOCK_EXECUTOR_PRIVATE_KEY");
        }

        ctx.hasTimelockAcceptEta = vm.envExists("TIMELOCK_ACCEPT_ETA");
        if (ctx.hasTimelockAcceptEta) {
            ctx.timelockAcceptEta = vm.envUint("TIMELOCK_ACCEPT_ETA");
        }
    }

    function _validateExpectedOwners(ExpectedOwners memory owners) internal pure {
        _requireNonZero("GOVERNANCE_OWNER", owners.protocolOwner);
        _requireNonZero("FINAL_GOVERNANCE_OWNER", owners.finalGovernanceOwner);
        _requireNonZero("TIMELOCK_OWNER", owners.timelockOwner);
        _requireNonZero("RISK_GOVERNOR_OWNER", owners.riskGovernorOwner);
        _requireNonZero("DEPLOYER_ADDRESS", owners.deployer);

        if (owners.protocolOwner == owners.deployer) revert("GOVERNANCE_OWNER is deployer");
        if (owners.timelockOwner == owners.deployer) revert("TIMELOCK_OWNER is deployer");
        if (owners.riskGovernorOwner == owners.deployer) revert("RISK_GOVERNOR_OWNER is deployer");

        if (owners.priceSources.length != owners.priceSourceOwners.length) {
            revert("PRICE_SOURCE_OWNERS length mismatch");
        }
        _requireNoZero("PRICE_SOURCES", owners.priceSources);
        _requireNoZero("PRICE_SOURCE_OWNERS", owners.priceSourceOwners);
    }

    function _requireDeployed(CoreAddresses memory addrs) internal view {
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

    function _acceptProtocolModules(CoreAddresses memory addrs, ExpectedOwners memory owners, AcceptContext memory ctx)
        internal
    {
        _acceptTwoStep("COLLATERAL_VAULT", addrs.collateralVault, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("ORACLE_ROUTER", addrs.oracleRouter, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("OPTION_PRODUCT_REGISTRY", addrs.optionProductRegistry, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("MARGIN_ENGINE", addrs.marginEngine, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("RISK_MODULE", addrs.riskModule, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("PERP_MARKET_REGISTRY", addrs.perpMarketRegistry, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("PERP_ENGINE", addrs.perpEngine, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("PERP_RISK_MODULE", addrs.perpRiskModule, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("COLLATERAL_SEIZER", addrs.collateralSeizer, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("FEES_MANAGER", addrs.feesManager, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("INSURANCE_FUND", addrs.insuranceFund, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("MATCHING_ENGINE", addrs.matchingEngine, owners.protocolOwner, owners, ctx);
        _acceptTwoStep("PERP_MATCHING_ENGINE", addrs.perpMatchingEngine, owners.protocolOwner, owners, ctx);
    }

    function _acceptGovernanceModules(CoreAddresses memory addrs, ExpectedOwners memory owners, AcceptContext memory ctx)
        internal
    {
        _acceptTwoStep("PROTOCOL_TIMELOCK", addrs.protocolTimelock, owners.timelockOwner, owners, ctx);
        _acceptTwoStep("RISK_GOVERNOR", addrs.riskGovernor, owners.riskGovernorOwner, owners, ctx);
    }

    function _acceptPriceSources(
        address[] memory sources,
        address[] memory expectedOwners,
        ExpectedOwners memory owners,
        AcceptContext memory ctx
    ) internal {
        for (uint256 i = 0; i < sources.length; i++) {
            _requireContract("PRICE_SOURCE", sources[i]);
            (bool hasPending, address pending) = _tryPendingOwner(sources[i]);
            if (hasPending) {
                if (pending == address(0) && _readExternalOwner("PRICE_SOURCE", sources[i]) == expectedOwners[i]) {
                    continue;
                }
                _acceptTwoStep("PRICE_SOURCE", sources[i], expectedOwners[i], owners, ctx);
            } else {
                _verifyExternalOwner("PRICE_SOURCE", sources[i], expectedOwners[i], owners.deployer);
            }
        }
    }

    function _acceptTwoStep(
        string memory label,
        address target,
        address expectedOwner,
        ExpectedOwners memory owners,
        AcceptContext memory ctx
    ) internal {
        IAcceptableOwnable ownable = IAcceptableOwnable(target);
        address currentOwner = ownable.owner();
        address pendingOwner = ownable.pendingOwner();

        if (currentOwner == expectedOwner) {
            if (pendingOwner != address(0)) revert(string.concat(label, " pending owner unexpectedly set"));
            return;
        }

        if (currentOwner == owners.deployer && pendingOwner == address(0)) {
            revert(string.concat(label, " still owned by deployer"));
        }
        if (pendingOwner != expectedOwner) revert(string.concat(label, " pending owner mismatch"));

        if (expectedOwner == address(ctx.timelock)) {
            _acceptViaTimelock(label, target, ctx);
        } else {
            if (expectedOwner.code.length != 0) revert(string.concat(label, " contract owner execution unsupported"));
            uint256 ownerPrivateKey = _privateKeyForOwner(expectedOwner, owners);
            vm.startBroadcast(ownerPrivateKey);
            ownable.acceptOwnership();
            vm.stopBroadcast();
        }

        _verifyTwoStepOwner(label, target, expectedOwner, owners.deployer);
    }

    function _acceptViaTimelock(string memory label, address target, AcceptContext memory ctx) internal {
        if (!ctx.hasTimelockExecutorPrivateKey) revert("TIMELOCK_EXECUTOR_PRIVATE_KEY missing");
        if (!ctx.hasTimelockAcceptEta) revert("TIMELOCK_ACCEPT_ETA missing");

        address executor = vm.addr(ctx.timelockExecutorPrivateKey);
        if (!ctx.timelock.executors(executor)) revert("timelock executor not allowed");

        bytes memory data = abi.encodeWithSignature("acceptOwnership()");
        if (!ctx.timelock.isOperationReady(target, 0, data, ctx.timelockAcceptEta)) {
            revert(string.concat(label, " timelock accept not ready"));
        }

        vm.startBroadcast(ctx.timelockExecutorPrivateKey);
        ctx.timelock.executeTransaction(target, 0, data, ctx.timelockAcceptEta);
        vm.stopBroadcast();
    }

    function _verifyProtocolModules(CoreAddresses memory addrs, ExpectedOwners memory owners) internal view {
        _verifyTwoStepOwner("COLLATERAL_VAULT", addrs.collateralVault, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("ORACLE_ROUTER", addrs.oracleRouter, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("OPTION_PRODUCT_REGISTRY", addrs.optionProductRegistry, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("MARGIN_ENGINE", addrs.marginEngine, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("RISK_MODULE", addrs.riskModule, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("PERP_MARKET_REGISTRY", addrs.perpMarketRegistry, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("PERP_ENGINE", addrs.perpEngine, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("PERP_RISK_MODULE", addrs.perpRiskModule, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("COLLATERAL_SEIZER", addrs.collateralSeizer, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("FEES_MANAGER", addrs.feesManager, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("INSURANCE_FUND", addrs.insuranceFund, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("MATCHING_ENGINE", addrs.matchingEngine, owners.protocolOwner, owners.deployer);
        _verifyTwoStepOwner("PERP_MATCHING_ENGINE", addrs.perpMatchingEngine, owners.protocolOwner, owners.deployer);
    }

    function _verifyGovernanceModules(CoreAddresses memory addrs, ExpectedOwners memory owners) internal view {
        _verifyTwoStepOwner("PROTOCOL_TIMELOCK", addrs.protocolTimelock, owners.timelockOwner, owners.deployer);
        _verifyTwoStepOwner("RISK_GOVERNOR", addrs.riskGovernor, owners.riskGovernorOwner, owners.deployer);
    }

    function _verifyPriceSources(address[] memory sources, address[] memory expectedOwners, address deployer)
        internal
        view
    {
        for (uint256 i = 0; i < sources.length; i++) {
            (bool hasPending,) = _tryPendingOwner(sources[i]);
            if (hasPending) {
                _verifyTwoStepOwner("PRICE_SOURCE", sources[i], expectedOwners[i], deployer);
            } else {
                _verifyExternalOwner("PRICE_SOURCE", sources[i], expectedOwners[i], deployer);
            }
        }
    }

    function _verifyTwoStepOwner(string memory label, address target, address expectedOwner, address deployer)
        internal
        view
    {
        IAcceptableOwnable ownable = IAcceptableOwnable(target);
        address currentOwner = ownable.owner();
        address pendingOwner = ownable.pendingOwner();

        if (currentOwner == deployer && currentOwner != expectedOwner) revert(string.concat(label, " still deployer"));
        if (currentOwner != expectedOwner) revert(string.concat(label, " final owner mismatch"));
        if (pendingOwner != address(0)) revert(string.concat(label, " pending owner not cleared"));
    }

    function _verifyExternalOwner(string memory label, address target, address expectedOwner, address deployer)
        internal
        view
    {
        address currentOwner = _readExternalOwner(label, target);
        if (currentOwner == deployer && currentOwner != expectedOwner) revert(string.concat(label, " still deployer"));
        if (currentOwner != expectedOwner) revert(string.concat(label, " final owner mismatch"));
    }

    function _privateKeyForOwner(address expectedOwner, ExpectedOwners memory owners)
        internal
        view
        returns (uint256 privateKey)
    {
        if (expectedOwner == owners.protocolOwner && vm.envExists("GOVERNANCE_OWNER_PRIVATE_KEY")) {
            privateKey = vm.envUint("GOVERNANCE_OWNER_PRIVATE_KEY");
        } else if (expectedOwner == owners.timelockOwner && vm.envExists("TIMELOCK_OWNER_PRIVATE_KEY")) {
            privateKey = vm.envUint("TIMELOCK_OWNER_PRIVATE_KEY");
        } else if (expectedOwner == owners.riskGovernorOwner && vm.envExists("RISK_GOVERNOR_OWNER_PRIVATE_KEY")) {
            privateKey = vm.envUint("RISK_GOVERNOR_OWNER_PRIVATE_KEY");
        } else if (expectedOwner == owners.finalGovernanceOwner && vm.envExists("FINAL_GOVERNANCE_OWNER_PRIVATE_KEY")) {
            privateKey = vm.envUint("FINAL_GOVERNANCE_OWNER_PRIVATE_KEY");
        } else {
            revert("owner private key missing");
        }

        if (vm.addr(privateKey) != expectedOwner) revert("owner private key mismatch");
    }

    function _readExternalOwner(string memory label, address target) internal view returns (address owner_) {
        (bool ok, bytes memory returndata) = target.staticcall(abi.encodeWithSignature("owner()"));
        if (!ok || returndata.length != 32) revert(string.concat(label, " owner() unavailable"));
        owner_ = abi.decode(returndata, (address));
        if (owner_ == address(0)) revert(string.concat(label, " owner zero"));
    }

    function _tryPendingOwner(address target) internal view returns (bool hasPending, address pendingOwner_) {
        (bool ok, bytes memory returndata) = target.staticcall(abi.encodeWithSignature("pendingOwner()"));
        if (!ok || returndata.length != 32) return (false, address(0));
        return (true, abi.decode(returndata, (address)));
    }

    function _requireContract(string memory name, address target) internal view {
        _requireNonZero(name, target);
        if (target.code.length == 0) revert(string.concat(name, " no code"));
    }

    function _envAddress(string memory name) internal view returns (address value) {
        if (!vm.envExists(name)) revert(string.concat(name, " missing"));
        value = vm.envAddress(name);
        if (value == address(0)) revert(string.concat(name, " zero"));
    }

    function _envAddressOr(string memory name, address defaultValue) internal view returns (address value) {
        if (!vm.envExists(name)) return defaultValue;
        value = vm.envAddress(name);
        if (value == address(0)) revert(string.concat(name, " zero"));
    }

    function _envAddressArrayOr(string memory name) internal view returns (address[] memory values) {
        if (!vm.envExists(name)) return new address[](0);
        values = vm.envAddress(name, DELIM);
    }

    function _requireNonZero(string memory label, address value) internal pure {
        if (value == address(0)) revert(string.concat(label, " zero"));
    }

    function _requireNoZero(string memory label, address[] memory values) internal pure {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == address(0)) revert(string.concat(label, " contains zero"));
        }
    }

    function _logOwnershipSummary(CoreAddresses memory addrs, ExpectedOwners memory owners) internal view {
        console2.log("DeOpt v2 final ownership verification");
        console2.log("chainId", block.chainid);
        console2.log("protocolOwner", owners.protocolOwner);
        console2.log("finalGovernanceOwner", owners.finalGovernanceOwner);
        console2.log("timelockOwner", owners.timelockOwner);
        console2.log("riskGovernorOwner", owners.riskGovernorOwner);
        console2.log("priceSourcesVerified", owners.priceSources.length);

        _logTwoStepOwner("CollateralVault", addrs.collateralVault);
        _logTwoStepOwner("OracleRouter", addrs.oracleRouter);
        _logTwoStepOwner("OptionProductRegistry", addrs.optionProductRegistry);
        _logTwoStepOwner("MarginEngine", addrs.marginEngine);
        _logTwoStepOwner("RiskModule", addrs.riskModule);
        _logTwoStepOwner("PerpMarketRegistry", addrs.perpMarketRegistry);
        _logTwoStepOwner("PerpEngine", addrs.perpEngine);
        _logTwoStepOwner("PerpRiskModule", addrs.perpRiskModule);
        _logTwoStepOwner("CollateralSeizer", addrs.collateralSeizer);
        _logTwoStepOwner("FeesManager", addrs.feesManager);
        _logTwoStepOwner("InsuranceFund", addrs.insuranceFund);
        _logTwoStepOwner("MatchingEngine", addrs.matchingEngine);
        _logTwoStepOwner("PerpMatchingEngine", addrs.perpMatchingEngine);
        _logTwoStepOwner("ProtocolTimelock", addrs.protocolTimelock);
        _logTwoStepOwner("RiskGovernor", addrs.riskGovernor);
    }

    function _logTwoStepOwner(string memory label, address target) internal view {
        IAcceptableOwnable ownable = IAcceptableOwnable(target);
        console2.log(label);
        console2.log("  owner", ownable.owner());
        console2.log("  pendingOwner", ownable.pendingOwner());
    }
}
