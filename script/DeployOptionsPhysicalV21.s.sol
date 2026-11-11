// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {OptionProductRegistry} from "../src/OptionProductRegistry.sol";
import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";
import {CoveredCallMarginEngine} from "../src/experimental/CoveredCallMarginEngine.sol";

/// @notice Registry-only deployment. Governance configures assets and creates
///         then deactivates the series before deploying its physical engine.
contract DeployOptionsPhysicalRegistryV21 is Script {
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        require(vm.envOr("OPTIONS_V21_DEPLOY_ALLOWED", false), "deployment not authorized");
        require(TIMELOCK.code.length != 0, "Timelock absent");
        vm.startBroadcast();
        OptionProductRegistry registry = new OptionProductRegistry(TIMELOCK);
        vm.stopBroadcast();
        require(registry.owner() == TIMELOCK, "Registry owner mismatch");
        console2.log("V21_PHYSICAL_REGISTRY", address(registry));
    }
}

/// @notice Two independent CREATE transactions, with no funding, external
///         executor, matching binding or unpause. Governance owns the matcher.
contract DeployOptionsPhysicalEngineV21 is Script {
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address internal constant MWETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    uint64 internal constant CANDIDATE_EXPIRY = 1_795_780_800; // 2026-11-27 12:00 UTC
    uint64 internal constant CANDIDATE_STRIKE = 2_100e8;

    function run() external {
        require(block.chainid == 84532, "Base Sepolia only");
        require(vm.envOr("OPTIONS_V21_DEPLOY_ALLOWED", false), "deployment not authorized");
        address registryAddress = vm.envAddress("OPTIONS_V21_REGISTRY");
        address oracle = vm.envAddress("OPTIONS_V21_ORACLE");
        uint256 optionId = vm.envUint("OPTIONS_V21_OPTION_ID");
        require(registryAddress.code.length != 0 && oracle.code.length != 0, "dependency absent");
        OptionProductRegistry registry = OptionProductRegistry(registryAddress);
        require(registry.owner() == TIMELOCK, "Registry owner mismatch");
        OptionProductRegistry.OptionSeries memory series = registry.getSeries(optionId);
        require(
            series.exists && !series.isActive && series.isCall && series.isEuropean && series.underlying == MWETH
                && series.settlementAsset == MUSDC && series.contractSize1e8 == 1e8 && series.strike == CANDIDATE_STRIKE
                && series.expiry == CANDIDATE_EXPIRY,
            "series policy mismatch"
        );
        require(block.timestamp < series.expiry, "candidate expiry elapsed");
        vm.startBroadcast();
        CoveredCallMarginEngine engine =
            new CoveredCallMarginEngine(TIMELOCK, registryAddress, optionId, oracle, 1_500, 48 hours);
        OptionMatchingEngine matcher = new OptionMatchingEngine(TIMELOCK, address(engine), registryAddress);
        vm.stopBroadcast();
        require(engine.paused() && engine.matchingEngine() == address(0), "engine active");
        require(
            engine.maxOpenContracts() == 0 && engine.makerFeePpm() == 0 && engine.takerFeePpm() == 0,
            "engine policy preset"
        );
        // OptionMatchingEngine grants its owner executor rights in the constructor.
        // Margin remains paused and unbound, so even the owner cannot open a lot.
        require(matcher.isExecutor(TIMELOCK), "matcher owner executor mismatch");
        console2.log("V21_PHYSICAL_ENGINE", address(engine));
        console2.log("V21_PHYSICAL_MATCHER", address(matcher));
    }
}
