// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface générique pour un module de risque DeOpt.
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
        uint256 maxWithdrawable;       // Montant maximum "sûr" que le module autorise (en unités du token)
        uint256 marginRatioBeforeBps;  // ratio de marge avant retrait: equity / MM * 1e4
        uint256 marginRatioAfterBps;   // ratio de marge après retrait "requestedAmount" (si possible)
        bool wouldBreachMargin;        // true si le retrait demandé ferait passer sous le seuil de liquidation
    }

    /*//////////////////////////////////////////////////////////////
                              CORE RISK VIEW
    //////////////////////////////////////////////////////////////*/

    /// @notice Calcule les métriques de risque pour un trader donné.
    /// @param trader Adresse du compte à analyser
    /// @return risk Structure contenant equity, MM et IM
    function computeAccountRisk(address trader)
        external
        view
        returns (AccountRisk memory risk);

    /// @notice Equity disponible après déduction de l'IM: equity - initialMargin (peut être négatif).
    /// @dev Exprimé en unités de baseCollateralToken (mêmes décimales).
    function computeFreeCollateral(address trader)
        external
        view
        returns (int256 freeCollateral);

    /*//////////////////////////////////////////////////////////////
                       WITHDRAW LIMITS (LEGACY V1)
    //////////////////////////////////////////////////////////////*/

    /// @notice Montant maximum retirable pour un token donné, en unités de ce token.
    /// @dev
    ///   - Tient compte de:
    ///       * la free collateral globale
    ///       * le haircut du token (weightBps)
    ///       * le prix oracle token/base (8 décimales)
    ///   - Si le token ne contribue pas à l'equity (désactivé, weight=0 ou pas de prix),
    ///     alors son retrait n'affecte pas la marge -> on autorise le retrait complet.
    function getWithdrawableAmount(address trader, address token)
        external
        view
        returns (uint256 amount);

    /*//////////////////////////////////////////////////////////////
                    WITHDRAW PREVIEW (UX-FRIENDLY V2)
    //////////////////////////////////////////////////////////////*/

    /// @notice Prévisualise l’impact d’un retrait sur le compte d’un trader.
    /// @param trader Compte concerné
    /// @param token  Token de collatéral que l’on souhaite retirer
    /// @param amount Montant demandé (en unités du token)
    /// @return preview Struct détaillant:
    ///           - requestedAmount
    ///           - maxWithdrawable
    ///           - marginRatioBeforeBps
    ///           - marginRatioAfterBps (si amount <= maxWithdrawable)
    ///           - wouldBreachMargin (true si le retrait demandé est "dangereux")
    function previewWithdrawImpact(
        address trader,
        address token,
        uint256 amount
    ) external view returns (WithdrawPreview memory preview);
}
