// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";

/// @notice Scheduling-only fork checks; Safe address impersonation does not test 2-of-3 signatures.
contract PerpsV2M1D6PauseSchedulingFinalReviewTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INSURANCE = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEARING = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant RUNTIME_EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    bytes constant PAUSE_DATA = hex"8456cb59";

    ProtocolTimelock timelock = ProtocolTimelock(payable(TIMELOCK));
    PerpMatchingEngineV2 d6 = PerpMatchingEngineV2(D6);
    PerpEngineV2 d4 = PerpEngineV2(D4);
    uint256 eta;
    bytes32 operationId;

    function setUp() public {
        vm.createSelectFork(vm.envString("M1_RPC_URL"), vm.envUint("M1_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        eta = vm.envUint("M1_PROPOSED_ETA");
        operationId = vm.envBytes32("M1_OPERATION_ID");
        assertEq(timelock.hashOperation(D6, 0, PAUSE_DATA, eta), operationId);
        assertEq(timelock.minDelay(), 86400);
        assertGe(eta, block.timestamp + timelock.minDelay());
        assertFalse(timelock.queuedTransactions(operationId));
        assertFalse(d6.paused());
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory result) {
        (bool ok, bytes memory response) = target.staticcall(data);
        assertTrue(ok);
        return response;
    }

    function _queue() internal {
        vm.prank(SAFE);
        assertEq(timelock.queueTransaction(D6, 0, PAUSE_DATA, eta), operationId);
    }

    function testExactScheduleOnlyLeavesD6AndSharedStateUnchanged() public {
        bytes memory ledger = _read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN));
        bytes memory vaultBalance = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT));
        bytes memory insuranceBalance = _read(INSURANCE, abi.encodeWithSignature("vaultBalance(address)", TOKEN));
        address owner = d6.owner();
        address guardian = d6.guardian();
        address engine = address(d6.perpEngine());
        bool timelockExecutor = d6.isExecutor(TIMELOCK);
        bool runtimeExecutor = d6.isExecutor(RUNTIME_EXECUTOR);
        uint256 traderNonce = d6.nonces(SAFE);
        uint128 filled = d6.intentFilled(keccak256("M1 scheduling-only untouched intent"));
        bytes32 snapshot = d4.migrationSnapshotHash();

        vm.expectEmit(true, true, false, true, TIMELOCK);
        emit ProtocolTimelock.TransactionQueued(operationId, D6, 0, PAUSE_DATA, eta);
        _queue();

        assertTrue(timelock.queuedTransactions(operationId));
        assertFalse(timelock.isOperationReady(D6, 0, PAUSE_DATA, eta));
        assertFalse(d6.paused());
        assertEq(d6.owner(), owner);
        assertEq(d6.guardian(), guardian);
        assertEq(address(d6.perpEngine()), engine);
        assertEq(d6.isExecutor(TIMELOCK), timelockExecutor);
        assertEq(d6.isExecutor(RUNTIME_EXECUTOR), runtimeExecutor);
        assertEq(d6.nonces(SAFE), traderNonce);
        assertEq(d6.intentFilled(keccak256("M1 scheduling-only untouched intent")), filled);
        assertEq(uint256(d4.migrationState()), 0);
        assertEq(d4.migrationSnapshotHash(), snapshot);
        assertEq(d4.riskModule(), address(0));
        assertEq(d4.matchingEngine(), address(0));
        assertFalse(d4.tradingPaused());
        assertFalse(d4.liquidationPaused());
        assertFalse(d4.fundingPaused());
        assertFalse(d4.collateralOpsPaused());
        assertEq(_read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN)), ledger);
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT)), vaultBalance);
        assertEq(_read(INSURANCE, abi.encodeWithSignature("vaultBalance(address)", TOKEN)), insuranceBalance);
    }

    function testWrongCallerAndTooEarlyEtaCannotQueue() public {
        uint256 tooSoonEta = block.timestamp + timelock.minDelay() - 1;
        vm.prank(RUNTIME_EXECUTOR);
        vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
        timelock.queueTransaction(D6, 0, PAUSE_DATA, eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.EtaTooSoon.selector);
        timelock.queueTransaction(D6, 0, PAUSE_DATA, tooSoonEta);
        assertFalse(timelock.queuedTransactions(operationId));
    }

    function testCollisionAndChangedTupleCannotSatisfyReviewedOperation() public {
        _queue();
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionAlreadyQueued.selector);
        timelock.queueTransaction(D6, 0, PAUSE_DATA, eta);
        assertTrue(timelock.hashOperation(D4, 0, PAUSE_DATA, eta) != operationId);
        assertTrue(timelock.hashOperation(D6, 1, PAUSE_DATA, eta) != operationId);
        assertTrue(timelock.hashOperation(D6, 0, hex"12345678", eta) != operationId);
        assertTrue(timelock.hashOperation(D6, 0, PAUSE_DATA, eta + 1) != operationId);
        assertFalse(d6.paused());
    }

    function testQueuedAndReadyDoNotExecuteWithoutSeparateAction() public {
        _queue();
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        timelock.executeTransaction(D6, 0, PAUSE_DATA, eta);
        assertFalse(d6.paused());
        vm.warp(eta);
        assertTrue(timelock.isOperationReady(D6, 0, PAUSE_DATA, eta));
        assertFalse(d6.paused());
        assertTrue(timelock.queuedTransactions(operationId));
    }
}
