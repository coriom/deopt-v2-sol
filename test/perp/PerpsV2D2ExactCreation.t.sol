// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";

/// @notice Isolated deployment of the committed D2 initcode; no public transaction.
contract PerpsV2D2ExactCreationTest is Test {
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant STRANDED_ENGINE = 0xA2bDc0EfE80806FFda20189294dd8A5a1B426f15;
    bytes32 constant INITCODE_HASH = 0xe9eb51f9ea8910be2be794f5f69441bfefe68c8ec69ae424ebcd3ed051f78169;
    bytes32 constant RUNTIME_HASH = 0x732101d67fb112f6d3159f32852071bbf995f8bd1995335cf9a2b0f167d08726;

    function testCommittedExactD2CreationAndInitialLiabilityState() public {
        bytes memory initcode =
            vm.parseJsonBytes(vm.readFile(vm.envString("D2_REVIEW_JSON_PATH")), ".creationTransactionData");
        assertEq(keccak256(initcode), INITCODE_HASH);
        address expectedLocalAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address deployed;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        assertEq(deployed, expectedLocalAddress);
        assertGt(deployed.code.length, 0);
        assertEq(deployed.codehash, RUNTIME_HASH);

        FeesManagerV2 fees = FeesManagerV2(deployed);
        assertEq(fees.owner(), TIMELOCK);
        assertEq(fees.feeRecipient(), TIMELOCK);
        assertEq(fees.protocolFeeVault(), address(0));
        assertEq(fees.rebateFundingAccount(), address(0));
        assertEq(fees.rebateBudget(TOKEN), 0);
        assertEq(fees.merkleRoot(), bytes32(0));
        assertEq(fees.rootValidFrom(), 0);
        assertEq(fees.rootValidUntil(), 0);
        assertEq(fees.claimedTiers(DEPLOYER).validUntil, 0);
        assertFalse(fees.isFeeConsumer(STRANDED_ENGINE));
        vm.prank(DEPLOYER);
        vm.expectRevert(FeesManagerV2.NotOwner.selector);
        fees.setFeeConsumer(STRANDED_ENGINE, true);
    }
}
