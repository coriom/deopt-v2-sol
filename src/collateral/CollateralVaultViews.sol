// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CollateralVaultYield.sol";

abstract contract CollateralVaultViews is CollateralVaultYield {
    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getCollateralTokens() external view returns (address[] memory) {
        return collateralTokens;
    }

    function collateralConfigs(address token) external view returns (CollateralTokenConfig memory cfg) {
        cfg = _collateralConfigs[token];
    }

    function collateralConfigsRaw(address token)
        external
        view
        returns (bool isSupported, uint8 decimals, uint16 collateralFactorBps)
    {
        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        return (cfg.isSupported, cfg.decimals, cfg.collateralFactorBps);
    }

    function getCollateralConfig(address token) external view returns (CollateralTokenConfig memory cfg) {
        cfg = _collateralConfigs[token];
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Vue économique réelle: idle + valeur des shares dans la stratégie.
    /// @dev Safe-view: si previewRedeem revert, retourne uniquement idle.
    function balanceWithYield(address user, address token) external view returns (uint256) {
        uint256 idle = idleBalances[user][token];
        uint256 shares = strategyShares[user][token];
        address adapter = tokenStrategy[token];

        if (shares == 0 || adapter == address(0)) return idle;

        try IYieldAdapter(adapter).previewRedeem(shares) returns (uint256 assetsFromShares) {
            return idle + assetsFromShares;
        } catch {
            return idle;
        }
    }

    /// @notice Diagnostic d’invariant utile pour tests / monitoring.
    /// @dev
    ///  - balanceClaimable = valeur comptable syncée
    ///  - idle = part liquide locale
    ///  - shares = parts détenues dans l’adapter
    ///  - assetsFromShares = valeur preview des shares
    ///  - effective = idle + assetsFromShares
    function checkInvariant(address user, address token)
        external
        view
        returns (uint256 balanceClaimable, uint256 idle, uint256 shares, uint256 assetsFromShares, uint256 effective)
    {
        balanceClaimable = balances[user][token];
        idle = idleBalances[user][token];
        shares = strategyShares[user][token];

        address adapter = tokenStrategy[token];
        if (shares != 0 && adapter != address(0)) {
            try IYieldAdapter(adapter).previewRedeem(shares) returns (uint256 a) {
                assetsFromShares = a;
            } catch {
                assetsFromShares = 0;
            }
        } else {
            assetsFromShares = 0;
        }

        effective = idle + assetsFromShares;
    }
}