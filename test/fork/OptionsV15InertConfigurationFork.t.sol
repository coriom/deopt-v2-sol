// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {ProtocolTimelock} from "../../src/gouvernance/ProtocolTimelock.sol";
import {OracleRouter} from "../../src/oracle/OracleRouter.sol";
import {CollateralVault} from "../../src/collateral/CollateralVault.sol";
import {OptionProductRegistry} from "../../src/OptionProductRegistry.sol";
import {OptionMatchingEngine} from "../../src/matching/OptionMatchingEngine.sol";

contract OptionsV15InertConfigurationForkTest is Test {
    address constant TIMELOCK = 0xa67f8E8E673ce4bb2Fb563B0e6E9FA8F70E3b588;
    address constant SAFE = 0xA6B9Bb5c7B26B33cfD28C6F5A79B3c527fDdcD46;
    address constant MUSDC = 0x6eAe407f5640B006faC9965182e238582A3B412E;
    address constant MWETH = 0x4DeEBc5f537F3b8ba0E3393807B4D699D72bDd02;
    address constant PRIMARY = 0x09BCd126FEB91e13007b2C69644c12AB56260473;
    address constant SECONDARY = 0x1a6302eDC9e9DC5EFaE8Dd5e931089ac6Dc5322b;

    function testV15InertConfigurationAndTimelockGas() public {
        vm.createSelectFork(vm.envString("RPC_URL"), 55_188_524);
        ProtocolTimelock tl = ProtocolTimelock(payable(TIMELOCK));
        assertTrue(tl.proposers(SAFE));
        assertTrue(tl.executors(SAFE));
        assertEq(tl.minDelay(), 86_400);
        OracleRouter router = new OracleRouter(TIMELOCK);
        CollateralVault vault = new CollateralVault(TIMELOCK);
        OptionProductRegistry registry = new OptionProductRegistry(TIMELOCK);
        OptionMatchingEngine matching = new OptionMatchingEngine(TIMELOCK, address(0x1), address(registry));

        address[6] memory targets =
            [address(registry), address(registry), address(matching), address(vault), address(router), address(router)];
        bytes[6] memory calls;
        calls[0] = abi.encodeCall(registry.pauseCreation, ());
        calls[1] = abi.encodeCall(registry.pauseSettlement, ());
        calls[2] = abi.encodeCall(matching.pause, ());
        calls[3] = abi.encodeCall(vault.setEmergencyModes, (true, true, true, true));
        calls[4] = abi.encodeCall(router.setMaxOracleDelay, (uint32(1_500)));
        calls[5] = abi.encodeWithSignature(
            "setFeed(address,address,address,address,uint32,uint16,bool)",
            MWETH,
            MUSDC,
            PRIMARY,
            SECONDARY,
            uint32(1_500),
            uint16(100),
            false
        );

        uint256 eta = block.timestamp + tl.minDelay() + 1 hours;
        uint256 totalQueue;
        for (uint256 i; i < calls.length; i++) {
            uint256 beforeGas = gasleft();
            vm.prank(SAFE); // fork-only impersonation, not an authentic Safe signature
            tl.queueTransaction(targets[i], 0, calls[i], eta);
            uint256 used = beforeGas - gasleft();
            totalQueue += used;
            console2.log("V15_QUEUE_GAS", i, used);
        }
        vm.warp(eta);
        uint256 totalExecute;
        for (uint256 i; i < calls.length; i++) {
            uint256 beforeGas = gasleft();
            vm.prank(SAFE);
            tl.executeTransaction(targets[i], 0, calls[i], eta);
            uint256 used = beforeGas - gasleft();
            totalExecute += used;
            console2.log("V15_EXECUTE_GAS", i, used);
        }
        console2.log("V15_CONFIG_QUEUE_GAS_SUM", totalQueue);
        console2.log("V15_CONFIG_EXECUTE_GAS_SUM", totalExecute);
        assertTrue(registry.creationPaused());
        assertTrue(registry.settlementPaused());
        assertTrue(matching.paused());
        assertTrue(vault.depositsPaused());
        assertFalse(router.hasActiveFeed(MWETH, MUSDC));
    }
}
