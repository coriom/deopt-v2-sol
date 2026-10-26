// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

interface ID2D3Safe {
    function nonce() external view returns (uint256);
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
    function approveHash(bytes32) external;
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

interface ID2D3Timelock {
    function queuedTransactions(bytes32) external view returns (bool);
    function hashOperation(address, uint256, bytes calldata, uint256) external pure returns (bytes32);
    function executeTransaction(address, uint256, bytes calldata, uint256) external payable returns (bytes memory);
}

interface ID2D3Seizer {
    function seizeConfigs(address) external view returns (uint16, bool, bool);
    function riskModule() external view returns (address);
}

interface ID2D3Fees {
    function getFeeProfile(uint8, uint8) external view returns (int32, int32);
    function feeRecipient() external view returns (address);
    function rebateBudget(address) external view returns (uint256);
}

interface ID2D3Engine {
    function tradingPaused() external view returns (bool);
    function liquidationPaused() external view returns (bool);
    function fundingPaused() external view returns (bool);
    function collateralOpsPaused() external view returns (bool);
    function migrationState() external view returns (uint8);
    function riskModule() external view returns (address);
    function matchingEngine() external view returns (address);
}

interface ID2D3Registry {
    function totalMarkets() external view returns (uint256);
}

interface ID2D3Vault {
    function balances(address, address) external view returns (uint256);
    function isAuthorizedEngine(address) external view returns (bool);
}

interface ID2D3Insurance {
    function isBackstopCaller(address) external view returns (bool);
}

/// @notice Isolated fork only. Owner-address impersonation exercises Safe mechanics, not genuine signatures.
contract PerpsV2D2D3SixS2ForkTest is Test {
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
    uint256 constant ETA = 1793102400;
    bytes32[6] ids = [
        bytes32(0x6678a5eefb1b1a1b7a9ff4aa5795e1ba7d09fba63ee59917d454e07fe2208c0d),
        bytes32(0x1976519a08a3a7e65cbe1a2f77fcf0f5fa0f783ccb6c7ef0e6c87b7481caf45b),
        bytes32(0xb79986810ad3e08b5495a8edeaed0654da513ef6acfa15e8ff1d496ff2ef4a11),
        bytes32(0x48b66ca38c21064a6605af4038a657a191a56f327784dc1e0d0bffdc21075a62),
        bytes32(0xaaf8ae230522b4a6b08a365be6e87f2544392e729b559db44968912b3a177f76),
        bytes32(0x9ec2e37332d4dbb27791ae7f4de7e852147b344f58210e61adb7b2f95a8d5b49)
    ];
    ID2D3Safe safe = ID2D3Safe(SAFE);
    ID2D3Timelock tl = ID2D3Timelock(TL);
    ID2D3Fees fees = ID2D3Fees(D2);
    ID2D3Seizer seizer = ID2D3Seizer(D3);
    ID2D3Engine engine = ID2D3Engine(D4);

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), vm.envUint("D2_D3_S2_FORK_BLOCK"));
        assertEq(block.chainid, 84532);
        assertLt(block.timestamp, ETA);
        assertEq(safe.nonce(), 36);
        assertEq(safe.getThreshold(), 2);
        for (uint256 i; i < 6; i++) {
            assertTrue(tl.queuedTransactions(ids[i]));
            assertEq(tl.hashOperation(_target(i), 0, _inner(i), ETA), ids[i]);
        }
        (uint16 spread, bool enabled, bool isSet) = seizer.seizeConfigs(TOKEN);
        assertEq(spread, 0);
        assertFalse(enabled);
        assertFalse(isSet);
        assertEq(seizer.riskModule(), 0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B);
        assertEq(fees.feeRecipient(), TL);
        assertEq(fees.rebateBudget(TOKEN), 0);
        assertEq(ID2D3Registry(D1).totalMarkets(), 0);
        _maintenance();
    }

    function _target(uint256 i) internal pure returns (address) {
        return i == 0 ? D3 : D2;
    }

    function _inner(uint256 i) internal pure returns (bytes memory) {
        if (i == 0) return abi.encodeWithSignature("setTokenSeizeConfig(address,uint16,bool)", TOKEN, uint16(5), true);
        return
            abi.encodeWithSignature(
                "setFeeProfile(uint8,uint8,int32,int32)", uint8(i - 1), uint8(1), int32(0), int32(200)
            );
    }

    function _executeData(uint256 i) internal pure returns (bytes memory) {
        return
            abi.encodeWithSignature("executeTransaction(address,uint256,bytes,uint256)", _target(i), 0, _inner(i), ETA);
    }

    function _maintenance() internal view {
        assertTrue(
            engine.tradingPaused() && engine.liquidationPaused() && engine.fundingPaused()
                && engine.collateralOpsPaused()
        );
        assertEq(engine.migrationState(), 0);
        assertEq(engine.riskModule(), D5);
        assertEq(engine.matchingEngine(), address(0));
        assertTrue(_bool(D6, "paused()"));
        assertFalse(ID2D3Vault(VAULT).isAuthorizedEngine(D4));
        assertFalse(ID2D3Insurance(INSURANCE).isBackstopCaller(D4));
        assertEq(ID2D3Registry(D1).totalMarkets(), 0);
    }

    function _bool(address target, string memory signature) internal view returns (bool) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(signature));
        assertTrue(ok);
        return abi.decode(data, (bool));
    }

    function _read(address target, bytes memory data) internal view returns (bytes32) {
        (bool ok, bytes memory result) = target.staticcall(data);
        assertTrue(ok);
        return keccak256(result);
    }

    function _economicDigest() internal view returns (bytes32 h) {
        h = keccak256(
            abi.encode(h, _read(VAULT, abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN)))
        );
        h = keccak256(
            abi.encode(h, _read(VAULT, abi.encodeWithSignature("balances(address,address)", INSURANCE, TOKEN)))
        );
        h = keccak256(abi.encode(h, _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", VAULT))));
        h = keccak256(abi.encode(h, _read(TOKEN, abi.encodeWithSignature("balanceOf(address)", INSURANCE))));
        h = keccak256(abi.encode(h, _read(D4, abi.encodeWithSignature("positions(address,uint256)", TRADER, 1))));
        h = keccak256(abi.encode(h, _read(D2, abi.encodeWithSignature("rebateBudget(address)", TOKEN))));
        h = keccak256(abi.encode(h, _read(D2, abi.encodeWithSignature("feeRecipient()"))));
        h = keccak256(abi.encode(h, _read(D2, abi.encodeWithSignature("merkleRoot()"))));
        h = keccak256(abi.encode(h, _read(D3, abi.encodeWithSignature("riskModule()"))));
        h = keccak256(abi.encode(h, _read(D5, abi.encodeWithSignature("maxOracleDelay()"))));
        for (uint8 tier; tier < 5; tier++) {
            h = keccak256(
                abi.encode(h, _read(D2, abi.encodeWithSignature("getFeeProfile(uint8,uint8)", tier, uint8(0))))
            );
        }
        h = keccak256(abi.encode(h, _read(D1, abi.encodeWithSignature("totalMarkets()"))));
    }

    function _assertResult(uint256 i) internal view {
        assertFalse(tl.queuedTransactions(ids[i]));
        if (i == 0) {
            (uint16 spread, bool enabled, bool isSet) = seizer.seizeConfigs(TOKEN);
            assertEq(spread, 5);
            assertTrue(enabled);
            assertTrue(isSet);
        } else {
            (int32 maker, int32 taker) = fees.getFeeProfile(uint8(i - 1), 1);
            assertEq(maker, 0);
            assertEq(taker, 200);
        }
        assertEq(fees.rebateBudget(TOKEN), 0);
        _maintenance();
    }

    function testPrematureUnauthorizedWrongIdentityAndExpiry() public {
        for (uint256 i; i < 6; i++) {
            vm.prank(SAFE);
            vm.expectRevert();
            tl.executeTransaction(_target(i), 0, _inner(i), ETA);
            assertTrue(tl.queuedTransactions(ids[i]));
        }
        vm.warp(ETA);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        tl.executeTransaction(D3, 0, _inner(0), ETA);
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D3, 0, _inner(0), ETA + 1);
        assertTrue(tl.queuedTransactions(ids[0]));
        vm.warp(ETA + 1209601);
        vm.prank(SAFE);
        vm.expectRevert();
        tl.executeTransaction(D3, 0, _inner(0), ETA);
        assertTrue(tl.queuedTransactions(ids[0]));
    }

    function testDirectSixExecutionsEventsNonDriftAndReplay() public {
        bytes32 econ = _economicDigest();
        vm.warp(ETA);
        for (uint256 i; i < 6; i++) {
            vm.recordLogs();
            vm.prank(SAFE);
            tl.executeTransaction(_target(i), 0, _inner(i), ETA);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            for (uint256 j; j < logs.length; j++) {
                if (
                    logs[j].emitter == TL
                        && logs[j].topics[0]
                            == keccak256("TransactionExecuted(bytes32,address,uint256,bytes,uint256,bytes)")
                        && logs[j].topics[1] == ids[i]
                ) found = true;
            }
            assertTrue(found);
            _assertResult(i);
            assertEq(_economicDigest(), econ);
            vm.prank(SAFE);
            vm.expectRevert();
            tl.executeTransaction(_target(i), 0, _inner(i), ETA);
        }
        assertEq(safe.nonce(), 36); // direct prank is not Safe execution
    }

    function _safeExecute(uint256 i) internal {
        bytes memory data = _executeData(i);
        bytes32 hash = safe.getTransactionHash(TL, 0, data, 0, 0, 0, 0, address(0), address(0), safe.nonce());
        address[] memory owners = safe.getOwners();
        address a = owners[0];
        address b = owners[1];
        if (uint160(a) > uint160(b)) (a, b) = (b, a);
        vm.prank(a);
        safe.approveHash(hash);
        vm.prank(b);
        safe.approveHash(hash);
        bytes memory approvals = abi.encodePacked(
            bytes32(uint256(uint160(a))),
            bytes32(0),
            bytes1(0x01),
            bytes32(uint256(uint160(b))),
            bytes32(0),
            bytes1(0x01)
        );
        assertTrue(safe.execTransaction(TL, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), approvals));
    }

    function testSyntheticSafeSequentialSixNonces() public {
        bytes32 econ = _economicDigest();
        vm.warp(ETA);
        for (uint256 i; i < 6; i++) {
            assertEq(safe.nonce(), 36 + i);
            _safeExecute(i);
            assertEq(safe.nonce(), 37 + i);
            _assertResult(i);
            assertEq(_economicDigest(), econ);
            for (uint256 j = i + 1; j < 6; j++) {
                assertTrue(tl.queuedTransactions(ids[j]));
            }
        }
    }
}
