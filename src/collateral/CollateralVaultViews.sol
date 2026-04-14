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
                        AUTHORIZED ENGINE VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the legacy primary engine pointer.
    /// @dev Kept for backward compatibility with existing integrations.
    function getPrimaryMarginEngine() external view returns (address) {
        return marginEngine;
    }

    /// @notice Returns whether an engine is authorized to call privileged vault hooks.
    function isEngineAuthorized(address engine) external view returns (bool) {
        return _isAuthorizedEngine(engine);
    }

    /// @notice Returns the list of engines that have been allowlisted at least once.
    /// @dev
    ///  Some returned engines may currently be disabled in `isAuthorizedEngine`.
    ///  This list is still useful for governance / monitoring / tests.
    function getAuthorizedEngines() external view returns (address[] memory) {
        return _getAuthorizedEngines();
    }

    /// @notice Returns whether an account is considered a protocol account.
    function isProtocolAccount(address account) external view returns (bool) {
        return _isProtocolAccount(account);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Economic balance view: idle + strategy-backed assets value.
    /// @dev Safe-view: if previewRedeem reverts, returns idle only.
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

    /// @notice Returns strategy-backed assets preview only.
    /// @dev Safe-view: returns 0 on preview failure.
    function strategyAssetsPreview(address user, address token) external view returns (uint256 assetsFromShares) {
        uint256 shares = strategyShares[user][token];
        address adapter = tokenStrategy[token];

        if (shares == 0 || adapter == address(0)) return 0;

        try IYieldAdapter(adapter).previewRedeem(shares) returns (uint256 a) {
            return a;
        } catch {
            return 0;
        }
    }

    /// @notice Returns a compact account state view for one user/token pair.
    function getAccountTokenState(address user, address token)
        external
        view
        returns (
            uint256 balanceClaimable,
            uint256 idle,
            uint256 shares,
            uint256 assetsFromShares,
            uint256 effective,
            bool yieldEnabled,
            address strategy
        )
    {
        balanceClaimable = balances[user][token];
        idle = idleBalances[user][token];
        shares = strategyShares[user][token];
        yieldEnabled = yieldOptIn[user][token];
        strategy = tokenStrategy[token];

        if (shares != 0 && strategy != address(0)) {
            try IYieldAdapter(strategy).previewRedeem(shares) returns (uint256 a) {
                assetsFromShares = a;
            } catch {
                assetsFromShares = 0;
            }
        }

        effective = idle + assetsFromShares;
    }

    /// @notice Invariant diagnostic helper for tests / monitoring.
    /// @dev
    ///  - balanceClaimable = synced accounting value
    ///  - idle = liquid local part
    ///  - shares = shares held in the adapter
    ///  - assetsFromShares = preview value of shares
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