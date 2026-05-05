// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";

/// @notice Minimal replacement deployment for PerpMatchingEngine only.
/// @dev Use when the existing core stack should be preserved and only perp matching ABI changes.
contract DeployPerpMatchingEngine is Script {
    function run() external returns (address perpMatchingEngine) {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address initialOwner = vm.envOr("INITIAL_OWNER", deployer);
        address perpEngine = vm.envAddress("PERP_ENGINE");

        if (initialOwner == address(0)) revert("INITIAL_OWNER zero");
        if (perpEngine == address(0)) revert("PERP_ENGINE zero");
        if (perpEngine.code.length == 0) revert("PERP_ENGINE no code");

        vm.startBroadcast(deployerPrivateKey);

        perpMatchingEngine = address(new PerpMatchingEngine(initialOwner, perpEngine));

        vm.stopBroadcast();

        console2.log("DeOpt v2 PerpMatchingEngine deployment");
        console2.log("chainId", block.chainid);
        console2.log("deployer", deployer);
        console2.log("initialOwner", initialOwner);
        console2.log("PerpEngine", perpEngine);
        console2.log("PerpMatchingEngine", perpMatchingEngine);
    }
}
