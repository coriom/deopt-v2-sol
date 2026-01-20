// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";

import "../src/OptionProductRegistry.sol";
import "../src/oracle/OracleRouter.sol";

/// @title SetupProductsWithOracle
/// @notice Liste automatiquement des séries d'options WBTC/USDC et WETH/USDC
///         avec une grille de strikes "à la Deribit" autour de l'ATM.
/// @dev
/// - Les strikes et le spot sont en *1e8* (même convention que l'oracle).
/// - Les steps sont calculés dynamiquement en fonction du spot et de la maturité.
contract SetupProductsWithOracle is Script {
    // =========================
    // 🔐 ADRESSES À RENSEIGNER
    // =========================
    address constant OWNER              = 0x0000000000000000000000000000000000000000; // ton EOA admin
    address constant OPTION_REGISTRY    = 0x0000000000000000000000000000000000000000; // OptionProductRegistry déployé
    address constant ORACLE_ROUTER_ADDR = 0x0000000000000000000000000000000000000000; // OracleRouter déployé

    // Tokens (Base)
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant WBTC = 0x0555E30da8f98308EdB960aa94C0Db47230d2B9c;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // =========================
    // ⚙️ CONFIG STRIKES
    // =========================

    /// @notice Nombre de strikes de chaque côté de l'ATM.
    /// STRIKES_PER_SIDE = 5 → 11 strikes au total (ATM ± 5 * step).
    uint8 constant STRIKES_PER_SIDE = 5;

    // =========================
    // 🕒 ÉCHÉANCES À RENSEIGNER
    // =========================
    // Remplis avec tes timestamps d’expiration (Unix, secondes).
    // Exemple: 2025-01-31 08:00:00 UTC → 1738300800
    uint64 constant EXPIRY_1 = 0; // TODO: set real timestamp
    uint64 constant EXPIRY_2 = 0; // TODO: set real timestamp
    // Tu peux en ajouter d’autres en dupliquant le schéma.

    function run() external {
        vm.startBroadcast(OWNER);

        OptionProductRegistry reg = OptionProductRegistry(OPTION_REGISTRY);
        OracleRouter oracle       = OracleRouter(ORACLE_ROUTER_ADDR);

        // 1) WBTC / USDC
        {
            uint64[] memory expiries = _buildExpiriesArray();
            _listWBTCWithOracle(reg, oracle, expiries);
        }

        // 2) WETH / USDC
        {
            uint64[] memory expiries = _buildExpiriesArray();
            _listWETHWithOracle(reg, oracle, expiries);
        }

        vm.stopBroadcast();
    }

    // =========================================================
    // 🧱 Construction des expiries
    // =========================================================

    /// @dev Construit un petit tableau d’échéances.
    /// Tu peux adapter pour avoir des expiries différentes entre WBTC et WETH
    /// (en dupliquant la fonction ou en faisant deux versions).
    function _buildExpiriesArray() internal pure returns (uint64[] memory expiries) {
        // Exemple avec 2 expiries
        expiries = new uint64;
        expiries[0] = EXPIRY_1;
        expiries[1] = EXPIRY_2;
    }

    // =========================================================
    // 📈 WBTC : listing avec step dynamique
    // =========================================================

    function _listWBTCWithOracle(
        OptionProductRegistry reg,
        OracleRouter oracle,
        uint64[] memory expiries
    ) internal {
        (uint256 spot, uint256 updatedAt) = oracle.getPrice(WBTC, USDC);
        require(spot > 0, "WBTC:NO_SPOT");
        require(updatedAt != 0, "WBTC:NO_TIMESTAMP");

        for (uint256 i = 0; i < expiries.length; i++) {
            uint64 expiry = expiries[i];
            require(expiry != 0, "WBTC:EXPIRY_ZERO");
            require(expiry > block.timestamp, "WBTC:EXPIRY_IN_PAST");

            uint64 step1e8 = _computeStepBtc(spot, expiry);
            require(step1e8 > 0, "WBTC:STEP_ZERO");

            // ATM = floor(spot / step) * step
            uint256 atm = (spot / uint256(step1e8)) * uint256(step1e8);
            require(
                atm > uint256(STRIKES_PER_SIDE) * uint256(step1e8),
                "WBTC:ATM_TOO_LOW"
            );

            uint64[] memory strikes = _buildStrikesAroundATM(
                atm,
                step1e8,
                STRIKES_PER_SIDE
            );

            // Crée toutes les séries Call + Put pour cette échéance
            reg.createStrip(
                WBTC,
                USDC,
                expiry,
                strikes,
                true // Européennes
            );
        }
    }

    // =========================================================
    // 📈 WETH : listing avec step dynamique
    // =========================================================

    function _listWETHWithOracle(
        OptionProductRegistry reg,
        OracleRouter oracle,
        uint64[] memory expiries
    ) internal {
        (uint256 spot, uint256 updatedAt) = oracle.getPrice(WETH, USDC);
        require(spot > 0, "WETH:NO_SPOT");
        require(updatedAt != 0, "WETH:NO_TIMESTAMP");

        for (uint256 i = 0; i < expiries.length; i++) {
            uint64 expiry = expiries[i];
            require(expiry != 0, "WETH:EXPIRY_ZERO");
            require(expiry > block.timestamp, "WETH:EXPIRY_IN_PAST");

            uint64 step1e8 = _computeStepEth(spot, expiry);
            require(step1e8 > 0, "WETH:STEP_ZERO");

            // ATM = floor(spot / step) * step
            uint256 atm = (spot / uint256(step1e8)) * uint256(step1e8);
            require(
                atm > uint256(STRIKES_PER_SIDE) * uint256(step1e8),
                "WETH:ATM_TOO_LOW"
            );

            uint64[] memory strikes = _buildStrikesAroundATM(
                atm,
                step1e8,
                STRIKES_PER_SIDE
            );

            reg.createStrip(
                WETH,
                USDC,
                expiry,
                strikes,
                true // Européennes
            );
        }
    }

    // =========================================================
    // 🧮 Logique de step "à la Deribit"
    // =========================================================

    /// @dev Step dynamique pour BTC, en fonction du spot (1e8) et de la maturité.
    /// Règle simple :
    ///  - Spot < 30k$  → base step = 500$
    ///  - 30k–60k$     → base step = 1 000$
    ///  - > 60k$       → base step = 2 000$
    /// puis :
    ///  - TTE <= 7j    → step /= 2 (grille plus fine)
    ///  - TTE >= 60j   → step *= 2 (grille plus large)
    function _computeStepBtc(uint256 spot1e8, uint64 expiry)
        internal
        view
        returns (uint64 step1e8)
    {
        uint256 tte = expiry > block.timestamp ? expiry - block.timestamp : 0;

        // Base step selon niveau de prix
        if (spot1e8 < 30_000 * 1e8) {
            step1e8 = uint64(500 * 1e8);
        } else if (spot1e8 < 60_000 * 1e8) {
            step1e8 = uint64(1_000 * 1e8);
        } else {
            step1e8 = uint64(2_000 * 1e8);
        }

        // Ajustement par maturité
        if (tte > 0 && tte <= 7 days) {
            step1e8 = step1e8 / 2;
        } else if (tte >= 60 days) {
            step1e8 = step1e8 * 2;
        }

        // Fallback défensif (au cas où)
        if (step1e8 == 0) {
            step1e8 = uint64(500 * 1e8);
        }
    }

    /// @dev Step dynamique pour ETH, en fonction du spot (1e8) et de la maturité.
    /// Règle simple :
    ///  - Spot < 2 000$ → base step = 25$
    ///  - 2k–5k$        → base step = 50$
    ///  - > 5k$         → base step = 100$
    /// puis :
    ///  - TTE <= 7j     → step /= 2
    ///  - TTE >= 60j    → step *= 2
    function _computeStepEth(uint256 spot1e8, uint64 expiry)
        internal
        view
        returns (uint64 step1e8)
    {
        uint256 tte = expiry > block.timestamp ? expiry - block.timestamp : 0;

        if (spot1e8 < 2_000 * 1e8) {
            step1e8 = uint64(25 * 1e8);
        } else if (spot1e8 < 5_000 * 1e8) {
            step1e8 = uint64(50 * 1e8);
        } else {
            step1e8 = uint64(100 * 1e8);
        }

        if (tte > 0 && tte <= 7 days) {
            step1e8 = step1e8 / 2;
        } else if (tte >= 60 days) {
            step1e8 = step1e8 * 2;
        }

        if (step1e8 == 0) {
            step1e8 = uint64(25 * 1e8);
        }
    }

    // =========================================================
    // 🧮 Construction de la grille de strikes
    // =========================================================

    /// @dev Construit le tableau des strikes :
    ///     baseStrike = ATM - N * step
    ///     puis baseStrike + k * step pour k = 0..(2N)
    function _buildStrikesAroundATM(
        uint256 atm,
        uint64 step1e8,
        uint8 strikesPerSide
    ) internal pure returns (uint64[] memory strikes) {
        uint256 totalStrikes = uint256(strikesPerSide) * 2 + 1;
        strikes = new uint64[](totalStrikes);

        uint256 step = uint256(step1e8);
        uint256 baseStrike = atm - uint256(strikesPerSide) * step;

        for (uint256 i = 0; i < totalStrikes; i++) {
            uint256 strike = baseStrike + i * step;
            strikes[i] = uint64(strike); // ok tant qu'on reste dans des valeurs raisonnables
        }
    }
}
