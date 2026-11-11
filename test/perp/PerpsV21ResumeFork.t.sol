// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";

interface IV21Safe {
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

/// @notice Pinned, fork-only V21 rehearsal. Owner pranks are not genuine signatures.
contract PerpsV21ResumeForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant MULTISEND = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address constant OWNER_A = 0x0E7DcB5b9fd969E4fDc6F3A7b7993819dDC5a35d;
    address constant OWNER_B = 0xa774C46C41064524dF895BD7bE9F294409798dFC;
    uint256 constant FORK_BLOCK = 57250691;
    uint256 constant ETA = 1794657600; // 2026-11-14 12:00 UTC, conditional.
    uint256 constant OLD_C02_ETA = 1792929600;
    uint256 constant OLD_MKT_ETA = 1793534400;
    bytes32 constant OLD_C02 = 0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e;
    bytes32 constant OLD_MKT = 0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268;
    bytes32 constant NEW_C02 = 0xee2e6d5e45752f49a06007becb4b5fba8a1c906a4e45b72c6e109b8ef014807f;
    bytes32 constant NEW_MKT = 0xd5df44f7f5a0ff062c46766587c194a0bc1a706c66555b8b01613e09bc5207a8;

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpMarketRegistry d1 = PerpMarketRegistry(D1);
    IV21Safe safe = IV21Safe(SAFE);
    bytes c02;
    bytes mkt;
    bytes atomicBatch;

    function setUp() public {
        string memory rpcUrl = vm.envOr("RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpcUrl, FORK_BLOCK);
        assertEq(block.chainid, 84532);
        assertEq(safe.nonce(), 43);
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(OLD_C02));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertFalse(tl.isOperationReady(D1, 0, _c02Data(), OLD_C02_ETA));
        c02 = _c02Data();
        mkt = abi.encodeCall(d1.setMarketStatus, (1, false, false));
        assertEq(tl.hashOperation(D1, 0, c02, OLD_C02_ETA), OLD_C02);
        assertEq(tl.hashOperation(D1, 0, mkt, OLD_MKT_ETA), OLD_MKT);
        assertEq(tl.hashOperation(D1, 0, c02, ETA), NEW_C02);
        assertEq(tl.hashOperation(D1, 0, mkt, ETA), NEW_MKT);
        bytes memory first = abi.encodeCall(tl.executeTransaction, (D1, 0, c02, ETA));
        bytes memory second = abi.encodeCall(tl.executeTransaction, (D1, 0, mkt, ETA));
        atomicBatch = abi.encodeWithSignature(
            "multiSend(bytes)",
            bytes.concat(
                abi.encodePacked(uint8(0), TL, uint256(0), uint256(first.length), first),
                abi.encodePacked(uint8(0), TL, uint256(0), uint256(second.length), second)
            )
        );
        assertEq(keccak256(atomicBatch), 0xff289af20486c643fd30e74ea108fe83abae930c760c7296bfcae7ed5eadde7c);
    }

