// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";

interface ISafeM1 {
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 nonce_
    ) external view returns (bytes32);
    function approveHash(bytes32 hashToApprove) external;
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool success);
}

/// @notice Isolated fork of the *already queued* public M1. Local owner pranks are not public Safe signatures.
contract PerpsV2M1D6PauseTimelockExecutionFinalReviewTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INS = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEAR = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant RUNTIME = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant LOST = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address constant OWNER_A = 0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d;
    address constant OWNER_B = 0xa774C46C41064524dF895BD7bE9F294409798dFC;
    address constant TRADER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;
    uint256 constant ETA = 1792029034;
    bytes32 constant OP = 0xce251e4c40b88520a90eab4f2e955ff6bd810f25f6e28c3e3d253dcafc93db02;
    bytes constant PAUSE = hex"8456cb59";

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpMatchingEngineV2 d6 = PerpMatchingEngineV2(D6);
    PerpEngineV2 d4 = PerpEngineV2(D4);
    ISafeM1 safe = ISafeM1(SAFE);

    function setUp() public {
        vm.createSelectFork(vm.envString("M1_RPC_URL"), vm.envUint("M1_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        assertEq(tl.hashOperation(D6, 0, PAUSE, ETA), OP);
        assertTrue(tl.queuedTransactions(OP));
        assertFalse(d6.paused());
        assertEq(safe.nonce(), 20);
        assertTrue(tl.executors(SAFE));
        assertEq(tl.GRACE_PERIOD(), 14 days);
        assertLt(block.timestamp, ETA);
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory response) {
        (bool ok, bytes memory result) = target.staticcall(data);
        assertTrue(ok);
        return result;
    }

    function _direct() internal {
        vm.prank(SAFE);
        tl.executeTransaction(D6, 0, PAUSE, ETA);
    }

    function testPreEtaRevertsAndKeepsQueue() public {
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        tl.executeTransaction(D6, 0, PAUSE, ETA);
        assertTrue(tl.queuedTransactions(OP));
        assertFalse(d6.paused());
    }

    function testWrongAuthorityAndDirectPauseRejected() public {
        address[3] memory actors = [RUNTIME, DEPLOYER, LOST];
        vm.warp(ETA);
        for (uint256 i; i < actors.length; i++) {
            vm.prank(actors[i]);
            vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
            tl.executeTransaction(D6, 0, PAUSE, ETA);
            vm.prank(actors[i]);
            vm.expectRevert();
            d6.pause();
        }
        assertTrue(tl.queuedTransactions(OP));
        assertFalse(d6.paused());
    }

    function testWrongTupleAndUnqueuedOperationRejected() public {
        vm.warp(ETA);
        assertTrue(tl.hashOperation(D4, 0, PAUSE, ETA) != OP);
        assertTrue(tl.hashOperation(D6, 0, hex"12345678", ETA) != OP);
        assertTrue(tl.hashOperation(D6, 0, PAUSE, ETA + 1) != OP);
        vm.startPrank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, PAUSE, ETA);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D6, 0, hex"12345678", ETA);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D6, 0, PAUSE, ETA + 1);
        vm.stopPrank();
        assertTrue(tl.queuedTransactions(OP));
        assertFalse(d6.paused());
    }

    function testCancellationAndExpirationBlockExecution() public {
        vm.prank(SAFE);
        tl.cancelTransaction(D6, 0, PAUSE, ETA);
        vm.warp(ETA);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D6, 0, PAUSE, ETA);
        assertFalse(d6.paused());
        // A fresh fork preserves the original queue while testing expiry.
        vm.createSelectFork(vm.envString("M1_RPC_URL"), vm.envUint("M1_REVIEW_BLOCK"));
        vm.warp(ETA + tl.GRACE_PERIOD() + 1);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionStale.selector);
        tl.executeTransaction(D6, 0, PAUSE, ETA);
        assertTrue(tl.queuedTransactions(OP));
    }

    function testExactDirectTimelockExecutionEventsReplayAndNonDrift() public {
        bytes memory ledger = _read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEAR, TOKEN));
        bytes memory vaultTokens = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT));
        bytes memory insurance = _read(INS, abi.encodeWithSignature("vaultBalance(address)", TOKEN));
        bytes memory position = _read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1));
        uint256 nonce = d6.nonces(TRADER);
        bytes32 intent = keccak256("M1 S2 untouched local fill");
        uint128 filled = d6.intentFilled(intent);
        bool nonceUsed = d6.intentNonceUsed(TRADER, 7);
        bytes32 domain = d6.domainSeparatorV4();
        assertFalse(tl.isOperationReady(D6, 0, PAUSE, ETA));
        vm.warp(ETA);
        assertTrue(tl.isOperationReady(D6, 0, PAUSE, ETA));
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        _direct();
        emit log_named_uint("M1_S2_LOCAL_DIRECT_TIMELOCK_GAS", gasBefore - gasleft());
        Vm.Log[] memory events = vm.getRecordedLogs();
        bool pauseSeen;
        bool executedSeen;
        for (uint256 i; i < events.length; i++) {
            if (events[i].emitter == D6 && events[i].topics[0] == keccak256("Paused(address)")) {
                assertEq(address(uint160(uint256(events[i].topics[1]))), TL);
                pauseSeen = true;
            }
            if (
                events[i].emitter == TL
                    && events[i].topics[0]
                        == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
            ) {
                assertEq(events[i].topics[1], OP);
                assertEq(address(uint160(uint256(events[i].topics[2]))), D6);
                executedSeen = true;
            }
        }
        assertTrue(pauseSeen && executedSeen);
        assertTrue(d6.paused());
        assertFalse(tl.queuedTransactions(OP));
        assertFalse(tl.isOperationReady(D6, 0, PAUSE, ETA));
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D6, 0, PAUSE, ETA);
        assertEq(d6.owner(), TL);
        assertEq(d6.pendingOwner(), address(0));
        assertEq(d6.guardian(), address(0));
        assertEq(address(d6.perpEngine()), D4);
        assertEq(d6.domainSeparatorV4(), domain);
        assertTrue(d6.isExecutor(TL));
        assertFalse(d6.isExecutor(RUNTIME));
        assertEq(d6.nonces(TRADER), nonce);
        assertEq(d6.intentFilled(intent), filled);
        assertEq(d6.intentNonceUsed(TRADER, 7), nonceUsed);
        assertEq(uint256(d4.migrationState()), 0);
        assertEq(d4.riskModule(), address(0));
        assertEq(d4.matchingEngine(), address(0));
        assertEq(d4.migrationSnapshotHash(), bytes32(0));
        assertFalse(d4.tradingPaused());
        assertFalse(d4.liquidationPaused());
        assertFalse(d4.fundingPaused());
        assertFalse(d4.collateralOpsPaused());
        assertEq(d4.totalResidualBadDebtBase(), 0);
        assertEq(_read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1)), position);
        assertEq(_read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEAR, TOKEN)), ledger);
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT)), vaultTokens);
        assertEq(_read(INS, abi.encodeWithSignature("vaultBalance(address)", TOKEN)), insurance);
        assertEq(_read(VAULT, abi.encodeWithSignature("isAuthorizedEngine(address)", D4)), abi.encode(false));
        assertEq(_read(INS, abi.encodeWithSignature("isBackstopCaller(address)", D4)), abi.encode(false));
    }

    function _approvedSignature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function testActualSafeProxyPathWithLocalOwnerApprovals() public {
        bytes memory data = abi.encodeWithSelector(tl.executeTransaction.selector, D6, 0, PAUSE, ETA);
        assertEq(bytes4(data), bytes4(0x06a41d09));
        vm.warp(ETA);
        bytes32 safeHash = safe.getTransactionHash(TL, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        vm.prank(OWNER_A);
        safe.approveHash(safeHash);
        vm.prank(OWNER_B);
        safe.approveHash(safeHash);
        bytes memory signatures = bytes.concat(_approvedSignature(OWNER_A), _approvedSignature(OWNER_B));
        uint256 gasBefore = gasleft();
        bool ok = safe.execTransaction(TL, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures);
        emit log_named_uint("M1_S2_LOCAL_SAFE_EXEC_GAS", gasBefore - gasleft());
        assertTrue(ok);
        assertEq(safe.nonce(), 21);
        assertFalse(tl.queuedTransactions(OP));
        assertTrue(d6.paused());
    }
}
