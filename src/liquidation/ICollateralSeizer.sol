// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICollateralSeizer
/// @notice Interface planner de saisie multi-collat valorisée en base (haircuts + spreads).
interface ICollateralSeizer {
    /// @notice Construit un plan de saisie pour couvrir `targetBaseAmount` (unités base token).
    /// @return tokensOut tokens saisis
    /// @return amountsOut montants saisis (unités natives token)
    /// @return baseCovered valeur effective couverte (unités base token), conservative floor
    function computeSeizurePlan(address trader, uint256 targetBaseAmount)
        external
        view
        returns (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered);

    /// @notice Discount appliqué à un token: weightBps (RiskModule) * (1 - spreadBps) (Seizer), en bps.
    function tokenDiscountBps(address token) external view returns (uint256);

    /// @notice Debug: valeur brute base + valeur effective (haircut+spread) pour amountToken.
    function previewEffectiveBaseValue(address token, uint256 amountToken)
        external
        view
        returns (uint256 valueBaseFloor, uint256 effectiveBaseFloor, bool ok);
}
