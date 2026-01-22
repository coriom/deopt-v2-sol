// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface générique pour un module de risque DeOpt.
/// @dev Conventions:
///  - strike / spot / settlementPrice sont en 1e8 (PRICE_SCALE) côté registry/oracles.
///  - La taille de contrat par série (contractSize1e8) est stockée dans OptionProductRegistry.OptionSeries
///    et doit être intégrée par l'implémentation pour scaler MM / liabilities / payoff par contrat.
interface IRiskModule {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Vue agrégée du risque d'un compte.
    /// @dev Toutes les valeurs sont exprimées en "devise de base" (baseCollateralToken).
    struct AccountRisk {
        int256 equity;             // Valeur totale du compte (collat + PnL latent éventuel)
        uint256 maintenanceMargin; // Marge de maintenance requise
        uint256 initialMargin;     // Marge initiale requise
    }

    /// @notice Prévisualisation de l'impact d'un retrait de collatéral.
    /// @dev Toutes les valeurs de marge / ratios sont exprimées en "devise de base".
    struct WithdrawPreview {
        uint256 requestedAmount;       // Montant demandé par l'utilisateur (en unités du token)
        uint256 maxWithdrawable;       // Montant maximum "sûr" autorisé (en unités du token)
        uint256 marginRatioBeforeBps;  // ratio avant: equity / MM * 1e4
        uint256 marginRatioAfterBps;   // ratio après "requestedAmount" (si possible)
        bool wouldBreachMargin;        // true si le retrait demandé passe sous les contraintes
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

    /*//////////////////////////////////////////////////////////////
                       WITHDRAW LIMITS (LEGACY V1)
    //////////////////////////////////////////////////////////////*/

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
}
