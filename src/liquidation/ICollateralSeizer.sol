// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ICollateralSeizer
/// @notice Conservative multi-collateral seizure planner valued in protocol base collateral units.
/// @dev
///  This component is intentionally a planning / valuation surface only.
///  It does not execute transfers itself.
///
/// exposed surface:
///   - conservative seizure plan computation
///   - effective token discount inspection
///   - valuation previews used by liquidation engines
///
///  Conventions:
///   - `base` = protocol reference collateral token
///   - every `...Base...` value is expressed in native units of the base token
///   - every `amountToken` value is expressed in native units of the corresponding token
///   - outputs are expected to be conservative floors unless stated otherwise
interface ICollateralSeizer {
    /// @notice Builds a seizure plan intended to cover `targetBaseAmount`.
    /// @dev
    ///  Expected properties:
    ///   - conservative result
    ///   - `baseCovered` may be strictly below `targetBaseAmount` if account collateral is insufficient
    ///   - `tokensOut.length == amountsOut.length`
    ///   - arrays are parallel-indexed
    ///
    /// @param trader Account whose collateral would be seized
    /// @param targetBaseAmount Target coverage amount, in native base token units
    ///
    /// @return tokensOut Tokens selected in the seizure plan
    /// @return amountsOut Planned seizure amounts, in native units of each token
    /// @return baseCovered Conservative effective coverage, in native base token units
    function computeSeizurePlan(address trader, uint256 targetBaseAmount)
        external
        view
        returns (address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered);

    /// @notice Returns the effective conservative discount applied to a token.
    /// @dev
    ///  Typical shape:
    ///   effectiveDiscountBps = riskWeightBps * (BPS - liquidationSpreadBps) / BPS
    ///  but the exact formula is implementation-defined.
    ///
    /// @param token Token being valued
    /// @return discountBps Effective conservative discount in basis points
    function tokenDiscountBps(address token) external view returns (uint256 discountBps);

    /// @notice Previews raw and effective base value for a token amount.
    /// @dev
    ///  - `valueBaseFloor` = raw floor value in base units
    ///  - `effectiveBaseFloor` = conservative post-discount floor value in base units
    ///  - `ok=false` means the token cannot be safely valued in the current context
    ///
    /// @param token Token being valued
    /// @param amountToken Token amount, in native token units
    ///
    /// @return valueBaseFloor Raw floor value in native base token units
    /// @return effectiveBaseFloor Effective conservative floor value in native base token units
    /// @return ok True if preview is usable
    function previewEffectiveBaseValue(address token, uint256 amountToken)
        external
        view
        returns (uint256 valueBaseFloor, uint256 effectiveBaseFloor, bool ok);
}