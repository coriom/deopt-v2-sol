// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./CollateralVaultStorage.sol";

abstract contract CollateralVaultAdmin is CollateralVaultStorage {
    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP MANAGEMENT (2-step)
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotAuthorized();
        address oldOwner = owner;
        owner = po;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, owner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSABLE
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN / CONFIG
    //////////////////////////////////////////////////////////////*/

    function setMarginEngine(address _marginEngine) external onlyOwner {
        if (_marginEngine == address(0)) revert ZeroAddress();
        marginEngine = _marginEngine;
        emit MarginEngineSet(_marginEngine);
    }

    function setRiskModule(address _riskModule) external onlyOwner {
        if (_riskModule == address(0)) revert ZeroAddress();
        riskModule = IRiskModule(_riskModule);
        emit RiskModuleSet(_riskModule);
    }

    function setCollateralToken(address token, bool isSupported, uint8 decimals, uint16 collateralFactorBps)
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        if (collateralFactorBps > 10_000) revert FactorTooHigh();
        if (isSupported && decimals == 0) revert BadDecimals();

        _collateralConfigs[token] = CollateralTokenConfig({
            isSupported: isSupported,
            decimals: decimals,
            collateralFactorBps: collateralFactorBps
        });

        if (!isCollateralTokenListed[token]) {
            isCollateralTokenListed[token] = true;
            collateralTokens.push(token);
        }

        emit CollateralTokenConfigured(token, isSupported, decimals, collateralFactorBps);
    }

    /// @notice Configure un adapter de rendement pour un token.
    /// @dev
    ///  - interdit de changer d’adapter si des shares sont encore actives
    ///  - autorise adapter = address(0) pour désactiver la stratégie
    ///  - si adapter != 0, l’asset de l’adapter doit matcher le token
    function setTokenStrategy(address token, address adapter) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        CollateralTokenConfig memory cfg = _collateralConfigs[token];
        if (!cfg.isSupported) revert TokenNotSupported();

        address old = tokenStrategy[token];
        if (old != address(0) && old != adapter) {
            if (tokenTotalStrategyShares[token] != 0) revert StrategyChangeNotAllowedWithActiveShares();

            try IYieldAdapter(old).totalShares() returns (uint256 ts) {
                if (ts != 0) revert StrategyChangeNotAllowedWithActiveShares();
            } catch {
                revert StrategyChangeNotAllowedWithActiveShares();
            }
        }

        if (adapter != address(0)) {
            if (IYieldAdapter(adapter).asset() != token) revert StrategyMismatch();
        }

        tokenStrategy[token] = adapter;
        emit TokenStrategySet(token, adapter);
    }
}