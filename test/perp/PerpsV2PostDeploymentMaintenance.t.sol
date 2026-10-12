// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";

/// @notice Fork-only maintenance rehearsal. Safe impersonation is local; no public transaction is sent.
contract PerpsV2PostDeploymentMaintenanceTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INSURANCE = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEARING = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant RUNTIME_EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant LOST_OWNER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    ProtocolTimelock timelock = ProtocolTimelock(payable(TIMELOCK));
    PerpEngineV2 engine = PerpEngineV2(D4);
    PerpMatchingEngineV2 pme = PerpMatchingEngineV2(D6);

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINTENANCE_RPC_URL"), vm.envUint("MAINTENANCE_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        assertEq(timelock.owner(), SAFE);
        assertTrue(timelock.proposers(SAFE));
        assertTrue(timelock.executors(SAFE));
        assertEq(timelock.minDelay(), 86400);
        assertEq(pme.owner(), TIMELOCK);
        assertEq(engine.owner(), TIMELOCK);
        assertFalse(pme.paused());
        assertFalse(engine.tradingPaused());
        assertFalse(engine.liquidationPaused());
        assertFalse(engine.fundingPaused());
        assertFalse(engine.collateralOpsPaused());
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertEq(uint256(engine.migrationState()), 0);
    }

    function _word(address target, bytes memory data) internal view returns (uint256) {
        (bool ok, bytes memory result) = target.staticcall(data);
        assertTrue(ok);
        return abi.decode(result, (uint256));
    }

    function _queue(address target, bytes memory data, uint256 eta) internal returns (bytes32) {
        vm.prank(SAFE);
        return timelock.queueTransaction(target, 0, data, eta);
    }

    function _execute(address target, bytes memory data, uint256 eta) internal {
        vm.prank(SAFE);
        timelock.executeTransaction(target, 0, data, eta);
    }

    function testM1ThenM2ThroughActualTimelockDelay() public {
        uint256 ledger = _word(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN));
        uint256 vaultTokenBalance = _word(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT));
        bytes32 pmrHash = D1.codehash;
        bytes32 snapshot = engine.migrationSnapshotHash();
        bytes memory m1 = abi.encodeWithSignature("pause()");
        uint256 eta1 = block.timestamp + timelock.minDelay();
        bytes32 id1 = _queue(D6, m1, eta1);
        assertTrue(timelock.queuedTransactions(id1));
        assertFalse(pme.paused());
        vm.warp(eta1);
        _execute(D6, m1, eta1);
        assertFalse(timelock.queuedTransactions(id1));
        assertTrue(pme.paused());
        assertFalse(engine.tradingPaused()); // Safe stopping point after M1.
        assertEq(uint256(engine.migrationState()), 0);

        bytes memory m2 = abi.encodeWithSignature("setEmergencyModes(bool,bool,bool,bool)", true, true, true, true);
        uint256 eta2 = block.timestamp + timelock.minDelay();
        bytes32 id2 = _queue(D4, m2, eta2);
        vm.warp(eta2);
        _execute(D4, m2, eta2);
        assertFalse(timelock.queuedTransactions(id2));
        assertTrue(pme.paused());
        assertTrue(engine.tradingPaused());
        assertTrue(engine.liquidationPaused());
        assertTrue(engine.fundingPaused());
        assertTrue(engine.collateralOpsPaused());
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertEq(uint256(engine.migrationState()), 0);
        assertEq(engine.migrationSnapshotHash(), snapshot);
        assertEq(D1.codehash, pmrHash);
        assertEq(_word(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN)), ledger);
        assertEq(_word(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT)), vaultTokenBalance);
        assertEq(_word(VAULT, abi.encodeWithSignature("isEngineAuthorized(address)", D4)), 0);
        assertEq(_word(INSURANCE, abi.encodeWithSignature("isBackstopCaller(address)", D4)), 0);
    }

    function testM1OnlySafeStopAndPrematureExecutionBlocked() public {
        bytes memory m1 = abi.encodeWithSignature("pause()");
        uint256 eta = block.timestamp + timelock.minDelay();
        _queue(D6, m1, eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        timelock.executeTransaction(D6, 0, m1, eta);
        assertFalse(pme.paused());
        vm.warp(eta);
        _execute(D6, m1, eta);
        assertTrue(pme.paused());
        assertFalse(engine.tradingPaused());
        assertEq(uint256(engine.migrationState()), 0);
    }

    function testUnauthorizedActorsCannotAdministerMaintenance() public {
        address[3] memory actors = [RUNTIME_EXECUTOR, DEPLOYER, LOST_OWNER];
        uint256 eta = block.timestamp + timelock.minDelay();
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            vm.expectRevert();
            pme.pause();
            vm.prank(actors[i]);
            vm.expectRevert();
            engine.setEmergencyModes(true, true, true, true);
            vm.prank(actors[i]);
            vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
            timelock.queueTransaction(D6, 0, abi.encodeWithSignature("pause()"), eta);
        }
    }

    function testBadTargetAndDuplicateOperationFail() public {
        bytes memory m1 = abi.encodeWithSignature("pause()");
        uint256 eta = block.timestamp + timelock.minDelay();
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.ZeroAddress.selector);
        timelock.queueTransaction(address(0), 0, m1, eta);
        _queue(D6, m1, eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionAlreadyQueued.selector);
        timelock.queueTransaction(D6, 0, m1, eta);
        vm.warp(eta);
        _execute(D6, m1, eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        timelock.executeTransaction(D6, 0, m1, eta);
    }

    function testWrongCalldataCannotMutateOtherState() public {
        bytes memory wrong = abi.encodeWithSignature("doesNotExist()");
        uint256 eta = block.timestamp + timelock.minDelay();
        _queue(D6, wrong, eta);
        vm.warp(eta);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D6, 0, wrong, eta);
        assertFalse(pme.paused());
        assertEq(engine.matchingEngine(), address(0));
        assertEq(uint256(engine.migrationState()), 0);
    }

    function testGuardianMayTightenButCannotRelaxFourFlags() public {
        PerpEngineV2 localEngine =
            new PerpEngineV2(address(this), D1, VAULT, 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581);
        address guardian = address(0xBEEF);
        localEngine.setGuardian(guardian);
        vm.prank(guardian);
        localEngine.setEmergencyModes(true, true, true, true);
        assertTrue(localEngine.tradingPaused());
        assertTrue(localEngine.liquidationPaused());
        assertTrue(localEngine.fundingPaused());
        assertTrue(localEngine.collateralOpsPaused());
        vm.prank(guardian);
        vm.expectRevert();
        localEngine.setEmergencyModes(false, true, true, true);
        assertTrue(localEngine.tradingPaused());
    }
}
