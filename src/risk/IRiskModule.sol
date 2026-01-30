// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface générique pour un module de risque DeOpt.
/// @dev Conventions:
///  - strike / spot / settlementPrice sont en 1e8 (PRICE_SCALE) côté registry/oracles.
///  - Le protocole est verrouillé sur USDC 6 décimales comme baseCollateralToken (côté impl),
///    mais cette interface reste générique en "devise de base".
///  - La taille de contrat est hard-lock à 1e8 dans OptionProductRegistry (1 contrat = 1 underlying),
///    donc les impls peuvent supposer contractSize1e8 == 1e8, mais ne doivent pas casser si futur.
///  - Quantity hardening: l'implémentation doit supposer que MarginEngine n'autorise jamais int128.min.
interface IRiskModule {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Vue agrégée du risque d'un compte.
    /// @dev Toutes les valeurs sont exprimées en "devise de base" (baseCollateralToken, ex: USDC 1e6).
    struct AccountRisk {
        int256 equity;             // Valeur totale du compte en base (peut être négative)
        uint256 maintenanceMargin; // Marge de maintenance requise en base
        uint256 initialMargin;     // Marge initiale requise en base
    }

    /// @notice Prévisualisation de l'impact d'un retrait de collatéral.
    /// @dev
    ///  - requestedAmount / maxWithdrawable sont en unités natives du token.
    ///  - marginRatio* sont en bps: equity / MM * 1e4 (ou max si MM==0).
    struct WithdrawPreview {
        uint256 requestedAmount;       // Montant demandé (unités token)
        uint256 maxWithdrawable;       // Montant max "safe" (unités token)
        uint256 marginRatioBeforeBps;  // ratio avant
        uint256 marginRatioAfterBps;   // ratio après (si simulable)
        bool wouldBreachMargin;        // true si le retrait demandé casse la contrainte
    }

    /*//////////////////////////////////////////////////////////////
                              CORE RISK VIEW
    //////////////////////////////////////////////////////////////*/

    function computeAccountRisk(address trader)
        external
        view
        returns (AccountRisk memory risk);

    function computeFreeCollateral(address trader)
        external
        view
        returns (int256 freeCollateral);

    /// @notice Ratio de marge en bps: equity / maintenanceMargin * 1e4.
    /// @dev Retourne type(uint256).max si maintenanceMargin == 0. Retourne 0 si equity <= 0.
    function computeMarginRatioBps(address trader)
        external
        view
        returns (uint256);

    /*//////////////////////////////////////////////////////////////
                       WITHDRAW LIMITS (LEGACY V1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Montant max retirable "legacy" (en unités du token).
    /// @dev Conservé pour compat CollateralVault, mais l’UX doit utiliser previewWithdrawImpact().
    function getWithdrawableAmount(address trader, address token)
        external
        view
        returns (uint256 amount);

    /*//////////////////////////////////////////////////////////////
                    WITHDRAW PREVIEW (UX-FRIENDLY V2)
    //////////////////////////////////////////////////////////////*/

    function previewWithdrawImpact(
        address trader,
        address token,
        uint256 amount
    ) external view returns (WithdrawPreview memory preview);

    /*//////////////////////////////////////////////////////////////
                           OPTIONAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Base collateral token (ex: USDC).
    /// @dev Permet aux autres modules de vérifier la cohérence sans lire l’impl.
    function baseCollateralToken() external view returns (address);

    /// @notice Décimales de la base (ex: 6 pour USDC).
    function baseDecimals() external view returns (uint8);
}
