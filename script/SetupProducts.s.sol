// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/OptionProductRegistry.sol";

/// @title SetupProducts
/// @notice Script de configuration des séries d’options (produits) pour DeOpt v2.
/// @dev
///  - À exécuter APRÈS :
///      * déploiement de OptionProductRegistry
///      * SetupRisk (qui configure les UnderlyingConfig pour WETH / WBTC)
///  - Ce script :
///      * autorise USDC comme asset de règlement
///      * (optionnel) définit un minExpiryDelay
///      * crée quelques strips (Calls + Puts) pour WETH & WBTC
contract SetupProducts is Script {
    // =========================
    // 🔐 ADRESSES À RENSEIGNER
    // =========================

    /// @notice EOA admin / owner qui fera le broadcast (doit être owner du Registry).
    address constant OWNER = 0x0000000000000000000000000000000000000000;

    /// @notice Adresse du OptionProductRegistry déjà déployé.
    address constant OPTION_REGISTRY_ADDR = 0x0000000000000000000000000000000000000000;

    // =========================
    // 💰 ASSETS (réseau Base)
    // =========================

    // Asset de règlement
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // Sous-jacents listés (doivent avoir une UnderlyingConfig isEnabled = true)
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;

    // =========================
    // ⚙️ PARAMÈTRES PRODUITS
    // =========================

    /// @notice Délai minimum entre la création et l’expiration (en secondes).
    /// @dev À adapter (1 heure / 1 jour / etc.). 0 = pas de contrainte.
    uint256 constant MIN_EXPIRY_DELAY = 1 hours;

    function run() external {
        vm.startBroadcast(OWNER);

        OptionProductRegistry reg = OptionProductRegistry(OPTION_REGISTRY_ADDR);

        // =========================
        // 1) CONFIG ASSET DE RÈGLEMENT
        // =========================

        // Autoriser USDC comme settlementAsset (obligatoire pour createSeries/createStrip)
        reg.setSettlementAssetAllowed(USDC, true);

        // (Optionnel) imposer un minimum de délai entre création et expiry
        if (MIN_EXPIRY_DELAY > 0) {
            reg.setMinExpiryDelay(MIN_EXPIRY_DELAY);
        }

        // =========================
        // 2) DÉFINITION DES ÉCHÉANCES
        // =========================
        // On part de block.timestamp pour construire quelques expirations relatives.
        // Tu peux modifier les horizons (7j / 30j / 90j) selon ton design produit.

        uint64 expiry1 = uint64(block.timestamp + 7 days); // ~1 semaine
        uint64 expiry2 = uint64(block.timestamp + 30 days); // ~1 mois
        uint64 expiry3 = uint64(block.timestamp + 90 days); // ~3 mois

        // =========================
        // 3) STRIKES WETH (en *1e8*)
        // =========================
        // ⚠️ À AJUSTER avant exécution pour coller au spot WETH au moment T.
        // Exemple avec un spot WETH ~ 3 000 :
        //  - strip 1w : 2800 / 3000 / 3200
        //  - strip 1m : 2600 / 3000 / 3400
        //  - strip 3m : 2400 / 3000 / 3600

        uint64;
        strikesWETH_1w[0] = uint64(2800 * 1e8);
        strikesWETH_1w[1] = uint64(3000 * 1e8);
        strikesWETH_1w[2] = uint64(3200 * 1e8);

        uint64;
        strikesWETH_1m[0] = uint64(2600 * 1e8);
        strikesWETH_1m[1] = uint64(3000 * 1e8);
        strikesWETH_1m[2] = uint64(3400 * 1e8);

        uint64;
        strikesWETH_3m[0] = uint64(2400 * 1e8);
        strikesWETH_3m[1] = uint64(3000 * 1e8);
        strikesWETH_3m[2] = uint64(3600 * 1e8);

        // =========================
        // 4) STRIKES WBTC (en *1e8*)
        // =========================
        // ⚠️ À AJUSTER aussi avant exécution.
        // Exemple avec spot WBTC ~ 60 000 :
        //  - strip 1w : 55k / 60k / 65k
        //  - strip 1m : 50k / 60k / 70k
        //  - strip 3m : 45k / 60k / 75k

        uint64;
        strikesWBTC_1w[0] = uint64(55_000 * 1e8);
        strikesWBTC_1w[1] = uint64(60_000 * 1e8);
        strikesWBTC_1w[2] = uint64(65_000 * 1e8);

        uint64;
        strikesWBTC_1m[0] = uint64(50_000 * 1e8);
        strikesWBTC_1m[1] = uint64(60_000 * 1e8);
        strikesWBTC_1m[2] = uint64(70_000 * 1e8);

        uint64;
        strikesWBTC_3m[0] = uint64(45_000 * 1e8);
        strikesWBTC_3m[1] = uint64(60_000 * 1e8);
        strikesWBTC_3m[2] = uint64(75_000 * 1e8);

        // =========================
        // 5) CRÉATION EFFECTIVE DES SÉRIES
        // =========================
        // createStrip crée pour chaque strike :
        //   - 1 Call
        //   - 1 Put
        // donc 3 strikes → 6 séries par sous-jacent & par expiration.

        // --- WETH strips ---
        reg.createStrip(WETH, USDC, expiry1, strikesWETH_1w, true); // 1w, européens
        reg.createStrip(WETH, USDC, expiry2, strikesWETH_1m, true); // 1m
        reg.createStrip(WETH, USDC, expiry3, strikesWETH_3m, true); // 3m

        // --- WBTC strips ---
        reg.createStrip(WBTC, USDC, expiry1, strikesWBTC_1w, true); // 1w
        reg.createStrip(WBTC, USDC, expiry2, strikesWBTC_1m, true); // 1m
        reg.createStrip(WBTC, USDC, expiry3, strikesWBTC_3m, true); // 3m

        vm.stopBroadcast();
    }
}