    function _c02Data() internal view returns (bytes memory) {
        return abi.encodeCall(
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
    }

    function _sig(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function _exec(address to, bytes memory data, uint8 operation, bool success) internal returns (uint256 gasUsed) {
        uint256 beforeNonce = safe.nonce();
        bytes32 hash = safe.getTransactionHash(to, 0, data, operation, 0, 0, 0, address(0), address(0), beforeNonce);
        vm.prank(OWNER_A);
        safe.approveHash(hash);
        vm.prank(OWNER_B);
        safe.approveHash(hash);
        uint256 beforeGas = gasleft();
        if (!success) vm.expectRevert(bytes("GS013"));
        bool ok = safe.execTransaction(
            to, 0, data, operation, 0, 0, 0, address(0), payable(address(0)), bytes.concat(_sig(OWNER_A), _sig(OWNER_B))
        );
        gasUsed = beforeGas - gasleft();
        if (success) {
            assertTrue(ok);
            assertEq(safe.nonce(), beforeNonce + 1);
        } else {
            assertEq(safe.nonce(), beforeNonce);
        }
    }

    function _queuePair() internal {
        assertGe(ETA - block.timestamp, tl.minDelay() + 12 hours);
        uint256 firstGas = _exec(TL, abi.encodeCall(tl.queueTransaction, (D1, 0, c02, ETA)), 0, true);
        uint256 secondGas = _exec(TL, abi.encodeCall(tl.queueTransaction, (D1, 0, mkt, ETA)), 0, true);
        emit log_named_uint("V21_C02_S1_SAFE_GAS_FORK", firstGas);
        emit log_named_uint("V21_MKT1_S1_SAFE_GAS_FORK", secondGas);
        assertEq(safe.nonce(), 45);
        assertTrue(tl.queuedTransactions(NEW_C02));
        assertTrue(tl.queuedTransactions(NEW_MKT));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertEq(d1.totalMarkets(), 0);
    }

    function testOldMktCannotCreateOrActivateMarket() public {
        _exec(TL, abi.encodeCall(tl.executeTransaction, (D1, 0, mkt, OLD_MKT_ETA)), 0, false);
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertEq(safe.nonce(), 43);
    }

    function testAtomicReplacementKeepsOldMktQueuedAndMarketInactive() public {
        bytes memory feeBefore = _read(D2, abi.encodeWithSignature("merkleRoot()"));
        bytes memory seizeBefore =
            _read(D3, abi.encodeWithSignature("seizeConfigs(address)", 0x6eAe407f5640B006faC9965182e238582A3B412E));
        _queuePair();
        vm.warp(ETA);
        vm.recordLogs();
        uint256 gasUsed = _exec(MULTISEND, atomicBatch, 1, true);
        emit log_named_uint("V21_ATOMIC_S2_SAFE_GAS_FORK", gasUsed);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 created = type(uint256).max;
        uint256 inactive = type(uint256).max;
        uint256 firstDone = type(uint256).max;
        uint256 secondDone = type(uint256).max;
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
                if (logs[i].topics[1] == NEW_C02) firstDone = i;
                if (logs[i].topics[1] == NEW_MKT) secondDone = i;
            }
        }
        assertLt(created, firstDone);
        assertLt(firstDone, inactive);
        assertLt(inactive, secondDone);
        assertEq(d1.totalMarkets(), 1);
        assertTrue(d1.getMarket(1).exists);
        assertFalse(d1.getMarket(1).isActive);
        assertFalse(d1.getMarket(1).isCloseOnly);
        assertFalse(tl.queuedTransactions(NEW_C02));
        assertFalse(tl.queuedTransactions(NEW_MKT));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertEq(_read(D2, abi.encodeWithSignature("merkleRoot()")), feeBefore);
        assertEq(
            _read(D3, abi.encodeWithSignature("seizeConfigs(address)", 0x6eAe407f5640B006faC9965182e238582A3B412E)),
            seizeBefore
        );
        assertTrue(abi.decode(_read(D4, abi.encodeWithSignature("tradingPaused()")), (bool)));
        assertTrue(abi.decode(_read(D4, abi.encodeWithSignature("liquidationPaused()")), (bool)));
        assertTrue(abi.decode(_read(D4, abi.encodeWithSignature("fundingPaused()")), (bool)));
        assertTrue(abi.decode(_read(D4, abi.encodeWithSignature("collateralOpsPaused()")), (bool)));
        assertTrue(abi.decode(_read(D6, abi.encodeWithSignature("paused()")), (bool)));
        // Fork-only interference test: the old setter can only repeat INACTIVE.
        _exec(TL, abi.encodeCall(tl.executeTransaction, (D1, 0, mkt, OLD_MKT_ETA)), 0, true);
        assertFalse(d1.getMarket(1).isActive);
        assertFalse(d1.getMarket(1).isCloseOnly);
        assertFalse(tl.queuedTransactions(OLD_MKT));
    }

    function testSecondStepFailureRevertsFirst() public {
        _queuePair();
        vm.prank(TL); // Fault injection on fork only.
        d1.pauseConfig();
        vm.warp(ETA);
        _exec(MULTISEND, atomicBatch, 1, false);
        assertEq(safe.nonce(), 45);
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(NEW_C02));
        assertTrue(tl.queuedTransactions(NEW_MKT));
        assertTrue(tl.queuedTransactions(OLD_MKT));
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory out) {
        (bool ok, bytes memory result) = target.staticcall(data);
        require(ok, "getter failed");
        return result;
    }
}
