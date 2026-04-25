// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ProtocolTimelock} from "../src/gouvernance/ProtocolTimelock.sol";
import {MatchingEngine} from "../src/matching/MatchingEngine.sol";
import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";

interface ITwoStepOwnable {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

interface IGuardianOwnable {
    function guardian() external view returns (address);
    function setGuardian(address newGuardian) external;
}

/// @notice Sixth-pass ownership and governance handoff script for a configured DeOpt v2 deployment.
/// @dev Configures governance roles and begins ownership transfers only. It does not accept ownership.
contract TransferOwnerships is Script {
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

    struct GovernanceRoles {
        address protocolOwner;
        address timelockOwner;
        address riskGovernorOwner;
        address guardian;
        address[] timelockProposers;
        bool[] timelockProposerAllowed;
        address[] timelockExecutors;
        bool[] timelockExecutorAllowed;
        address[] matchingExecutors;
        bool[] matchingExecutorAllowed;
        address[] perpMatchingExecutors;
        bool[] perpMatchingExecutorAllowed;
        address[] priceSources;
        address[] priceSourceOwners;
    }

    function run() external {
        uint256 deployerPrivateKey = _envUint("DEPLOYER_PRIVATE_KEY");
        address caller = vm.addr(deployerPrivateKey);

        CoreAddresses memory addrs = _readCoreAddresses();
        _requireDeployed(addrs);

        GovernanceRoles memory roles = _readGovernanceRoles();
        _validateGovernanceRoles(roles, addrs);

        vm.startBroadcast(deployerPrivateKey);

        _configureGuardians(addrs, roles.guardian);
        _configureTimelockRoles(addrs.protocolTimelock, roles);
        _configureMatchingExecutors(addrs, roles);
        _transferPriceSources(roles.priceSources, roles.priceSourceOwners, caller);
        _beginOwnershipTransfers(addrs, roles, caller);

        vm.stopBroadcast();

        _verifyOwnershipTargets(addrs, roles);
        _logOwnershipSummary(caller, addrs, roles);
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

    function _readGovernanceRoles() internal view returns (GovernanceRoles memory roles) {
        roles.protocolOwner = _envAddress("GOVERNANCE_OWNER");
        roles.timelockOwner = _envAddress("TIMELOCK_OWNER");
        roles.riskGovernorOwner = _envAddress("RISK_GOVERNOR_OWNER");
        roles.guardian = _envAddress("GOVERNANCE_GUARDIAN");

        roles.timelockProposers = _envAddressArray("TIMELOCK_PROPOSERS");
        roles.timelockProposerAllowed = _envBoolArray("TIMELOCK_PROPOSER_ALLOWED");
        roles.timelockExecutors = _envAddressArray("TIMELOCK_EXECUTORS");
        roles.timelockExecutorAllowed = _envBoolArray("TIMELOCK_EXECUTOR_ALLOWED");

        roles.matchingExecutors = _envAddressArrayOr("MATCHING_EXECUTORS");
        roles.matchingExecutorAllowed = _envBoolArrayOr("MATCHING_EXECUTOR_ALLOWED");
        roles.perpMatchingExecutors = _envAddressArrayOr("PERP_MATCHING_EXECUTORS");
        roles.perpMatchingExecutorAllowed = _envBoolArrayOr("PERP_MATCHING_EXECUTOR_ALLOWED");

        roles.priceSources = _envAddressArrayOr("PRICE_SOURCES");
        roles.priceSourceOwners = _envAddressArrayOr("PRICE_SOURCE_OWNERS");
    }

    function _validateGovernanceRoles(GovernanceRoles memory roles, CoreAddresses memory addrs) internal pure {
        _requireNonZero("GOVERNANCE_OWNER", roles.protocolOwner);
        _requireNonZero("TIMELOCK_OWNER", roles.timelockOwner);
        _requireNonZero("RISK_GOVERNOR_OWNER", roles.riskGovernorOwner);
        _requireNonZero("GOVERNANCE_GUARDIAN", roles.guardian);

        _requireLength("TIMELOCK_PROPOSER_ALLOWED", roles.timelockProposerAllowed.length, roles.timelockProposers.length);
        _requireLength("TIMELOCK_EXECUTOR_ALLOWED", roles.timelockExecutorAllowed.length, roles.timelockExecutors.length);
        _requireLength("MATCHING_EXECUTOR_ALLOWED", roles.matchingExecutorAllowed.length, roles.matchingExecutors.length);
        _requireLength(
            "PERP_MATCHING_EXECUTOR_ALLOWED",
            roles.perpMatchingExecutorAllowed.length,
            roles.perpMatchingExecutors.length
        );

        if (roles.timelockProposers.length == 0) revert("TIMELOCK_PROPOSERS empty");
        if (roles.timelockExecutors.length == 0) revert("TIMELOCK_EXECUTORS empty");
        if (!_arrayAllows(roles.timelockProposers, roles.timelockProposerAllowed, addrs.riskGovernor)) {
            revert("RISK_GOVERNOR must be allowed timelock proposer");
        }
        if (!_hasAllowed(roles.timelockExecutors, roles.timelockExecutorAllowed)) revert("no allowed timelock executor");

        _requireNoZero("TIMELOCK_PROPOSERS", roles.timelockProposers);
        _requireNoZero("TIMELOCK_EXECUTORS", roles.timelockExecutors);
        _requireNoZero("MATCHING_EXECUTORS", roles.matchingExecutors);
        _requireNoZero("PERP_MATCHING_EXECUTORS", roles.perpMatchingExecutors);

        if (roles.priceSources.length != roles.priceSourceOwners.length) {
            revert("PRICE_SOURCE_OWNERS length mismatch");
        }
        _requireNoZero("PRICE_SOURCES", roles.priceSources);
        _requireNoZero("PRICE_SOURCE_OWNERS", roles.priceSourceOwners);
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

    function _configureGuardians(CoreAddresses memory addrs, address guardian) internal {
        _setGuardianIfNeeded("COLLATERAL_VAULT", addrs.collateralVault, guardian);
        _setGuardianIfNeeded("ORACLE_ROUTER", addrs.oracleRouter, guardian);
        _setGuardianIfNeeded("OPTION_PRODUCT_REGISTRY", addrs.optionProductRegistry, guardian);
        _setGuardianIfNeeded("MARGIN_ENGINE", addrs.marginEngine, guardian);
        _setGuardianIfNeeded("RISK_MODULE", addrs.riskModule, guardian);
        _setGuardianIfNeeded("PERP_MARKET_REGISTRY", addrs.perpMarketRegistry, guardian);
        _setGuardianIfNeeded("PERP_ENGINE", addrs.perpEngine, guardian);
        _setGuardianIfNeeded("PERP_RISK_MODULE", addrs.perpRiskModule, guardian);
        _setGuardianIfNeeded("FEES_MANAGER", addrs.feesManager, guardian);
        _setGuardianIfNeeded("INSURANCE_FUND", addrs.insuranceFund, guardian);
        _setGuardianIfNeeded("MATCHING_ENGINE", addrs.matchingEngine, guardian);
        _setGuardianIfNeeded("PERP_MATCHING_ENGINE", addrs.perpMatchingEngine, guardian);
        _setGuardianIfNeeded("PROTOCOL_TIMELOCK", addrs.protocolTimelock, guardian);
        _setGuardianIfNeeded("RISK_GOVERNOR", addrs.riskGovernor, guardian);
    }

    function _configureTimelockRoles(address timelock_, GovernanceRoles memory roles) internal {
        ProtocolTimelock timelock = ProtocolTimelock(payable(timelock_));

        for (uint256 i = 0; i < roles.timelockProposers.length; i++) {
            if (timelock.proposers(roles.timelockProposers[i]) != roles.timelockProposerAllowed[i]) {
                timelock.setProposer(roles.timelockProposers[i], roles.timelockProposerAllowed[i]);
            }
        }

        for (uint256 i = 0; i < roles.timelockExecutors.length; i++) {
            if (timelock.executors(roles.timelockExecutors[i]) != roles.timelockExecutorAllowed[i]) {
                timelock.setExecutor(roles.timelockExecutors[i], roles.timelockExecutorAllowed[i]);
            }
        }
    }

    function _configureMatchingExecutors(CoreAddresses memory addrs, GovernanceRoles memory roles) internal {
        for (uint256 i = 0; i < roles.matchingExecutors.length; i++) {
            MatchingEngine matching = MatchingEngine(addrs.matchingEngine);
            if (matching.isExecutor(roles.matchingExecutors[i]) != roles.matchingExecutorAllowed[i]) {
                matching.setExecutor(roles.matchingExecutors[i], roles.matchingExecutorAllowed[i]);
            }
        }

        for (uint256 i = 0; i < roles.perpMatchingExecutors.length; i++) {
            PerpMatchingEngine matching = PerpMatchingEngine(addrs.perpMatchingEngine);
            if (matching.isExecutor(roles.perpMatchingExecutors[i]) != roles.perpMatchingExecutorAllowed[i]) {
                matching.setExecutor(roles.perpMatchingExecutors[i], roles.perpMatchingExecutorAllowed[i]);
            }
        }
    }

    function _transferPriceSources(address[] memory sources, address[] memory owners, address caller) internal {
        for (uint256 i = 0; i < sources.length; i++) {
            _requireContract("PRICE_SOURCE", sources[i]);
            _transferPriceSource(sources[i], owners[i], caller);
        }
    }

    function _beginOwnershipTransfers(CoreAddresses memory addrs, GovernanceRoles memory roles, address caller)
        internal
    {
        _beginTwoStepTransfer("COLLATERAL_VAULT", addrs.collateralVault, roles.protocolOwner, caller);
        _beginTwoStepTransfer("ORACLE_ROUTER", addrs.oracleRouter, roles.protocolOwner, caller);
        _beginTwoStepTransfer("OPTION_PRODUCT_REGISTRY", addrs.optionProductRegistry, roles.protocolOwner, caller);
        _beginTwoStepTransfer("MARGIN_ENGINE", addrs.marginEngine, roles.protocolOwner, caller);
        _beginTwoStepTransfer("RISK_MODULE", addrs.riskModule, roles.protocolOwner, caller);
        _beginTwoStepTransfer("PERP_MARKET_REGISTRY", addrs.perpMarketRegistry, roles.protocolOwner, caller);
        _beginTwoStepTransfer("PERP_ENGINE", addrs.perpEngine, roles.protocolOwner, caller);
        _beginTwoStepTransfer("PERP_RISK_MODULE", addrs.perpRiskModule, roles.protocolOwner, caller);
        _beginTwoStepTransfer("COLLATERAL_SEIZER", addrs.collateralSeizer, roles.protocolOwner, caller);
        _beginTwoStepTransfer("FEES_MANAGER", addrs.feesManager, roles.protocolOwner, caller);
        _beginTwoStepTransfer("INSURANCE_FUND", addrs.insuranceFund, roles.protocolOwner, caller);
        _beginTwoStepTransfer("MATCHING_ENGINE", addrs.matchingEngine, roles.protocolOwner, caller);
        _beginTwoStepTransfer("PERP_MATCHING_ENGINE", addrs.perpMatchingEngine, roles.protocolOwner, caller);

        _beginTwoStepTransfer("PROTOCOL_TIMELOCK", addrs.protocolTimelock, roles.timelockOwner, caller);
        _beginTwoStepTransfer("RISK_GOVERNOR", addrs.riskGovernor, roles.riskGovernorOwner, caller);
    }

    function _beginTwoStepTransfer(string memory label, address target, address newOwner, address caller) internal {
        ITwoStepOwnable ownable = ITwoStepOwnable(target);
        address currentOwner = ownable.owner();
        address pendingOwner = ownable.pendingOwner();

        if (currentOwner == newOwner) {
            if (pendingOwner != address(0)) revert(string.concat(label, " pending owner unexpectedly set"));
            return;
        }

        if (pendingOwner == newOwner) return;
        if (pendingOwner != address(0)) revert(string.concat(label, " pending owner mismatch"));
        if (currentOwner != caller) revert(string.concat(label, " current owner mismatch"));

        ownable.transferOwnership(newOwner);
        if (ownable.pendingOwner() != newOwner) revert(string.concat(label, " pending owner not set"));
    }

    function _setGuardianIfNeeded(string memory label, address target, address guardian) internal {
        IGuardianOwnable ownable = IGuardianOwnable(target);
        if (ownable.guardian() == guardian) return;

        ownable.setGuardian(guardian);
        if (ownable.guardian() != guardian) revert(string.concat(label, " guardian not set"));
    }

    function _transferPriceSource(address source, address newOwner, address caller) internal {
        address currentOwner = _readExternalOwner("PRICE_SOURCE", source);
        if (currentOwner == newOwner) return;
        if (currentOwner != caller) revert("PRICE_SOURCE current owner mismatch");

        (bool ok, bytes memory returndata) =
            source.call(abi.encodeWithSignature("transferOwnership(address)", newOwner));
        if (!ok) _revertWithData(returndata, "PRICE_SOURCE transferOwnership failed");

        (bool hasPending, address pending) = _tryPendingOwner(source);
        if (hasPending) {
            if (pending != newOwner) revert("PRICE_SOURCE pending owner not set");
        } else if (_readExternalOwner("PRICE_SOURCE", source) != newOwner) {
            revert("PRICE_SOURCE owner not set");
        }
    }

    function _verifyOwnershipTargets(CoreAddresses memory addrs, GovernanceRoles memory roles) internal view {
        _verifyPendingOrOwner("COLLATERAL_VAULT", addrs.collateralVault, roles.protocolOwner);
        _verifyPendingOrOwner("ORACLE_ROUTER", addrs.oracleRouter, roles.protocolOwner);
        _verifyPendingOrOwner("OPTION_PRODUCT_REGISTRY", addrs.optionProductRegistry, roles.protocolOwner);
        _verifyPendingOrOwner("MARGIN_ENGINE", addrs.marginEngine, roles.protocolOwner);
        _verifyPendingOrOwner("RISK_MODULE", addrs.riskModule, roles.protocolOwner);
        _verifyPendingOrOwner("PERP_MARKET_REGISTRY", addrs.perpMarketRegistry, roles.protocolOwner);
        _verifyPendingOrOwner("PERP_ENGINE", addrs.perpEngine, roles.protocolOwner);
        _verifyPendingOrOwner("PERP_RISK_MODULE", addrs.perpRiskModule, roles.protocolOwner);
        _verifyPendingOrOwner("COLLATERAL_SEIZER", addrs.collateralSeizer, roles.protocolOwner);
        _verifyPendingOrOwner("FEES_MANAGER", addrs.feesManager, roles.protocolOwner);
        _verifyPendingOrOwner("INSURANCE_FUND", addrs.insuranceFund, roles.protocolOwner);
        _verifyPendingOrOwner("MATCHING_ENGINE", addrs.matchingEngine, roles.protocolOwner);
        _verifyPendingOrOwner("PERP_MATCHING_ENGINE", addrs.perpMatchingEngine, roles.protocolOwner);
        _verifyPendingOrOwner("PROTOCOL_TIMELOCK", addrs.protocolTimelock, roles.timelockOwner);
        _verifyPendingOrOwner("RISK_GOVERNOR", addrs.riskGovernor, roles.riskGovernorOwner);
    }

    function _verifyPendingOrOwner(string memory label, address target, address expectedOwner) internal view {
        ITwoStepOwnable ownable = ITwoStepOwnable(target);
        if (ownable.owner() == expectedOwner) return;
        if (ownable.pendingOwner() != expectedOwner) revert(string.concat(label, " handoff mismatch"));
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

    function _envUint(string memory name) internal view returns (uint256 value) {
        if (!vm.envExists(name)) revert(string.concat(name, " missing"));
        value = vm.envUint(name);
    }

    function _envAddressArray(string memory name) internal view returns (address[] memory values) {
        if (!vm.envExists(name)) revert(string.concat(name, " missing"));
        values = vm.envAddress(name, DELIM);
        if (values.length == 0) revert(string.concat(name, " empty"));
    }

    function _envBoolArray(string memory name) internal view returns (bool[] memory values) {
        if (!vm.envExists(name)) revert(string.concat(name, " missing"));
        values = vm.envBool(name, DELIM);
        if (values.length == 0) revert(string.concat(name, " empty"));
    }

    function _envAddressArrayOr(string memory name) internal view returns (address[] memory values) {
        if (!vm.envExists(name)) return new address[](0);
        values = vm.envAddress(name, DELIM);
    }

    function _envBoolArrayOr(string memory name) internal view returns (bool[] memory values) {
        if (!vm.envExists(name)) return new bool[](0);
        values = vm.envBool(name, DELIM);
    }

    function _requireNonZero(string memory label, address value) internal pure {
        if (value == address(0)) revert(string.concat(label, " zero"));
    }

    function _requireNoZero(string memory label, address[] memory values) internal pure {
        for (uint256 i = 0; i < values.length; i++) {
            if (values[i] == address(0)) revert(string.concat(label, " contains zero"));
        }
    }

    function _requireLength(string memory label, uint256 actual, uint256 expected) internal pure {
        if (actual != expected) revert(string.concat(label, " length mismatch"));
    }

    function _hasAllowed(address[] memory accounts, bool[] memory allowed) internal pure returns (bool) {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (allowed[i]) return true;
        }
        return false;
    }

    function _arrayAllows(address[] memory accounts, bool[] memory allowed, address account)
        internal
        pure
        returns (bool)
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == account && allowed[i]) return true;
        }
        return false;
    }

