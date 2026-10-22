// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface IParallelSafe {
    function nonce() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function approveHash(bytes32 hashToApprove) external;
    function getTransactionHash(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address refundReceiver,
        uint256 _nonce
    ) external view returns (bytes32);
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);
}

interface IParallelTimelock {
    function queuedTransactions(bytes32) external view returns (bool);
    function hashOperation(address, uint256, bytes calldata, uint256) external pure returns (bytes32);
    function executeTransaction(address, uint256, bytes calldata, uint256) external payable returns (bytes memory);
}

interface IParallelRegistry {
    function isSettlementAssetAllowed(address) external view returns (bool);
    function totalMarkets() external view returns (uint256);
    function nextMarketId() external view returns (uint256);
}

interface IParallelEngine {
    function riskModule() external view returns (address);
    function matchingEngine() external view returns (address);
    function migrationState() external view returns (uint8);
    function migrationSnapshotHash() external view returns (bytes32);
    function tradingPaused() external view returns (bool);
    function liquidationPaused() external view returns (bool);
    function fundingPaused() external view returns (bool);
    function collateralOpsPaused() external view returns (bool);
    function totalResidualBadDebtBase() external view returns (uint256);
    function updateFunding(uint256 marketId) external;
    function liquidate(address trader, uint256 marketId, uint256 closeAbs) external;
}

interface IParallelVault {
    function balances(address, address) external view returns (uint256);
    function isAuthorizedEngine(address) external view returns (bool);
}

interface IParallelInsurance {
    function isBackstopCaller(address) external view returns (bool);
}

interface IParallelToken {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Only an isolated fork rehearsal. vm.prank(owner) approvals are synthetic, not real owner signatures.
contract PerpsV2C01C12ParallelS2ForkTest is Test {
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant TL = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant INSURANCE = 0x009f38440F058d095b61E0E2ee7fAbDF05BE7500;
    address constant CLEARING = 0x54d49c088DD27cFc82685b867c182b4bB4aC435c;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant TRADER = 0x290bD12C93E467Bf51c51f5273D35bdDb19e9274;
    uint256 constant ETA = 1792756800;
    bytes32 constant C01_ID = 0x589fb819f60769c77ad9090750f2173377eb45dcbb5367fbc0fb978e4e15d396;
    bytes32 constant C12_ID = 0xd15ec63a22daebd4eb015de23561089547af9b02945fb8ae6dd7028ae7581229;
    bytes32 constant C01_NONCE27 = 0xa4b8f2a256b90c8fdf4ad685aaeb472642dfd76ae9d974d2457a3b69f235b96c;
    bytes32 constant C12_NONCE28 = 0xb41d702689c8be0df90db46c02cd6896c60dd45ac9065575bbfa462d16781eed;
    bytes32 constant C12_NONCE27 = 0x2aca973090455776ab5f9767069c4d186d0daa21b19be58bcc145c7366d741fd;
    bytes32 constant C01_NONCE28 = 0xbfc8e4d8e2cad49a31020ec8df5953419fe0b79595f12c4352717a9372548c19;

    IParallelSafe safe = IParallelSafe(SAFE);
    IParallelTimelock tl = IParallelTimelock(TL);
    IParallelRegistry d1 = IParallelRegistry(D1);
    IParallelEngine d4 = IParallelEngine(D4);
    IParallelVault vault = IParallelVault(VAULT);
    bytes c01Inner = abi.encodeWithSignature("setSettlementAssetAllowed(address,bool)", TOKEN, true);
    bytes c12Inner = abi.encodeWithSignature("setRiskModule(address)", D5);

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), vm.envUint("PARALLEL_S2_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        assertLt(block.timestamp, ETA);
        assertEq(safe.nonce(), 27);
        assertEq(safe.getThreshold(), 2);
        assertTrue(tl.queuedTransactions(C01_ID));
        assertTrue(tl.queuedTransactions(C12_ID));
        assertEq(tl.hashOperation(D1, 0, c01Inner, ETA), C01_ID);
        assertEq(tl.hashOperation(D4, 0, c12Inner, ETA), C12_ID);
        assertFalse(d1.isSettlementAssetAllowed(TOKEN));
        assertEq(d4.riskModule(), address(0));
        _assertMaintenance();
    }

    function _readHash(address target, bytes memory input) internal view returns (bytes32) {
        (bool ok, bytes memory result) = target.staticcall(input);
        assertTrue(ok);
        return keccak256(result);
    }

