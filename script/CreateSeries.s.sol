// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OptionProductRegistry.sol";

contract CreateSeries is Script {
    uint256 internal constant PRICE_1E8 = 1e8;

    // Renseigne ces deux valeurs AVANT exécution
    address constant OPTION_REGISTRY_ADDR = 0x0000000000000000000000000000000000000000;
    uint64 constant EXPIRY_1 = 0; // must be > block.timestamp
    uint64 constant EXPIRY_2 = 0; // optional (0 = disabled)

    // Base
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    function run() external {
        // Plus robuste que startBroadcast(address) : tu passes PRIVATE_KEY au runtime
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        OptionProductRegistry reg = OptionProductRegistry(OPTION_REGISTRY_ADDR);

        require(EXPIRY_1 > block.timestamp, "EXPIRY_1 must be in the future");
        if (EXPIRY_2 != 0) require(EXPIRY_2 > block.timestamp, "EXPIRY_2 must be in the future");

        // -------------------------
        // WBTC / USDC strikes (1e8)
        // -------------------------
        uint64;
        wbtcStrikes[0] = uint64(60_000 * PRICE_1E8);
        wbtcStrikes[1] = uint64(70_000 * PRICE_1E8);
        wbtcStrikes[2] = uint64(80_000 * PRICE_1E8);

        reg.createStrip(WBTC, USDC, EXPIRY_1, wbtcStrikes, true);
        if (EXPIRY_2 != 0) reg.createStrip(WBTC, USDC, EXPIRY_2, wbtcStrikes, true);

        // -------------------------
        // WETH / USDC strikes (1e8)
        // -------------------------
        uint64;
        wethStrikes[0] = uint64(2_500 * PRICE_1E8);
        wethStrikes[1] = uint64(3_000 * PRICE_1E8);
        wethStrikes[2] = uint64(3_500 * PRICE_1E8);

        reg.createStrip(WETH, USDC, EXPIRY_1, wethStrikes, true);
        if (EXPIRY_2 != 0) reg.createStrip(WETH, USDC, EXPIRY_2, wethStrikes, true);

        vm.stopBroadcast();
    }
}
