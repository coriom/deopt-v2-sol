// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../src/oracle/OracleRouter.sol";
import "../src/oracle/ChainlinkPriceSource.sol";
import "../src/oracle/IPriceSource.sol";
import "../src/oracle/PythPriceSource.sol";

/// @title SetupOracle
/// @notice Script de déploiement / configuration de l'oracle pour DeOpt v2.
/// @dev
///  - WBTC/USDC : prix via Chainlink (feed WBTC/USD, traité comme WBTC/USDC).
///  - WETH/USDC : prix via Pyth (feed WETH/USD, traité comme WETH/USDC).
contract SetupOracle is Script {
    // =========================================================
    // 🔐 ADRESSES À RENSEIGNER
    // =========================================================

    /// @notice Adresse qui possèdera l'OracleRouter et signe les tx du script.
    /// @dev Mets ici ton EOA admin (le même que pour MarginEngine / RiskModule).
    address constant OWNER = 0x0000000000000000000000000000000000000000;

    /// @notice Si tu as DÉJÀ déployé un OracleRouter, mets son adresse ici.
    ///         Sinon laisse à address(0) et le script va en déployer un nouveau.
    address constant EXISTING_ORACLE_ROUTER = address(0);

    // ===== Tokens (réseau Base) =====
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // ===== Chainlink : feed WBTC / USD (sur Base) =====
    // Utilisé comme proxy WBTC / USDC (USDC ~ 1 USD).
    address constant CHAINLINK_WBTC_USD = 0xCCADC697c55bbB68dc5bCdf8d3CBe83CdD4E071E;

    // ===== Pyth core contract (sur Base) =====
    // ⚠️ À REMPLIR avec l’adresse officielle Pyth sur Base Mainnet
    //    (ne laisse PAS 0x0 pour la prod).
    address constant PYTH_CORE = 0x0000000000000000000000000000000000000000;

    // ===== IDs de price feeds Pyth (WETH/USD, USDC/USD) =====
    // fournis par toi (sans le préfixe 0x) → remis au format bytes32.
    bytes32 constant PYTH_WETH_USD_PRICE_ID =
        0x9d4294bbcd1174d6f2003ec365831e64cc31d9f6f15a2b85399db8d5000960f6;

    // (Optionnel – gardé pour usage futur si tu veux un jour un prix USDC/USD)
    bytes32 constant PYTH_USDC_USD_PRICE_ID =
        0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;

    // ===== Paramètres de sécurité de l’oracle =====
    uint32 constant MAX_DELAY   = 600; // 10 minutes
    uint16 constant MAX_DEV_BPS = 0;   // pas de secondary, donc 0

    function run() external {
        vm.startBroadcast(OWNER);

        // 1) Récupérer ou déployer l'OracleRouter
        OracleRouter router;
        if (EXISTING_ORACLE_ROUTER == address(0)) {
            // Nouveau déploiement, owner = OWNER
            router = new OracleRouter(OWNER);
        } else {
            // Router déjà déployé
            router = OracleRouter(EXISTING_ORACLE_ROUTER);
        }

        // Optionnel mais propre : on force la valeur de maxOracleDelay
        router.setMaxOracleDelay(MAX_DELAY);

        // =====================================================
        // 2) Déployer les sources de prix
        // =====================================================

        // --- WBTC via Chainlink ---
        ChainlinkPriceSource wbtcSource = new ChainlinkPriceSource(CHAINLINK_WBTC_USD);

        // --- WETH via Pyth (WETH/USD) ---
        PythPriceSource wethSource =
            new PythPriceSource(PYTH_CORE, PYTH_WETH_USD_PRICE_ID);

        // (Optionnel) USDC/USD via Pyth, si tu veux l’exposer plus tard.
        // PythPriceSource usdcSource =
        //     new PythPriceSource(PYTH_CORE, PYTH_USDC_USD_PRICE_ID);

        // =====================================================
        // 3) Enregistrer les feeds dans l’OracleRouter
        // =====================================================

        // WBTC / USDC via Chainlink (WBTC/USD)
        router.setFeed(
            WBTC,
            USDC,
            IPriceSource(address(wbtcSource)),
            IPriceSource(address(0)), // pas de secondary pour l’instant
            MAX_DELAY,
            MAX_DEV_BPS,
            true
        );

        // WETH / USDC via Pyth (WETH/USD)
        router.setFeed(
            WETH,
            USDC,
            IPriceSource(address(wethSource)),
            IPriceSource(address(0)),
            MAX_DELAY,
            MAX_DEV_BPS,
            true
        );

        // (Optionnel) si un jour tu veux un prix USDC / "USD numéraire",
        // il faudra définir une adresse pour l’asset "USD" et décommenter ceci.
        /*
        router.setFeed(
            USDC,
            USD_NUMERAIRE,
            IPriceSource(address(usdcSource)),
            IPriceSource(address(0)),
            MAX_DELAY,
            MAX_DEV_BPS,
            true
        );
        */

        vm.stopBroadcast();
    }
}
