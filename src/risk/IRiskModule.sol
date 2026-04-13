// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRiskModule
/// @notice Unified protocol risk interface for DeOpt v2.
/// @dev
///  Target role:
///   - source of truth for global account risk across shared collateral
///   - options stack compatibility today
///   - extensible toward options + perps unified cross-margin
///
///  Canonical conventions:
///   - PRICE_SCALE = 1e8
///   - BPS = 10_000
///   - all fields suffixed `Base` are expressed in native units of the protocol base collateral token
///   - all fields suffixed `Bps` are expressed in basis points
///   - equity may be negative
///
///  Integration notes:
///   - `getWithdrawableAmount()` may be called in best-effort mode by CollateralVault via staticcall
///   - `previewWithdrawImpact()` is intended for withdrawal surfaces
///   - richer decomposition helpers are exposed to avoid duplicating protocol accounting offchain
interface IRiskModule {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimal unified account risk snapshot.
    /// @dev All amounts are denominated in native units of the protocol base collateral token.
    struct AccountRisk {
        int256 equityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
    }

    /// @notice Detailed withdrawal preview.
    /// @dev
    ///  - `requestedAmount` and `maxWithdrawable` are denominated in the withdrawn token native units
    ///  - margin ratios are in basis points
    ///  - marginRatio = equity / maintenanceMargin
    ///      * 0 if equity <= 0
    ///      * max uint if maintenanceMargin == 0
    struct WithdrawPreview {
        uint256 requestedAmount;
        uint256 maxWithdrawable;
        uint256 marginRatioBeforeBps;
        uint256 marginRatioAfterBps;
        bool wouldBreachMargin;
    }

    /// @notice Collateral-side decomposition in base-token native units.
    struct CollateralState {
        uint256 grossCollateralValueBase; // before haircut
        uint256 adjustedCollateralValueBase; // after haircut / collateral factors
    }

    /// @notice Product-side decomposition in base-token native units.
    /// @dev
    ///  Current implementations may leave some fields at zero if the product
    ///  is not wired yet. The interface is intentionally forward-compatible.
    struct ProductRiskState {
        int256 unrealizedPnlBase;
        int256 fundingAccruedBase;
        uint256 optionsInitialMarginBase;
        uint256 optionsMaintenanceMarginBase;
        uint256 perpsInitialMarginBase;
        uint256 perpsMaintenanceMarginBase;
        uint256 residualBadDebtBase;
    }

    /// @notice Full decomposed global risk state in base-token native units.
    struct AccountRiskBreakdown {
        int256 equityBase;
        uint256 maintenanceMarginBase;
        uint256 initialMarginBase;
        CollateralState collateral;
        ProductRiskState products;
    }

    /*//////////////////////////////////////////////////////////////
                                CORE VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Unified protocol account risk.
    function computeAccountRisk(address trader) external view returns (AccountRisk memory risk);

    /// @notice Unified free collateral = equity - initialMargin, in base-token native units.
    function computeFreeCollateral(address trader) external view returns (int256 freeCollateralBase);

    /// @notice Unified margin ratio in basis points.
    function computeMarginRatioBps(address trader) external view returns (uint256);

    /// @notice Full decomposed unified account risk.
    function computeAccountRiskBreakdown(address trader)
        external
        view
        returns (AccountRiskBreakdown memory breakdown);

    /*//////////////////////////////////////////////////////////////
                            WITHDRAW HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Max withdrawable amount in token native units without breaking constraints.
    function getWithdrawableAmount(address trader, address token) external view returns (uint256 amount);

    /// @notice Detailed preview of a withdrawal.
    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        returns (WithdrawPreview memory preview);

    /*//////////////////////////////////////////////////////////////
                        PRODUCT / COLLATERAL BREAKDOWNS
    //////////////////////////////////////////////////////////////*/

    /// @notice Haircut-adjusted collateral state in base-token native units.
    function computeCollateralState(address trader) external view returns (CollateralState memory state);

    /// @notice Product-side risk decomposition in base-token native units.
    function computeProductRiskState(address trader) external view returns (ProductRiskState memory state);

    /// @notice Residual bad debt consumed by unified risk, in base-token native units.
    function getResidualBadDebt(address trader) external view returns (uint256 amountBase);

    /*//////////////////////////////////////////////////////////////
                            PARAMS / CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Protocol base collateral token used as the unified risk numeraire.
    function baseCollateralToken() external view returns (address);

    /// @notice Native decimals of the base collateral token.
    function baseDecimals() external view returns (uint8);

    /// @dev Legacy options-side config getter kept for compatibility.
    ///      Denominated in base-token native units.
    function baseMaintenanceMarginPerContract() external view returns (uint256);

    /// @dev Legacy options-side config getter kept for compatibility.
    ///      Expressed in basis points.
    function imFactorBps() external view returns (uint256);
}