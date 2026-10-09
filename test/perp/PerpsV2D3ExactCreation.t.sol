// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralSeizer} from "../../src/liquidation/CollateralSeizer.sol";

/// @notice Isolated EVM rehearsal of the frozen D3 creation bytes; no public send.
contract PerpsV2D3ExactCreationTest is Test {
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant VAULT = 0x00340C360353a5AB784c5Bc5c44322A6AF0625D3;
    address constant ORACLE = 0xB416406F200B2Ef3D7a86A5D5877Ed41D9B1A581;
    address constant COLLATERAL_RISK = 0xc0f019005a25524a34F2Ee8839DCDCC50715DD7B;
    address constant STRANDED_PERP_RISK = 0x8C3d9F71cA59B908Fa200546A63ea62F9C932998;
    address constant DEPLOYER = 0xDA9146F7A0aAcC41EB7Fe7e0d27E3e7ff0ABb9C0;
    address constant LOST_OWNER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address constant EXECUTOR = 0x58Ad437Cb9E32B0fAEe810ef05810d5Ba2aE52B8;
    address constant TOKEN = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    bytes32 constant INITCODE_HASH = 0x55842c43456d4e17e1b10543fafa97c2d867b688952264d7388052566f4c9699;
    bytes32 constant RUNTIME_HASH = 0x6d199e027af598ee903513a1ab41e27e2937115c79b8ec85e386d739615befcb;

    function _deploy() internal returns (CollateralSeizer seizer) {
        bytes memory initcode =
            vm.parseJsonBytes(vm.readFile(vm.envString("D3_REVIEW_JSON_PATH")), ".creationTransactionData");
        assertEq(keccak256(initcode), INITCODE_HASH);
        assertEq(initcode.length, 7136);
        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address deployed;
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        assertEq(deployed, expected);
        assertGt(deployed.code.length, 0);
        assertEq(deployed.codehash, RUNTIME_HASH);
        return CollateralSeizer(deployed);
    }

    function testCommittedExactD3CreationAndInitialState() public {
        // Constructor assigns only local storage and emits events; these sentinels prove no external writes.
        vm.store(VAULT, bytes32(uint256(123)), bytes32(uint256(456)));
        vm.store(ORACLE, bytes32(uint256(123)), bytes32(uint256(789)));
        vm.store(COLLATERAL_RISK, bytes32(uint256(123)), bytes32(uint256(101112)));
        CollateralSeizer seizer = _deploy();
        assertEq(vm.load(VAULT, bytes32(uint256(123))), bytes32(uint256(456)));
        assertEq(vm.load(ORACLE, bytes32(uint256(123))), bytes32(uint256(789)));
        assertEq(vm.load(COLLATERAL_RISK, bytes32(uint256(123))), bytes32(uint256(101112)));
        assertEq(seizer.owner(), TIMELOCK);
        assertEq(seizer.pendingOwner(), address(0));
        assertEq(address(seizer.collateralVault()), VAULT);
        assertEq(address(seizer.oracle()), ORACLE);
        assertEq(address(seizer.riskModule()), COLLATERAL_RISK);
        assertTrue(address(seizer.riskModule()) != STRANDED_PERP_RISK);
        assertEq(seizer.oracleMaxDelay(), 600);
        (uint16 spreadBps, bool enabled, bool isSet) = seizer.seizeConfigs(TOKEN);
        assertEq(spreadBps, 0);
        assertFalse(enabled);
        assertFalse(isSet);
    }

    function testOnlyTimelockCanConfigureAfterDeployerAndLostOwnerAreUnavailable() public {
        CollateralSeizer seizer = _deploy();
        address[3] memory unauthorized = [DEPLOYER, LOST_OWNER, EXECUTOR];
        for (uint256 i = 0; i < unauthorized.length; i++) {
            vm.prank(unauthorized[i]);
            vm.expectRevert(CollateralSeizer.NotAuthorized.selector);
            seizer.setOracleMaxDelay(300);
            vm.prank(unauthorized[i]);
            vm.expectRevert(CollateralSeizer.NotAuthorized.selector);
            seizer.setRiskModule(STRANDED_PERP_RISK);
        }
        vm.prank(TIMELOCK);
        seizer.setOracleMaxDelay(300);
        assertEq(seizer.oracleMaxDelay(), 300);
        assertEq(address(seizer.riskModule()), COLLATERAL_RISK);
    }
}
