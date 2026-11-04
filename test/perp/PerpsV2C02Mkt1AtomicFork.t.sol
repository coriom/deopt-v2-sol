// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";

interface IAtomicSafe {
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

/// @notice Fork-only rehearsal. Pranked owner approvals are NOT real Safe signatures or operator authorization.
contract PerpsV2C02Mkt1AtomicForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant MULTISEND = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address constant OWNER_A = 0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d;
    address constant OWNER_B = 0xa774C46C41064524dF895BD7bE9F294409798dFC;
    uint256 constant FORK_BLOCK = 54323530;
    uint256 constant C02_ETA = 1792929600;
    uint256 constant MKT_ETA = 1793534400;
    bytes32 constant C02_OP = 0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e;
    bytes32 constant MKT_OP = 0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268;

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpMarketRegistry d1 = PerpMarketRegistry(D1);
    IAtomicSafe safe = IAtomicSafe(SAFE);
    bytes c02;
    bytes mkt;
    bytes batchData;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), FORK_BLOCK);
        assertEq(block.chainid, 84532);
        assertEq(blockhash(FORK_BLOCK - 1) != bytes32(0), true);
        assertGt(MULTISEND.code.length, 0);
        assertEq(safe.nonce(), 43);
        assertEq(d1.totalMarkets(), 0);
        assertFalse(d1.marketExists(1));
        assertTrue(tl.executors(SAFE));
        assertTrue(tl.queuedTransactions(C02_OP));
        assertTrue(tl.queuedTransactions(MKT_OP));
        c02 = abi.encodeCall(
            d1.createMarket,
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
        mkt = abi.encodeCall(d1.setMarketStatus, (1, false, false));
        assertEq(tl.hashOperation(D1, 0, c02, C02_ETA), C02_OP);
        assertEq(tl.hashOperation(D1, 0, mkt, MKT_ETA), MKT_OP);
        bytes memory first = abi.encodeCall(tl.executeTransaction, (D1, 0, c02, C02_ETA));
        bytes memory second = abi.encodeCall(tl.executeTransaction, (D1, 0, mkt, MKT_ETA));
        bytes memory packed = bytes.concat(
            abi.encodePacked(uint8(0), TL, uint256(0), uint256(first.length), first),
            abi.encodePacked(uint8(0), TL, uint256(0), uint256(second.length), second)
        );
        batchData = abi.encodeWithSignature("multiSend(bytes)", packed);
    }

    function _signature(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function _execute() internal returns (bool ok) {
        bytes32 txHash =
            safe.getTransactionHash(MULTISEND, 0, batchData, 1, 0, 0, 0, address(0), address(0), safe.nonce());
        vm.prank(OWNER_A);
        safe.approveHash(txHash);
        vm.prank(OWNER_B);
        safe.approveHash(txHash);
        try safe.execTransaction(
            MULTISEND,
            0,
            batchData,
            1,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            bytes.concat(_signature(OWNER_A), _signature(OWNER_B))
        ) returns (
            bool success
        ) {
            ok = success;
        } catch Error(string memory reason) {
            assertEq(reason, "GS013");
            ok = false;
        }
        emit log_named_bytes32("FORK_ONLY_SAFE_TX_HASH", txHash);
    }

    function _assertMaintenance() internal view {
        assertTrue(abi.decode(_read(D4, "tradingPaused()"), (bool)));
        assertTrue(abi.decode(_read(D4, "liquidationPaused()"), (bool)));
        assertTrue(abi.decode(_read(D4, "fundingPaused()"), (bool)));
        assertTrue(abi.decode(_read(D4, "collateralOpsPaused()"), (bool)));
        assertTrue(abi.decode(_read(D6, "paused()"), (bool)));
    }

    function _read(address a, string memory sig) internal view returns (bytes memory out) {
        (bool ok, bytes memory data) = a.staticcall(abi.encodeWithSignature(sig));
        require(ok);
        return data;
    }

    function testAtomicExecutionViaActualSafeAndMultisend() public {
        _assertMaintenance();
        vm.recordLogs();
        uint256 beforeGas = gasleft();
        assertTrue(_execute());
        emit log_named_uint("FORK_ONLY_SAFE_BATCH_GAS", beforeGas - gasleft());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 created = type(uint256).max;
        uint256 inactive = type(uint256).max;
        uint256 c02Done = type(uint256).max;
        uint256 mktDone = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == D1
                    && logs[i].topics[0] == keccak256("MarketCreated(uint256,address,address,address,bytes32)")
            ) created = i;
            if (logs[i].emitter == D1 && logs[i].topics[0] == keccak256("MarketStatusUpdated(uint256,bool,bool)")) {
                inactive = i;
            }
            if (
                logs[i].emitter == TL
                    && logs[i].topics[0]
                        == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
            ) {
                if (logs[i].topics[1] == C02_OP) c02Done = i;
                if (logs[i].topics[1] == MKT_OP) mktDone = i;
            }
        }
        assertLt(created, c02Done);
        assertLt(c02Done, inactive);
        assertLt(inactive, mktDone);
        assertEq(d1.totalMarkets(), 1);
        PerpMarketRegistry.Market memory market = d1.getMarket(1);
        assertTrue(market.exists);
        assertFalse(market.isActive);
        assertFalse(market.isCloseOnly);
        assertFalse(tl.queuedTransactions(C02_OP));
        assertFalse(tl.queuedTransactions(MKT_OP));
        assertEq(safe.nonce(), 44);
        _assertMaintenance();
    }

    function testSecondOperationFailureRevertsEntireBatch() public {
        vm.prank(TL); // Local-only artificial config pause: createMarket remains possible; setter fails.
        d1.pauseConfig();
        assertTrue(_execute() == false);
        assertEq(d1.totalMarkets(), 0);
        assertFalse(d1.marketExists(1));
        assertTrue(tl.queuedTransactions(C02_OP));
        assertTrue(tl.queuedTransactions(MKT_OP));
        assertEq(safe.nonce(), 43); // GS013 reverts the complete Safe transaction, including its nonce update.
        _assertMaintenance();
    }

    function testExpiredC02CannotCreateMarket() public {
        vm.warp(C02_ETA + 14 days + 1);
        assertFalse(_execute());
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(C02_OP));
        assertTrue(tl.queuedTransactions(MKT_OP));
    }

    function testWrongOrderFailsWithoutMarketCreation() public {
        bytes memory first = abi.encodeCall(tl.executeTransaction, (D1, 0, c02, C02_ETA));
        bytes memory second = abi.encodeCall(tl.executeTransaction, (D1, 0, mkt, MKT_ETA));
        bytes memory reversed = bytes.concat(
            abi.encodePacked(uint8(0), TL, uint256(0), uint256(second.length), second),
            abi.encodePacked(uint8(0), TL, uint256(0), uint256(first.length), first)
        );
        batchData = abi.encodeWithSignature("multiSend(bytes)", reversed);
        assertFalse(_execute());
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(C02_OP));
        assertTrue(tl.queuedTransactions(MKT_OP));
        assertEq(safe.nonce(), 43);
    }

    function testCancelledC02CannotCreateMarket() public {
        vm.prank(SAFE); // Fork-only cancel, never performed on public chain.
        tl.cancelTransaction(D1, 0, c02, C02_ETA);
        assertFalse(_execute());
        assertEq(d1.totalMarkets(), 0);
        assertFalse(tl.queuedTransactions(C02_OP));
        assertTrue(tl.queuedTransactions(MKT_OP));
        assertEq(safe.nonce(), 43);
    }

    function testStaleSafeApprovalCannotExecuteAtAdvancedNonce() public {
        bytes32 oldHash = safe.getTransactionHash(MULTISEND, 0, batchData, 1, 0, 0, 0, address(0), address(0), 43);
        vm.prank(OWNER_A);
        safe.approveHash(oldHash);
        vm.prank(OWNER_B);
        safe.approveHash(oldHash);

        bytes memory readData = abi.encodeWithSignature("marketExists(uint256)", 1);
        bytes32 noopHash = safe.getTransactionHash(D1, 0, readData, 0, 0, 0, 0, address(0), address(0), 43);
        vm.prank(OWNER_A);
        safe.approveHash(noopHash);
        vm.prank(OWNER_B);
        safe.approveHash(noopHash);
        assertTrue(
            safe.execTransaction(
                D1,
                0,
                readData,
                0,
                0,
                0,
                0,
                address(0),
                payable(address(0)),
                bytes.concat(_signature(OWNER_A), _signature(OWNER_B))
            )
        );
        assertEq(safe.nonce(), 44);
        vm.expectRevert(); // Owner approvals were for nonce 43, not nonce 44.
        safe.execTransaction(
            MULTISEND,
            0,
            batchData,
            1,
            0,
            0,
            0,
            address(0),
            payable(address(0)),
            bytes.concat(_signature(OWNER_A), _signature(OWNER_B))
        );
        assertEq(safe.nonce(), 44);
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(C02_OP));
        assertTrue(tl.queuedTransactions(MKT_OP));
    }
}
