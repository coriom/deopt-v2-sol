// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";

interface IV23Safe {
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

/// @notice Current-state fork only. Synthetic owner preapprovals are not Safe signatures.
contract PerpsV23AtomicS2ForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant MULTISEND = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address constant OWNER_A = 0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d;
    address constant OWNER_B = 0xa774C46C41064524dF895BD7bE9F294409798dFC;
    uint256 constant ETA = 1794657600;
    uint256 constant OLD_MKT_ETA = 1793534400;
    bytes32 constant C02 = 0xee2e6d5e45752f49a06007becb4b5fba8a1c906a4e45b72c6e109b8ef014807f;
    bytes32 constant MKT = 0xd5df44f7f5a0ff062c46766587c194a0bc1a706c66555b8b01613e09bc5207a8;
    bytes32 constant OLD_MKT = 0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268;
    bytes32 constant SAFE_HASH = 0x4ddefb02fc131b134be68507147c586391f5e00f62757c7c0ae9147efbe8125f;
    bytes32 constant BATCH_HASH = 0xff289af20486c643fd30e74ea108fe83abae930c760c7296bfcae7ed5eadde7c;

    IV23Safe safe = IV23Safe(SAFE);
    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpMarketRegistry registry = PerpMarketRegistry(D1);
    bytes c02Data;
    bytes mktData;
    bytes batchData;

    function setUp() public {
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        uint256 forkBlock = vm.envOr("V23_FORK_BLOCK", uint256(0));
        if (bytes(rpcUrl).length == 0 || forkBlock == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 84532);
        assertEq(safe.nonce(), 45);
        assertEq(registry.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(C02));
        assertTrue(tl.queuedTransactions(MKT));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertLt(block.timestamp, ETA);
        c02Data = abi.encodeCall(
            registry.createMarket,
            (
                0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02,
                0x6eAe407f5640B006faC9965182e238582A3B412E,
                0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581,
                bytes32("ETH-PERP"),
                PerpMarketRegistry.RiskConfig(1000, 750, 500, 10000000000, 50000000000, true),
                PerpMarketRegistry.LiquidationConfig(5000, 100, 50, 60),
                PerpMarketRegistry.FundingConfig(false, 0, 0, 0, 0, 0)
            )
        );
        mktData = abi.encodeCall(registry.setMarketStatus, (1, false, false));
        assertEq(tl.hashOperation(D1, 0, c02Data, ETA), C02);
        assertEq(tl.hashOperation(D1, 0, mktData, ETA), MKT);
        bytes memory first = abi.encodeCall(tl.executeTransaction, (D1, 0, c02Data, ETA));
        bytes memory second = abi.encodeCall(tl.executeTransaction, (D1, 0, mktData, ETA));
        batchData = abi.encodeWithSignature(
            "multiSend(bytes)",
            bytes.concat(
                abi.encodePacked(uint8(0), TL, uint256(0), uint256(first.length), first),
                abi.encodePacked(uint8(0), TL, uint256(0), uint256(second.length), second)
            )
        );
        assertEq(keccak256(batchData), BATCH_HASH);
        assertEq(safe.getTransactionHash(MULTISEND, 0, batchData, 1, 0, 0, 0, address(0), address(0), 45), SAFE_HASH);
    }

    function _signature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function _execute(address target, bytes memory data, uint8 operation, bool shouldSucceed)
        internal
        returns (uint256 gasUsed)
    {
        uint256 nonceBefore = safe.nonce();
        bytes32 hash = safe.getTransactionHash(target, 0, data, operation, 0, 0, 0, address(0), address(0), nonceBefore);
        vm.prank(OWNER_A);
        safe.approveHash(hash);
        vm.prank(OWNER_B);
        safe.approveHash(hash);
        uint256 gasBefore = gasleft();
        if (!shouldSucceed) vm.expectRevert(bytes("GS013"));
        bool ok = safe.execTransaction(
            target,
            0,
            data,
            operation,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            bytes.concat(_signature(OWNER_A), _signature(OWNER_B))
        );
        gasUsed = gasBefore - gasleft();
        assertEq(safe.nonce(), nonceBefore + (shouldSucceed ? 1 : 0));
        if (shouldSucceed) assertTrue(ok);
    }

    function _paused() internal view {
        assertTrue(_bool(D4, abi.encodeWithSignature("tradingPaused()")));
        assertTrue(_bool(D4, abi.encodeWithSignature("liquidationPaused()")));
        assertTrue(_bool(D4, abi.encodeWithSignature("fundingPaused()")));
        assertTrue(_bool(D4, abi.encodeWithSignature("collateralOpsPaused()")));
        assertTrue(_bool(D6, abi.encodeWithSignature("paused()")));
    }

    function _bool(address target, bytes memory data) internal view returns (bool) {
        (bool ok, bytes memory result) = target.staticcall(data);
        require(ok, "getter failed");
        return abi.decode(result, (bool));
    }

    function testAtomicBatchFinalInactiveAndOrderedEvents() public {
        _paused();
        vm.warp(ETA);
        assertTrue(tl.isOperationReady(D1, 0, c02Data, ETA));
        assertTrue(tl.isOperationReady(D1, 0, mktData, ETA));
        vm.recordLogs();
        uint256 gasUsed = _execute(MULTISEND, batchData, 1, true);
        emit log_named_uint("V23_ATOMIC_S2_SAFE_GAS_FORK", gasUsed);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 created = type(uint256).max;
        uint256 c02Done = type(uint256).max;
        uint256 inactive = type(uint256).max;
        uint256 mktDone = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == D1
                    && logs[i].topics[0] == keccak256("MarketCreated(uint256,address,address,address,bytes32)")
            ) {
                created = i;
            }
            if (logs[i].emitter == D1 && logs[i].topics[0] == keccak256("MarketStatusUpdated(uint256,bool,bool)")) {
                inactive = i;
            }
            if (
                logs[i].emitter == TL
                    && logs[i].topics[0]
                        == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
            ) {
                if (logs[i].topics[1] == C02) c02Done = i;
                if (logs[i].topics[1] == MKT) mktDone = i;
            }
        }
        assertLt(created, c02Done);
        assertLt(c02Done, inactive);
        assertLt(inactive, mktDone);
        assertEq(registry.totalMarkets(), 1);
        assertTrue(registry.getMarket(1).exists);
        assertFalse(registry.getMarket(1).isActive);
        assertFalse(registry.getMarket(1).isCloseOnly);
        assertFalse(tl.queuedTransactions(C02));
        assertFalse(tl.queuedTransactions(MKT));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertEq(safe.nonce(), 46);
        _paused();
    }

    function testMktFailureRevertsCreationAndPreservesQueue() public {
        vm.prank(TL); // Fork-only fault injection.
        registry.pauseConfig();
        vm.warp(ETA);
        _execute(MULTISEND, batchData, 1, false);
        assertEq(registry.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(C02));
        assertTrue(tl.queuedTransactions(MKT));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertEq(safe.nonce(), 45);
        _paused();
    }

    function testOldMktCannotCreateMarketAndOnlyRepeatsInactiveAfterBatch() public {
        bytes memory oldCall = abi.encodeCall(tl.executeTransaction, (D1, 0, mktData, OLD_MKT_ETA));
        _execute(TL, oldCall, 0, false);
        assertEq(registry.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(OLD_MKT));
        vm.warp(ETA);
        _execute(MULTISEND, batchData, 1, true);
        _execute(TL, oldCall, 0, true); // Fork only; this is never an authorized live action.
        assertFalse(registry.getMarket(1).isActive);
        assertFalse(registry.getMarket(1).isCloseOnly);
        _paused();
    }
}
