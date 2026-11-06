// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";

interface IV15Timelock {
    function minDelay() external view returns (uint256);
    function proposers(address) external view returns (bool);
    function executors(address) external view returns (bool);
    function hashOperation(address, uint256, bytes calldata, uint256) external pure returns (bytes32);
    function queueTransaction(address, uint256, bytes calldata, uint256) external returns (bytes32);
    function executeTransaction(address, uint256, bytes calldata, uint256) external payable returns (bytes memory);
}

/// @dev Foundry fork only; both fixtures must come from the same validated dry-run.
contract OptionsV15FullPackageForkTest is Test {
    address constant DEPLOYER = 0xc35F7A8A103A9A4464adfaa76B9B514093D23C27;
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;

    function testFullV15PackageQueueExecuteOrderAndGas() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_204_686);
        string memory manifest = vm.readFile(vm.envString("OPTIONS_V15_PACKAGE_PATH"));
        string memory initcodes = vm.readFile(vm.envString("OPTIONS_V15_INITCODES_PATH"));
        assertEq(vm.parseJsonUint(manifest, ".chain_id"), block.chainid);
        assertEq(vm.parseJsonUint(manifest, ".pending_nonce_supplied"), 812);
        assertEq(vm.parseJsonAddress(manifest, ".deployer"), DEPLOYER);
        IV15Timelock tl = IV15Timelock(TIMELOCK);
        assertTrue(tl.proposers(SAFE) && tl.executors(SAFE));
        uint256 eta = vm.parseJsonUint(manifest, ".timelock_eta");
        assertGe(eta, block.timestamp + tl.minDelay());

        vm.setNonce(DEPLOYER, 812);
        for (uint256 i; i < 9; ++i) {
            bytes memory initcode = vm.parseJsonBytes(initcodes, string.concat(".initcodes[", vm.toString(i), "]"));
            address deployed;
            vm.broadcast(DEPLOYER); // forge test simulates locally; no public send.
            assembly { deployed := create(0, add(initcode, 32), mload(initcode)) }
            assertTrue(deployed != address(0), "local CREATE failed");
            assertEq(
                deployed,
                vm.parseJsonAddress(manifest, string.concat(".contracts[", vm.toString(i), "].predicted_address")),
                "CREATE address differs from manifest"
            );
        }

        uint256 queueSum;
        for (uint256 i; i < 36; ++i) {
            string memory path = string.concat(".timelock_operations_by_dependency_order[", vm.toString(i), "]");
            address target = vm.parseJsonAddress(manifest, string.concat(path, ".target"));
            bytes memory data = vm.parseJsonBytes(manifest, string.concat(path, ".data"));
            assertEq(
                tl.hashOperation(target, 0, data, eta),
                vm.parseJsonBytes32(manifest, string.concat(path, ".timelock_operation_id"))
            );
            vm.prank(SAFE); // fork impersonation, not a Safe signature.
            uint256 beforeGas = gasleft();
            tl.queueTransaction(target, 0, data, eta);
            uint256 used = beforeGas - gasleft();
            queueSum += used;
            console2.log("V15_QUEUE_GAS", i, used);
        }

        vm.warp(eta);
        uint256 executeSum;
        for (uint256 i; i < 36; ++i) {
            string memory path = string.concat(".timelock_operations_by_dependency_order[", vm.toString(i), "]");
            address target = vm.parseJsonAddress(manifest, string.concat(path, ".target"));
            bytes memory data = vm.parseJsonBytes(manifest, string.concat(path, ".data"));
            vm.prank(SAFE);
            uint256 beforeGas = gasleft();
            tl.executeTransaction(target, 0, data, eta);
            uint256 used = beforeGas - gasleft();
            executeSum += used;
            console2.log("V15_EXECUTE_GAS", i, used);
        }
        console2.log("V15_QUEUE_SUM", queueSum);
        console2.log("V15_EXECUTE_SUM", executeSum);
    }
}
