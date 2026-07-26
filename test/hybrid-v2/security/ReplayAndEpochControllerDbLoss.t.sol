// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";

import {ReplayAndEpochControllerHarness} from "./harness/ReplayAndEpochControllerHarness.sol";
import {IReplayAndEpochController} from "../../../src/hybrid-v2/security/IReplayAndEpochController.sol";
import {ReplayAndEpochController} from "../../../src/hybrid-v2/security/ReplayAndEpochController.sol";
import {SubaccountRegistry} from "../../../src/hybrid-v2/registry/SubaccountRegistry.sol";
import {Versions} from "../../../src/hybrid-v2/libraries/Versions.sol";

/// @title ReplayAndEpochControllerDbLoss
/// @notice L8 database-loss + chain-only reconstruction drill for the WP-05 foundation.
///
/// Models "backend PostgreSQL loss" as: any off-chain ghost store the reconciler owned
/// is dropped. The on-chain contract remains authoritative. Duplicate D.2 action
/// execution MUST remain rejected. Recovery epoch state MUST reconstruct from events
/// alone. INV-AUTH-05 + INV-AUTH-06.
contract ReplayAndEpochControllerDbLoss is Test {
    ReplayAndEpochControllerHarness internal controller;
    SubaccountRegistry internal registry;

    address internal owner = address(0xB1);
    address internal signer = address(0xC1);
    address internal recoveryAuthority = address(0xA1);

    function setUp() public {
        registry = new SubaccountRegistry(address(0xDEAD));
        controller =
            new ReplayAndEpochControllerHarness(address(registry), "DeOptV2-TestEngine", "1", recoveryAuthority);
        vm.prank(owner);
        registry.registerNext();
    }

    /*//////////////////////////////////////////////////////////////
                     DB LOSS: CONSUMED INTENT REMAINS
    //////////////////////////////////////////////////////////////*/

    function test_dbLoss_consumedIntentRemainsRejected() public {
        bytes32 intent = keccak256("real-order");
        controller.consumeIntent(intent, signer, keccak256("SUBMIT_OPTION_ORDER"));
        assertTrue(controller.isIntentConsumed(intent));

        // "Backend PostgreSQL is destroyed" — we do NOT touch on-chain storage. The
        // contract remains authoritative. The intent MUST remain consumed.
        // Chain state observability:
        assertTrue(controller.isIntentConsumed(intent), "chain-side state survives DB loss");
        // Duplicate execution remains rejected.
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.IntentReplayed.selector, intent));
        controller.consumeIntent(intent, signer, keccak256("SUBMIT_OPTION_ORDER"));
    }

    function test_dbLoss_nonceStateRemains() public {
        controller.consumeNonce(signer, 0);
        controller.consumeNonce(signer, 1);
        controller.consumeNonce(signer, 2);
        assertEq(controller.nonces(signer), 3);
        // Re-attempt nonce=2: rejected.
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.BadNonce.selector, signer, 3, 2));
        controller.consumeNonce(signer, 2);
    }

    /*//////////////////////////////////////////////////////////////
                RECONSTRUCT REPLAY STATE FROM EVENTS
    //////////////////////////////////////////////////////////////*/

    function test_reconstruct_intentSetFromEvents() public {
        bytes32 h1 = keccak256("i1");
        bytes32 h2 = keccak256("i2");
        bytes32 h3 = keccak256("i3");

        vm.recordLogs();
        controller.consumeIntent(h1, signer, keccak256("A"));
        controller.consumeIntent(h2, signer, keccak256("A"));
        controller.consumeIntent(h3, signer, keccak256("B"));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Rebuild the consumed-hash set from events alone.
        bytes32 intentConsumedTopic = keccak256("IntentConsumed(bytes32,address,address,bytes32,uint16)");
        bytes32[] memory reconstructed = new bytes32[](3);
        uint256 seen;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == intentConsumedTopic) {
                reconstructed[seen++] = entries[i].topics[1];
            }
        }
        assertEq(seen, 3);
        // Assert on-chain view matches every rebuilt entry.
        for (uint256 j = 0; j < seen; j++) {
            assertTrue(controller.isIntentConsumed(reconstructed[j]));
        }
    }

    function test_reconstruct_ownerEpochFromEvents() public {
        vm.recordLogs();
        vm.prank(owner);
        controller.advanceMyOwnerRecoveryEpoch();
        vm.prank(owner);
        controller.advanceMyOwnerRecoveryEpoch();
        vm.prank(owner);
        controller.advanceMyOwnerRecoveryEpoch();
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 topic = keccak256("OwnerRecoveryEpochAdvanced(address,uint256,uint256,address,uint16)");
        uint256 highestNewEpoch;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == topic && address(uint160(uint256(entries[i].topics[1]))) == owner) {
                (uint256 prev, uint256 next,,) = abi.decode(entries[i].data, (uint256, uint256, address, uint16));
                assertEq(next, prev + 1, "monotonic advance");
                if (next > highestNewEpoch) highestNewEpoch = next;
            }
        }
        assertEq(highestNewEpoch, controller.ownerRecoveryEpoch(owner));
    }

    function test_reconstruct_subaccountEpochFromEvents() public {
        bytes32 subKey = registry.subKeyOf(owner, 1);
        vm.recordLogs();
        vm.prank(owner);
        controller.advanceMySubaccountRecoveryEpoch(1);
        vm.prank(owner);
        controller.advanceMySubaccountRecoveryEpoch(1);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 topic =
            keccak256("SubaccountRecoveryEpochAdvanced(bytes32,address,uint32,uint256,uint256,address,uint16)");
        uint256 highestNext;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == topic && entries[i].topics[1] == subKey) {
                (, uint256 prev, uint256 next,,) =
                    abi.decode(entries[i].data, (uint32, uint256, uint256, address, uint16));
                assertEq(next, prev + 1);
                if (next > highestNext) highestNext = next;
            }
        }
        assertEq(highestNext, controller.subaccountRecoveryEpoch(subKey));
    }

    /*//////////////////////////////////////////////////////////////
             D.1 RESTART-EMPTY DOES NOT ENABLE D.2 REPLAY
    //////////////////////////////////////////////////////////////*/

    function test_d1RestartEmpty_cannotFabricateD2Availability() public {
        // Model a D.1 restart-empty scenario. In production the backend's
        // `used_nonces_v2` table (D.1 API-level replay guard) is dropped and reseeded
        // as empty. In this Foundry test we simulate that by simply having a fresh
        // "backend" (no seen intents) after some D.2 consumption on chain.
        bytes32 intent = keccak256("submitted-order");
        // Backend accepts the order, chain-side D.2 consumption records it.
        controller.consumeIntent(intent, signer, keccak256("SUBMIT_OPTION_ORDER"));

        // Backend loses D.1 state. A malicious operator re-submits the same order.
        // Chain-side D.2 barrier blocks the duplicate.
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.IntentReplayed.selector, intent));
        controller.consumeIntent(intent, signer, keccak256("SUBMIT_OPTION_ORDER"));

        // Sequential nonce path: same behavior — chain state persists.
        controller.consumeNonce(signer, 0);
        vm.expectRevert(abi.encodeWithSelector(ReplayAndEpochController.BadNonce.selector, signer, 1, 0));
        controller.consumeNonce(signer, 0);
    }
}
