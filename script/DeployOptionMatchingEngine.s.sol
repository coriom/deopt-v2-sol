// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";

/// @notice Isolated deployment for the dedicated option execution ingress.
/// @dev Deploy after DeployCore and before WireCore when option intent execution is enabled.
contract DeployOptionMatchingEngine is Script {
    function run() external returns (address optionMatchingEngine) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address initialOwner = vm.envOr("INITIAL_OWNER", deployer);
        address marginEngine = vm.envAddress("MARGIN_ENGINE");
        address optionRegistry = vm.envAddress("OPTION_PRODUCT_REGISTRY");

        if (initialOwner == address(0)) revert("INITIAL_OWNER zero");
        if (marginEngine == address(0)) revert("MARGIN_ENGINE zero");
        if (optionRegistry == address(0)) revert("OPTION_PRODUCT_REGISTRY zero");
        if (marginEngine.code.length == 0) revert("MARGIN_ENGINE no code");
        if (optionRegistry.code.length == 0) revert("OPTION_PRODUCT_REGISTRY no code");

        vm.startBroadcast(deployerPrivateKey);

        optionMatchingEngine = address(new OptionMatchingEngine(initialOwner, marginEngine, optionRegistry));

        vm.stopBroadcast();

        console2.log("DeOpt v2 OptionMatchingEngine deployment");
        console2.log("chainId", block.chainid);
        console2.log("deployer", deployer);
        console2.log("initialOwner", initialOwner);
        console2.log("MarginEngine", marginEngine);
        console2.log("OptionProductRegistry", optionRegistry);
        console2.log("OptionMatchingEngine", optionMatchingEngine);
        console2.log(string.concat("OPTION_MATCHING_ENGINE_ADDR=", vm.toString(optionMatchingEngine)));
    }
}
