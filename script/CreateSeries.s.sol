// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OptionProductRegistry.sol";

/// @title CreateSeries
/// @notice Script pour créer des séries d'options WBTC & WETH sur DeOpt v2.
/// @dev
///  - Utilise createStrip pour créer Call + Put pour chaque strike.
///  - Settlement asset = USDC.
///  - Strikes exprimés en *1e8* (même convention que l'oracle).
contract CreateSeries is Script {
    // =========================
    // 🔐 ADRESSES À RENSEIGNER
    // =========================

    /// @notice EOA qui va exécuter le script (doit être `owner` ou `isSeriesCreator` dans OptionProductRegistry)
    address constant OWNER = 0x0000000000000000000000000000000000000000;

    /// @notice Adresse de l'OptionProductRegistry déployé
    address constant OPTION_REGISTRY_ADDR = 0x0000000000000000000000000000000000000000;

    /// @notice Tokens (réseau Base)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    // =========================
    // ⏰ EXPIRIES À RENSEIGNER
    // =========================
    //
    // Tu peux mettre des timestamps fixes (UNIX) ici.
    // Exemple (à adapter) :
    //  - EXPIRY_1 = 1737072000; // 17 janv 2025 00:00:00 UTC
    //  - EXPIRY_2 = 1738281600; // 31 janv 2025 00:00:00 UTC

    uint64 constant EXPIRY_1 = 0; // ⚠️ REMPLIR avec un timestamp > block.timestamp
    uint64 constant EXPIRY_2 = 0; // optionnel, mets 0 si tu ne veux pas l'utiliser

    function run() external {
        vm.startBroadcast(OWNER);

        OptionProductRegistry reg = OptionProductRegistry(OPTION_REGISTRY_ADDR);

        // Sanity check basique pour éviter d'oublier de remplir
        require(EXPIRY_1 > block.timestamp, "EXPIRY_1 must be in the future");
        if (EXPIRY_2 != 0) {
            require(EXPIRY_2 > block.timestamp, "EXPIRY_2 must be in the future");
        }

        // =========================
        // 🎯 SÉRIES WBTC / USDC
        // =========================
        //
        // Strikes en *1e8*.
        // Exemple si BTC spot ~ 70k :
        //   60k, 70k, 80k
        //
        // 60_000 * 1e8 = 6_000_000_000_000_000
        // 70_000 * 1e8 = 7_000_000_000_000_000
        // 80_000 * 1e8 = 8_000_000_000_000_000

        uint64;
        wbtcStrikes[0] = 60_000 * 1e8;
        wbtcStrikes[1] = 70_000 * 1e8;
        wbtcStrikes[2] = 80_000 * 1e8;

        // Strip WBTC (Call + Put) sur EXPIRY_1
        reg.createStrip(
            WBTC,
            USDC,
            EXPIRY_1,
            wbtcStrikes,
            true // isEuropean
        );

        // (Optionnel) Strip WBTC sur EXPIRY_2 si défini
        if (EXPIRY_2 != 0) {
            reg.createStrip(
                WBTC,
                USDC,
                EXPIRY_2,
                wbtcStrikes,
                true
            );
        }

        // =========================
        // 🎯 SÉRIES WETH / USDC
        // =========================
        //
        // Strikes en *1e8*.
        // Exemple si ETH spot ~ 3k :
        //   2500, 3000, 3500
        //
        // 2_500 * 1e8 = 250_000_000_000_000
        // 3_000 * 1e8 = 300_000_000_000_000
        // 3_500 * 1e8 = 350_000_000_000_000

        uint64;
        wethStrikes[0] = 2_500 * 1e8;
        wethStrikes[1] = 3_000 * 1e8;
        wethStrikes[2] = 3_500 * 1e8;

        // Strip WETH (Call + Put) sur EXPIRY_1
        reg.createStrip(
            WETH,
            USDC,
            EXPIRY_1,
            wethStrikes,
            true // isEuropean
        );

        // (Optionnel) Strip WETH sur EXPIRY_2
        if (EXPIRY_2 != 0) {
            reg.createStrip(
                WETH,
                USDC,
                EXPIRY_2,
                wethStrikes,
                true
            );
        }

        vm.stopBroadcast();
    }
}
