// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRiskModule
/// @notice Interface RiskModule compatible avec MarginEngine + CollateralVault.
/// @dev
///  - PRICE_SCALE = 1e8
///  - BPS = 10_000
///  - getWithdrawableAmount() est utilisé en best-effort hook par CollateralVault (staticcall)
///  - previewWithdrawImpact() est utilisé par MarginEngine.withdrawCollateral()
interface IRiskModule {
    uint256 constant PRICE_SCALE = 1e8;
    uint256 constant BPS = 10_000;

    /// @notice Résumé du risque d’un compte à l’instant t.
    /// @dev equity peut être négative.
    struct AccountRisk {
        int256 equity; // base collateral units
        uint256 maintenanceMargin; // base collateral units
        uint256 initialMargin; // base collateral units
    }

    /// @notice Prévisualisation d’un retrait.
    /// @dev marginRatio = equity / maintenanceMargin en bps (0 si equity<=0, max si MM=0)
    struct WithdrawPreview {
        uint256 requestedAmount;
        uint256 maxWithdrawable;
        uint256 marginRatioBeforeBps;
        uint256 marginRatioAfterBps;
        bool wouldBreachMargin;
    }

    /*//////////////////////////////////////////////////////////////
                                CORE VIEWS
    //////////////////////////////////////////////////////////////*/

    function computeAccountRisk(address trader) external view returns (AccountRisk memory risk);
    function computeFreeCollateral(address trader) external view returns (int256 freeCollateral);
    function computeMarginRatioBps(address trader) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Montant max retirable (token units) sans casser les contraintes.
    function getWithdrawableAmount(address trader, address token) external view returns (uint256 amount);

    /// @notice Preview détaillée d’un retrait.
    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        returns (WithdrawPreview memory preview);

    /*//////////////////////////////////////////////////////////////
                            PARAMS / CONFIG
    //////////////////////////////////////////////////////////////*/

    function baseCollateralToken() external view returns (address);
    function baseDecimals() external view returns (uint8);
    function baseMaintenanceMarginPerContract() external view returns (uint256);
    function imFactorBps() external view returns (uint256);
}