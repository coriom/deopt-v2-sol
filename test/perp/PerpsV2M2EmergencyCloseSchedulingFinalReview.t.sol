// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";

/// @notice Fork-only S1-M2 scheduling review. Safe-address prank does not validate signatures.
contract PerpsV2M2EmergencyCloseSchedulingFinalReviewTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INS = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEAR = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant RUNTIME = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    address constant TRADER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;
    bytes32 constant EXPECTED_ID = 0xe67e4f92022dd5cdbabc05c6ce0ee63f2cb186ef0aaccbe5eec002d6f3718063;
    bytes32 constant EXPECTED_DOMAIN = 0x1ff87de391024af5fcccddf4e4a83e9fb5acc5ddf28cf85f76eefc96d5d4d0f5;
    uint256 constant ETA = 1792465200;

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpEngineV2 d4 = PerpEngineV2(D4);
    PerpMatchingEngineV2 d6 = PerpMatchingEngineV2(D6);
    bytes inner;

    function setUp() public {
        vm.createSelectFork(vm.envString("M2_RPC_URL"), vm.envUint("M2_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        assertTrue(d6.paused());
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
        assertFalse(tl.queuePaused());
        assertGe(ETA, block.timestamp + tl.minDelay() + 3600);
        inner = abi.encodeWithSelector(bytes4(0xf64e345d), true, true, true, true);
        assertEq(keccak256(inner), 0xede11d55a86c671f6ff569f50d69a0dcac0a9584879fcad82e931aed5cbd7830);
        assertEq(tl.hashOperation(D4, 0, inner, ETA), EXPECTED_ID);
        assertFalse(tl.queuedTransactions(EXPECTED_ID));
    }

    function _queue() internal {
        vm.prank(SAFE); // fork-only role check; no real Safe owner signatures
        assertEq(tl.queueTransaction(D4, 0, inner, ETA), EXPECTED_ID);
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory result) {
        (bool ok, bytes memory raw) = target.staticcall(data);
        assertTrue(ok);
        return raw;
    }

    function testExactOuterCalldataAndOperationIdentity() public view {
        bytes memory outer =
            abi.encodeWithSignature("queueTransaction(address,uint256,bytes,uint256)", D4, 0, inner, ETA);
        assertTrue(bytes4(outer) == bytes4(0x8e361cdf));
        assertEq(keccak256(outer), 0xb379a7191b4e098982e2bed3e1667471afd031d53afcf9fed0d76cbdd4ee845e);
        assertEq(EXPECTED_ID, keccak256(abi.encode(D4, uint256(0), inner, ETA)));
        assertTrue(tl.hashOperation(D4, 0, inner, ETA + 1) != EXPECTED_ID);
        assertTrue(tl.hashOperation(D6, 0, inner, ETA) != EXPECTED_ID);
    }

    function testScheduleEmitsExactEventAndDoesNotExecute() public {
        vm.recordLogs();
        _queue();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != TL) continue;
            assertEq(logs[i].topics[0], keccak256("TransactionQueued(bytes32,address,uint256,bytes,uint256)"));
            assertEq(logs[i].topics[1], EXPECTED_ID);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), D4);
            (uint256 value, bytes memory data, uint256 eta) = abi.decode(logs[i].data, (uint256, bytes, uint256));
            assertEq(value, 0);
            assertEq(data, inner);
            assertEq(eta, ETA);
            ++count;
        }
        assertEq(count, 1);
        assertTrue(tl.queuedTransactions(EXPECTED_ID));
        assertFalse(tl.isOperationReady(D4, 0, inner, ETA));
        assertFalse(d4.tradingPaused());
        assertFalse(d4.liquidationPaused());
        assertFalse(d4.fundingPaused());
        assertFalse(d4.collateralOpsPaused());
        assertTrue(d6.paused());
    }

    function testUnauthorizedCollisionAndPrematureExecution() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
        tl.queueTransaction(D4, 0, inner, ETA);
        _queue();
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionAlreadyQueued.selector);
        tl.queueTransaction(D4, 0, inner, ETA);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        tl.executeTransaction(D4, 0, inner, ETA);
        assertTrue(tl.queuedTransactions(EXPECTED_ID));
        assertFalse(d4.tradingPaused());
    }

    function testSchedulingPreservesBoundedEconomicState() public {
        bytes memory pos = _read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1));
        bytes memory clearing = _read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEAR, TOKEN));
        bytes memory custody = _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT));
        bytes memory insurance = _read(INS, abi.encodeWithSignature("vaultBalance(address)", TOKEN));
        bytes32 domain = d6.domainSeparatorV4();
        uint256 nonce = d6.nonces(TRADER);
        bytes32 sampleIntent = keccak256("M2 S1 untouched fill");
        uint128 fill = d6.intentFilled(sampleIntent);
        _queue();
        assertEq(uint256(d4.migrationState()), 0);
        assertEq(d4.migrationSnapshotHash(), bytes32(0));
        assertEq(d4.riskModule(), address(0));
        assertEq(d4.matchingEngine(), address(0));
        assertEq(d4.totalResidualBadDebtBase(), 0);
        assertEq(_read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1)), pos);
        assertEq(_read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEAR, TOKEN)), clearing);
        assertEq(_read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT)), custody);
        assertEq(_read(INS, abi.encodeWithSignature("vaultBalance(address)", TOKEN)), insurance);
        assertEq(_read(VAULT, abi.encodeWithSignature("isAuthorizedEngine(address)", D4)), abi.encode(false));
        assertEq(_read(INS, abi.encodeWithSignature("isBackstopCaller(address)", D4)), abi.encode(false));
        assertTrue(d6.paused());
        assertEq(d6.domainSeparatorV4(), EXPECTED_DOMAIN);
        assertEq(d6.domainSeparatorV4(), domain);
        assertTrue(d6.isExecutor(TL));
        assertFalse(d6.isExecutor(RUNTIME));
        assertEq(d6.nonces(TRADER), nonce);
        assertEq(d6.intentFilled(sampleIntent), fill);
        assertFalse(d4.tradingPaused());
        assertFalse(d4.liquidationPaused());
        assertFalse(d4.fundingPaused());
        assertFalse(d4.collateralOpsPaused());
    }
}
