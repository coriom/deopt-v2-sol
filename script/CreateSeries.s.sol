// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OptionProductRegistry.sol";

/// Create strips (calls+puts) for WBTC/USDC and WETH/USDC.
/// Strikes are uint64 in 1e8, matching OptionProductRegistry convention.
contract CreateSeries is Script {
    // Prefer env vars to avoid hardcoding:
    //   export PRIVATE_KEY=...
    //   export OPTION_REGISTRY=0x...
    uint256 internal constant PRICE_1E8 = 1e8;

    // Base mainnet tokens (as you had)
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    // Put real timestamps before running (compile is fine with 0)
    uint64 internal constant EXPIRY_1 = 0;
    uint64 internal constant EXPIRY_2 = 0;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address registryAddr = vm.envAddress("OPTION_REGISTRY");
        OptionProductRegistry reg = OptionProductRegistry(registryAddr);

        vm.startBroadcast(pk);

        // Prevent accidental runs with empty expiries
        require(EXPIRY_1 != 0 && EXPIRY_1 > block.timestamp, "bad EXPIRY_1");
        if (EXPIRY_2 != 0) require(EXPIRY_2 > block.timestamp, "bad EXPIRY_2");

        // -------------------------
        // WBTC / USDC strikes (1e8)
        // -------------------------
        wbtcStrikes[0] = uint64(60_000 * PRICE_1E8);
        wbtcStrikes[1] = uint64(70_000 * PRICE_1E8);
        wbtcStrikes[2] = uint64(80_000 * PRICE_1E8);

        reg.createStrip(WBTC, USDC, EXPIRY_1, wbtcStrikes, true);
        if (EXPIRY_2 != 0) reg.createStrip(WBTC, USDC, EXPIRY_2, wbtcStrikes, true);

        // -------------------------
        // WETH / USDC strikes (1e8)
        // -------------------------
        wethStrikes[0] = uint64(2_500 * PRICE_1E8);
        wethStrikes[1] = uint64(3_000 * PRICE_1E8);
        wethStrikes[2] = uint64(3_500 * PRICE_1E8);

        reg.createStrip(WETH, USDC, EXPIRY_1, wethStrikes, true);
        if (EXPIRY_2 != 0) reg.createStrip(WETH, USDC, EXPIRY_2, wethStrikes, true);

        vm.stopBroadcast();
    }
}
