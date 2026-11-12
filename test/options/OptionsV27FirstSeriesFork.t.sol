// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {OptionProductRegistry} from "../../src/OptionProductRegistry.sol";
import {OptionMatchingEngine} from "../../src/matching/OptionMatchingEngine.sol";
import {CoveredCallMarginEngine} from "../../src/experimental/CoveredCallMarginEngine.sol";

interface IV27Safe {
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

interface IV27Timelock {
    function minDelay() external view returns (uint256);
    function queuedTransactions(bytes32) external view returns (bool);
    function queueTransaction(address, uint256, bytes calldata, uint256) external returns (bytes32);
    function executeTransaction(address, uint256, bytes calldata, uint256) external payable returns (bytes memory);
}

interface IV27Token {
    function balanceOf(address) external view returns (uint256);
}

contract OptionsV27FirstSeriesFork is Test {
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
    address constant ORACLE = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    uint64 constant EXPIRY = 1795780800; // candidate: 2026-11-27 12:00 UTC
    uint64 constant STRIKE = 2100e8; // candidate only, not a new approval

    IV27Safe safe = IV27Safe(SAFE);
    IV27Timelock tl = IV27Timelock(TL);
    OptionProductRegistry registry = OptionProductRegistry(REG);
    CoveredCallMarginEngine engine = CoveredCallMarginEngine(ENG);
    OptionMatchingEngine matcher = OptionMatchingEngine(MAT);
    uint256 optionId;
    uint256 eta;
    bytes[5] inner;
    bytes32[5] ids;

    function setUp() public {
        vm.createSelectFork(vm.envString("OPTIONS_V27_FORK_RPC"), 57_692_769);
        assertEq(block.chainid, 84532);
        assertEq(safe.nonce(), 46);
        assertEq(registry.totalSeries(), 0);
        assertTrue(engine.paused());
        assertEq(engine.maxOpenContracts(), 0);
        assertEq(engine.matchingEngine(), address(0));
        optionId = registry.computeOptionId(MWETH, MUSDC, EXPIRY, STRIKE, 1e8, true, true);
    }

    function _multiSendItem(address target, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), target, uint256(0), uint256(data.length), data);
    }

    function _safeCall(bytes memory data) internal returns (bool) {
        bytes32 hash = safe.getTransactionHash(MS, 0, data, 1, 0, 0, 0, address(0), address(0), safe.nonce());
        address[] memory owners = safe.getOwners();
        for (uint256 i; i < owners.length; ++i) {
            for (uint256 j = i + 1; j < owners.length; ++j) {
                if (owners[j] < owners[i]) (owners[i], owners[j]) = (owners[j], owners[i]);
            }
        }
        vm.prank(owners[0]);
        safe.approveHash(hash);
        vm.prank(owners[1]);
        safe.approveHash(hash);
        bytes memory signatures = bytes.concat(
            abi.encodePacked(bytes32(uint256(uint160(owners[0]))), bytes32(0), uint8(1)),
            abi.encodePacked(bytes32(uint256(uint160(owners[1]))), bytes32(0), uint8(1))
        );
        return safe.execTransaction(MS, 0, data, 1, 0, 0, 0, address(0), address(0), signatures);
    }

    function _executeV24Protections() internal {
        string memory doc = vm.readFile("/tmp/deopt-options-v24-package.json");
        uint256 v24Eta = vm.parseJsonUint(doc, ".operations[0].eta");
        vm.warp(v24Eta);
        bytes memory actions = vm.parseJsonBytes(doc, ".executeSafeActionConditional.data");
        assertTrue(_safeCall(actions)); // Fork-only Safe owner impersonation, never authentic signatures.
        assertTrue(registry.paused());
        assertTrue(matcher.paused());
        assertEq(registry.guardian(), SAFE);
        assertEq(matcher.guardian(), SAFE);
    }

    function _queueCandidate(bool wrongDeactivateId) internal {
        OptionProductRegistry.UnderlyingConfig memory cfg = OptionProductRegistry.UnderlyingConfig({
            oracle: ORACLE,
            spotShockDownBps: 0,
            spotShockUpBps: 0,
            volShockDownBps: 0,
            volShockUpBps: 0,
            isEnabled: true
        });
        inner[0] = abi.encodeCall(registry.unpause, ());
        inner[1] = abi.encodeCall(registry.setUnderlyingConfig, (MWETH, cfg));
        inner[2] = abi.encodeCall(registry.setSettlementAssetAllowed, (MUSDC, true));
        inner[3] = abi.encodeWithSignature(
            "createSeries(address,address,uint64,uint64,bool,bool)", MWETH, MUSDC, EXPIRY, STRIKE, true, true
        );
        inner[4] = abi.encodeCall(registry.setSeriesActive, (wrongDeactivateId ? optionId + 1 : optionId, false));
        string memory doc = vm.readFile("/tmp/deopt-options-v27-package.json");
        eta = vm.parseJsonUint(doc, ".eta");
        assertGe(eta, block.timestamp + tl.minDelay());
        assertLt(eta, EXPIRY);
        bytes memory calls;
        for (uint256 i; i < inner.length; ++i) {
            bytes memory queueCall = abi.encodeCall(tl.queueTransaction, (REG, 0, inner[i], eta));
            calls = bytes.concat(calls, _multiSendItem(TL, queueCall));
            ids[i] = keccak256(abi.encode(REG, uint256(0), inner[i], eta));
            if (!wrongDeactivateId) {
                assertEq(
                    ids[i], vm.parseJsonBytes32(doc, string.concat(".operations[", vm.toString(i), "].operationId"))
                );
                assertEq(
                    queueCall, vm.parseJsonBytes(doc, string.concat(".operations[", vm.toString(i), "].queueCalldata"))
                );
            }
        }
        bytes memory safeData = abi.encodeWithSignature("multiSend(bytes)", calls);
        if (!wrongDeactivateId) assertEq(safeData, vm.parseJsonBytes(doc, ".queueSafeAction.data"));
        uint256 gasBefore = gasleft();
        assertTrue(_safeCall(safeData)); // Fork-only Safe owner impersonation.
        emit log_named_uint("V27 Safe queue gas", gasBefore - gasleft());
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(tl.queuedTransactions(ids[i]));
        }
    }

    function _executeCandidate() internal returns (bool) {
        bytes memory calls;
        for (uint256 i; i < inner.length; ++i) {
            calls =
                bytes.concat(calls, _multiSendItem(TL, abi.encodeCall(tl.executeTransaction, (REG, 0, inner[i], eta))));
        }
        calls = bytes.concat(calls, _multiSendItem(REG, abi.encodeCall(registry.pause, ())));
        bytes memory safeData = abi.encodeWithSignature("multiSend(bytes)", calls);
        if (keccak256(inner[4]) == keccak256(abi.encodeCall(registry.setSeriesActive, (optionId, false)))) {
            string memory doc = vm.readFile("/tmp/deopt-options-v27-package.json");
            assertEq(safeData, vm.parseJsonBytes(doc, ".executeSafeActionConditional.data"));
        }
        return _safeCall(safeData);
    }

    function executeCandidateExternal() external returns (bool) {
        return _executeCandidate();
    }

    function testCandidateAtomicCreateInactiveAndLegacyIsolation() public {
        uint256 oldUsdc = IV27Token(MUSDC).balanceOf(OLD_VAULT);
        uint256 oldWeth = IV27Token(MWETH).balanceOf(OLD_VAULT);
        uint256 oldSeries = OptionProductRegistry(OLD_REG).totalSeries();
        _executeV24Protections();
        vm.startPrank(TL);
        vm.expectRevert();
        registry.createSeries(MWETH, MUSDC, EXPIRY, STRIKE, true, true);
        vm.stopPrank();
        vm.startPrank(address(0xBEEF));
        vm.expectRevert();
        matcher.unpause();
        vm.expectRevert();
        engine.setPaused(false);
        vm.stopPrank();
        _queueCandidate(false);
        vm.warp(eta);
        uint256 gasBefore = gasleft();
        assertTrue(_executeCandidate());
        emit log_named_uint("V27 Safe atomic execution gas", gasBefore - gasleft());
        OptionProductRegistry.OptionSeries memory series = registry.getSeries(optionId);
        (bool readOk, bytes memory seriesOutput) =
            REG.staticcall(abi.encodeWithSignature("getSeries(uint256)", optionId));
        assertTrue(readOk);
        assertEq(seriesOutput.length, 9 * 32);
        (bool idsOk, bytes memory idsOutput) = REG.staticcall(abi.encodeWithSignature("getAllOptionIds()"));
        assertTrue(idsOk);
        assertEq(idsOutput.length, 3 * 32);
        assertTrue(series.exists);
        assertFalse(series.isActive);
        assertTrue(registry.paused());
        assertTrue(matcher.paused());
        assertTrue(engine.paused());
        assertEq(engine.maxOpenContracts(), 0);
        assertEq(engine.matchingEngine(), address(0));
        assertEq(registry.totalSeries(), 1);
        for (uint256 i; i < ids.length; ++i) {
            assertFalse(tl.queuedTransactions(ids[i]));
        }
        assertEq(OptionProductRegistry(OLD_REG).totalSeries(), oldSeries);
        assertEq(IV27Token(MUSDC).balanceOf(OLD_VAULT), oldUsdc);
        assertEq(IV27Token(MWETH).balanceOf(OLD_VAULT), oldWeth);
    }

    function testDeactivateFailureRollsBackEntireSafeTransaction() public {
        _executeV24Protections();
        _queueCandidate(true);
        vm.warp(eta);
        uint256 nonceBefore = safe.nonce();
        vm.expectRevert(bytes("GS013"));
        this.executeCandidateExternal();
        assertEq(safe.nonce(), nonceBefore);
        assertTrue(registry.paused());
        assertEq(registry.totalSeries(), 0);
        for (uint256 i; i < ids.length; ++i) {
            assertTrue(tl.queuedTransactions(ids[i]));
        }
    }
}
