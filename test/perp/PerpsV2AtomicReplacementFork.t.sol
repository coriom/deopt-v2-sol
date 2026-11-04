// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpMarketRegistry} from "../../src/perp/PerpMarketRegistry.sol";

interface IV9Safe {
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

/// @notice Fork-only replacement rehearsal. Owner pranks are synthetic, never public signatures.
contract PerpsV2AtomicReplacementForkTest is Test {
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
    address constant OLD_DEPLOYER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    uint256 constant FORK_BLOCK = 54389568;
    uint256 constant OLD_C02_ETA = 1792929600;
    uint256 constant OLD_MKT_ETA = 1793534400;
    uint256 constant NEW_ETA = 1794312000; // Conditional 2026-11-10 12:00 UTC, not approved.
    bytes32 constant OLD_C02 = 0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e;
    bytes32 constant OLD_MKT = 0x9d2bd83ac8d34252fa2418e5b403a716e0131121fd14dad25a112220f7eef268;

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpMarketRegistry d1 = PerpMarketRegistry(D1);
    IV9Safe safe = IV9Safe(SAFE);
    bytes c02;
    bytes mkt;
    bytes batch;
    bytes32 newC02;
    bytes32 newMkt;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), FORK_BLOCK);
        assertEq(block.chainid, 84532);
        assertEq(safe.nonce(), 43);
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(OLD_C02));
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertTrue(tl.executors(SAFE));
        assertFalse(tl.executors(address(0)));
        assertFalse(tl.executors(OLD_DEPLOYER));
        assertEq(tl.owner(), SAFE);
        assertEq(tl.guardian(), SAFE);
        assertEq(tl.minDelay(), 1 days);
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
        assertEq(tl.hashOperation(D1, 0, c02, OLD_C02_ETA), OLD_C02);
        assertEq(tl.hashOperation(D1, 0, mkt, OLD_MKT_ETA), OLD_MKT);
        newC02 = tl.hashOperation(D1, 0, c02, NEW_ETA);
        newMkt = tl.hashOperation(D1, 0, mkt, NEW_ETA);
        bytes memory first = abi.encodeCall(tl.executeTransaction, (D1, 0, c02, NEW_ETA));
        bytes memory second = abi.encodeCall(tl.executeTransaction, (D1, 0, mkt, NEW_ETA));
        batch = abi.encodeWithSignature(
            "multiSend(bytes)",
            bytes.concat(
                abi.encodePacked(uint8(0), TL, uint256(0), uint256(first.length), first),
                abi.encodePacked(uint8(0), TL, uint256(0), uint256(second.length), second)
            )
        );
    }

    function _sig(address owner) internal pure returns (bytes memory) {
        return abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
    }

    function _approve(address to, bytes memory data, uint8 operation) internal returns (bytes32 hash) {
        hash = safe.getTransactionHash(to, 0, data, operation, 0, 0, 0, address(0), address(0), safe.nonce());
        vm.prank(OWNER_A);
        safe.approveHash(hash);
        vm.prank(OWNER_B);
        safe.approveHash(hash);
    }

    function _exec(address to, bytes memory data, uint8 operation, bool expectSuccess) internal {
        uint256 nonceBefore = safe.nonce();
        _approve(to, data, operation);
        if (!expectSuccess) vm.expectRevert(bytes("GS013"));
        bool ok = safe.execTransaction(
            to, 0, data, operation, 0, 0, 0, address(0), payable(address(0)), bytes.concat(_sig(OWNER_A), _sig(OWNER_B))
        );
        if (expectSuccess) {
            assertTrue(ok);
            assertEq(safe.nonce(), nonceBefore + 1);
        } else {
            assertEq(safe.nonce(), nonceBefore);
        }
    }

    function _stageReplacement() internal {
        _exec(TL, abi.encodeCall(tl.cancelTransaction, (D1, 0, c02, OLD_C02_ETA)), 0, true);
        _exec(TL, abi.encodeCall(tl.cancelTransaction, (D1, 0, mkt, OLD_MKT_ETA)), 0, true);
        assertFalse(tl.queuedTransactions(OLD_C02));
        assertFalse(tl.queuedTransactions(OLD_MKT));
        assertGt(NEW_ETA, block.timestamp + tl.minDelay());
        _exec(TL, abi.encodeCall(tl.queueTransaction, (D1, 0, c02, NEW_ETA)), 0, true);
        _exec(TL, abi.encodeCall(tl.queueTransaction, (D1, 0, mkt, NEW_ETA)), 0, true);
        assertTrue(tl.queuedTransactions(newC02));
        assertTrue(tl.queuedTransactions(newMkt));
        assertEq(safe.nonce(), 47);
        assertEq(d1.totalMarkets(), 0);
        emit log_named_bytes32("FORK_ONLY_NEW_C02_OPERATION", newC02);
        emit log_named_bytes32("FORK_ONLY_NEW_MKT_OPERATION", newMkt);
    }

    function testUnauthorizedExecutorAndCancellerRejected() public {
        for (uint256 i; i < 2; ++i) {
            address actor = i == 0 ? address(0xBEEF) : OLD_DEPLOYER;
            vm.prank(actor);
            vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
            tl.executeTransaction(D1, 0, c02, OLD_C02_ETA);
            vm.prank(actor);
            vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
            tl.cancelTransaction(D1, 0, c02, OLD_C02_ETA);
        }
        assertTrue(tl.queuedTransactions(OLD_C02));
        assertEq(d1.totalMarkets(), 0);
    }

    function testOldMktAloneCannotCreateMarket() public {
        _exec(TL, abi.encodeCall(tl.executeTransaction, (D1, 0, mkt, OLD_MKT_ETA)), 0, false);
        assertTrue(tl.queuedTransactions(OLD_MKT));
        assertEq(d1.totalMarkets(), 0);
        assertEq(safe.nonce(), 43);
    }

    function testReplacementQueueDelayAndAtomicFinalState() public {
        bytes memory feeBefore = _read(D2, abi.encodeWithSignature("merkleRoot()"));
        bytes memory d3Before =
            _read(D3, abi.encodeWithSignature("seizeConfigs(address)", 0x6eAe407f5640B006faC9965182e238582A3B412E));
        _stageReplacement();
        vm.warp(NEW_ETA);
        vm.recordLogs();
        uint256 beforeGas = gasleft();
        _exec(MULTISEND, batch, 1, true);
        emit log_named_uint("FORK_ONLY_REPLACEMENT_BATCH_GAS", beforeGas - gasleft());
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
                if (logs[i].topics[1] == newC02) firstDone = i;
                if (logs[i].topics[1] == newMkt) secondDone = i;
            }
        }
        assertLt(created, firstDone);
        assertLt(firstDone, inactive);
        assertLt(inactive, secondDone);
        assertEq(d1.totalMarkets(), 1);
        PerpMarketRegistry.Market memory market = d1.getMarket(1);
        assertTrue(market.exists);
        assertFalse(market.isActive);
        assertFalse(market.isCloseOnly);
        assertFalse(tl.queuedTransactions(newC02));
        assertFalse(tl.queuedTransactions(newMkt));
        assertEq(safe.nonce(), 48);
        assertTrue(abi.decode(_read(D4, abi.encodeWithSignature("tradingPaused()")), (bool)));
        assertTrue(abi.decode(_read(D4, abi.encodeWithSignature("liquidationPaused()")), (bool)));
        assertTrue(abi.decode(_read(D4, abi.encodeWithSignature("fundingPaused()")), (bool)));
        assertTrue(abi.decode(_read(D4, abi.encodeWithSignature("collateralOpsPaused()")), (bool)));
        assertTrue(abi.decode(_read(D6, abi.encodeWithSignature("paused()")), (bool)));
        assertEq(_read(D2, abi.encodeWithSignature("merkleRoot()")), feeBefore);
        assertEq(
            _read(D3, abi.encodeWithSignature("seizeConfigs(address)", 0x6eAe407f5640B006faC9965182e238582A3B412E)),
            d3Before
        );
    }

    function testPrematureBatchFailsClosed() public {
        _stageReplacement();
        vm.warp(NEW_ETA - 1);
        _exec(MULTISEND, batch, 1, false);
        assertEq(safe.nonce(), 47);
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(newC02));
        assertTrue(tl.queuedTransactions(newMkt));
    }

    function testSecondFailureRevertsFirstOperation() public {
        _stageReplacement();
        vm.prank(TL); // Fork-only fault injection; no public D1 pause.
        d1.pauseConfig();
        vm.warp(NEW_ETA);
        _exec(MULTISEND, batch, 1, false);
        assertEq(safe.nonce(), 47);
        assertEq(d1.totalMarkets(), 0);
        assertTrue(tl.queuedTransactions(newC02));
        assertTrue(tl.queuedTransactions(newMkt));
    }

    function testChangedSafeNonceInvalidatesOldApproval() public {
        _stageReplacement();
        bytes32 oldHash = _approve(MULTISEND, batch, 1); // Approved at nonce 47, fork only.
        bytes memory readCall = abi.encodeWithSignature("marketExists(uint256)", 1);
        _exec(D1, readCall, 0, true); // Local-only nonce advance.
        assertEq(safe.nonce(), 48);
        bytes32 freshHash = safe.getTransactionHash(MULTISEND, 0, batch, 1, 0, 0, 0, address(0), address(0), 48);
        assertTrue(freshHash != oldHash);
        vm.expectRevert();
        safe.execTransaction(
            MULTISEND, 0, batch, 1, 0, 0, 0, address(0), payable(address(0)), bytes.concat(_sig(OWNER_A), _sig(OWNER_B))
        );
        assertEq(d1.totalMarkets(), 0);
    }

    function _read(address target, bytes memory data) internal view returns (bytes memory out) {
        (bool ok, bytes memory value) = target.staticcall(data);
        require(ok, "getter failed");
        return value;
    }
}
