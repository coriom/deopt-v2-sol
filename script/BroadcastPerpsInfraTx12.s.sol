// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PerpMatchingEngine} from "../src/matching/PerpMatchingEngine.sol";

/// @notice PERPS_BASE_SEPOLIA_TX12_DEPLOYER_EXECUTOR_REVOKE_V1 - broadcasts
///         ONLY TX-12: PerpMatchingEngine.setExecutor(DEPLOYER, false).
///
///         Fails closed on any drift:
///           - wrong chain id
///           - PME target mismatch
///           - owner != deployer
///           - **new executor NOT enabled** (TX-11 not landed)
///           - **new executor balance < 0.002 ether** (closed-test threshold;
///             prevents authorized-but-unfunded lockout)
///           - PME paused
///           - tx.origin != expected deployer
///           - calldata keccak mismatch against the frozen value
///
///         Does NOT touch the new executor role (unchanged, verified true).
///         Contains no other state-changing call.
///
///         POST-execution: new executor is the SOLE authorized executor. If
///         the new executor keystore signing path is broken, matching
///         engine execution stops until the deployer executor is re-enabled.
///         The pre-check balance guard is a partial safety net; the full
///         operational verification (identity, sign-test) is out-of-band.
contract BroadcastPerpsInfraTx12 is Script {
    uint256 internal constant BASE_SEPOLIA_CHAIN_ID = 84532;

    address internal constant PME          = 0x774d96E5739bffadEE91508b4D3D74F5BE29F165;
    address internal constant DEPLOYER     = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address internal constant NEW_EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;

    // Closed-test funding threshold (revised by operator directive; NOT a
    // production policy). Ensures the sole remaining executor has enough
    // Base Sepolia ETH to sign runtime matching txs.
    uint256 internal constant EXECUTOR_MIN_BALANCE = 0.002 ether;

    // Frozen calldata for setExecutor(DEPLOYER, false) - Perps FINAL manifest 5f93e199
    bytes32 internal constant FROZEN_CALLDATA_KECCAK =
        0x905fb3f8aad76e84e11e1906d78e987536979a634b62163f2d17d96f4c7323a3;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "chain id must be 84532");

        PerpMatchingEngine pme = PerpMatchingEngine(PME);
        require(pme.owner() == DEPLOYER, "PME.owner != deployer");
        require(!pme.paused(), "PME is paused");
        require(pme.isExecutor(NEW_EXECUTOR), "new executor NOT enabled (TX-11 not landed)");
        require(pme.isExecutor(DEPLOYER), "deployer executor already revoked (idempotent refusal)");
        require(
            NEW_EXECUTOR.balance >= EXECUTOR_MIN_BALANCE,
            "new executor balance below closed-test funding threshold (0.002 ether)"
        );

        bytes memory calldataBytes = abi.encodeWithSelector(
            PerpMatchingEngine.setExecutor.selector,
            DEPLOYER,
            false
        );
        require(keccak256(calldataBytes) == FROZEN_CALLDATA_KECCAK, "calldata keccak mismatch");

        console2.log("=================================================================");
        console2.log("PERPS_BASE_SEPOLIA_TX12_DEPLOYER_EXECUTOR_REVOKE");
        console2.log("=================================================================");
        console2.log("chain id              :", block.chainid);
        console2.log("block number          :", block.number);
        console2.log("PME target            :", PME);
        console2.log("PME.owner (pre)       :", pme.owner());
        console2.log("PME.paused (pre)      :", pme.paused());
        console2.log("isExecutor(new,pre)   :", pme.isExecutor(NEW_EXECUTOR));
        console2.log("isExecutor(dep,pre)   :", pme.isExecutor(DEPLOYER));
        console2.log("new executor balance  :", NEW_EXECUTOR.balance);
        console2.log("threshold (0.002 eth) :", EXECUTOR_MIN_BALANCE);
        console2.log("expected signer       :", DEPLOYER);
        console2.log("frozen calldata keccak:");
        console2.logBytes32(FROZEN_CALLDATA_KECCAK);

        vm.startBroadcast();

        require(tx.origin == DEPLOYER, "signer address is not the expected deployer");

        pme.setExecutor(DEPLOYER, false);

        vm.stopBroadcast();

        // Postcondition assertions
        require(pme.isExecutor(NEW_EXECUTOR), "post: new executor unexpectedly revoked");
        require(!pme.isExecutor(DEPLOYER), "post: deployer executor NOT revoked");
        require(pme.owner() == DEPLOYER, "post: owner mutated (unexpected)");
        require(!pme.paused(), "post: paused mutated");

        console2.log("");
        console2.log("=================================================================");
        console2.log("TX-12 broadcast complete. Post-state:");
        console2.log("  isExecutor(new)     :", pme.isExecutor(NEW_EXECUTOR));
        console2.log("  isExecutor(deployer):", pme.isExecutor(DEPLOYER));
        console2.log("  PME.owner           :", pme.owner());
        console2.log("  PME.paused          :", pme.paused());
        console2.log("=================================================================");
    }
}
