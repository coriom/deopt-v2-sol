// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface IC20Timelock {
    function minDelay() external view returns (uint256);
    function hashOperation(address, uint256, bytes calldata, uint256) external pure returns (bytes32);
    function queuedTransactions(bytes32) external view returns (bool);
    function queueTransaction(address, uint256, bytes calldata, uint256) external returns (bytes32);
    function executeTransaction(address, uint256, bytes calldata, uint256) external payable returns (bytes memory);
    function cancelTransaction(address, uint256, bytes calldata, uint256) external returns (bytes32);
}

interface IC20Risk {
    function maxOracleDelay() external view returns (uint256);
    function owner() external view returns (address);
    function guardian() external view returns (address);
    function perpEngine() external view returns (address);
    function collateralVault() external view returns (address);
    function oracle() external view returns (address);
    function baseCollateralToken() external view returns (address);
    function paused() external view returns (bool);
    function riskComputationPaused() external view returns (bool);
    function withdrawPreviewPaused() external view returns (bool);
    function setMaxOracleDelay(uint256) external;
}

interface IC20Engine {
    function tradingPaused() external view returns (bool);
    function liquidationPaused() external view returns (bool);
    function fundingPaused() external view returns (bool);
    function collateralOpsPaused() external view returns (bool);
    function migrationState() external view returns (uint8);
    function riskModule() external view returns (address);
    function matchingEngine() external view returns (address);
    function migrationSnapshotHash() external view returns (bytes32);
    function totalResidualBadDebtBase() external view returns (uint256);
}

interface IC20PME {
    function paused() external view returns (bool);
    function owner() external view returns (address);
    function perpEngine() external view returns (address);
    function domainSeparatorV4() external view returns (bytes32);
    function nonces(address) external view returns (uint256);
    function intentFilled(bytes32) external view returns (uint256);
    function isExecutor(address) external view returns (bool);
}

interface IC20Vault {
    function balances(address, address) external view returns (uint256);
    function isAuthorizedEngine(address) external view returns (bool);
}

interface IC20Insurance {
    function isBackstopCaller(address) external view returns (bool);
}

interface IC20Token {
    function balanceOf(address) external view returns (uint256);
}

