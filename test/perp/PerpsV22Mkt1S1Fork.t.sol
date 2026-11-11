// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";

interface IV22Safe {
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

/// @notice Read-only fork rehearsal. vm.prank approvals are never real Safe signatures.
contract PerpsV22Mkt1S1ForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant OWNER_A = 0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d;
    address constant OWNER_B = 0xa774C46C41064524dF895BD7bE9F294409798dFC;
    uint256 constant ETA = 1794657600;
    bytes32 constant C02 = 0xee2e6d5e45752f49a06007becb4b5fba8a1c906a4e45b72c6e109b8ef014807f;
    bytes32 constant MKT = 0xd5df44f7f5a0ff062c46766587c194a0bc1a706c66555b8b01613e09bc5207a8;
    bytes32 constant OLD_MKT = 0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268;
    bytes32 constant SAFE_HASH = 0xd8dae05f3362d3dea6fd23497c14ec61ed3db2e2a78c4361e2192e1d60290e84;
    bytes32 constant QUEUED_TOPIC = keccak256("TransactionQueued(bytes32,address,uint256,bytes,uint256)");

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpMarketRegistry registry = PerpMarketRegistry(D1);
    IV22Safe safe = IV22Safe(SAFE);
    bytes mktData;
    bytes queueData;

    function setUp() public {
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        uint256 forkBlock = vm.envOr("V22_FORK_BLOCK", uint256(0));
        if (bytes(rpcUrl).length == 0 || forkBlock == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, forkBlock);
        assertEq(block.chainid, 84532);
        assertEq(safe.nonce(), 44);
        assertEq(registry.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(C02));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertFalse(tl.queuedTransactions(MKT));
        assertTrue(tl.proposers(SAFE));
        assertEq(tl.minDelay(), 1 days);
        assertGe(ETA - block.timestamp, tl.minDelay() + 12 hours);
        mktData = abi.encodeCall(registry.setMarketStatus, (1, false, false));
        assertEq(tl.hashOperation(D1, 0, mktData, ETA), MKT);
        queueData = abi.encodeCall(tl.queueTransaction, (D1, 0, mktData, ETA));
        assertEq(safe.getTransactionHash(TL, 0, queueData, 0, 0, 0, 0, address(0), address(0), 44), SAFE_HASH);
    }

    function _signature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function testQueueOnlyMkt1AndPreservePauses() public {
        bytes32 txHash = safe.getTransactionHash(TL, 0, queueData, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        vm.prank(OWNER_A);
        safe.approveHash(txHash);
        vm.prank(OWNER_B);
        safe.approveHash(txHash);
        vm.recordLogs();
        uint256 beforeGas = gasleft();
        bool success = safe.execTransaction(
            TL,
            0,
            queueData,
            0,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            bytes.concat(_signature(OWNER_A), _signature(OWNER_B))
        );
        emit log_named_uint("V22_MKT1_S1_SAFE_GAS_FORK", beforeGas - gasleft());
        assertTrue(success);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 queuedCount;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == TL && logs[i].topics[0] == QUEUED_TOPIC) {
                ++queuedCount;
                assertEq(logs[i].topics[1], MKT);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), D1);
                (uint256 value, bytes memory data, uint256 eta) = abi.decode(logs[i].data, (uint256, bytes, uint256));
                assertEq(value, 0);
                assertEq(data, mktData);
                assertEq(eta, ETA);
            }
        }
        assertEq(queuedCount, 1);
        assertEq(safe.nonce(), 45);
        assertTrue(tl.queuedTransactions(C02));
        assertTrue(tl.queuedTransactions(MKT));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertEq(registry.totalMarkets(), 0);
        assertEq(registry.nextMarketId(), 1);
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
}
