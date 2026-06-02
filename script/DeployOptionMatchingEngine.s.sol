// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {OptionMatchingEngine} from "../src/matching/OptionMatchingEngine.sol";

/// @notice Isolated deployment for the dedicated option execution ingress.
/// @dev Deploy after DeployCore and before WireCore when option intent execution is enabled.
///
///      V2G-P signer-source patch: `DEPLOYER_PRIVATE_KEY` is now optional. When
///      unset the script broadcasts via `vm.startBroadcast()` (no-arg), so the
///      operator can sign with Foundry's `--account <keystore>` /
///      `--sender <addr>` CLI flags instead of an env-supplied key.
contract DeployOptionMatchingEngine is Script {
    /// @notice V2G-P — only address allowed to deploy a new V2 OptionMatchingEngine.
    ///         Matches the live owner of every V2 contract on Base Sepolia.
    address internal constant CANONICAL_DEPLOYER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    error DeployerPrivateKeyAddressMismatch(address fromPk, address fromEnv);
    error DeployerNotCanonical(address provided, address required);

    function run() external returns (address optionMatchingEngine) {
        // V2G-P keystore mode: PK is optional; deployer address taken from env or
        // canonical default. Validate equality + canonical-deployer guard.
        uint256 deployerPrivateKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address envDeployer = vm.envOr("DEPLOYER_ADDRESS", CANONICAL_DEPLOYER);

        address deployer;
        if (deployerPrivateKey != 0) {
            deployer = vm.addr(deployerPrivateKey);
            if (deployer != envDeployer) {
                revert DeployerPrivateKeyAddressMismatch(deployer, envDeployer);
            }
        } else {
            deployer = envDeployer;
        }
        if (deployer != CANONICAL_DEPLOYER) {
            revert DeployerNotCanonical(deployer, CANONICAL_DEPLOYER);
        }

        address initialOwner = vm.envOr("INITIAL_OWNER", deployer);
        address marginEngine = vm.envAddress("MARGIN_ENGINE");
        address optionRegistry = vm.envAddress("OPTION_PRODUCT_REGISTRY");

        if (initialOwner == address(0)) revert("INITIAL_OWNER zero");
        if (marginEngine == address(0)) revert("MARGIN_ENGINE zero");
        if (optionRegistry == address(0)) revert("OPTION_PRODUCT_REGISTRY zero");
        if (marginEngine.code.length == 0) revert("MARGIN_ENGINE no code");
        if (optionRegistry.code.length == 0) revert("OPTION_PRODUCT_REGISTRY no code");

        console2.log("DeOpt v2 OptionMatchingEngine deployment (V2G-P keystore-aware)");
        console2.log("chainId", block.chainid);
        console2.log("deployer (sanitized, no key)", deployer);
        console2.log(
            "signer source", deployerPrivateKey != 0 ? "DEPLOYER_PRIVATE_KEY env" : "Foundry --account / --sender"
        );
        console2.log("initialOwner", initialOwner);
        console2.log("MarginEngine", marginEngine);
        console2.log("OptionProductRegistry", optionRegistry);

        if (deployerPrivateKey != 0) {
            vm.startBroadcast(deployerPrivateKey);
        } else {
            vm.startBroadcast();
        }

        optionMatchingEngine = address(new OptionMatchingEngine(initialOwner, marginEngine, optionRegistry));

        vm.stopBroadcast();

        console2.log("OptionMatchingEngine", optionMatchingEngine);
        console2.log(string.concat("OPTION_MATCHING_ENGINE_ADDR=", vm.toString(optionMatchingEngine)));
    }
}
