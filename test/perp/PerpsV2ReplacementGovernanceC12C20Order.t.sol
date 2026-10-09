// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpRiskModule} from "../../src/perp/PerpRiskModule.sol";

/// @notice Isolated local rehearsal. No public fork or transaction is used.
contract PerpsV2ReplacementGovernanceC12C20OrderTest is Test {
    address internal constant SAFE = address(0xA6B9);
    ProtocolTimelock internal timelock;
    PerpEngineV2 internal engine;
    PerpRiskModule internal risk;

    function setUp() public {
        vm.warp(1_800_000_000);
        timelock = new ProtocolTimelock(SAFE, SAFE, 1 days);
        engine = new PerpEngineV2(address(timelock), address(0x11), address(0x12), address(0x13));
        risk = new PerpRiskModule(address(timelock), address(0x12), address(engine), address(0x13), address(0x14));
    }

    function _queue(address target, bytes memory data, uint256 eta) internal returns (bytes32) {
        vm.prank(SAFE);
        return timelock.queueTransaction(target, 0, data, eta);
    }

    function _execute(address target, bytes memory data, uint256 eta) internal {
        vm.prank(SAFE);
        timelock.executeTransaction(target, 0, data, eta);
    }

    function _ready() internal view returns (bool) {
        return risk.maxOracleDelay() == 600 && address(risk.perpEngine()) == address(engine)
            && engine.riskModule() == address(0) && uint8(engine.migrationState()) == 0 && engine.tradingPaused()
            && engine.liquidationPaused() && engine.fundingPaused() && engine.collateralOpsPaused();
    }

    function testC20MustClearRealTimelockDelayBeforeC12Readiness() public {
        assertEq(risk.maxOracleDelay(), 0);
        assertFalse(_ready());
        assertEq(engine.riskModule(), address(0));
        assertEq(uint8(engine.migrationState()), 0);

        bytes memory maintenance = abi.encodeCall(engine.setEmergencyModes, (true, true, true, true));
        uint256 maintenanceEta = block.timestamp + timelock.minDelay();
        _queue(address(engine), maintenance, maintenanceEta);
        vm.warp(maintenanceEta);
        _execute(address(engine), maintenance, maintenanceEta);
        assertFalse(_ready());

        bytes memory c20 = abi.encodeCall(risk.setMaxOracleDelay, (600));
        uint256 eta = block.timestamp + timelock.minDelay();
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.EtaTooSoon.selector);
        timelock.queueTransaction(address(risk), 0, c20, eta - 1);
        bytes32 op = _queue(address(risk), c20, eta);
        assertTrue(timelock.queuedTransactions(op));
        assertFalse(_ready()); // queued-only C20 cannot unlock C12
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        timelock.executeTransaction(address(risk), 0, c20, eta);
        vm.warp(eta);
        _execute(address(risk), c20, eta);
        assertFalse(timelock.queuedTransactions(op));
        assertEq(risk.maxOracleDelay(), 600);
        assertTrue(_ready());
        assertEq(engine.riskModule(), address(0)); // C12 still separate and unexecuted

        bytes memory change = abi.encodeCall(risk.setMaxOracleDelay, (599));
        uint256 secondEta = block.timestamp + timelock.minDelay();
        _queue(address(risk), change, secondEta);
        vm.warp(secondEta);
        _execute(address(risk), change, secondEta);
        assertEq(risk.maxOracleDelay(), 599);
        assertFalse(_ready()); // subsequent configuration invalidates readiness
        assertEq(engine.riskModule(), address(0));
    }
}
