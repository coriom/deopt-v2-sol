// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface IC01Timelock {
    function minDelay() external view returns (uint256);
    function hashOperation(address, uint256, bytes calldata, uint256) external pure returns (bytes32);
    function queuedTransactions(bytes32) external view returns (bool);
    function queueTransaction(address, uint256, bytes calldata, uint256) external returns (bytes32);
    function executeTransaction(address, uint256, bytes calldata, uint256) external payable returns (bytes memory);
}

interface IC01Registry {
    function owner() external view returns (address);
    function totalMarkets() external view returns (uint256);
    function nextMarketId() external view returns (uint256);
    function isSettlementAssetAllowed(address) external view returns (bool);
    function isMarketCreator(address) external view returns (bool);
    function setSettlementAssetAllowed(address, bool) external;
}

interface IC01Engine {
    function tradingPaused() external view returns (bool);
    function liquidationPaused() external view returns (bool);
    function fundingPaused() external view returns (bool);
    function collateralOpsPaused() external view returns (bool);
    function migrationState() external view returns (uint8);
    function riskModule() external view returns (address);
    function matchingEngine() external view returns (address);
}

interface IC01Vault {
    function balances(address, address) external view returns (uint256);
    function isAuthorizedEngine(address) external view returns (bool);
}

interface IC01Insurance {
    function isBackstopCaller(address) external view returns (bool);
}

interface IC01Token {
    function balanceOf(address) external view returns (uint256);
}

