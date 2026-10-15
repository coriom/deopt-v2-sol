// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";

/// @notice Fork-only rehearsal from the public post-M1 state. No public transaction is sent.
contract PerpsV2M2EmergencyClosePreparationTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INS = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEAR = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant RUNTIME = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant LOST = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address constant TRADER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpEngineV2 d4 = PerpEngineV2(D4);
    PerpMatchingEngineV2 d6 = PerpMatchingEngineV2(D6);
    uint256 eta;
    bytes inner;
    bytes32 operationId;

    function setUp() public {
        vm.createSelectFork(vm.envString("M2_RPC_URL"), vm.envUint("M2_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        assertTrue(d6.paused());
        assertEq(d6.owner(), TL);
        assertEq(d4.owner(), TL);
        assertEq(d4.guardian(), TL);
        assertEq(uint256(d4.migrationState()), 0);
        assertEq(d4.riskModule(), address(0));
        assertEq(d4.matchingEngine(), address(0));
        assertFalse(d4.tradingPaused());
        assertFalse(d4.liquidationPaused());
        assertFalse(d4.fundingPaused());
        assertFalse(d4.collateralOpsPaused());
        assertTrue(tl.proposers(SAFE));
        assertTrue(tl.executors(SAFE));
        assertEq(tl.minDelay(), 86400);
        eta = vm.envUint("M2_PROPOSED_ETA");
        assertGe(eta, block.timestamp + tl.minDelay() + 3600);
        inner = abi.encodeWithSignature("setEmergencyModes(bool,bool,bool,bool)", true, true, true, true);
        operationId = tl.hashOperation(D4, 0, inner, eta);
        assertTrue(bytes4(inner) == bytes4(0xf64e345d));
        assertFalse(tl.queuedTransactions(operationId));
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory response) {
        (bool ok, bytes memory result) = target.staticcall(data);
        assertTrue(ok);
        return result;
    }

    function _schedule() internal {
        vm.prank(SAFE); // local Safe-address impersonation, not real 2-of-3 signatures
        assertEq(tl.queueTransaction(D4, 0, inner, eta), operationId);
    }

    function _execute() internal {
        vm.prank(SAFE);
        assertEq(tl.executeTransaction(D4, 0, inner, eta), bytes(""));
    }

    function testExactCalldataAndOperationIdentity() public view {
        assertEq(inner.length, 132);
        assertEq(operationId, keccak256(abi.encode(D4, uint256(0), inner, eta)));
        assertFalse(tl.queuedTransactions(operationId));
        assertTrue(operationId != tl.hashOperation(D4, 0, inner, eta + 1));
        assertTrue(operationId != tl.hashOperation(D6, 0, inner, eta));
    }

    function testSafeSchedulingQueuesOnlyAndPreservesM1Stop() public {
        _schedule();
        assertTrue(tl.queuedTransactions(operationId));
        assertFalse(tl.isOperationReady(D4, 0, inner, eta));
        assertTrue(d6.paused());
        assertFalse(d4.tradingPaused());
        assertFalse(d4.liquidationPaused());
        assertFalse(d4.fundingPaused());
        assertFalse(d4.collateralOpsPaused());
    }

    function testPrematureExecutionRevertsWithoutConsumingQueue() public {
        _schedule();
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        tl.executeTransaction(D4, 0, inner, eta);
        assertTrue(tl.queuedTransactions(operationId));
        assertFalse(d4.tradingPaused());
        assertTrue(d6.paused());
    }

    function testExactExecutionEventsReplayAndSharedNonDrift() public {
        bytes memory position = _read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1));
        bytes memory clearing = _read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEAR, TOKEN));
        bytes memory vaultToken = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT));
        bytes memory insurance = _read(INS, abi.encodeWithSignature("vaultBalance(address)", TOKEN));
        bytes32 domain = d6.domainSeparatorV4();
        uint256 traderNonce = d6.nonces(TRADER);
        bytes32 sampleIntent = keccak256("M2 untouched sample fill");
        uint128 sampleFill = d6.intentFilled(sampleIntent);
        bool sampleNonceUsed = d6.intentNonceUsed(TRADER, 7);
        _schedule();
        vm.warp(eta);
        assertTrue(tl.isOperationReady(D4, 0, inner, eta));
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        _execute();
        emit log_named_uint("M2_LOCAL_DIRECT_TIMELOCK_GAS", gasBefore - gasleft());
        Vm.Log[] memory events = vm.getRecordedLogs();
        bytes32[5] memory expected = [
            keccak256("TradingPauseSet(bool)"),
            keccak256("LiquidationPauseSet(bool)"),
            keccak256("FundingPauseSet(bool)"),
            keccak256("CollateralOpsPauseSet(bool)"),
            keccak256("EmergencyModeUpdated(bool,bool,bool,bool)")
        ];
        uint256 found;
        bool executed;
        for (uint256 i; i < events.length; ++i) {
            if (events[i].emitter == D4) {
                assertLt(found, 5);
                assertEq(events[i].topics[0], expected[found]);
                ++found;
            }
            if (
                events[i].emitter == TL
                    && events[i].topics[0]
                        == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
            ) {
                assertEq(events[i].topics[1], operationId);
                assertEq(address(uint160(uint256(events[i].topics[2]))), D4);
                executed = true;
            }
        }
        assertEq(found, 5);
        assertTrue(executed);
        assertTrue(d4.tradingPaused());
        assertTrue(d4.liquidationPaused());
        assertTrue(d4.fundingPaused());
        assertTrue(d4.collateralOpsPaused());
        assertFalse(tl.queuedTransactions(operationId));
        assertFalse(tl.isOperationReady(D4, 0, inner, eta));
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, eta);
        assertEq(d4.owner(), TL);
        assertEq(d4.guardian(), TL);
        assertEq(uint256(d4.migrationState()), 0);
        assertEq(d4.migrationSnapshotHash(), bytes32(0));
        assertEq(d4.riskModule(), address(0));
        assertEq(d4.matchingEngine(), address(0));
        assertEq(d4.totalResidualBadDebtBase(), 0);
        assertEq(_read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1)), position);
        assertTrue(d6.paused());
        assertEq(d6.owner(), TL);
        assertEq(address(d6.perpEngine()), D4);
        assertEq(d6.domainSeparatorV4(), domain);
        assertTrue(d6.isExecutor(TL));
        assertFalse(d6.isExecutor(RUNTIME));
        assertEq(d6.nonces(TRADER), traderNonce);
        assertEq(d6.intentFilled(sampleIntent), sampleFill);
        assertEq(d6.intentNonceUsed(TRADER, 7), sampleNonceUsed);
        assertEq(_read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEAR, TOKEN)), clearing);
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT)), vaultToken);
        assertEq(_read(INS, abi.encodeWithSignature("vaultBalance(address)", TOKEN)), insurance);
        assertEq(_read(VAULT, abi.encodeWithSignature("isAuthorizedEngine(address)", D4)), abi.encode(false));
        assertEq(_read(INS, abi.encodeWithSignature("isBackstopCaller(address)", D4)), abi.encode(false));
    }

    function testWrongTupleAndUnqueuedOperationCannotExecute() public {
        _schedule();
        vm.warp(eta);
        vm.startPrank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, eta + 1);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D6, 0, inner, eta);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(
            D4, 0, abi.encodeWithSignature("setEmergencyModes(bool,bool,bool,bool)", false, true, true, true), eta
        );
        vm.stopPrank();
        assertTrue(tl.queuedTransactions(operationId));
        assertFalse(d4.tradingPaused());
    }

    function testUnauthorizedActorsAndGuardianRestriction() public {
        address[3] memory actors = [RUNTIME, DEPLOYER, LOST];
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            vm.expectRevert();
            d4.setEmergencyModes(true, true, true, true);
            vm.prank(actors[i]);
            vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
            tl.queueTransaction(D4, 0, inner, eta);
        }
        PerpEngineV2 local = new PerpEngineV2(address(this), D1, VAULT, 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581);
        address guardian = address(0xBEEF);
        local.setGuardian(guardian);
        vm.prank(guardian);
        local.setEmergencyModes(true, true, true, true);
        vm.prank(guardian);
        vm.expectRevert();
        local.setEmergencyModes(false, true, true, true);
        assertTrue(local.tradingPaused());
    }

    function testOwnerAdministrativeSetterStillCallableWhileClosed() public {
        _schedule();
        vm.warp(eta);
        _execute();
        vm.prank(TL);
        d4.setRiskModule(D5); // fork-only demonstration of compatibility, not a public C12 authorization
        assertEq(d4.riskModule(), D5);
        assertTrue(d4.tradingPaused());
        assertTrue(d6.paused());
    }
}
