// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICollateralSeizer
/// @notice Interface planner de saisie multi-collat valorisée en base (haircuts + spreads).
/// @dev
///  Le seizer est un composant de planification / valorisation conservatrice.
///  Il ne définit pas ici l’exécution de transfert; il expose uniquement:
///   - un plan de saisie,
///   - les discounts effectifs,
///   - des helpers de preview.
///
///  Convention:
///   - `base` = token de collatéral de référence du protocole
///   - toutes les valeurs `...Base...` sont exprimées en unités natives du base token
///   - toutes les valeurs `amountToken` sont exprimées en unités natives du token concerné
interface ICollateralSeizer {
    /// @notice Construit un plan de saisie pour couvrir `targetBaseAmount` (unités base token).
    /// @dev
    ///  - Le résultat est conservateur.
    ///  - `baseCovered` peut être inférieur à `targetBaseAmount` si le compte ne couvre pas assez.
    ///  - Les tableaux retournés ont la même longueur et sont indexés en parallèle.
    ///
    /// @param trader Compte dont le collatéral serait saisi
    /// @param targetBaseAmount Montant cible à couvrir, exprimé en unités natives du base token
    ///
    /// @return tokensOut Tokens retenus dans le plan de saisie
    /// @return amountsOut Montants saisis correspondants, en unités natives de chaque token
    /// @return baseCovered Valeur effective totale couverte, en unités natives du base token
    function computeSeizurePlan(address trader, uint256 targetBaseAmount)
        external
        view
        returns (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered);

    /// @notice Discount effectif appliqué à un token.
    /// @dev
    ///  Typiquement:
    ///   effectiveDiscountBps = riskWeightBps * (BPS - liquidationSpreadBps) / BPS
    ///  mais la formule exacte reste à l’implémentation.
    ///
    /// @param token Token à valoriser
    /// @return discountBps Discount effectif conservateur en basis points
    function tokenDiscountBps(address token) external view returns (uint256 discountBps);

    /// @notice Preview de valorisation brute et effective pour un montant donné.
    /// @dev
    ///  - `valueBaseFloor` = valeur brute floor en base
    ///  - `effectiveBaseFloor` = valeur après haircut / discount, conservative floor
    ///  - `ok=false` si le token n’est pas valorisable proprement dans le contexte courant
    ///
    /// @param token Token à valoriser
    /// @param amountToken Montant du token, en unités natives
    ///
    /// @return valueBaseFloor Valeur brute floor en unités natives du base token
    /// @return effectiveBaseFloor Valeur effective floor en unités natives du base token
    /// @return ok True si la preview est exploitable
    function previewEffectiveBaseValue(address token, uint256 amountToken)
        external
        view
        returns (uint256 valueBaseFloor, uint256 effectiveBaseFloor, bool ok);
}