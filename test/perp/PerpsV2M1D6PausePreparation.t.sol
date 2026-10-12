// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";

/// @notice M1-only rehearsal against a pinned Base Sepolia fork; Safe address impersonation is local.
contract PerpsV2M1D6PausePreparationTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INSURANCE = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEARING = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant RUNTIME_EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant LOST_OWNER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address constant TRADER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;
    bytes constant M1_DATA = hex"8456cb59";

    ProtocolTimelock timelock = ProtocolTimelock(payable(TIMELOCK));
    PerpMatchingEngineV2 pme = PerpMatchingEngineV2(D6);
    PerpEngineV2 engine = PerpEngineV2(D4);
    uint256 eta;
    bytes32 operationId;

    function setUp() public {
        vm.createSelectFork(vm.envString("M1_RPC_URL"), vm.envUint("M1_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        eta = vm.envUint("M1_PROPOSED_ETA");
        assertEq(eta, block.timestamp + 72 hours);
        assertEq(timelock.minDelay(), 86400);
        assertEq(timelock.owner(), SAFE);
        assertTrue(timelock.proposers(SAFE));
        assertTrue(timelock.executors(SAFE));
        assertFalse(timelock.queuePaused());
        assertFalse(pme.paused());
        assertEq(pme.owner(), TIMELOCK);
        assertEq(pme.guardian(), address(0));
        assertEq(address(pme.perpEngine()), D4);
        assertEq(uint256(engine.migrationState()), 0);
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertEq(keccak256(M1_DATA), keccak256(abi.encodeWithSignature("pause()")));
        operationId = keccak256(abi.encode(D6, uint256(0), M1_DATA, eta));
        assertEq(operationId, vm.envBytes32("M1_OPERATION_ID"));
        assertEq(timelock.hashOperation(D6, 0, M1_DATA, eta), operationId);
        assertFalse(timelock.queuedTransactions(operationId));
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory result) {
        (bool ok, bytes memory response) = target.staticcall(data);
        assertTrue(ok);
        return response;
    }

    function _queue() internal {
        vm.prank(SAFE);
        assertEq(timelock.queueTransaction(D6, 0, M1_DATA, eta), operationId);
    }

    function _execute() internal {
        vm.prank(SAFE);
        timelock.executeTransaction(D6, 0, M1_DATA, eta);
    }

    function testExactM1ScheduleDelayExecuteAndNonDrift() public {
        bytes32 d1Hash = D1.codehash;
        bytes32 d2Hash = D2.codehash;
        bytes32 d3Hash = D3.codehash;
        bytes32 d5Hash = D5.codehash;
        bytes32 snapshot = engine.migrationSnapshotHash();
        bytes memory ledger = _read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN));
        bytes memory vaultTokens = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT));
        bytes memory insuranceBalance = _read(INSURANCE, abi.encodeWithSignature("vaultBalance(address)", TOKEN));
        bytes memory d1Markets = _read(D1, abi.encodeWithSignature("getAllMarketIds()"));
        bytes memory d2Root = _read(D2, abi.encodeWithSignature("merkleRoot()"));
        bytes memory d3Config = _read(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN));
        bytes memory d4Position = _read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1));
        bytes32 intent = keccak256("M1 bounded untouched intent");
        uint256 traderNonce = pme.nonces(TRADER);
        uint128 filled = pme.intentFilled(intent);
        bool intentUsed = pme.intentNonceUsed(TRADER, 7);

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        _queue();
        emit log_named_uint("M1_LOCAL_DIRECT_TIMELOCK_QUEUE_GAS", gasBefore - gasleft());
        Vm.Log[] memory queueLogs = vm.getRecordedLogs();
        bool queuedEvent;
        for (uint256 i; i < queueLogs.length; ++i) {
            if (
                queueLogs[i].emitter == TIMELOCK
                    && queueLogs[i].topics[0] == keccak256("TransactionQueued(bytes32,address,uint256,bytes,uint256)")
            ) {
                assertEq(queueLogs[i].topics[1], operationId);
                assertEq(address(uint160(uint256(queueLogs[i].topics[2]))), D6);
                queuedEvent = true;
            }
        }
        assertTrue(queuedEvent);
        assertTrue(timelock.queuedTransactions(operationId));
        assertFalse(timelock.isOperationReady(D6, 0, M1_DATA, eta));
        assertFalse(pme.paused());
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        timelock.executeTransaction(D6, 0, M1_DATA, eta);

        vm.warp(eta);
        assertTrue(timelock.isOperationReady(D6, 0, M1_DATA, eta));
        vm.recordLogs();
        gasBefore = gasleft();
        _execute();
        emit log_named_uint("M1_LOCAL_DIRECT_TIMELOCK_EXECUTE_GAS", gasBefore - gasleft());
        Vm.Log[] memory executionLogs = vm.getRecordedLogs();
        bool executedEvent;
        bool pausedEvent;
        for (uint256 i; i < executionLogs.length; ++i) {
            if (
                executionLogs[i].emitter == TIMELOCK
                    && executionLogs[i].topics[0]
                        == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
            ) {
                assertEq(executionLogs[i].topics[1], operationId);
                executedEvent = true;
            }
            if (executionLogs[i].emitter == D6 && executionLogs[i].topics[0] == keccak256("Paused(address)")) {
                assertEq(address(uint160(uint256(executionLogs[i].topics[1]))), TIMELOCK);
                pausedEvent = true;
            }
        }
        assertTrue(executedEvent && pausedEvent);
        assertFalse(timelock.queuedTransactions(operationId));
        assertTrue(pme.paused());
        assertEq(pme.owner(), TIMELOCK);
        assertEq(pme.pendingOwner(), address(0));
        assertEq(pme.guardian(), address(0));
        assertEq(address(pme.perpEngine()), D4);
        assertTrue(pme.isExecutor(TIMELOCK));
        assertFalse(pme.isExecutor(RUNTIME_EXECUTOR));
        assertEq(pme.nonces(TRADER), traderNonce);
        assertEq(pme.intentFilled(intent), filled);
        assertEq(pme.intentNonceUsed(TRADER, 7), intentUsed);
        assertEq(uint256(engine.migrationState()), 0);
        assertEq(engine.migrationSnapshotHash(), snapshot);
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertFalse(engine.tradingPaused());
        assertFalse(engine.liquidationPaused());
        assertFalse(engine.fundingPaused());
        assertFalse(engine.collateralOpsPaused());
        assertEq(engine.totalResidualBadDebtBase(), 0);
        assertEq(_read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1)), d4Position);
        assertEq(_read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN)), ledger);
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT)), vaultTokens);
        assertEq(_read(INSURANCE, abi.encodeWithSignature("vaultBalance(address)", TOKEN)), insuranceBalance);
        assertEq(_read(VAULT, abi.encodeWithSignature("isEngineAuthorized(address)", D4)), abi.encode(false));
        assertEq(_read(INSURANCE, abi.encodeWithSignature("isBackstopCaller(address)", D4)), abi.encode(false));
        assertEq(_read(D1, abi.encodeWithSignature("getAllMarketIds()")), d1Markets);
        assertEq(_read(D2, abi.encodeWithSignature("merkleRoot()")), d2Root);
        assertEq(_read(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN)), d3Config);
        assertEq(D1.codehash, d1Hash);
        assertEq(D2.codehash, d2Hash);
        assertEq(D3.codehash, d3Hash);
        assertEq(D5.codehash, d5Hash);
    }

    function testQueuedAndReadyAreSafeStopsWithoutPause() public {
        _queue();
        assertTrue(timelock.queuedTransactions(operationId));
        assertFalse(pme.paused());
        vm.warp(eta);
        assertTrue(timelock.isOperationReady(D6, 0, M1_DATA, eta));
        assertFalse(pme.paused());
        assertEq(engine.matchingEngine(), address(0));
    }

    function testUnauthorizedActorsCannotPauseOrSchedule() public {
        address[3] memory actors = [RUNTIME_EXECUTOR, DEPLOYER, LOST_OWNER];
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            vm.expectRevert();
            pme.pause();
            vm.prank(actors[i]);
            vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
            timelock.queueTransaction(D6, 0, M1_DATA, eta);
        }
        assertFalse(pme.paused());
    }

    function testWrongIdentityAndRepeatedExecutionRejected() public {
        bytes memory wrongSelector = hex"12345678";
        assertTrue(timelock.hashOperation(D6, 0, M1_DATA, eta + 1) != operationId);
        assertTrue(timelock.hashOperation(D4, 0, M1_DATA, eta) != operationId);
        assertTrue(timelock.hashOperation(D6, 0, wrongSelector, eta) != operationId);
        _queue();
        vm.warp(eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        timelock.executeTransaction(D6, 0, M1_DATA, eta + 1);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        timelock.executeTransaction(D6, 0, wrongSelector, eta);
        _execute();
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        timelock.executeTransaction(D6, 0, M1_DATA, eta);
        assertTrue(pme.paused());
    }

    function testCancellationOrTooSoonEtaCannotPause() public {
        uint256 tooSoonEta = block.timestamp + timelock.minDelay() - 1;
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.EtaTooSoon.selector);
        timelock.queueTransaction(D6, 0, M1_DATA, tooSoonEta);
        _queue();
        vm.prank(SAFE);
        timelock.cancelTransaction(D6, 0, M1_DATA, eta);
        assertFalse(timelock.queuedTransactions(operationId));
        vm.warp(eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        timelock.executeTransaction(D6, 0, M1_DATA, eta);
        assertFalse(pme.paused());
    }

    function testPauseRepeatedTargetCallIsNoOp() public {
        _queue();
        vm.warp(eta);
        _execute();
        assertTrue(pme.paused());
        vm.recordLogs();
        vm.prank(TIMELOCK);
        pme.pause();
        assertEq(vm.getRecordedLogs().length, 0);
        assertTrue(pme.paused());
    }
}