contract PerpsV2C01MarketProtectionFastForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INSURANCE = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEARING = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    uint256 constant FORK_BLOCK = 48642380;
    uint256 constant ETA = 1792756800;
    bytes32 constant C01_ID = 0x589fb819f60769c77ad9090750f2173377eb45dcbb5367fbc0fb978e4e15d396;
    bytes32 constant C12_ID = 0xd15ec63a22daebd4eb015de23561089547af9b02945fb8ae6dd7028ae7581229;

    IC01Timelock timelock = IC01Timelock(TL);
    IC01Registry registry = IC01Registry(D1);
    IC01Engine engine = IC01Engine(D4);
    IC01Vault vault = IC01Vault(VAULT);
    bytes inner = abi.encodeWithSignature("setSettlementAssetAllowed(address,bool)", TOKEN, true);

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), FORK_BLOCK);
        assertEq(block.chainid, 84532);
        assertEq(registry.owner(), TL);
        assertEq(registry.totalMarkets(), 0);
        assertEq(registry.nextMarketId(), 1);
        assertFalse(registry.isSettlementAssetAllowed(TOKEN));
        assertTrue(registry.isMarketCreator(TL));
        assertEq(timelock.minDelay(), 86400);
        assertTrue(timelock.queuedTransactions(C12_ID));
        assertFalse(timelock.queuedTransactions(C01_ID));
        assertEq(timelock.hashOperation(D1, 0, inner, ETA), C01_ID);
        assertGe(ETA, block.timestamp + timelock.minDelay() + 3600);
        _assertMaintenance();
    }

    function testC01QueuedThenExecutedPreservesIsolationAndC12() public {
        uint256 clearingBefore = vault.balances(CLEARING, TOKEN);
        uint256 insuranceBefore = vault.balances(INSURANCE, TOKEN);
        uint256 vaultBalanceBefore = IC01Token(TOKEN).balanceOf(VAULT);

        vm.recordLogs();
        vm.prank(SAFE);
        assertEq(timelock.queueTransaction(D1, 0, inner, ETA), C01_ID);
        Vm.Log[] memory queueLogs = vm.getRecordedLogs();
        assertEq(queueLogs.length, 1);
        assertEq(queueLogs[0].emitter, TL);
        assertEq(queueLogs[0].topics[1], C01_ID);
        assertTrue(timelock.queuedTransactions(C01_ID));
        assertTrue(timelock.queuedTransactions(C12_ID));
        assertFalse(registry.isSettlementAssetAllowed(TOKEN));

        vm.warp(ETA - 1);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D1, 0, inner, ETA);
        assertTrue(timelock.queuedTransactions(C01_ID));
        vm.warp(ETA);
        vm.recordLogs();
        vm.prank(SAFE);
        timelock.executeTransaction(D1, 0, inner, ETA);
        Vm.Log[] memory executeLogs = vm.getRecordedLogs();
        bool foundD1Event;
        for (uint256 i; i < executeLogs.length; ++i) {
            if (
                executeLogs[i].emitter == D1
                    && executeLogs[i].topics[0] == keccak256("SettlementAssetConfigured(address,bool)")
            ) {
                assertEq(executeLogs[i].topics[1], bytes32(uint256(uint160(TOKEN))));
                assertEq(abi.decode(executeLogs[i].data, (bool)), true);
                foundD1Event = true;
            }
        }
        assertTrue(foundD1Event);
        assertTrue(registry.isSettlementAssetAllowed(TOKEN));
        assertEq(registry.totalMarkets(), 0);
        assertEq(registry.nextMarketId(), 1);
        assertTrue(timelock.queuedTransactions(C12_ID));
        assertFalse(timelock.queuedTransactions(C01_ID));
        _assertMaintenance();
        assertEq(vault.balances(CLEARING, TOKEN), clearingBefore);
        assertEq(vault.balances(INSURANCE, TOKEN), insuranceBefore);
        assertEq(IC01Token(TOKEN).balanceOf(VAULT), vaultBalanceBefore);
        assertFalse(vault.isAuthorizedEngine(D4));
        assertFalse(IC01Insurance(INSURANCE).isBackstopCaller(D4));
    }

    function testWrongCallerDelayIdentityAndReplayRejected() public {
        vm.prank(address(0x1234));
        vm.expectRevert();
        registry.setSettlementAssetAllowed(TOKEN, true);
        vm.prank(address(0x1234));
        vm.expectRevert();
        timelock.queueTransaction(D1, 0, inner, ETA);
        uint256 tooSoon = block.timestamp + timelock.minDelay() - 1;
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.queueTransaction(D1, 0, inner, tooSoon);

        vm.prank(SAFE);
        timelock.queueTransaction(D1, 0, inner, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.queueTransaction(D1, 0, inner, ETA);
        vm.warp(ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(
            D1, 0, abi.encodeWithSignature("setSettlementAssetAllowed(address,bool)", TOKEN, false), ETA
        );
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D1, 0, inner, ETA + 1);
        vm.prank(address(0x1234));
        vm.expectRevert();
        timelock.executeTransaction(D1, 0, inner, ETA);
        assertTrue(timelock.queuedTransactions(C01_ID));
        vm.prank(SAFE);
        timelock.executeTransaction(D1, 0, inner, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        timelock.executeTransaction(D1, 0, inner, ETA);
        assertTrue(timelock.queuedTransactions(C12_ID));
        _assertMaintenance();
    }

    function testNoNewMarketOrAccessibleEconomicRouteAfterC01() public {
        vm.prank(SAFE);
        timelock.queueTransaction(D1, 0, inner, ETA);
        vm.warp(ETA);
        vm.prank(SAFE);
        timelock.executeTransaction(D1, 0, inner, ETA);

        assertEq(registry.totalMarkets(), 0);
        assertEq(registry.nextMarketId(), 1);
        (bool marketOk,) = D1.staticcall(abi.encodeWithSignature("getMarket(uint256)", 1));
        assertFalse(marketOk);
        assertTrue(_readBool(D6, "paused()"));
        assertTrue(engine.tradingPaused());
        assertEq(engine.migrationState(), 0);
        assertEq(engine.matchingEngine(), address(0));
        assertFalse(vault.isAuthorizedEngine(D4));
        assertFalse(IC01Insurance(INSURANCE).isBackstopCaller(D4));
        assertTrue(timelock.queuedTransactions(C12_ID));
    }

    function _assertMaintenance() private view {
        assertTrue(engine.tradingPaused());
        assertTrue(engine.liquidationPaused());
        assertTrue(engine.fundingPaused());
        assertTrue(engine.collateralOpsPaused());
        assertEq(engine.migrationState(), 0);
        assertEq(engine.riskModule(), address(0));
        assertEq(engine.matchingEngine(), address(0));
        assertTrue(_readBool(D6, "paused()"));
    }

    function _readBool(address target, string memory signature) private view returns (bool) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        require(ok, "readback failed");
        return abi.decode(data, (bool));
    }
}
