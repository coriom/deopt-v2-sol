// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpEngineTypes} from "../../src/perp/PerpEngineTypes.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";

/// @notice Replacement-source policy test. No fork or public chain state is used.
contract PerpsV2ReplacementGuardianTest is Test {
    address internal constant TIMELOCK = address(0x71);
    address internal constant SAFE = address(0x5afe);
    address internal constant DEPLOYER = address(0xd3);
    address internal constant EXECUTOR = address(0xe3);

    PerpMarketRegistry internal pmr;
    PerpEngineV2 internal engine;

    function setUp() public {
        vm.startPrank(DEPLOYER);
        pmr = new PerpMarketRegistry(TIMELOCK);
        engine = new PerpEngineV2(TIMELOCK, address(pmr), address(0x100), address(0x101));
        vm.stopPrank();
        vm.startPrank(TIMELOCK);
        pmr.setGuardian(SAFE);
        engine.setGuardian(SAFE);
        vm.stopPrank();
    }

    function testDirectTimelockOwnershipAndNoPendingOwner() public view {
        assertEq(pmr.owner(), TIMELOCK);
        assertEq(pmr.pendingOwner(), address(0));
        assertEq(engine.owner(), TIMELOCK);
        assertEq(engine.pendingOwner(), address(0));
        assertLe(address(engine).code.length, 24_576);
    }

    function testGuardianCanTightenButCannotRelaxEngineFlags() public {
        vm.prank(SAFE);
        engine.setEmergencyModes(true, false, false, false);
        assertTrue(engine.tradingPaused());
        vm.prank(SAFE);
        engine.setEmergencyModes(true, true, true, true);
        vm.prank(SAFE);
        vm.expectRevert(PerpEngineTypes.GuardianCannotRelaxEmergency.selector);
        engine.setEmergencyModes(true, false, true, true);
        vm.prank(TIMELOCK);
        engine.setEmergencyModes(false, false, false, false);
        assertFalse(engine.tradingPaused());
        assertFalse(engine.fundingPaused());
    }

    function testGuardianCannotHideEngineReleaseInMixedTransition() public {
        vm.prank(SAFE);
        engine.setEmergencyModes(true, false, false, false);
        vm.prank(SAFE);
        vm.expectRevert(PerpEngineTypes.GuardianCannotRelaxEmergency.selector);
        engine.setEmergencyModes(false, true, true, true);
        assertTrue(engine.tradingPaused());
        assertFalse(engine.liquidationPaused());
    }

    function testGuardianCanTightenButCannotRelaxPmrFlags() public {
        vm.prank(SAFE);
        pmr.setEmergencyModes(true, false);
        assertTrue(pmr.creationPaused());
        vm.prank(SAFE);
        vm.expectRevert(PerpMarketRegistry.GuardianCannotRelaxEmergency.selector);
        pmr.setEmergencyModes(false, true);
        vm.prank(TIMELOCK);
        pmr.setEmergencyModes(false, false);
        assertFalse(pmr.creationPaused());
    }

    function testLostDeployerAndExecutorCannotAdminister() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(PerpEngineTypes.GuardianNotAuthorized.selector);
        engine.setEmergencyModes(true, true, true, true);
        vm.prank(EXECUTOR);
        vm.expectRevert(PerpMarketRegistry.GuardianNotAuthorized.selector);
        pmr.setEmergencyModes(true, true);
        vm.prank(DEPLOYER);
        vm.expectRevert(PerpEngineTypes.NotAuthorized.selector);
        engine.setGuardian(DEPLOYER);
        vm.prank(DEPLOYER);
        vm.expectRevert(PerpMarketRegistry.NotAuthorized.selector);
        pmr.setGuardian(DEPLOYER);
    }
}
