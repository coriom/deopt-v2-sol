// SPDX-License-Identifier: MIT 
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../src/MarginEngine.sol";
import "../src/risk/RiskModule.sol";
import "../src/CollateralVault.sol";
import "../src/OptionProductRegistry.sol";
import "../src/oracle/OracleRouter.sol";

/// @title SetupRisk
/// @notice Script de wiring + configuration du moteur de risque de DeOpt v2.
/// @dev
///  - Base collateral : USDC
///  - Sous-jacents listés : WETH, WBTC
///  - Oracles : OracleRouter (WBTC/USDC via Chainlink, WETH/USDC via Pyth)
///  - Attention : ce script suppose que tous les contrats core sont déjà déployés
///    et que leurs adresses sont correctement renseignées ci-dessous.
contract SetupRisk is Script {
    // =========================
    // 🔐 ADRESSES À RENSEIGNER
    // =========================

    /// @notice EOA admin / owner qui va faire les tx de config
    address constant OWNER = 0x0000000000000000000000000000000000000000;

    /// @notice Contrats core DÉJÀ déployés
    address constant MARGIN_ENGINE_ADDR    = 0x0000000000000000000000000000000000000000;
    address constant RISK_MODULE_ADDR      = 0x0000000000000000000000000000000000000000;
    address constant COLLATERAL_VAULT_ADDR = 0x0000000000000000000000000000000000000000;
    address constant OPTION_REGISTRY_ADDR  = 0x0000000000000000000000000000000000000000;
    address constant ORACLE_ROUTER_ADDR    = 0x0000000000000000000000000000000000000000;

    // =========================
    // 💰 TOKENS (réseau Base)
    // =========================

    // Base collateral
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // 6 décimales

    // Sous-jacents listés
    address constant WETH = 0x4200000000000000000000000000000000000006; // 18 décimales
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c; // ⚠️ vérifier ses décimales (souvent 8)

    // =========================
    // ⚙️ PARAMÈTRES DE RISQUE GLOBAUX
    // =========================

    /// @notice Base maintenance margin par contrat (en unités de USDC).
    /// Ici: 10_000_000 = 10 USDC si USDC a 6 décimales.
    uint256 constant BASE_MM_PER_CONTRACT = 10_000_000;

    /// @notice Facteur d'IM en bps: IM = MM * IM_FACTOR_BPS / 1e4.
    /// 12_000 = 120% → IM = 1.2 * MM.
    uint256 constant IM_FACTOR_BPS = 12_000;

    /// @notice Délai max de fraîcheur des prix oracle (en secondes) côté RiskModule.
    /// On réduit à 5 minutes pour limiter le risque de prix trop stale.
    uint256 constant MAX_ORACLE_DELAY = 300; // 5 minutes

    /// @notice Haircuts collatéraux (en bps) – côté RiskModule.
    /// Ces poids sont appliqués à la valeur du collat lorsqu'on calcule l'equity.
    /// Exemple: 9_500 = 95% → 100 USDC de collat comptent comme 95 en equity.
    uint16 constant WEIGHT_USDC = 9_500; // 95% (stable mais risque depeg / protocole)
    uint16 constant WEIGHT_WETH = 8_000; // 80% (volatile L1)
    uint16 constant WEIGHT_WBTC = 8_500; // 85% (BTC-like)

    /// @notice Paramètres de liquidation (en bps)
    /// - Seuil de liquidation : equity / MM < 103% → compte liquidable.
    /// - Pénalité : 3% de la MM sur les contrats liquidés (entièrement pour le liquidateur v1).
    uint256 constant LIQ_THRESHOLD_BPS = 10_300; // 103%
    uint256 constant LIQ_PENALTY_BPS   = 300;    // 3%

    // =========================
    // 📌 DÉCIMALES COLLATERAL VAULT
    // =========================
    // ⚠️ À vérifier sur les vrais contrats de tokens.
    uint8 constant USDC_DECIMALS = 6;
    uint8 constant WETH_DECIMALS = 18;
    uint8 constant WBTC_DECIMALS = 8; // mets 18 si ton WBTC a 18 décimales

    /// @notice collateralFactorBps dans le Vault (RiskModule gère les haircuts).
    /// On laisse 100% ici pour ne pas doubler les décotes.
    uint16 constant VAULT_COLLATERAL_FACTOR = 10_000;

    function run() external {
        vm.startBroadcast(OWNER);

        // Instances des contrats
        MarginEngine margin       = MarginEngine(MARGIN_ENGINE_ADDR);
        RiskModule risk           = RiskModule(RISK_MODULE_ADDR);
        CollateralVault vault     = CollateralVault(COLLATERAL_VAULT_ADDR);
        OptionProductRegistry reg = OptionProductRegistry(OPTION_REGISTRY_ADDR);
        OracleRouter oracle       = OracleRouter(ORACLE_ROUTER_ADDR);

        // =========================
        // 🔌 WIRING DES CONTRATS
        // =========================

        // MarginEngine <-> RiskModule
        margin.setRiskModule(address(risk));
        risk.setMarginEngine(address(margin));

        // Oracles
        margin.setOracle(address(oracle));
        risk.setOracle(address(oracle));

        // Vault <-> Risk/Margin
        vault.setRiskModule(address(risk));
        vault.setMarginEngine(address(margin));

        // =========================
        // ⚙️ PARAMÈTRES GLOBAUX
        // =========================

        // baseCollateralToken = USDC pour RiskModule et MarginEngine
        // Important : setRiskParams du RiskModule va aussi forcer USDC comme collat 100%,
        // puis on override juste après avec le haircut à 95%.
        risk.setRiskParams(USDC, BASE_MM_PER_CONTRACT, IM_FACTOR_BPS);
        margin.setRiskParams(USDC, BASE_MM_PER_CONTRACT, IM_FACTOR_BPS);

        // Fraîcheur max des prix oracle (côté RiskModule)
        risk.setMaxOracleDelay(MAX_ORACLE_DELAY);

        // =========================
        // 💰 CONFIG COLLATERAL (RISK MODULE)
        // =========================

        // On applique les haircuts décidés :
        //  - USDC : 95%
        //  - WETH : 80%
        //  - WBTC : 85%
        risk.setCollateralConfig(USDC, WEIGHT_USDC, true);
        risk.setCollateralConfig(WETH, WEIGHT_WETH, true);
        risk.setCollateralConfig(WBTC, WEIGHT_WBTC, true);

        // =========================
        // 💰 CONFIG COLLATERAL (COLLATERAL VAULT)
        // =========================
        // On configure les décimales pour que le RiskModule puisse les lire correctement.
        // collateralFactorBps = 100% partout (les haircuts sont centralisés dans le RiskModule).

        vault.setCollateralToken(USDC, true, USDC_DECIMALS, VAULT_COLLATERAL_FACTOR);
        vault.setCollateralToken(WETH, true, WETH_DECIMALS, VAULT_COLLATERAL_FACTOR);
        vault.setCollateralToken(WBTC, true, WBTC_DECIMALS, VAULT_COLLATERAL_FACTOR);

        // =========================
        // 📈 CONFIG SOUS-JACENTS (UNDERLYINGCONFIG)
        // =========================
        // WETH & WBTC : même "bucket majors" (BTC/ETH-like).
        // Chocs spot +/-25%, vol +20% : assez conservateur pour v1.

        OptionProductRegistry.UnderlyingConfig memory cfgMajors =
            OptionProductRegistry.UnderlyingConfig({
                oracle: address(oracle),
                spotShockDownBps: 2_500, // -25%
                spotShockUpBps:   2_500, // +25%
                volShockDownBps:  0,
                volShockUpBps:    2_000, // +20%
                isEnabled:        true
            });

        reg.setUnderlyingConfig(WETH, cfgMajors);
        reg.setUnderlyingConfig(WBTC, cfgMajors);

        // =========================
        // ☠️ PARAMÈTRES DE LIQUIDATION (MARGIN ENGINE)
        // =========================
        // Seuil 103% = coussin dynamique (latence, oracles, slippage) par-dessus
        // les haircuts et la MM par contrat.
        margin.setLiquidationParams(LIQ_THRESHOLD_BPS, LIQ_PENALTY_BPS);

        vm.stopBroadcast();
    }
}
