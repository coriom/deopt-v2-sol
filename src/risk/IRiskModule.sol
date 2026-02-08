// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice IRiskModule (compatible MarginEngine/CollateralVault de ton codebase)
interface IRiskModule {
    uint256 constant PRICE_SCALE = 1e8;
    uint256 constant BPS = 10_000;

    struct AccountRisk {
        int256 equity;
        uint256 maintenanceMargin;
        uint256 initialMargin;
    }

    struct WithdrawPreview {
        uint256 requestedAmount;
        uint256 maxWithdrawable;
        uint256 marginRatioBeforeBps;
        uint256 marginRatioAfterBps;
        bool wouldBreachMargin;
    }

    function computeAccountRisk(address trader) external view returns (AccountRisk memory risk);
    function computeFreeCollateral(address trader) external view returns (int256 freeCollateral);
    function computeMarginRatioBps(address trader) external view returns (uint256);

    function getWithdrawableAmount(address trader, address token) external view returns (uint256 amount);

    function previewWithdrawImpact(address trader, address token, uint256 amount)
        external
        view
        returns (WithdrawPreview memory preview);

    function baseCollateralToken() external view returns (address);
    function baseDecimals() external view returns (uint8);
    function baseMaintenanceMarginPerContract() external view returns (uint256);
    function imFactorBps() external view returns (uint256);
}
