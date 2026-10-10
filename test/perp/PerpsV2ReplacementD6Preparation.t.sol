// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {PerpMatchingEngineV2} from "../../src/matching/PerpMatchingEngineV2.sol";

/// @notice Exact-address, fork-only construction check. No public transaction is sent.
contract PerpsV2ReplacementD6PreparationTest is Test {
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
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
    address constant EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    address constant LOST_OWNER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;

    function _address(address target, string memory signature) internal view returns (address value) {
        (bool ok, bytes memory result) = target.staticcall(abi.encodeWithSignature(signature));
        assertTrue(ok, signature);
        value = abi.decode(result, (address));
    }

    function _word(address target, string memory signature) internal view returns (bytes32 value) {
        (bool ok, bytes memory result) = target.staticcall(abi.encodeWithSignature(signature));
        assertTrue(ok, signature);
        value = abi.decode(result, (bytes32));
    }

    function testExactAddressConstructionAndInertTopology() public {
        vm.createSelectFork(vm.envString("D6_RPC_URL"), vm.envUint("D6_REVIEW_BLOCK"));
        assertEq(block.chainid, 84532);
        assertEq(vm.getNonce(DEPLOYER), 5);
        assertEq(D6.code.length, 0);
        assertEq(_address(D1, "owner()"), TIMELOCK);
        assertEq(_address(D2, "owner()"), TIMELOCK);
        assertEq(_address(D3, "owner()"), TIMELOCK);
        assertEq(_address(D5, "owner()"), TIMELOCK);
        assertEq(_address(D5, "perpEngine()"), D4);
        assertEq(uint256(_word(D5, "maxOracleDelay()")), 0);
        assertEq(uint256(_word(D1, "totalMarkets()")), 0);
        assertEq(_address(D4, "riskModule()"), address(0));
        assertEq(_address(D4, "matchingEngine()"), address(0));
        assertEq(uint256(_word(D4, "migrationState()")), 0);
        bytes32 snapshotBefore = _word(D4, "migrationSnapshotHash()");
        (bool vaultOk, bytes memory vaultResult) =
            VAULT.staticcall(abi.encodeWithSignature("isEngineAuthorized(address)", D4));
        assertTrue(vaultOk);
        assertFalse(abi.decode(vaultResult, (bool)));
        (bool insuranceOk, bytes memory insuranceResult) =
            INSURANCE.staticcall(abi.encodeWithSignature("isBackstopCaller(address)", D4));
        assertTrue(insuranceOk);
        assertFalse(abi.decode(insuranceResult, (bool)));
        (bool ledgerOk, bytes memory ledgerResult) =
            VAULT.staticcall(abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN));
        assertTrue(ledgerOk);
        uint256 ledgerBefore = abi.decode(ledgerResult, (uint256));
        assertEq(ledgerBefore, 1_000_000_000);

        bytes memory initcode = vm.envBytes("D6_CREATION_DATA");
        assertEq(initcode.length, 11949);
        assertEq(keccak256(initcode), 0x78c2b65e7bb1f36054e093845b6d97d51e7335698c5f16fada43b7b597a73e18);
        address deployed;
        vm.prank(DEPLOYER);
        assembly { deployed := create(0, add(initcode, 32), mload(initcode)) }
        assertEq(deployed, D6);
        PerpMatchingEngineV2 pme = PerpMatchingEngineV2(deployed);
        console2.log("D6_RUNTIME_HASH");
        console2.logBytes32(deployed.codehash);
        assertEq(deployed.codehash, 0x3bad813e8654fddf86fb459a738d912b0c6c4dd4ad20119c52a4cc0dc1db834f);
        vm.writeFile("/tmp/d6_exact_runtime.hex", vm.toString(deployed.code));
        console2.log("D6_DOMAIN_SEPARATOR");
        console2.logBytes32(pme.domainSeparatorV4());

        assertEq(pme.owner(), TIMELOCK);
        assertEq(pme.pendingOwner(), address(0));
        assertEq(pme.guardian(), address(0));
        assertEq(address(pme.perpEngine()), D4);
        assertFalse(pme.paused());
        assertTrue(pme.isExecutor(TIMELOCK));
        assertFalse(pme.isExecutor(EXECUTOR));
        assertFalse(pme.isExecutor(DEPLOYER));
        assertFalse(pme.isExecutor(LOST_OWNER));
        assertEq(pme.nonces(DEPLOYER), 0);
        assertEq(pme.intentFilled(bytes32(0)), 0);
        assertFalse(pme.intentNonceUsed(DEPLOYER, 0));
        (bytes1 fields, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            pme.eip712Domain();
        assertEq(fields, bytes1(0x0f));
        assertEq(name, "DeOptV2-PerpMatchingEngine");
        assertEq(version, "2");
        assertEq(chainId, 84532);
        assertEq(verifyingContract, D6);
        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                D6
            )
        );
        assertEq(pme.domainSeparatorV4(), expectedDomain);
        // A correctly signed local trade reaches D4, but OPEN migration
        // blocks it before accounting; nonce writes revert with the call.
        uint256 buyerKey = 0xB0B0;
        uint256 sellerKey = 0xA11CE;
        PerpMatchingEngineV2.PerpTrade memory trade = PerpMatchingEngineV2.PerpTrade({
            intentId: keccak256("D6 local inert-route probe"),
            buyer: vm.addr(buyerKey),
            seller: vm.addr(sellerKey),
            marketId: 1,
            sizeDelta1e8: 1_000_000,
            executionPrice1e8: 246_831_000_000,
            maxExecutionPrice1e8: 246_831_000_000,
            minExecutionPrice1e8: 246_831_000_000,
            buyerIsMaker: false,
            buyerNonce: 0,
            sellerNonce: 0,
            deadline: block.timestamp + 900
        });
        bytes32 digest = pme.hashTrade(trade);
        (uint8 bv, bytes32 br, bytes32 bs) = vm.sign(buyerKey, digest);
        (uint8 sv, bytes32 sr, bytes32 ss) = vm.sign(sellerKey, digest);
        vm.prank(TIMELOCK);
        vm.expectRevert(bytes4(keccak256("MigrationNotSealed()")));
        pme.executeTrade(trade, abi.encodePacked(br, bs, bv), abi.encodePacked(sr, ss, sv));
        assertEq(pme.nonces(trade.buyer), 0);
        assertEq(pme.nonces(trade.seller), 0);
        vm.prank(EXECUTOR);
        vm.expectRevert(PerpMatchingEngineV2.NotAuthorized.selector);
        pme.setExecutor(EXECUTOR, true);
        vm.prank(TIMELOCK);
        pme.setExecutor(EXECUTOR, true);
        assertTrue(pme.isExecutor(EXECUTOR));
        vm.prank(TIMELOCK);
        pme.setExecutor(EXECUTOR, false);
        assertFalse(pme.isExecutor(EXECUTOR));
        assertEq(_address(D4, "riskModule()"), address(0));
        assertEq(_address(D4, "matchingEngine()"), address(0));
        assertEq(uint256(_word(D4, "migrationState()")), 0);
        assertEq(_word(D4, "migrationSnapshotHash()"), snapshotBefore);
        assertEq(uint256(_word(D5, "maxOracleDelay()")), 0);
        (vaultOk, vaultResult) = VAULT.staticcall(abi.encodeWithSignature("isEngineAuthorized(address)", D4));
        assertTrue(vaultOk);
        assertFalse(abi.decode(vaultResult, (bool)));
        (insuranceOk, insuranceResult) = INSURANCE.staticcall(abi.encodeWithSignature("isBackstopCaller(address)", D4));
        assertTrue(insuranceOk);
        assertFalse(abi.decode(insuranceResult, (bool)));
        (ledgerOk, ledgerResult) =
            VAULT.staticcall(abi.encodeWithSignature("balances(address,address)", CLEARING, TOKEN));
        assertTrue(ledgerOk);
        assertEq(abi.decode(ledgerResult, (uint256)), ledgerBefore);
    }
}
