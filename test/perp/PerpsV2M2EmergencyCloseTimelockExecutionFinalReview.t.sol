// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";

interface ISafeM2S2 {
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

/// @notice Fork-only review of the existing queued M2. Local Safe-owner pranks are not public signatures.
contract PerpsV2M2EmergencyCloseTimelockExecutionFinalReviewTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
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
    address constant OWNER_A = 0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d;
    address constant OWNER_B = 0xa774C46C41064524dF895BD7bE9F294409798dFC;
    address constant TRADER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;
    uint256 constant ETA = 1792465200;
    bytes32 constant OP = 0xe67e4f92022dd5cdbabc05c6ce0ee63f2cb186ef0aaccbe5eec002d6f3718063;

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpEngineV2 d4 = PerpEngineV2(D4);
    PerpMatchingEngineV2 d6 = PerpMatchingEngineV2(D6);
    ISafeM2S2 safe = ISafeM2S2(SAFE);
    bytes inner;

    function setUp() public {
        vm.createSelectFork(vm.envString("M2_RPC_URL"), vm.envUint("M2_REVIEW_BLOCK"));
        inner = abi.encodeWithSignature("setEmergencyModes(bool,bool,bool,bool)", true, true, true, true);
        assertEq(block.chainid, 84532);
        assertLt(block.timestamp, ETA);
        assertEq(tl.hashOperation(D4, 0, inner, ETA), OP);
        assertTrue(tl.queuedTransactions(OP));
        assertTrue(tl.executors(SAFE));
        assertEq(tl.GRACE_PERIOD(), 14 days);
        assertEq(safe.nonce(), 22);
        assertTrue(d6.paused());
        _assertOpenPrestate();
    }

    function _assertOpenPrestate() internal view {
        assertFalse(d4.tradingPaused());
        assertFalse(d4.liquidationPaused());
        assertFalse(d4.fundingPaused());
        assertFalse(d4.collateralOpsPaused());
        assertEq(uint256(d4.migrationState()), 0);
        assertEq(d4.riskModule(), address(0));
        assertEq(d4.matchingEngine(), address(0));
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory) {
        (bool ok, bytes memory out) = target.staticcall(data);
        assertTrue(ok);
        return out;
    }

    function _direct() internal {
        vm.prank(SAFE); // Fork-only Safe-address impersonation.
        assertEq(tl.executeTransaction(D4, 0, inner, ETA), bytes(""));
    }

    function testQueuedTupleExecutionAbiAndReadiness() public view {
        assertEq(inner.length, 132);
        assertEq(bytes4(inner), bytes4(0xf64e345d));
        assertEq(OP, keccak256(abi.encode(D4, uint256(0), inner, ETA)));
        bytes memory payload = abi.encodeWithSelector(tl.executeTransaction.selector, D4, 0, inner, ETA);
        assertEq(bytes4(payload), bytes4(0x06a41d09));
        assertEq(payload.length, 324);
        assertFalse(tl.isOperationReady(D4, 0, inner, ETA));
    }

    function testPrematureExecutionRevertsAndQueuePersists() public {
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        tl.executeTransaction(D4, 0, inner, ETA);
        assertTrue(tl.queuedTransactions(OP));
        _assertOpenPrestate();
        assertTrue(d6.paused());
    }