contract PerpsV2C20OracleDelayPreparationForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INSURANCE = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEARING = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant RUNTIME = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    uint256 constant FORK_BLOCK = 48354014;
    uint256 constant PROPOSED_ETA = 1792810800;
    bytes32 constant PROPOSED_ID = 0x9f2f5b40839a71031bf95e2ea3eda634360351e851fa83fa2f6045ba00084317;

    IC20Timelock timelock = IC20Timelock(TL);
    IC20Risk risk = IC20Risk(D5);
    IC20Engine engine = IC20Engine(D4);
    IC20PME pme = IC20PME(D6);
    IC20Vault vault = IC20Vault(VAULT);
    bytes c20 = abi.encodeWithSignature("setMaxOracleDelay(uint256)", 600);
    uint256 eta;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), FORK_BLOCK);
        eta = PROPOSED_ETA;
        assertGt(eta, block.timestamp + timelock.minDelay() + 1 hours);
        assertEq(risk.maxOracleDelay(), 0);
        assertEq(risk.owner(), TL);
        assertEq(risk.guardian(), address(0));
        assertEq(risk.perpEngine(), D4);
        assertTrue(
            engine.tradingPaused() && engine.liquidationPaused() && engine.fundingPaused()
                && engine.collateralOpsPaused()
        );
        assertTrue(pme.paused());
    }

    function testC20ScheduleExecuteAndBoundedNonDrift() public {
        uint256 clearingBefore = vault.balances(CLEARING, TOKEN);
        uint256 insuranceBefore = vault.balances(INSURANCE, TOKEN);
        uint256 tokenBefore = IC20Token(TOKEN).balanceOf(VAULT);
        bytes32 d1Before = _readHash(D1, abi.encodeWithSignature("totalMarkets()"));
        bytes32 d2Before = _readHash(D2, abi.encodeWithSignature("merkleRoot()"));
        bytes32 d3Before = _readHash(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN));
        bytes32 domainBefore = pme.domainSeparatorV4();
        address oracleBefore = risk.oracle();
        address vaultBefore = risk.collateralVault();
        address baseBefore = risk.baseCollateralToken();
        bool riskPausedBefore = risk.paused();
        bool computationPausedBefore = risk.riskComputationPaused();
        bool previewPausedBefore = risk.withdrawPreviewPaused();
        uint256 nonceBefore = pme.nonces(address(0x1234));
        uint256 fillBefore = pme.intentFilled(bytes32(0));
        bool runtimeBefore = pme.isExecutor(RUNTIME);
        bool timelockExecutorBefore = pme.isExecutor(TL);
        bytes32 op = timelock.hashOperation(D5, 0, c20, eta);
        assertEq(op, keccak256(abi.encode(D5, uint256(0), c20, eta)));
        assertEq(op, PROPOSED_ID);
        vm.prank(SAFE);
        assertEq(timelock.queueTransaction(D5, 0, c20, eta), op);
        assertTrue(timelock.queuedTransactions(op));
        assertEq(risk.maxOracleDelay(), 0);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, c20, eta);
        assertTrue(timelock.queuedTransactions(op));
        vm.warp(eta);
        vm.recordLogs();
        vm.prank(SAFE);
        timelock.executeTransaction(D5, 0, c20, eta);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool setterEvent;
        bool executeEvent;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == D5 && logs[i].topics[0] == keccak256("MaxOracleDelaySet(uint256,uint256)")) {
                (uint256 oldDelay, uint256 newDelay) = abi.decode(logs[i].data, (uint256, uint256));
                setterEvent = oldDelay == 0 && newDelay == 600;
            }
            if (
                logs[i].emitter == TL
                    && logs[i].topics[0]
                        == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
            ) {
                executeEvent = logs[i].topics[1] == op;
            }
        }
        assertTrue(setterEvent && executeEvent);
        assertFalse(timelock.queuedTransactions(op));
        assertEq(risk.maxOracleDelay(), 600);
        assertEq(risk.owner(), TL);
        assertEq(risk.guardian(), address(0));
        assertEq(risk.perpEngine(), D4);
        assertEq(risk.oracle(), oracleBefore);
        assertEq(risk.collateralVault(), vaultBefore);
        assertEq(risk.baseCollateralToken(), baseBefore);
        assertEq(risk.paused(), riskPausedBefore);
        assertEq(risk.riskComputationPaused(), computationPausedBefore);
        assertEq(risk.withdrawPreviewPaused(), previewPausedBefore);
        assertTrue(
            engine.tradingPaused() && engine.liquidationPaused() && engine.fundingPaused()
                && engine.collateralOpsPaused()
        );
        assertEq(engine.migrationState(), 0);
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertEq(engine.migrationSnapshotHash(), bytes32(0));
        assertEq(engine.totalResidualBadDebtBase(), 0);
        assertTrue(pme.paused());
        assertEq(pme.owner(), TL);
        assertEq(pme.perpEngine(), D4);
        assertEq(pme.domainSeparatorV4(), domainBefore);
        assertEq(pme.nonces(address(0x1234)), nonceBefore);
        assertEq(pme.intentFilled(bytes32(0)), fillBefore);
        assertEq(pme.isExecutor(RUNTIME), runtimeBefore);
        assertEq(pme.isExecutor(TL), timelockExecutorBefore);
        assertEq(vault.balances(CLEARING, TOKEN), clearingBefore);
        assertEq(vault.balances(INSURANCE, TOKEN), insuranceBefore);
        assertEq(IC20Token(TOKEN).balanceOf(VAULT), tokenBefore);
        assertEq(_readHash(D1, abi.encodeWithSignature("totalMarkets()")), d1Before);
        assertEq(_readHash(D2, abi.encodeWithSignature("merkleRoot()")), d2Before);
        assertEq(_readHash(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN)), d3Before);
        assertFalse(vault.isAuthorizedEngine(D4));
        assertFalse(IC20Insurance(INSURANCE).isBackstopCaller(D4));
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, c20, eta);
    }

    function testC20NegativeAuthoritiesPayloadEtaAndCancellation() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        risk.setMaxOracleDelay(600);
        vm.prank(RUNTIME);
        vm.expectRevert();
        risk.setMaxOracleDelay(600);
        vm.prank(address(0x1234));
        vm.expectRevert();
        timelock.queueTransaction(D5, 0, c20, eta);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, c20, eta);
        uint256 tooSoon = block.timestamp + timelock.minDelay() - 1;
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.queueTransaction(D5, 0, c20, tooSoon);
        bytes32 op = timelock.hashOperation(D5, 0, c20, eta);
        vm.prank(SAFE);
        timelock.queueTransaction(D5, 0, c20, eta);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.queueTransaction(D5, 0, c20, eta);
        vm.warp(eta);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D4, 0, c20, eta);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, abi.encodeWithSignature("setMaxOracleDelay(uint256)", 601), eta);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, c20, eta + 1);
        vm.prank(address(0x1234));
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, c20, eta);
        vm.prank(SAFE);
        timelock.cancelTransaction(D5, 0, c20, eta);
        assertFalse(timelock.queuedTransactions(op));
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, c20, eta);
        assertEq(risk.maxOracleDelay(), 0);
    }

    function _readHash(address target, bytes memory data) private view returns (bytes32) {
        (bool ok, bytes memory result) = target.staticcall(data);
        require(ok, "bounded readback unavailable");
        return keccak256(result);
    }
}
