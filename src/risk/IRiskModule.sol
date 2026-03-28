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
///  Conventions:
///   - PRICE_SCALE = 1e8
///   - BPS = 10_000
///   - all margin / equity / pnl / bad debt fields are expressed in native base-collateral units
///   - equity may be negative
///
///  Integration notes:
///   - `getWithdrawableAmount()` may be called in best-effort mode by CollateralVault via staticcall
///   - `previewWithdrawImpact()` is intended for withdrawal surfaces
///   - richer decomposition helpers are exposed to avoid duplicating protocol accounting offchain
interface IRiskModule {
    uint256 constant PRICE_SCALE = 1e8;
    uint256 constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimal unified account risk snapshot.
    struct AccountRisk {
        int256 equity; // base collateral units
        uint256 maintenanceMargin; // base collateral units
        uint256 initialMargin; // base collateral units
    }

    /// @notice Detailed withdrawal preview.
    /// @dev marginRatio = equity / maintenanceMargin in bps
    ///      - 0 if equity <= 0
    ///      - max uint if maintenanceMargin == 0
    struct WithdrawPreview {
        uint256 requestedAmount;
        uint256 maxWithdrawable;
        uint256 marginRatioBeforeBps;
        uint256 marginRatioAfterBps;
        bool wouldBreachMargin;
    }

    /// @notice Collateral-side decomposition in base units.
    struct CollateralState {
        uint256 grossCollateralValue; // before haircut
        uint256 adjustedCollateralValue; // after haircut / collateral factors
    }

    /// @notice Product-side decomposition in base units.
    /// @dev
    ///  Current implementations may leave some fields at zero if the product
    ///  is not wired yet. The interface is intentionally forward-compatible.
    struct ProductRiskState {
        int256 unrealizedPnl;
        int256 fundingAccrued;
        uint256 optionsInitialMargin;
        uint256 optionsMaintenanceMargin;
        uint256 perpsInitialMargin;
        uint256 perpsMaintenanceMargin;
        uint256 residualBadDebt;
    }

    /// @notice Full decomposed global risk state.
    struct AccountRiskBreakdown {
        int256 equity;
        uint256 maintenanceMargin;
        uint256 initialMargin;
        CollateralState collateral;
        ProductRiskState products;
    }

    /*//////////////////////////////////////////////////////////////
                                CORE VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Unified protocol account risk.
    function computeAccountRisk(address trader) external view returns (AccountRisk memory risk);

    /// @notice Unified free collateral = equity - initialMargin.
    function computeFreeCollateral(address trader) external view returns (int256 freeCollateral);

    /// @notice Unified margin ratio in bps.
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

    /// @notice Haircut-adjusted collateral state in base units.
    function computeCollateralState(address trader) external view returns (CollateralState memory state);

    /// @notice Product-side risk decomposition in base units.
    function computeProductRiskState(address trader) external view returns (ProductRiskState memory state);

    /// @notice Residual bad debt consumed by unified risk, in base units.
    function getResidualBadDebt(address trader) external view returns (uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            PARAMS / CONFIG
    //////////////////////////////////////////////////////////////*/

    function baseCollateralToken() external view returns (address);
    function baseDecimals() external view returns (uint8);

    /// @dev Legacy options-side config getter kept for compatibility.
    function baseMaintenanceMarginPerContract() external view returns (uint256);

    /// @dev Legacy options-side config getter kept for compatibility.
    function imFactorBps() external view returns (uint256);
}