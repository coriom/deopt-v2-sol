// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionProductRegistry} from "../../src/OptionProductRegistry.sol";
import {OptionMatchingEngine} from "../../src/matching/OptionMatchingEngine.sol";
import {CoveredCallMarginEngine} from "../../src/experimental/CoveredCallMarginEngine.sol";

interface IV24Safe {
    function nonce() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
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
        address,
        bytes calldata
    ) external returns (bool);
}

interface IV24Timelock {
    function queuedTransactions(bytes32) external view returns (bool);
    function executeTransaction(address, uint256, bytes calldata, uint256) external payable returns (bytes memory);
}

interface IV24Token {
    function balanceOf(address) external view returns (uint256);
}

contract OptionsV24GovernedConfigFork is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant MS = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;
    address constant REG = 0xcb7bc539ed4A5771F3420f498002e0fc4eE1bD27;
    address constant ENG = 0x2C4589c88323009db372B4067702e6292ddD294C;
    address constant MAT = 0x63DE63912BB6743F72ea77847572503Cc93B7d80;
    address constant OLD_REG = 0x3d52b033Fab00ed6104DD3bc0a715F8648344ecA;
    address constant OLD_VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant MWETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;

    IV24Safe safe = IV24Safe(SAFE);
    IV24Timelock tl = IV24Timelock(TL);
    OptionProductRegistry registry = OptionProductRegistry(REG);
    OptionMatchingEngine matcher = OptionMatchingEngine(MAT);
    CoveredCallMarginEngine engine = CoveredCallMarginEngine(ENG);
    bytes queueData;
    bytes executeData;
    bytes32[4] ids;
    uint256 eta;

    function setUp() public {
        string memory doc = vm.readFile("/tmp/deopt-options-v24-package.json");
        vm.createSelectFork(vm.envString("OPTIONS_V24_FORK_RPC"), vm.parseJsonUint(doc, ".snapshot.block"));
        queueData = vm.parseJsonBytes(doc, ".queueSafeAction.data");
        executeData = vm.parseJsonBytes(doc, ".executeSafeActionConditional.data");
        eta = vm.parseJsonUint(doc, ".operations[0].eta");
        for (uint256 i; i < 4; ++i) {
            ids[i] = vm.parseJsonBytes32(doc, string.concat(".operations[", vm.toString(i), "].operationId"));
        }
        assertEq(block.chainid, 84532);
        assertEq(safe.nonce(), 45);
        assertEq(registry.totalSeries(), 0);
        assertTrue(engine.paused());
        assertEq(engine.matchingEngine(), address(0));
        assertEq(engine.maxOpenContracts(), 0);
    }

    function signedByForkImpersonation(bytes memory data) internal returns (bool) {
        return signedByForkImpersonation(data, false);
    }

    function signedByForkImpersonation(bytes memory data, bool expectFailure) internal returns (bool) {
        uint256 nonce = safe.nonce();
        bytes32 hash = safe.getTransactionHash(MS, 0, data, 1, 0, 0, 0, address(0), address(0), nonce);
        address[] memory owners = safe.getOwners();
        require(owners.length == 3, "unexpected Safe owners");
        for (uint256 i; i < owners.length; ++i) {
            for (uint256 j = i + 1; j < owners.length; ++j) {
                if (owners[j] < owners[i]) (owners[i], owners[j]) = (owners[j], owners[i]);
            }
        }
        vm.prank(owners[0]);
        safe.approveHash(hash);
        vm.prank(owners[1]);
        safe.approveHash(hash);
        bytes memory sigs = bytes.concat(
            abi.encodePacked(bytes32(uint256(uint160(owners[0]))), bytes32(0), uint8(1)),
            abi.encodePacked(bytes32(uint256(uint160(owners[1]))), bytes32(0), uint8(1))
        );
        if (expectFailure) {
            vm.expectRevert();
            safe.execTransaction(MS, 0, data, 1, 0, 0, 0, address(0), address(0), sigs);
            return false;
        }
        uint256 safeGasBefore = gasleft();
        bool ok = safe.execTransaction(MS, 0, data, 1, 0, 0, 0, address(0), address(0), sigs);
        emit log_named_uint("V24 Safe execTransaction only gas", safeGasBefore - gasleft());
        return ok;
    }

    function queueAll() internal {
        uint256 gasBefore = gasleft();
        assertTrue(signedByForkImpersonation(queueData));
        emit log_named_uint("V24 Safe queue fork gas", gasBefore - gasleft());
        for (uint256 i; i < 4; ++i) {
            assertTrue(tl.queuedTransactions(ids[i]));
        }
        assertEq(safe.nonce(), 46);
    }

    function testQueueAndExecuteSafetyOnly() public {
        queueAll();
        vm.warp(eta - 1);
        string memory doc = vm.readFile("/tmp/deopt-options-v24-package.json");
        address firstTarget = vm.parseJsonAddress(doc, ".operations[0].target");
        bytes memory firstInner = vm.parseJsonBytes(doc, ".operations[0].innerCalldata");
        vm.expectRevert();
        vm.prank(SAFE);
        tl.executeTransaction(firstTarget, 0, firstInner, eta);
        assertEq(safe.nonce(), 46);
        vm.warp(eta);
        uint256 gasBefore = gasleft();
        assertTrue(signedByForkImpersonation(executeData));
        emit log_named_uint("V24 Safe execute fork gas", gasBefore - gasleft());
        assertEq(safe.nonce(), 47);
        for (uint256 i; i < 4; ++i) {
            assertFalse(tl.queuedTransactions(ids[i]));
        }
        assertTrue(matcher.paused());
        assertEq(matcher.guardian(), SAFE);
        assertEq(registry.guardian(), SAFE);
        assertTrue(registry.paused());
        vm.prank(SAFE);
        registry.setEmergencyModes(false, false, false);
        assertTrue(registry.paused());
        assertEq(registry.totalSeries(), 0);
        assertTrue(engine.paused());
        assertEq(engine.matchingEngine(), address(0));
        assertEq(engine.maxOpenContracts(), 0);
        assertEq(engine.totalLockedUnderlying(), 0);
        assertEq(OptionProductRegistry(OLD_REG).totalSeries(), 2);
        assertEq(IV24Token(MWETH).balanceOf(OLD_VAULT), 0);
        assertEq(IV24Token(MUSDC).balanceOf(OLD_VAULT), 224_066_000_000);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        registry.setGuardian(address(0xBEEF));
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        matcher.unpause();
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        registry.createSeries(MWETH, MUSDC, uint64(eta + 30 days), uint64(2100e8), true, true);
    }

    function testPartialFailureRevertsAndRecovery() public {
        queueAll();
        // Fork-only owner drift makes the third executeTransaction fail.
        vm.prank(TL);
        registry.transferOwnership(address(0xBEEF));
        vm.prank(address(0xBEEF));
        registry.acceptOwnership();
        vm.warp(eta);
        assertFalse(signedByForkImpersonation(executeData, true));
        // With zero Safe gas refund parameters, GS013 reverts the whole Safe tx.
        assertEq(safe.nonce(), 46);
        assertFalse(matcher.paused());
        assertEq(matcher.guardian(), address(0));
        assertEq(registry.guardian(), address(0));
        for (uint256 i; i < 4; ++i) {
            assertTrue(tl.queuedTransactions(ids[i]));
        }
        // Restore the expected owner only on this fork, then resume the same queued batch.
        vm.prank(address(0xBEEF));
        registry.transferOwnership(TL);
        vm.prank(TL);
        registry.acceptOwnership();
        assertTrue(signedByForkImpersonation(executeData));
        assertEq(safe.nonce(), 47);
        assertTrue(matcher.paused());
        assertTrue(registry.paused());
        assertEq(registry.totalSeries(), 0);
    }
}