    function testWrongAuthorityAndDirectD4SetterRejected() public {
        vm.warp(ETA);
        address[3] memory actors = [RUNTIME, DEPLOYER, LOST];
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
            tl.executeTransaction(D4, 0, inner, ETA);
            vm.prank(actors[i]);
            vm.expectRevert();
            d4.setEmergencyModes(true, true, true, true);
        }
        assertTrue(tl.queuedTransactions(OP));
        _assertOpenPrestate();
    }

    function testWrongTargetDataEtaAndUnqueuedExecutionRejected() public {
        vm.warp(ETA);
        vm.startPrank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D6, 0, inner, ETA);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, hex"12345678", ETA);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, ETA + 1);
        vm.stopPrank();
        assertTrue(tl.queuedTransactions(OP));
        _assertOpenPrestate();
    }

    function testCancelledAndExpiredOperationCannotExecute() public {
        vm.prank(SAFE);
        tl.cancelTransaction(D4, 0, inner, ETA);
        vm.warp(ETA);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, ETA);
        _assertOpenPrestate();
        vm.createSelectFork(vm.envString("M2_RPC_URL"), vm.envUint("M2_REVIEW_BLOCK"));
        vm.warp(ETA + tl.GRACE_PERIOD() + 1);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionStale.selector);
        tl.executeTransaction(D4, 0, inner, ETA);
        assertTrue(tl.queuedTransactions(OP));
    }

    function testExactExecutionEventsReplayAndEconomicNonDrift() public {
        bytes memory position = _read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1));
        bytes memory clearing = _read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEAR, TOKEN));
        bytes memory vaultTokens = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT));
        bytes memory insurance = _read(INS, abi.encodeWithSignature("vaultBalance(address)", TOKEN));
        bytes memory clearingTokens = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", CLEAR));
        bytes memory insuranceTokens = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", INS));
        bytes memory marketCount = _read(D1, abi.encodeWithSignature("totalMarkets()"));
        bytes memory feeRecipient = _read(D2, abi.encodeWithSignature("feeRecipient()"));
        bytes memory feeVault = _read(D2, abi.encodeWithSignature("protocolFeeVault()"));
        bytes memory seizerConfig = _read(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN));
        bytes memory oracleDelay = _read(D5, abi.encodeWithSignature("maxOracleDelay()"));
        bytes32 domain = d6.domainSeparatorV4();
        uint256 traderNonce = d6.nonces(TRADER);
        bytes32 sampleIntent = keccak256("M2 S2 untouched sample fill");
        uint128 sampleFill = d6.intentFilled(sampleIntent);
        bool sampleNonceUsed = d6.intentNonceUsed(TRADER, 7);
        vm.warp(ETA);
        assertTrue(tl.isOperationReady(D4, 0, inner, ETA));
        vm.recordLogs();
        uint256 gasBefore = gasleft();
        _direct();
        emit log_named_uint("M2_S2_LOCAL_DIRECT_TIMELOCK_GAS", gasBefore - gasleft());
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
                assertEq(events[i].topics[1], OP);
                assertEq(address(uint160(uint256(events[i].topics[2]))), D4);
                (uint256 value, bytes memory data, uint256 eta, bytes memory ret) =
                    abi.decode(events[i].data, (uint256, bytes, uint256, bytes));
                assertEq(value, 0);
                assertEq(data, inner);
                assertEq(eta, ETA);
                assertEq(ret, bytes(""));
                executed = true;
            }
        }
        assertEq(found, 5);
        assertTrue(executed);
        assertTrue(d4.tradingPaused());
        assertTrue(d4.liquidationPaused());
        assertTrue(d4.fundingPaused());
        assertTrue(d4.collateralOpsPaused());
        assertFalse(tl.queuedTransactions(OP));
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, ETA);
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
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT)), vaultTokens);
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", CLEAR)), clearingTokens);
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", INS)), insuranceTokens);
        assertEq(_read(INS, abi.encodeWithSignature("vaultBalance(address)", TOKEN)), insurance);
        assertEq(_read(D1, abi.encodeWithSignature("totalMarkets()")), marketCount);
        assertEq(_read(D2, abi.encodeWithSignature("feeRecipient()")), feeRecipient);
        assertEq(_read(D2, abi.encodeWithSignature("protocolFeeVault()")), feeVault);
        assertEq(_read(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN)), seizerConfig);
        assertEq(_read(D5, abi.encodeWithSignature("maxOracleDelay()")), oracleDelay);
        assertEq(_read(VAULT, abi.encodeWithSignature("isAuthorizedEngine(address)", D4)), abi.encode(false));
        assertEq(_read(INS, abi.encodeWithSignature("isBackstopCaller(address)", D4)), abi.encode(false));
    }

    function _approvedSignature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function testSafeProxyPathWithForkOnlyOwnerApprovals() public {
        bytes memory data = abi.encodeWithSelector(tl.executeTransaction.selector, D4, 0, inner, ETA);
        vm.warp(ETA);
        bytes32 safeHash = safe.getTransactionHash(TL, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        vm.prank(OWNER_A);
        safe.approveHash(safeHash);
        vm.prank(OWNER_B);
        safe.approveHash(safeHash);
        bytes memory signatures = bytes.concat(_approvedSignature(OWNER_A), _approvedSignature(OWNER_B));
        uint256 gasBefore = gasleft();
        bool ok = safe.execTransaction(TL, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), signatures);
        emit log_named_uint("M2_S2_LOCAL_SAFE_EXEC_GAS", gasBefore - gasleft());
        assertTrue(ok);
        assertEq(safe.nonce(), 23);
        assertFalse(tl.queuedTransactions(OP));
        assertTrue(d4.tradingPaused());
        assertTrue(d4.liquidationPaused());
        assertTrue(d4.fundingPaused());
        assertTrue(d4.collateralOpsPaused());
        assertTrue(d6.paused());
    }
}
