// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";

/// @notice PERPS_BASE_SEPOLIA_TX11_EXECUTOR_ENABLE_V1 - broadcasts ONLY
///         TX-11: PerpMatchingEngine.setExecutor(NEW_EXECUTOR, true).
///
///         Fails closed on any drift:
///           - wrong chain id
///           - PME target mismatch
///           - owner != deployer
///           - deployer executor role missing
///           - new executor already enabled (idempotent refusal)
///           - PME paused
///           - tx.origin != expected deployer
///           - calldata keccak mismatch against the frozen value
///
///         Does NOT revoke the deployer executor (that is TX-12, separate).
///         Contains no other state-changing call.
///
///         Invocation (operator - password prompt hits /dev/tty on their terminal):
///           forge script script/BroadcastPerpsInfraTx11.s.sol \
///             --rpc-url https://sepolia.base.org \
///             --broadcast \
///             --sender 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27 \
///             --keystore /home/corio/.foundry/keystores/deopt-deployer
contract BroadcastPerpsInfraTx11 is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    address internal constant PME          = 0x774d96E5739bffadEE91508b4D3D74F5BE29F165;
    address internal constant DEPLOYER     = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address internal constant NEW_EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;

    // Frozen calldata for setExecutor(NEW_EXECUTOR, true) - Perps FINAL manifest 5f93e199 / 906ef8f
    bytes32 internal constant FROZEN_CALLDATA_KECCAK =
        0xbd7f4082a38a7039ba7b501f389d279813bbe95aa72cc6eb97fc9387c0cddf89;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "chain id must be 84532");

        PerpMatchingEngine pme = PerpMatchingEngine(PME);
        require(pme.owner() == DEPLOYER, "PME.owner != deployer");
        require(!pme.paused(), "PME is paused");
        require(!pme.isExecutor(NEW_EXECUTOR), "new executor already enabled (idempotent refusal)");
        require(pme.isExecutor(DEPLOYER), "deployer is not a current executor");

        bytes memory calldataBytes = abi.encodeWithSelector(
            PerpMatchingEngine.setExecutor.selector,
            NEW_EXECUTOR,
            true
        );
        require(keccak256(calldataBytes) == FROZEN_CALLDATA_KECCAK, "calldata keccak mismatch");

        console2.log("=================================================================");
        console2.log("PERPS_BASE_SEPOLIA_TX11_EXECUTOR_ENABLE");
        console2.log("=================================================================");
        console2.log("chain id           :", block.chainid);
        console2.log("block number       :", block.number);
        console2.log("PME target         :", PME);
        console2.log("PME.owner (pre)    :", pme.owner());
        console2.log("PME.paused (pre)   :", pme.paused());
        console2.log("isExecutor(new,pre):", pme.isExecutor(NEW_EXECUTOR));
        console2.log("isExecutor(dep,pre):", pme.isExecutor(DEPLOYER));
        console2.log("expected signer    :", DEPLOYER);
        console2.log("frozen calldata keccak:");
        console2.logBytes32(FROZEN_CALLDATA_KECCAK);

        vm.startBroadcast();

        require(tx.origin == DEPLOYER, "signer address is not the expected deployer");

        pme.setExecutor(NEW_EXECUTOR, true);

        vm.stopBroadcast();

        // Postcondition assertions - refuse to persist the broadcast artefact if state didn't advance as expected.
        require(pme.isExecutor(NEW_EXECUTOR), "post: new executor NOT enabled");
        require(pme.isExecutor(DEPLOYER), "post: deployer executor unexpectedly revoked");
        require(pme.owner() == DEPLOYER, "post: owner mutated (unexpected)");
        require(!pme.paused(), "post: paused mutated");

        console2.log("");
        console2.log("=================================================================");
        console2.log("TX-11 broadcast complete. Post-state:");
        console2.log("  isExecutor(new)     :", pme.isExecutor(NEW_EXECUTOR));
        console2.log("  isExecutor(deployer):", pme.isExecutor(DEPLOYER));
        console2.log("  PME.owner           :", pme.owner());
        console2.log("  PME.paused          :", pme.paused());
        console2.log("=================================================================");
    }
}
