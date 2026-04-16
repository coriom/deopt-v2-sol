// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {FeesManager} from "../../../src/fees/FeesManager.sol";
import {IFeesManagerGov} from "../../../src/gouvernance/RiskGovernorInterfaces.sol";
import {ProtocolTimelock} from "../../../src/gouvernance/ProtocolTimelock.sol";
import {RiskGovernor} from "../../../src/gouvernance/RiskGovernor.sol";
import {RiskGovernorStorage} from "../../../src/gouvernance/RiskGovernorStorage.sol";

contract GovernanceTest is Test {
    uint256 internal constant MIN_DELAY = 1 hours;

    address internal constant OWNER = address(0xA11CE);
    address internal constant GUARDIAN = address(0xB0B);
    address internal constant PROPOSER = address(0xCAFE);
    address internal constant ALICE = address(0xA1);
    address internal constant NEW_GUARDIAN = address(0xD00D);

    ProtocolTimelock internal timelock;
    RiskGovernor internal governor;
    FeesManager internal feesManager;

    function setUp() external {
        timelock = new ProtocolTimelock(OWNER, GUARDIAN, MIN_DELAY);
        feesManager = new FeesManager(
            address(timelock),
            2,
            4,
            5,
            6,
            100
        );

        governor = new RiskGovernor(
            OWNER,
            GUARDIAN,
            address(timelock),
            address(0),
            address(0),
            address(0),
            address(feesManager),
            address(0),
            address(0),
            address(0),
            address(0),
            address(0)
        );

        vm.startPrank(OWNER);
        timelock.setProposer(address(governor), true);
        timelock.setExecutor(address(governor), true);
        timelock.setGuardian(address(governor));
        timelock.setProposer(PROPOSER, true);
        vm.stopPrank();
    }

    function testQueueOperationStoresTheCorrectOperationHash() external {
        uint256 eta = _eta();
        bytes memory data = abi.encodeCall(IFeesManagerGov.setFeeBpsCap, (55));

        bytes32 expectedHash = governor.hashOperation(address(feesManager), 0, data, eta);

        vm.prank(OWNER);
        bytes32 queuedHash = governor.queueOperation(address(feesManager), 0, data, eta);

        (
            address target,
            uint256 value,
            uint256 storedEta,
            bytes memory storedData,
            RiskGovernorStorage.OperationState state
        ) = governor.getQueuedOperation(expectedHash);

        assertEq(queuedHash, expectedHash);
        assertTrue(timelock.queuedTransactions(expectedHash));
        assertEq(target, address(feesManager));
        assertEq(value, 0);
        assertEq(storedEta, eta);
        assertEq(storedData, data);
        assertEq(uint256(state), uint256(RiskGovernorStorage.OperationState.Queued));
    }

    function testCancelOperationMarksAQueuedOperationAsCancelled() external {
        uint256 eta = _eta();
        bytes memory data = abi.encodeCall(IFeesManagerGov.setFeeBpsCap, (55));

        vm.prank(OWNER);
        bytes32 txHash = governor.queueOperation(address(feesManager), 0, data, eta);

        vm.prank(OWNER);
        governor.cancelOperation(address(feesManager), 0, data, eta);

        (, , , , RiskGovernorStorage.OperationState state) = governor.getQueuedOperation(txHash);

        assertFalse(timelock.queuedTransactions(txHash));
        assertEq(uint256(state), uint256(RiskGovernorStorage.OperationState.Cancelled));
    }

    function testExecuteOperationRevertsIfCalledBeforeEta() external {
        uint256 eta = _eta();
        bytes memory data = abi.encodeCall(IFeesManagerGov.setGuardian, (NEW_GUARDIAN));

        vm.prank(OWNER);
        bytes32 txHash = governor.queueOperation(address(feesManager), 0, data, eta);

        vm.warp(eta - 1);

        vm.prank(OWNER);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        governor.executeOperation(address(feesManager), 0, data, eta);

        (, , , , RiskGovernorStorage.OperationState state) = governor.getQueuedOperation(txHash);
        assertTrue(timelock.queuedTransactions(txHash));
        assertEq(uint256(state), uint256(RiskGovernorStorage.OperationState.Queued));
    }

    function testExecuteOperationSucceedsAfterEta() external {
        uint256 eta = _eta();
        bytes memory data = abi.encodeCall(IFeesManagerGov.setGuardian, (NEW_GUARDIAN));

        vm.prank(OWNER);
        bytes32 txHash = governor.queueOperation(address(feesManager), 0, data, eta);

        vm.warp(eta);

        vm.prank(OWNER);
        governor.executeOperation(address(feesManager), 0, data, eta);

        (, , , , RiskGovernorStorage.OperationState state) = governor.getQueuedOperation(txHash);

        assertEq(feesManager.guardian(), NEW_GUARDIAN);
        assertFalse(timelock.queuedTransactions(txHash));
        assertEq(uint256(state), uint256(RiskGovernorStorage.OperationState.Executed));
    }

    function testExecutingAQueuedParameterChangeUpdatesTheTargetModuleCorrectly() external {
        uint256 eta = _eta();

        vm.prank(OWNER);
        bytes32 txHash = governor.queueFeesSetFeeBpsCap(77, eta);

        vm.warp(eta);

        bytes memory data = abi.encodeCall(IFeesManagerGov.setFeeBpsCap, (77));

        vm.prank(OWNER);
        governor.executeOperation(address(feesManager), 0, data, eta);

        (, , , , RiskGovernorStorage.OperationState state) = governor.getQueuedOperation(txHash);

        assertEq(feesManager.feeBpsCap(), 77);
        assertEq(uint256(state), uint256(RiskGovernorStorage.OperationState.Executed));
    }

    function testOnlyAuthorizedOwnerProposerPathsCanQueueOperations() external {
        uint256 eta = _eta();
        bytes memory data = abi.encodeCall(IFeesManagerGov.setFeeBpsCap, (55));

        vm.prank(ALICE);
        vm.expectRevert(RiskGovernorStorage.NotAuthorized.selector);
        governor.queueOperation(address(feesManager), 0, data, eta);

        vm.prank(ALICE);
        vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
        timelock.queueTransaction(address(feesManager), 0, data, eta);

        vm.prank(OWNER);
        bytes32 governorHash = governor.queueOperation(address(feesManager), 0, data, eta);
        assertTrue(timelock.queuedTransactions(governorHash));

        uint256 directEta = eta + 1;
        vm.prank(PROPOSER);
        bytes32 proposerHash = timelock.queueTransaction(address(feesManager), 0, data, directEta);
        assertTrue(timelock.queuedTransactions(proposerHash));
    }

    function testGuardianOwnerCancelPermissionsBehaveCorrectly() external {
        uint256 etaA = _eta();
        bytes memory dataA = abi.encodeCall(IFeesManagerGov.setFeeBpsCap, (55));

        vm.prank(OWNER);
        bytes32 hashA = governor.queueOperation(address(feesManager), 0, dataA, etaA);

        vm.prank(GUARDIAN);
        governor.cancelOperation(address(feesManager), 0, dataA, etaA);

        (, , , , RiskGovernorStorage.OperationState stateA) = governor.getQueuedOperation(hashA);
        assertEq(uint256(stateA), uint256(RiskGovernorStorage.OperationState.Cancelled));

        uint256 etaB = etaA + 1;
        bytes memory dataB = abi.encodeCall(IFeesManagerGov.setGuardian, (NEW_GUARDIAN));

        vm.prank(OWNER);
        bytes32 hashB = governor.queueOperation(address(feesManager), 0, dataB, etaB);

        vm.prank(OWNER);
        governor.cancelOperation(address(feesManager), 0, dataB, etaB);

        (, , , , RiskGovernorStorage.OperationState stateB) = governor.getQueuedOperation(hashB);
        assertEq(uint256(stateB), uint256(RiskGovernorStorage.OperationState.Cancelled));
    }

    function testMalformedOrMismatchedCalldataCannotExecuteSuccessfully() external {
        uint256 eta = _eta();
        bytes memory malformedData = abi.encodeWithSelector(IFeesManagerGov.setFeeBpsCap.selector);

        vm.prank(OWNER);
        bytes32 txHash = governor.queueOperation(address(feesManager), 0, malformedData, eta);

        vm.warp(eta);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(ProtocolTimelock.TransactionExecutionFailed.selector, bytes("")));
        governor.executeOperation(address(feesManager), 0, malformedData, eta);

        (, , , , RiskGovernorStorage.OperationState state) = governor.getQueuedOperation(txHash);
        assertEq(feesManager.feeBpsCap(), 100);
        assertTrue(timelock.queuedTransactions(txHash));
        assertEq(uint256(state), uint256(RiskGovernorStorage.OperationState.Queued));
    }

    function _eta() internal view returns (uint256) {
        return block.timestamp + MIN_DELAY + 1;
    }
}