    function _sharedDigest() internal view returns (bytes32 h) {
        h = keccak256(abi.encode(h, _readHash(D2, abi.encodeWithSignature("merkleRoot()"))));
        h = keccak256(abi.encode(h, _readHash(D2, abi.encodeWithSignature("rebateBudget(address)", TOKEN))));
        h = keccak256(abi.encode(h, _readHash(D3, abi.encodeWithSignature("seizeConfigs(address)", TOKEN))));
        h = keccak256(abi.encode(h, _readHash(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1))));
        h = keccak256(abi.encode(h, _readHash(D6, abi.encodeWithSignature("domainSeparatorV4()"))));
        h = keccak256(abi.encode(h, _readHash(D6, abi.encodeWithSignature("nonces(address)", TRADER))));
        h = keccak256(
            abi.encode(h, _readHash(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN)))
        );
        h = keccak256(
            abi.encode(h, _readHash(VAULT, abi.encodeWithSignature("balances(address,address)", INSURANCE, TOKEN)))
        );
        h = keccak256(abi.encode(h, _readHash(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT))));
        h = keccak256(abi.encode(h, _readHash(TOKEN, abi.encodeWithSignature("balanceOf(address)", INSURANCE))));
        h = keccak256(abi.encode(h, _readHash(D5, abi.encodeWithSignature("maxOracleDelay()"))));
    }

    function _assertMaintenance() internal view {
        assertTrue(d4.tradingPaused() && d4.liquidationPaused() && d4.fundingPaused() && d4.collateralOpsPaused());
        assertEq(d4.migrationState(), 0);
        assertEq(d4.migrationSnapshotHash(), bytes32(0));
        assertEq(d4.matchingEngine(), address(0));
        assertEq(d4.totalResidualBadDebtBase(), 0);
        assertTrue(_readBool(D6, "paused()"));
        assertFalse(vault.isAuthorizedEngine(D4));
        assertFalse(IParallelInsurance(INSURANCE).isBackstopCaller(D4));
        assertEq(d1.totalMarkets(), 0);
        assertEq(d1.nextMarketId(), 1);
    }

    function _readBool(address target, string memory sig) internal view returns (bool) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        assertTrue(ok);
        return abi.decode(data, (bool));
    }

    function _approveAndExecute(address target, bytes memory inner, bytes32 expectedHash, string memory gasLabel)
        internal
    {
        bytes memory data =
            abi.encodeWithSignature("executeTransaction(address,uint256,bytes,uint256)", target, 0, inner, ETA);
        bytes32 txHash = safe.getTransactionHash(TL, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        assertEq(txHash, expectedHash);
        address[] memory owners = safe.getOwners();
        address a = owners[0];
        address b = owners[1];
        if (uint160(a) > uint160(b)) (a, b) = (b, a);
        vm.prank(a); // Fork-only owner-address impersonation; no real key or signature.
        safe.approveHash(txHash);
        vm.prank(b);
        safe.approveHash(txHash);
        bytes memory approvals = abi.encodePacked(
            bytes32(uint256(uint160(a))),
            bytes32(0),
            bytes1(0x01),
            bytes32(uint256(uint160(b))),
            bytes32(0),
            bytes1(0x01)
        );
        uint256 gasBefore = gasleft();
        assertTrue(safe.execTransaction(TL, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), approvals));
        emit log_named_uint(gasLabel, gasBefore - gasleft());
    }

    function _assertEventPair(Vm.Log[] memory logs, bytes32 operationId, address target) internal pure {
        bool foundTimelock;
        bool foundTarget;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == TL
                    && logs[i].topics[0]
                        == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
            ) {
                foundTimelock = logs[i].topics[1] == operationId;
            }
            if (
                target == D1 && logs[i].emitter == D1
                    && logs[i].topics[0] == keccak256("SettlementAssetConfigured(address,bool)")
            ) {
                foundTarget =
                    logs[i].topics[1] == bytes32(uint256(uint160(TOKEN))) && abi.decode(logs[i].data, (bool));
            }
            if (target == D4 && logs[i].emitter == D4 && logs[i].topics[0] == keccak256("RiskModuleSet(address)")) {
                foundTarget = logs[i].topics[1] == bytes32(uint256(uint160(D5)));
            }
        }
        require(foundTimelock && foundTarget, "missing exact execution events");
    }

    function testC01ThenC12SafeNonceSequenceAndIsolation() public {
        bytes32 sharedBefore = _sharedDigest();
        vm.warp(ETA);
        vm.recordLogs();
        _approveAndExecute(D1, c01Inner, C01_NONCE27, "C01 first Safe simulated gas");
        _assertEventPair(vm.getRecordedLogs(), C01_ID, D1);
        assertEq(safe.nonce(), 28);
        assertTrue(d1.isSettlementAssetAllowed(TOKEN));
        assertEq(d4.riskModule(), address(0));
        assertFalse(tl.queuedTransactions(C01_ID));
        assertTrue(tl.queuedTransactions(C12_ID));
        _assertMaintenance();
        assertEq(_sharedDigest(), sharedBefore);
        vm.recordLogs();
        _approveAndExecute(D4, c12Inner, C12_NONCE28, "C12 second Safe simulated gas");
        _assertEventPair(vm.getRecordedLogs(), C12_ID, D4);
        assertEq(safe.nonce(), 29);
        assertEq(d4.riskModule(), D5);
        assertEq(_readHash(D5, abi.encodeWithSignature("perpEngine()")), keccak256(abi.encode(D4)));
        assertFalse(tl.queuedTransactions(C01_ID));
        assertFalse(tl.queuedTransactions(C12_ID));
        assertTrue(d1.isSettlementAssetAllowed(TOKEN));
        _assertMaintenance();
        assertEq(_sharedDigest(), sharedBefore);
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D1, 0, c01Inner, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D4, 0, c12Inner, ETA);
        vm.expectRevert();
        d4.updateFunding(1);
        vm.expectRevert();
        d4.liquidate(TRADER, 1, 1);
    }

    function testC12ThenC01AlsoSafeButDifferentHashes() public {
        bytes32 sharedBefore = _sharedDigest();
        vm.warp(ETA);
        vm.recordLogs();
        _approveAndExecute(D4, c12Inner, C12_NONCE27, "C12 first Safe simulated gas");
        _assertEventPair(vm.getRecordedLogs(), C12_ID, D4);
        assertEq(safe.nonce(), 28);
        assertEq(d4.riskModule(), D5);
        assertTrue(tl.queuedTransactions(C01_ID));
        assertFalse(d1.isSettlementAssetAllowed(TOKEN));
        _assertMaintenance();
        assertEq(_sharedDigest(), sharedBefore);
        vm.recordLogs();
        _approveAndExecute(D1, c01Inner, C01_NONCE28, "C01 second Safe simulated gas");
        _assertEventPair(vm.getRecordedLogs(), C01_ID, D1);
        assertEq(safe.nonce(), 29);
        assertFalse(tl.queuedTransactions(C01_ID));
        assertFalse(tl.queuedTransactions(C12_ID));
        assertEq(d4.riskModule(), D5);
        assertTrue(d1.isSettlementAssetAllowed(TOKEN));
        _assertMaintenance();
        assertEq(_sharedDigest(), sharedBefore);
    }

    function testBothPrematureExecutionAndIdentityFailures() public {
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D1, 0, c01Inner, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D4, 0, c12Inner, ETA);
        assertTrue(tl.queuedTransactions(C01_ID));
        assertTrue(tl.queuedTransactions(C12_ID));
        vm.warp(ETA);
        vm.prank(address(0x1234));
        vm.expectRevert();
        tl.executeTransaction(D1, 0, c01Inner, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D1, 0, c01Inner, ETA + 1);
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D4, 0, c01Inner, ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D4, 0, abi.encodeWithSignature("setRiskModule(address)", D1), ETA);
        assertTrue(tl.queuedTransactions(C01_ID));
        assertTrue(tl.queuedTransactions(C12_ID));
        assertEq(safe.nonce(), 27);
    }

    function testDirectTimelockGasObservationOnly() public {
        vm.warp(ETA);
        uint256 gasBefore = gasleft();
        vm.prank(SAFE);
        tl.executeTransaction(D1, 0, c01Inner, ETA);
        emit log_named_uint("C01 direct Timelock simulated gas", gasBefore - gasleft());
        gasBefore = gasleft();
        vm.prank(SAFE);
        tl.executeTransaction(D4, 0, c12Inner, ETA);
        emit log_named_uint("C12 direct Timelock simulated gas", gasBefore - gasleft());
        assertEq(safe.nonce(), 27); // Direct fork prank does not exercise Safe or signatures.
        assertTrue(d1.isSettlementAssetAllowed(TOKEN));
        assertEq(d4.riskModule(), D5);
        _assertMaintenance();
    }
}
