// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {CoveredCallMarginEngine} from "../src/experimental/CoveredCallMarginEngine.sol";

abstract contract PhysicalDeployScriptV23 is Script {
    function startApprovedBroadcast(address deployer) internal {
        if (vm.envOr("OPTIONS_V23_LOCAL_ANVIL", false)) {
            vm.startBroadcast(deployer);
            return;
        }
        require(vm.envOr("OPTIONS_V23_PUBLIC_BROADCAST_ALLOWED", false), "public deployment not authorized");
        uint256 key = vm.envUint("DEPLOYER_PRIVATE_KEY");
        require(vm.addr(key) == deployer, "deployer signer mismatch");
        vm.startBroadcast(key);
    }
}

/// @notice Registry-only deployment. The engine can now be installed unbound
///         before a series is separately approved and created.
contract DeployOptionsPhysicalRegistryV21 is PhysicalDeployScriptV23 {
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        require(vm.envOr("OPTIONS_V21_DEPLOY_ALLOWED", false), "deployment not authorized");
        require(TIMELOCK.code.length != 0, "Timelock absent");
        address deployer = vm.envAddress("OPTIONS_V23_DEPLOYER");
        require(vm.getNonce(deployer) == vm.envUint("OPTIONS_V23_EXPECTED_NONCE"), "deployer nonce drift");
        startApprovedBroadcast(deployer);
        OptionProductRegistry registry = new OptionProductRegistry(TIMELOCK);
        vm.stopBroadcast();
        require(registry.owner() == TIMELOCK, "Registry owner mismatch");
        console2.log("V21_PHYSICAL_REGISTRY", address(registry));
    }
}

/// @notice Engine-only CREATE. The matcher has a separate resumable step.
contract DeployOptionsPhysicalEngineV21 is PhysicalDeployScriptV23 {
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant MWETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    uint64 internal constant CANDIDATE_EXPIRY = 1_795_780_800; // 2026-11-27 12:00 UTC
    uint64 internal constant CANDIDATE_STRIKE = 2_100e8;

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        require(vm.envOr("OPTIONS_V21_DEPLOY_ALLOWED", false), "deployment not authorized");
        address deployer = vm.envAddress("OPTIONS_V23_DEPLOYER");
        require(vm.getNonce(deployer) == vm.envUint("OPTIONS_V23_EXPECTED_NONCE"), "deployer nonce drift");
        address registryAddress = vm.envAddress("OPTIONS_V21_REGISTRY");
        address oracle = vm.envAddress("OPTIONS_V21_ORACLE");
        uint256 optionId = vm.envOr("OPTIONS_V21_OPTION_ID", uint256(0));
        require(registryAddress.code.length != 0 && oracle.code.length != 0, "dependency absent");
        OptionProductRegistry registry = OptionProductRegistry(registryAddress);
        require(registry.owner() == TIMELOCK, "Registry owner mismatch");
        if (optionId != 0) {
            OptionProductRegistry.OptionSeries memory series = registry.getSeries(optionId);
            require(
                series.exists && !series.isActive && series.isCall && series.isEuropean && series.underlying == MWETH
                    && series.settlementAsset == MUSDC && series.contractSize1e8 == 1e8
                    && series.strike == CANDIDATE_STRIKE && series.expiry == CANDIDATE_EXPIRY,
                "series policy mismatch"
            );
            require(block.timestamp < series.expiry, "candidate expiry elapsed");
        } else {
            require(registry.getAllOptionIds().length == 0, "unbound deployment requires empty Registry");
        }
        startApprovedBroadcast(deployer);
        CoveredCallMarginEngine engine =
            new CoveredCallMarginEngine(TIMELOCK, registryAddress, optionId, oracle, 1_500, 48 hours);
        vm.stopBroadcast();
        require(engine.paused() && engine.matchingEngine() == address(0), "engine active");
        require(engine.seriesBound() == (optionId != 0), "series binding mismatch");
        require(
            engine.maxOpenContracts() == 0 && engine.makerFeePpm() == 0 && engine.takerFeePpm() == 0,
            "engine policy preset"
        );
        console2.log("V21_PHYSICAL_ENGINE", address(engine));
    }
}

/// @notice Matcher-only CREATE after a verified engine receipt; safe to resume
///         if a previous run stopped after deploying the engine.
contract DeployOptionsPhysicalMatcherV23 is PhysicalDeployScriptV23 {
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        require(vm.envOr("OPTIONS_V21_DEPLOY_ALLOWED", false), "deployment not authorized");
        address deployer = vm.envAddress("OPTIONS_V23_DEPLOYER");
        require(vm.getNonce(deployer) == vm.envUint("OPTIONS_V23_EXPECTED_NONCE"), "deployer nonce drift");
        address registryAddress = vm.envAddress("OPTIONS_V21_REGISTRY");
        address engineAddress = vm.envAddress("OPTIONS_V23_ENGINE");
        require(registryAddress.code.length != 0 && engineAddress.code.length != 0, "dependency absent");
        CoveredCallMarginEngine engine = CoveredCallMarginEngine(engineAddress);
        require(
            engine.owner() == TIMELOCK && address(engine.registry()) == registryAddress && engine.paused()
                && engine.matchingEngine() == address(0) && !engine.seriesBound(),
            "engine not safely unbound"
        );
        startApprovedBroadcast(deployer);
        OptionMatchingEngine matcher = new OptionMatchingEngine(TIMELOCK, engineAddress, registryAddress);
        vm.stopBroadcast();
        require(matcher.isExecutor(TIMELOCK), "matcher owner executor mismatch");
        require(address(matcher.marginEngine()) == engineAddress, "matcher engine mismatch");
        require(address(matcher.optionRegistry()) == registryAddress, "matcher Registry mismatch");
        console2.log("V23_PHYSICAL_MATCHER", address(matcher));
    }
}
