// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {PerpEngineV2} from "../../src/perp/PerpEngineV2.sol";
import {PerpEngineTradingV2} from "../../src/perp/PerpEngineTradingV2.sol";
import {PerpRiskModule} from "../../src/perp/PerpRiskModule.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";
import {IPerpEngineTrade} from "../../src/matching/IPerpEngineTrade.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {InsuranceFund} from "../../src/core/InsuranceFund.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";

/// @notice Fork-only C12 rehearsal. SAFE pranks do not prove real 2/3 signatures.
contract PerpsV2C12FastTrackForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INS = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEAR = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant TRADER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;

    ProtocolTimelock tl = ProtocolTimelock(payable(TL));
    PerpEngineV2 d4 = PerpEngineV2(D4);
    PerpRiskModule d5 = PerpRiskModule(D5);
    PerpMatchingEngineV2 d6 = PerpMatchingEngineV2(D6);
    bytes inner;
    uint256 eta;
    bytes32 op;

    function setUp() public {
        vm.createSelectFork(vm.envString("C12_RPC_URL"), vm.envUint("C12_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        assertEq(d5.maxOracleDelay(), 600);
        assertEq(d4.riskModule(), address(0));
        assertEq(address(d5.perpEngine()), D4);
        assertTrue(tl.proposers(SAFE));
        assertTrue(tl.executors(SAFE));
        assertEq(tl.minDelay(), 86400);
        assertTrue(d6.paused());
        _closed();
        assertFalse(CollateralVault(VAULT).isAuthorizedEngine(D4));
        assertFalse(InsuranceFund(INS).isBackstopCaller(D4));
        inner = abi.encodeCall(d4.setRiskModule, (D5));
        eta = block.timestamp + tl.minDelay() + 7200;
        op = keccak256(abi.encode(D4, uint256(0), inner, eta));
        assertEq(tl.hashOperation(D4, 0, inner, eta), op);
        assertFalse(tl.queuedTransactions(op));
    }

    function _closed() internal view {
        assertTrue(d4.tradingPaused() && d4.liquidationPaused() && d4.fundingPaused() && d4.collateralOpsPaused());
        assertEq(uint256(d4.migrationState()), 0);
        assertEq(d4.migrationSnapshotHash(), bytes32(0));
        assertEq(d4.matchingEngine(), address(0));
    }

    function _queue() internal {
        vm.prank(SAFE); // Safe-address impersonation only on isolated fork.
        assertEq(tl.queueTransaction(D4, 0, inner, eta), op);
    }

    function _execute() internal {
        vm.prank(SAFE);
        tl.executeTransaction(D4, 0, inner, eta);
    }

    function _position() internal view returns (bytes32) {
        (bool ok, bytes memory data) = D4.staticcall(abi.encodeWithSignature("positions(address,uint256)", TRADER, 1));
        assertTrue(ok);
        return keccak256(data);
    }

    function _readHash(address target, bytes memory data) internal view returns (bytes32) {
        (bool ok, bytes memory result) = target.staticcall(data);
        assertTrue(ok);
        return keccak256(result);
    }

    function _sharedDigest() internal view returns (bytes32 h) {
        h = keccak256(abi.encode(h, _readHash(D1, abi.encodeWithSignature("totalMarkets()"))));
        h = keccak256(abi.encode(h, _readHash(D2, abi.encodeWithSignature("merkleRoot()"))));
        h = keccak256(abi.encode(h, _readHash(D2, abi.encodeWithSignature("rebateBudget(address)", TOKEN))));
        h = keccak256(abi.encode(h, _readHash(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN))));
        h = keccak256(abi.encode(h, _readHash(D5, abi.encodeWithSignature("oracle()"))));
        h = keccak256(abi.encode(h, _readHash(D5, abi.encodeWithSignature("riskComputationPaused()"))));
        h = keccak256(abi.encode(h, _readHash(D5, abi.encodeWithSignature("withdrawPreviewPaused()"))));
        h = keccak256(abi.encode(h, _readHash(D6, abi.encodeWithSignature("isExecutor(address)", TL))));
        h = keccak256(abi.encode(h, _readHash(D6, abi.encodeWithSignature("intentFilled(bytes32)", bytes32(0)))));
        h = keccak256(
            abi.encode(h, _readHash(VAULT, abi.encodeWithSignature("balances(address,address)", CLEAR, TOKEN)))
        );
        h = keccak256(abi.encode(h, _readHash(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT))));
        h = keccak256(abi.encode(h, _readHash(TOKEN, abi.encodeWithSignature("balanceOf(address)", INS))));
    }

    function testSelectorAndQueueOnly() public {
        assertEq(bytes4(inner), bytes4(0x04f6f5b2));
        assertEq(inner.length, 36);
        _queue();
        assertTrue(tl.queuedTransactions(op));
        assertEq(d4.riskModule(), address(0));
        _closed();
        assertTrue(d6.paused());
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionAlreadyQueued.selector);
        tl.queueTransaction(D4, 0, inner, eta);
    }

    function testPrematureWrongTupleAndUnauthorizedRejected() public {
        vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
        tl.queueTransaction(D4, 0, inner, eta);
        uint256 tooSoon = block.timestamp + tl.minDelay() - 1;
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.EtaTooSoon.selector);
        tl.queueTransaction(D4, 0, inner, tooSoon);
        _queue();
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
        tl.executeTransaction(D4, 0, inner, eta);
        assertTrue(tl.queuedTransactions(op));
        vm.warp(eta);
        vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
        tl.executeTransaction(D4, 0, inner, eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D5, 0, inner, eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, hex"04f6f5b2", eta);
        address legacyCollateralRisk = address(CollateralSeizer(D3).riskModule());
        assertTrue(legacyCollateralRisk != D5 && legacyCollateralRisk != address(0));
        bytes memory wrongRisk = abi.encodeCall(d4.setRiskModule, (legacyCollateralRisk));
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, wrongRisk, eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, eta + 1);
        vm.expectRevert();
        d4.setRiskModule(D5);
        assertEq(d4.riskModule(), address(0));
    }

    function testExecutionEventsConsumptionAndEconomicIsolation() public {
        bytes32 positionBefore = _position();
        uint256 debtBefore = d4.totalResidualBadDebtBase();
        uint256 clearingBefore = CollateralVault(VAULT).balances(CLEAR, TOKEN);
        uint256 vaultBalanceBefore = IERC20Like(TOKEN).balanceOf(VAULT);
        uint256 insuranceBalanceBefore = IERC20Like(TOKEN).balanceOf(INS);
        bytes32 domainBefore = d6.domainSeparatorV4();
        uint256 nonceBefore = d6.nonces(TRADER);
        bytes32 sharedBefore = _sharedDigest();
        address ownerBefore = d4.owner();
        address guardianBefore = d4.guardian();
        _queue();
        vm.warp(eta);
        vm.recordLogs();
        _execute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool riskEvent;
        bool executedEvent;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == D4 && logs[i].topics[0] == keccak256("RiskModuleSet(address)")) {
                riskEvent = logs[i].topics[1] == bytes32(uint256(uint160(D5)));
            }
            if (
                logs[i].emitter == TL
                    && logs[i].topics[0]
                        == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
            ) {
                executedEvent = logs[i].topics[1] == op;
            }
        }
        assertTrue(riskEvent && executedEvent);
        assertFalse(tl.queuedTransactions(op));
        assertEq(d4.riskModule(), D5);
        assertEq(address(d5.perpEngine()), D4);
        assertEq(d5.maxOracleDelay(), 600);
        assertEq(d4.owner(), ownerBefore);
        assertEq(d4.guardian(), guardianBefore);
        _closed();
        assertTrue(d6.paused());
        assertEq(_position(), positionBefore);
        assertEq(d4.totalResidualBadDebtBase(), debtBefore);
        assertEq(CollateralVault(VAULT).balances(CLEAR, TOKEN), clearingBefore);
        assertEq(IERC20Like(TOKEN).balanceOf(VAULT), vaultBalanceBefore);
        assertEq(IERC20Like(TOKEN).balanceOf(INS), insuranceBalanceBefore);
        assertEq(d6.domainSeparatorV4(), domainBefore);
        assertEq(d6.nonces(TRADER), nonceBefore);
        assertEq(_sharedDigest(), sharedBefore);
        assertFalse(CollateralVault(VAULT).isAuthorizedEngine(D4));
        assertFalse(InsuranceFund(INS).isBackstopCaller(D4));
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, eta);
    }

    function testNoPublicEconomicRouteAfterPointerWiring() public {
        _queue();
        vm.warp(eta);
        _execute();
        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        d4.updateFunding(1);
        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        d4.liquidate(TRADER, 1, 1);
        IPerpEngineTrade.Trade memory trade = IPerpEngineTrade.Trade({
            buyer: TRADER, seller: SAFE, marketId: 1, sizeDelta1e8: 1, executionPrice1e8: 1, buyerIsMaker: false
        });
        vm.expectRevert(PerpEngineTradingV2.MigrationNotSealed.selector);
        d4.applyTrade(trade);
        _closed();
        assertTrue(d6.paused());
    }

    function testCancelledOperationRejected() public {
        _queue();
        vm.prank(SAFE);
        tl.cancelTransaction(D4, 0, inner, eta);
        vm.warp(eta);
        vm.prank(SAFE);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        tl.executeTransaction(D4, 0, inner, eta);
        assertEq(d4.riskModule(), address(0));
    }
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
}
