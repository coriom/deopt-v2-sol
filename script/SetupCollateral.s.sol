// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CollateralVault.sol";

/// @title SetupCollateral
/// @notice Configure les tokens de collatéral dans le CollateralVault de DeOpt v2.
contract SetupCollateral is Script {
    // =========================
    // 🔐 ADRESSES À RENSEIGNER
    // =========================

    // EOA admin / owner qui va lancer le script
    address constant OWNER = 0x0000000000000000000000000000000000000000;

    // Vault déjà déployé
    address constant COLLATERAL_VAULT_ADDR = 0x0000000000000000000000000000000000000000;

    // Tokens sur Base (adresses réelles à mettre)
    address constant USDC = 0x0000000000000000000000000000000000000000;
    address constant USDT = 0x0000000000000000000000000000000000000000;
    address constant WBTC = 0x0000000000000000000000000000000000000000;
    address constant WETH = 0x0000000000000000000000000000000000000000;
    address constant WSOL = 0x0000000000000000000000000000000000000000;
    address constant BNB  = 0x0000000000000000000000000000000000000000;
    address constant WXRP = 0x0000000000000000000000000000000000000000;

    // Décimales (à vérifier avec les vrais ERC20 sur Base)
    uint8 constant DECIMALS_USDC = 6;
    uint8 constant DECIMALS_USDT = 6;
    uint8 constant DECIMALS_WBTC = 8;  // souvent 8, à confirmer
    uint8 constant DECIMALS_WETH = 18;
    uint8 constant DECIMALS_WSOL = 9;  // ou 18 suivant le wrapper, à vérifier
    uint8 constant DECIMALS_BNB  = 18;
    uint8 constant DECIMALS_WXRP = 18;

    // Facteurs de collat dans le Vault (rôle différent des haircuts RiskModule)
    // Ici on met 100% partout et on laisse le RiskModule gérer les haircuts réels.
    uint16 constant CF_USDC = 10_000;
    uint16 constant CF_USDT = 10_000;
    uint16 constant CF_WBTC = 10_000;
    uint16 constant CF_WETH = 10_000;
    uint16 constant CF_WSOL = 10_000;
    uint16 constant CF_BNB  = 10_000;
    uint16 constant CF_WXRP = 10_000;

    function run() external {
        vm.startBroadcast(OWNER);

        CollateralVault vault = CollateralVault(COLLATERAL_VAULT_ADDR);

        // Autoriser les tokens comme collatéral dans le Vault
        vault.setCollateralToken(USDC, true, DECIMALS_USDC, CF_USDC);
        vault.setCollateralToken(USDT, true, DECIMALS_USDT, CF_USDT);
        vault.setCollateralToken(WBTC, true, DECIMALS_WBTC, CF_WBTC);
        vault.setCollateralToken(WETH, true, DECIMALS_WETH, CF_WETH);
        vault.setCollateralToken(WSOL, true, DECIMALS_WSOL, CF_WSOL);
        vault.setCollateralToken(BNB,  true, DECIMALS_BNB,  CF_BNB);
        vault.setCollateralToken(WXRP, true, DECIMALS_WXRP, CF_WXRP);

        vm.stopBroadcast();
    }
}
