// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OptionProductRegistry.sol";

/// @title SetupProducts
/// @notice Script pour créer les premières séries d’options (WBTC/USDC & WETH/USDC)
/// @dev À lancer une fois que:
///      - le OptionProductRegistry est déployé,
///      - les UnderlyingConfig WBTC/WETH sont configurés & isEnabled = true,
///      - USDC est autorisé comme settlement asset,
///      - OWNER est bien owner ou seriesCreator du Registry.
contract SetupProducts is Script {
    // =========================
    // 🔐 ADRESSES À RENSEIGNER
    // =========================

    // EOA admin / owner qui va faire les tx de création de séries
    address constant OWNER                = 0x0000000000000000000000000000000000000000;

    // Adresse du OptionProductRegistry déjà déployé
    address constant OPTION_REGISTRY_ADDR = 0x0000000000000000000000000000000000000000;

    // Tokens (réseau Base)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    function run() external {
        vm.startBroadcast(OWNER);

        OptionProductRegistry reg = OptionProductRegistry(OPTION_REGISTRY_ADDR);

        // =========================
        // 1) Paramètres d’échéance
        // =========================
        // Exemple : 1 semaine et 1 mois à partir de maintenant.
        uint64 expiry1W  = uint64(block.timestamp + 7 days);
        uint64 expiry1M  = uint64(block.timestamp + 30 days);

        // ⚠️ Important :
        // assure-toi que expiryX >= block.timestamp + minExpiryDelay
        // (sinon createSeries va revert avec ExpiryTooSoon).

        // =========================
        // 2) Strikes WETH (en *1e8*)
        // =========================
        // Exemple : 2k / 2.5k / 3k USDC
        uint64;
        wethStrikes1W[0] = uint64(2_000 * 1e8);
        wethStrikes1W[1] = uint64(2_500 * 1e8);
        wethStrikes1W[2] = uint64(3_000 * 1e8);

        uint64;
        wethStrikes1M[0] = uint64(2_000 * 1e8);
        wethStrikes1M[1] = uint64(2_500 * 1e8);
        wethStrikes1M[2] = uint64(3_000 * 1e8);

        // =========================
        // 3) Strikes WBTC (en *1e8*)
        // =========================
        // Exemple : 40k / 50k / 60k USDC
        uint64;
        wbtcStrikes1W[0] = uint64(40_000 * 1e8);
        wbtcStrikes1W[1] = uint64(50_000 * 1e8);
        wbtcStrikes1W[2] = uint64(60_000 * 1e8);

        uint64;
        wbtcStrikes1M[0] = uint64(40_000 * 1e8);
        wbtcStrikes1M[1] = uint64(50_000 * 1e8);
        wbtcStrikes1M[2] = uint64(60_000 * 1e8);

        // =========================
        // 4) Création des séries
        // =========================
        // On crée des strips (calls + puts) européens WETH/USDC & WBTC/USDC
        // pour 1W et 1M.

        // --- WETH / USDC ---
        reg.createStrip(
            WETH,
            USDC,
            expiry1W,
            wethStrikes1W,
            true // isEuropean
        );

        reg.createStrip(
            WETH,
            USDC,
            expiry1M,
            wethStrikes1M,
            true
        );

        // --- WBTC / USDC ---
        reg.createStrip(
            WBTC,
            USDC,
            expiry1W,
            wbtcStrikes1W,
            true
        );

        reg.createStrip(
            WBTC,
            USDC,
            expiry1M,
            wbtcStrikes1M,
            true
        );

        vm.stopBroadcast();
    }
}
