// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";

/// @notice Isolated EVM rehearsal of the committed D1 creation bytes. No public send.
contract PerpsV2D1ExactCreationTest is Test {
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    bytes32 constant INITCODE_HASH = 0x04e445c4ce66e0e221f706cb58c7a55b41f6d98a1de85701d8531f9aa2d074b1;
    bytes32 constant RUNTIME_HASH = 0x7aca46efbadcc4b8770e5f399deb54a381eb3f32bff45126a8a9564ad34c24c5;

    function testCommittedExactD1CreationAndInitialState() public {
        bytes memory initcode =
            vm.parseJsonBytes(vm.readFile(vm.envString("D1_REVIEW_JSON_PATH")), ".creationTransactionData");
        assertEq(keccak256(initcode), INITCODE_HASH);
        address expectedLocalAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address deployed;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        assertEq(deployed, expectedLocalAddress);
        assertGt(deployed.code.length, 0);
        assertEq(deployed.codehash, RUNTIME_HASH);

        PerpMarketRegistry pmr = PerpMarketRegistry(deployed);
        assertEq(pmr.owner(), TIMELOCK);
        assertEq(pmr.pendingOwner(), address(0));
        assertEq(pmr.guardian(), address(0));
        assertFalse(pmr.paused());
        assertFalse(pmr.creationPaused());
        assertFalse(pmr.configPaused());
        assertEq(pmr.nextMarketId(), 1);
        assertEq(pmr.getAllMarketIds().length, 0);
        assertTrue(pmr.isMarketCreator(TIMELOCK));
        assertFalse(pmr.isMarketCreator(DEPLOYER));
        vm.prank(DEPLOYER);
        vm.expectRevert();
        pmr.setGuardian(DEPLOYER);
    }
}
