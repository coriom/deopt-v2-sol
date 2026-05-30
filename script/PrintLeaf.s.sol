// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FeesManagerV2} from "../src/fees/FeesManagerV2.sol";

contract PrintLeaf is Script {
    function run() external {
        FeesManagerV2 fm = new FeesManagerV2(address(0xA11CE), address(0xFEE));
        bytes32 leaf = fm.hashTierLeaf(
            address(0x0000000000000000000000000000000000000001),
            4,
            25_000_000 * 1e8,
            50_000,
            250_000 * 1e8,
            1_700_000_000,
            1_700_000_000 + 7 * 86_400
        );
        console.logBytes32(leaf);
    }
}
