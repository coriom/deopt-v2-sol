// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CollateralVault.sol";

contract SetupCollateralVault is Script {
    // À REMPLIR avant d'exécuter le script
    address constant OWNER      = 0x0000000000000000000000000000000000000000; // ton EOA gouvernance
    address constant VAULT_ADDR = 0x0000000000000000000000000000000000000000; // adresse du CollateralVault déployé

    // Tokens Base (réseau Base)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6 décimales
    address constant WETH = 0x4200000000000000000000000000000000000006; // 18 décimales
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c; // 8 ou 18 selon impl., on met 8 si c'est Wrapped BTC “classique”

    function run() external {
        vm.startBroadcast(OWNER);

        CollateralVault vault = CollateralVault(VAULT_ADDR);

        // Collat principal : USDC
        vault.setCollateralToken(
            USDC,
            true,   // isSupported
            6,      // decimals
            10_000  // collateralFactorBps (100%, on gère les haircuts dans le RiskModule)
        );

        // WETH
        vault.setCollateralToken(
            WETH,
            true,
            18,
            10_000
        );

        // WBTC — à adapter si ton WBTC a 8 décimales
        vault.setCollateralToken(
            WBTC,
            true,
            8,      // si ton WBTC est 8 décimales ; mets 18 si besoin
            10_000
        );

        vm.stopBroadcast();
    }
}
