// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";

interface IC20S2Risk {
    function maxOracleDelay() external view returns (uint256);
    function owner() external view returns (address);
    function guardian() external view returns (address);
    function perpEngine() external view returns (address);
    function setMaxOracleDelay(uint256) external;
}

interface IC20S2Safe {
    function nonce() external view returns (uint256);
    function getTransactionHash(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address,
        uint256
    ) external view returns (bytes32);
    function approveHash(bytes32) external;
    function execTransaction(
        address,
        uint256,
        bytes calldata,
        uint8,
        uint256,
        uint256,
        uint256,
        address,
        address payable,
        bytes calldata
    ) external payable returns (bool);
}

/// @notice Isolated fork rehearsal of an already queued operation. Owner pranks are local-only approvals.
contract PerpsV2C20FastExecutionForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
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
    address constant RUNTIME = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant OWNER_A = 0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d;
    address constant OWNER_B = 0xa774C46C41064524dF895BD7bE9F294409798dFC;
    address constant TRADER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;
    uint256 constant FORK_BLOCK = 48356476;
    uint256 constant ETA = 1792584000;
    bytes32 constant OP = 0xad2000557d6dfd7a9adec3d2ba7e66c27386191195c78bd1090f40f8bd7ebc0a;

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    IC20S2Risk risk = IC20S2Risk(D5);
    IC20S2Safe safe = IC20S2Safe(SAFE);
    bytes inner = abi.encodeWithSignature("setMaxOracleDelay(uint256)", 600);

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), FORK_BLOCK);
        assertEq(block.chainid, 84532);
        assertLt(block.timestamp, ETA);
        assertEq(tl.GRACE_PERIOD(), 14 days);
        assertEq(tl.hashOperation(D5, 0, inner, ETA), OP);
        assertTrue(tl.queuedTransactions(OP));
        assertTrue(tl.executors(SAFE));
        assertEq(safe.nonce(), 24);
        assertEq(risk.maxOracleDelay(), 0);
        assertEq(risk.owner(), TL);
        assertEq(risk.perpEngine(), D4);
        _assertMaintenance();
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory) {
        (bool ok, bytes memory value) = target.staticcall(data);
        require(ok, "bounded getter unavailable");
        return value;
    }

    function _assertMaintenance() internal view {
        assertEq(_read(D4, abi.encodeWithSignature("tradingPaused()")), abi.encode(true));
        assertEq(_read(D4, abi.encodeWithSignature("liquidationPaused()")), abi.encode(true));
        assertEq(_read(D4, abi.encodeWithSignature("fundingPaused()")), abi.encode(true));
        assertEq(_read(D4, abi.encodeWithSignature("collateralOpsPaused()")), abi.encode(true));
        assertEq(_read(D4, abi.encodeWithSignature("migrationState()")), abi.encode(uint8(0)));
        assertEq(_read(D4, abi.encodeWithSignature("riskModule()")), abi.encode(address(0)));
        assertEq(_read(D4, abi.encodeWithSignature("matchingEngine()")), abi.encode(address(0)));
        assertEq(_read(D6, abi.encodeWithSignature("paused()")), abi.encode(true));
    }

    function _execute() internal {
        vm.prank(SAFE); // Safe-address impersonation proves Timelock authority only.
        assertEq(tl.executeTransaction(D5, 0, inner, ETA), bytes(""));
    }

    function testExactExecutionAbiAndQueuedIdentity() public view {
        assertEq(bytes4(inner), bytes4(0xcd3b691c));
        assertEq(inner.length, 36);
        bytes memory data = abi.encodeWithSelector(tl.executeTransaction.selector, D5, 0, inner, ETA);
        assertEq(bytes4(data), bytes4(0x06a41d09));
        assertEq(data.length, 228);
        assertEq(keccak256(abi.encode(D5, uint256(0), inner, ETA)), OP);
        assertFalse(tl.isOperationReady(D5, 0, inner, ETA));
    }

    function testPrematureExecutionRevertsAndQueuePersists() public {
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        tl.executeTransaction(D5, 0, inner, ETA);
        assertTrue(tl.queuedTransactions(OP));
        assertEq(risk.maxOracleDelay(), 0);
        _assertMaintenance();
    }

    function testWrongAuthorityAndDirectSetterRejected() public {
        vm.warp(ETA);
        for (uint256 i; i < 3; ++i) {
            address actor = i == 0 ? RUNTIME : i == 1 ? DEPLOYER : TRADER;
            vm.prank(actor);
            vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
            tl.executeTransaction(D5, 0, inner, ETA);
            vm.prank(actor);
            vm.expectRevert();
            risk.setMaxOracleDelay(600);
        }
        assertTrue(tl.queuedTransactions(OP));
        assertEq(risk.maxOracleDelay(), 0);
    }

    function testWrongTargetDataEtaAndUnqueuedOperationRejected() public {
        vm.warp(ETA);
        vm.startPrank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, ETA);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D5, 0, abi.encodeWithSignature("setMaxOracleDelay(uint256)", 601), ETA);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D5, 0, inner, ETA + 1);
        vm.stopPrank();
        assertTrue(tl.queuedTransactions(OP));
    }

    function testCancelledAndExpiredCannotExecute() public {
        vm.prank(SAFE);
        tl.cancelTransaction(D5, 0, inner, ETA);
        vm.warp(ETA);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D5, 0, inner, ETA);
        assertEq(risk.maxOracleDelay(), 0);
        vm.createSelectFork(vm.envString("RPC_URL"), FORK_BLOCK);
        vm.warp(ETA + tl.GRACE_PERIOD() + 1);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionStale.selector);
        tl.executeTransaction(D5, 0, inner, ETA);
        assertTrue(tl.queuedTransactions(OP));
    }

    function testExactExecutionEventsReplayAndSharedNonDrift() public {
        bytes memory clearing = _read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN));
        bytes memory insurance = _read(VAULT, abi.encodeWithSignature("balances(address,address)", INSURANCE, TOKEN));
        bytes memory vaultTokens = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT));
        bytes memory insuranceAccounting = _read(INSURANCE, abi.encodeWithSignature("vaultBalance(address)", TOKEN));
        bytes memory marketCount = _read(D1, abi.encodeWithSignature("totalMarkets()"));
        bytes memory feeRoot = _read(D2, abi.encodeWithSignature("merkleRoot()"));
        bytes memory seizerConfig = _read(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN));
        bytes memory position = _read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1));
        bytes memory domain = _read(D6, abi.encodeWithSignature("domainSeparatorV4()"));
        bytes memory nonce = _read(D6, abi.encodeWithSignature("nonces(address)", TRADER));
        bytes memory fill = _read(D6, abi.encodeWithSignature("intentFilled(bytes32)", bytes32(0)));
        bytes memory executor = _read(D6, abi.encodeWithSignature("isExecutor(address)", RUNTIME));
        address ownerBefore = risk.owner();
        address engineBefore = risk.perpEngine();
        address guardianBefore = risk.guardian();
        vm.warp(ETA);
        assertTrue(tl.isOperationReady(D5, 0, inner, ETA));
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        _execute();
        emit log_named_uint("C20_S2_LOCAL_DIRECT_TIMELOCK_GAS", gasBefore - gasleft());
        Vm.Log[] memory events = vm.getRecordedLogs();
        bool sawRisk;
        bool sawTimelock;
        for (uint256 i; i < events.length; ++i) {
            if (events[i].emitter == D5) {
                assertEq(events[i].topics[0], keccak256("MaxOracleDelaySet(uint256,uint256)"));
                (uint256 oldDelay, uint256 newDelay) = abi.decode(events[i].data, (uint256, uint256));
                assertEq(oldDelay, 0);
                assertEq(newDelay, 600);
                sawRisk = true;
            }
            if (events[i].emitter == TL) {
                assertEq(
                    events[i].topics[0], keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
                );
                assertEq(events[i].topics[1], OP);
                assertEq(address(uint160(uint256(events[i].topics[2]))), D5);
                (uint256 value, bytes memory data, uint256 eta, bytes memory ret) =
                    abi.decode(events[i].data, (uint256, bytes, uint256, bytes));
                assertEq(value, 0);
                assertEq(data, inner);
                assertEq(eta, ETA);
                assertEq(ret, bytes(""));
                sawTimelock = true;
            }
        }
        assertTrue(sawRisk && sawTimelock);
        assertEq(risk.maxOracleDelay(), 600);
        assertFalse(tl.queuedTransactions(OP));
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D5, 0, inner, ETA);
        assertEq(risk.owner(), ownerBefore);
        assertEq(risk.perpEngine(), engineBefore);
        assertEq(risk.guardian(), guardianBefore);
        _assertMaintenance();
        assertEq(_read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN)), clearing);
        assertEq(_read(VAULT, abi.encodeWithSignature("balances(address,address)", INSURANCE, TOKEN)), insurance);
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT)), vaultTokens);
        assertEq(_read(INSURANCE, abi.encodeWithSignature("vaultBalance(address)", TOKEN)), insuranceAccounting);
        assertEq(_read(D1, abi.encodeWithSignature("totalMarkets()")), marketCount);
        assertEq(_read(D2, abi.encodeWithSignature("merkleRoot()")), feeRoot);
        assertEq(_read(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN)), seizerConfig);
        assertEq(_read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1)), position);
        assertEq(_read(D6, abi.encodeWithSignature("domainSeparatorV4()")), domain);
        assertEq(_read(D6, abi.encodeWithSignature("nonces(address)", TRADER)), nonce);
        assertEq(_read(D6, abi.encodeWithSignature("intentFilled(bytes32)", bytes32(0))), fill);
        assertEq(_read(D6, abi.encodeWithSignature("isExecutor(address)", RUNTIME)), executor);
        assertEq(_read(VAULT, abi.encodeWithSignature("isAuthorizedEngine(address)", D4)), abi.encode(false));
        assertEq(_read(INSURANCE, abi.encodeWithSignature("isBackstopCaller(address)", D4)), abi.encode(false));
    }

    function _approvedSignature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function testSafeProxyPathWithForkOnlyApprovals() public {
        bytes memory data = abi.encodeWithSelector(tl.executeTransaction.selector, D5, 0, inner, ETA);
        vm.warp(ETA);
        bytes32 safeHash = safe.getTransactionHash(TL, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        vm.prank(OWNER_A);
        safe.approveHash(safeHash);
        vm.prank(OWNER_B);
        safe.approveHash(safeHash);
        bytes memory approvals = bytes.concat(_approvedSignature(OWNER_A), _approvedSignature(OWNER_B));
        uint256 gasBefore = gasleft();
        bool ok = safe.execTransaction(TL, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), approvals);
        emit log_named_uint("C20_S2_LOCAL_SAFE_EXEC_GAS", gasBefore - gasleft());
        assertTrue(ok);
        assertEq(safe.nonce(), 25);
        assertFalse(tl.queuedTransactions(OP));
        assertEq(risk.maxOracleDelay(), 600);
        _assertMaintenance();
    }
}