    function _revertWithData(bytes memory returndata, string memory fallbackMessage) internal pure {
        if (returndata.length != 0) {
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }
        revert(fallbackMessage);
    }

    function _logOwnershipSummary(address caller, CoreAddresses memory addrs, GovernanceRoles memory roles)
        internal
        view
    {
        console2.log("DeOpt v2 ownership handoff");
        console2.log("chainId", block.chainid);
        console2.log("caller", caller);
        console2.log("protocolOwner", roles.protocolOwner);
        console2.log("timelockOwner", roles.timelockOwner);
        console2.log("riskGovernorOwner", roles.riskGovernorOwner);
        console2.log("guardian", roles.guardian);
        console2.log("timelockProposers", roles.timelockProposers.length);
        console2.log("timelockExecutors", roles.timelockExecutors.length);
        console2.log("matchingExecutors", roles.matchingExecutors.length);
        console2.log("perpMatchingExecutors", roles.perpMatchingExecutors.length);
        console2.log("priceSourcesTransferred", roles.priceSources.length);

        _logOwnerState("CollateralVault", addrs.collateralVault);
        _logOwnerState("OracleRouter", addrs.oracleRouter);
        _logOwnerState("OptionProductRegistry", addrs.optionProductRegistry);
        _logOwnerState("MarginEngine", addrs.marginEngine);
        _logOwnerState("RiskModule", addrs.riskModule);
        _logOwnerState("PerpMarketRegistry", addrs.perpMarketRegistry);
        _logOwnerState("PerpEngine", addrs.perpEngine);
        _logOwnerState("PerpRiskModule", addrs.perpRiskModule);
        _logOwnerState("CollateralSeizer", addrs.collateralSeizer);
        _logOwnerState("FeesManager", addrs.feesManager);
        _logOwnerState("InsuranceFund", addrs.insuranceFund);
        _logOwnerState("MatchingEngine", addrs.matchingEngine);
        _logOwnerState("PerpMatchingEngine", addrs.perpMatchingEngine);
        _logOwnerState("ProtocolTimelock", addrs.protocolTimelock);
        _logOwnerState("RiskGovernor", addrs.riskGovernor);
    }

    function _logOwnerState(string memory label, address target) internal view {
        ITwoStepOwnable ownable = ITwoStepOwnable(target);
        console2.log(label);
        console2.log("  owner", ownable.owner());
        console2.log("  pendingOwner", ownable.pendingOwner());
    }
}
