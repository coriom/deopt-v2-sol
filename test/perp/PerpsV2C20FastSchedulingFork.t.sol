// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface IFastC20Timelock {
    function minDelay() external view returns (uint256);
    function hashOperation(address, uint256, bytes calldata, uint256) external pure returns (bytes32);
    function queuedTransactions(bytes32) external view returns (bool);
    function queueTransaction(address, uint256, bytes calldata, uint256) external returns (bytes32);
    function executeTransaction(address, uint256, bytes calldata, uint256) external payable returns (bytes memory);
}

interface IFastC20Risk {
    function maxOracleDelay() external view returns (uint256);
    function owner() external view returns (address);
    function perpEngine() external view returns (address);
}

interface IFastC20Engine {
    function tradingPaused() external view returns (bool);
    function liquidationPaused() external view returns (bool);
    function fundingPaused() external view returns (bool);
    function collateralOpsPaused() external view returns (bool);
    function migrationState() external view returns (uint8);
    function riskModule() external view returns (address);
    function matchingEngine() external view returns (address);
}

interface IFastC20PME {
    function paused() external view returns (bool);
    function isExecutor(address) external view returns (bool);
}

interface IFastC20Vault {
    function balances(address, address) external view returns (uint256);
    function isAuthorizedEngine(address) external view returns (bool);
}

interface IFastC20Token {
    function balanceOf(address) external view returns (uint256);
}

contract PerpsV2C20FastSchedulingForkTest is Test {
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
    uint256 constant FORK_BLOCK = 48355121;
    uint256 constant ETA = 1792584000;
    bytes32 constant OP = 0xad2000557d6dfd7a9adec3d2ba7e66c27386191195c78bd1090f40f8bd7ebc0a;

    IFastC20Timelock timelock = IFastC20Timelock(TL);
    IFastC20Risk risk = IFastC20Risk(D5);
    IFastC20Engine engine = IFastC20Engine(D4);
    IFastC20PME pme = IFastC20PME(D6);
    IFastC20Vault vault = IFastC20Vault(VAULT);
    bytes c20 = abi.encodeWithSignature("setMaxOracleDelay(uint256)", 600);

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), FORK_BLOCK);
        assertEq(timelock.minDelay(), 86400);
        assertGe(ETA, block.timestamp + timelock.minDelay() + 3600);
        assertEq(risk.maxOracleDelay(), 0);
        assertEq(risk.owner(), TL);
        assertEq(risk.perpEngine(), D4);
        assertTrue(pme.paused());
        assertTrue(
            engine.tradingPaused() && engine.liquidationPaused() && engine.fundingPaused()
                && engine.collateralOpsPaused()
        );
        assertEq(engine.migrationState(), 0);
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertFalse(timelock.queuedTransactions(OP));
    }

    function testExactAcceleratedQueueEventAndNoEconomicDrift() public {
        uint256 clearingBefore = vault.balances(CLEARING, TOKEN);
        uint256 insuranceBefore = vault.balances(INSURANCE, TOKEN);
        uint256 vaultTokenBefore = IFastC20Token(TOKEN).balanceOf(VAULT);
        bytes32 marketBefore = _readHash(D1, abi.encodeWithSignature("totalMarkets()"));
        bytes32 feesBefore = _readHash(D2, abi.encodeWithSignature("merkleRoot()"));
        bytes32 seizerBefore = _readHash(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN));
        bool executorBefore = pme.isExecutor(RUNTIME);
        bool bootstrapBefore = pme.isExecutor(TL);
        assertEq(OP, timelock.hashOperation(D5, 0, c20, ETA));
        vm.recordLogs();
        vm.prank(SAFE);
        assertEq(timelock.queueTransaction(D5, 0, c20, ETA), OP);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, TL);
        assertEq(logs[0].topics[0], keccak256("TransactionQueued(bytes32,address,uint256,bytes,uint256)"));
        assertEq(logs[0].topics[1], OP);
        assertEq(uint256(logs[0].topics[2]), uint256(uint160(D5)));
        (uint256 value, bytes memory data, uint256 eta) = abi.decode(logs[0].data, (uint256, bytes, uint256));
        assertEq(value, 0);
        assertEq(data, c20);
        assertEq(eta, ETA);
        assertTrue(timelock.queuedTransactions(OP));
        assertEq(risk.maxOracleDelay(), 0);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, c20, ETA);
        assertTrue(timelock.queuedTransactions(OP));
        assertEq(risk.maxOracleDelay(), 0);
        assertTrue(
            engine.tradingPaused() && engine.liquidationPaused() && engine.fundingPaused()
                && engine.collateralOpsPaused()
        );
        assertEq(engine.migrationState(), 0);
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertTrue(pme.paused());
        assertEq(pme.isExecutor(RUNTIME), executorBefore);
        assertEq(pme.isExecutor(TL), bootstrapBefore);
        assertEq(vault.balances(CLEARING, TOKEN), clearingBefore);
        assertEq(vault.balances(INSURANCE, TOKEN), insuranceBefore);
        assertEq(IFastC20Token(TOKEN).balanceOf(VAULT), vaultTokenBefore);
        assertEq(_readHash(D1, abi.encodeWithSignature("totalMarkets()")), marketBefore);
        assertEq(_readHash(D2, abi.encodeWithSignature("merkleRoot()")), feesBefore);
        assertEq(_readHash(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN)), seizerBefore);
        assertFalse(vault.isAuthorizedEngine(D4));
    }

    function testWrongActorPayloadEtaAndDuplicateRejected() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        timelock.queueTransaction(D5, 0, c20, ETA);
        vm.prank(SAFE);
        timelock.queueTransaction(D5, 0, c20, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.queueTransaction(D5, 0, c20, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D4, 0, c20, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, abi.encodeWithSignature("setMaxOracleDelay(uint256)", 601), ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D5, 0, c20, ETA + 1);
        assertTrue(timelock.queuedTransactions(OP));
        assertEq(risk.maxOracleDelay(), 0);
    }

    function _readHash(address target, bytes memory data) private view returns (bytes32) {
        (bool ok, bytes memory result) = target.staticcall(data);
        require(ok, "bounded readback unavailable");
        return keccak256(result);
    }
}
