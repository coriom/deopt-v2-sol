// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";
import {FeesManagerV2} from "../../src/fees/FeesManagerV2.sol";
import {IFeesManagerV2} from "../../src/fees/IFeesManagerV2.sol";

interface IApprovedPolicyMaintenance {
    function tradingPaused() external view returns (bool);
    function liquidationPaused() external view returns (bool);
    function fundingPaused() external view returns (bool);
    function collateralOpsPaused() external view returns (bool);
    function riskModule() external view returns (address);
    function matchingEngine() external view returns (address);
    function collateralSeizer() external view returns (address);
    function migrationState() external view returns (uint8);
}

interface IApprovedPolicyPaused {
    function paused() external view returns (bool);
}

interface IApprovedPolicyVault {
    function balances(address account, address token) external view returns (uint256);
}

interface IApprovedPolicyRegistry {
    function nextMarketId() external view returns (uint256);
}

/// @dev Isolated Base Sepolia fork; Safe address impersonation is not a 2/3 signature test.
contract DeoptD2D3ApprovedPolicyForkTest is Test {
    address internal constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address internal constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address internal constant D1 = 0x6B3D846536116082dC4E7227861C341Bb85Ee963;
    address internal constant D2 = 0x9947F42cC29A32992bbf2030ee49E35C839EDEd5;
    address internal constant D3 = 0x43Ac3782e75018981a8F8d210049f2A185b07331;
    address internal constant D4 = 0xd0901DE8f6de72aecC716CA1465C4Cf58a0B99fB;
    address internal constant D5 = 0x90CAA6D5bC628577bc76d6Cc8b775f983c75e110;
    address internal constant D6 = 0xeeA4e5d891B90D3d99E9C4e2c61069911477110E;
    address internal constant LEGACY_RISK = 0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B;
    address internal constant LEGACY_FEES = 0x00dA0B9876bcBf0c79CB5BcAcfEBAFb8C7Ad774f;
    address internal constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address internal constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    bytes32 internal constant C02_ID = 0x9e10ee1c04280e36ba1d7144b5abd2d1a48b08fac54087bd5e7090d91030913e;
    uint256 internal constant ETA = 1793102400;

    ProtocolTimelock internal timelock;
    CollateralSeizer internal seizer;
    FeesManagerV2 internal fees;

    function setUp() public {
        string memory rpc = vm.envOr("DEOPT_POLICY_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "Set DEOPT_POLICY_FORK_RPC to Base Sepolia RPC");
            return;
        }
        vm.createSelectFork(rpc, 49_976_909);
        assertEq(block.chainid, 84532);
        timelock = ProtocolTimelock(payable(TIMELOCK));
        seizer = CollateralSeizer(D3);
        fees = FeesManagerV2(D2);
        assertEq(timelock.minDelay(), 86400);
        assertTrue(timelock.proposers(SAFE) && timelock.executors(SAFE));
        assertTrue(timelock.queuedTransactions(C02_ID));
        assertEq(address(seizer.riskModule()), LEGACY_RISK);
        assertEq(fees.owner(), TIMELOCK);
    }

    function _inner(uint256 i) internal pure returns (address target, bytes memory data) {
        if (i == 0) {
            return (D3, abi.encodeCall(CollateralSeizer.setTokenSeizeConfig, (MUSDC, 5, true)));
        }
        return
            (D2, abi.encodeCall(FeesManagerV2.setFeeProfile, (uint8(i - 1), IFeesManagerV2.ProductKind.PERP, 0, 200)));
    }

    function _queue(uint256 i) internal returns (bytes32 id) {
        (address target, bytes memory data) = _inner(i);
        bytes32 localId = keccak256(abi.encode(target, uint256(0), data, ETA));
        assertEq(timelock.hashOperation(target, 0, data, ETA), localId);
        vm.prank(SAFE);
        id = timelock.queueTransaction(target, 0, data, ETA);
        assertEq(id, localId);
        assertTrue(timelock.queuedTransactions(id));
    }

    function _execute(uint256 i) internal {
        (address target, bytes memory data) = _inner(i);
        vm.prank(SAFE);
        timelock.executeTransaction(target, 0, data, ETA);
        assertFalse(timelock.queuedTransactions(keccak256(abi.encode(target, uint256(0), data, ETA))));
    }

    function _assertIsolation(uint256 timelockVaultBalance) internal view {
        IApprovedPolicyMaintenance engine = IApprovedPolicyMaintenance(D4);
        assertTrue(engine.tradingPaused());
        assertTrue(engine.liquidationPaused());
        assertTrue(engine.fundingPaused());
        assertTrue(engine.collateralOpsPaused());
        assertEq(engine.migrationState(), 0);
        assertEq(engine.riskModule(), D5);
        assertEq(engine.matchingEngine(), address(0));
        assertEq(engine.collateralSeizer(), address(0));
        assertTrue(IApprovedPolicyPaused(D6).paused());
        assertEq(IApprovedPolicyRegistry(D1).nextMarketId(), 1);
        assertTrue(timelock.queuedTransactions(C02_ID));
        assertEq(IApprovedPolicyVault(VAULT).balances(TIMELOCK, MUSDC), timelockVaultBalance);
        assertEq(FeesManagerV2(LEGACY_FEES).rebateBudget(MUSDC), 999_977);
        assertEq(fees.rebateBudget(MUSDC), 0);
        assertFalse(fees.isFeeConsumer(D4));
    }

    function testSixIndependentQueuesDelayExecutionAndReplay() public {
        uint256 beforeVault = IApprovedPolicyVault(VAULT).balances(TIMELOCK, MUSDC);
        bytes32[] memory ids = new bytes32[](6);
        for (uint256 i; i < 6; ++i) {
            ids[i] = _queue(i);
        }
        assertEq(seizer.tokenDiscountBps(MUSDC), 10_000);
        vm.warp(ETA - 1);
        for (uint256 i; i < 6; ++i) {
            (address target, bytes memory data) = _inner(i);
            vm.expectRevert(ProtocolTimelock.TransactionNotReady.selector);
            vm.prank(SAFE);
            timelock.executeTransaction(target, 0, data, ETA);
            assertTrue(timelock.queuedTransactions(ids[i]));
        }
        vm.warp(ETA);
        for (uint256 i; i < 6; ++i) {
            _execute(i);
        }
        (uint16 spread, bool enabled, bool isSet) = seizer.seizeConfigs(MUSDC);
        assertEq(spread, 5);
        assertTrue(enabled && isSet);
        assertEq(seizer.tokenDiscountBps(MUSDC), 9_995);
        assertEq(address(seizer.riskModule()), LEGACY_RISK);
        for (uint8 tier; tier < 5; ++tier) {
            IFeesManagerV2.ProductFeeProfilePpm memory p = fees.getFeeProfile(tier, IFeesManagerV2.ProductKind.PERP);
            assertEq(p.makerPpm, 0);
            assertEq(p.takerPpm, 200);
        }
        assertEq(fees.feeRecipient(), TIMELOCK);
        assertEq(fees.rebateFundingAccount(), address(0));
        assertEq(fees.protocolFeeVault(), address(0));
        assertEq(fees.merkleRoot(), bytes32(0));
        _assertIsolation(beforeVault);
        for (uint256 i; i < 6; ++i) {
            (address target, bytes memory data) = _inner(i);
            vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
            vm.prank(SAFE);
            timelock.executeTransaction(target, 0, data, ETA);
        }
    }

    function testUnauthorizedQueueAndUnqueuedExecutionReject() public {
        (address target, bytes memory data) = _inner(0);
        vm.expectRevert(ProtocolTimelock.NotAuthorized.selector);
        vm.prank(address(0xBEEF));
        timelock.queueTransaction(target, 0, data, ETA);
        vm.warp(ETA);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        vm.prank(SAFE);
        timelock.executeTransaction(target, 0, data, ETA);
    }

    function testWrongFeeTierOrEtaDoesNotConsumeQueuedOperation() public {
        bytes32 id = _queue(1);
        vm.warp(ETA);
        (address target,) = _inner(1);
        bytes memory wrongData =
            abi.encodeCall(FeesManagerV2.setFeeProfile, (uint8(1), IFeesManagerV2.ProductKind.PERP, 0, 200));
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        vm.prank(SAFE);
        timelock.executeTransaction(target, 0, wrongData, ETA);
        (, bytes memory correctData) = _inner(1);
        vm.expectRevert(ProtocolTimelock.TransactionNotQueued.selector);
        vm.prank(SAFE);
        timelock.executeTransaction(target, 0, correctData, ETA + 1);
        assertTrue(timelock.queuedTransactions(id));
    }
}
