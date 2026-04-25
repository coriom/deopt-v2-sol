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

        emit OwnershipTransferred(oldOwner, po);
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
                              GUARDIAN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the emergency guardian.
    /// @dev address(0) is allowed to disable the guardian.
    function setGuardian(address newGuardian) external onlyOwner {
        _setGuardian(newGuardian);
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Legacy global pause.
    /// @dev Guardian or owner may trigger emergency freeze.
    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
            emit GlobalPauseSet(true);
        }
    }

    /// @notice Clears legacy global pause.
    /// @dev Owner only.
    function unpause() external onlyOwner {
        if (paused) {
            paused = false;
            emit Unpaused(msg.sender);
            emit GlobalPauseSet(false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        GRANULAR EMERGENCY CONTROLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency freeze of deposits.
    function pauseDeposits() external onlyGuardianOrOwner {
        if (!depositsPaused) {
            depositsPaused = true;
            emit DepositPauseSet(true);
            emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
        }
    }

    function unpauseDeposits() external onlyOwner {
        if (depositsPaused) {
            depositsPaused = false;
            emit DepositPauseSet(false);
            emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
        }
    }

    /// @notice Emergency freeze of withdrawals.
    function pauseWithdrawals() external onlyGuardianOrOwner {
        if (!withdrawalsPaused) {
            withdrawalsPaused = true;
            emit WithdrawalPauseSet(true);
            emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
        }
    }

    function unpauseWithdrawals() external onlyOwner {
        if (withdrawalsPaused) {
            withdrawalsPaused = false;
            emit WithdrawalPauseSet(false);
            emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
        }
    }

    /// @notice Emergency freeze of internal protocol account transfers.
    function pauseInternalTransfers() external onlyGuardianOrOwner {
        if (!internalTransfersPaused) {
            internalTransfersPaused = true;
            emit InternalTransferPauseSet(true);
            emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
        }
    }

    function unpauseInternalTransfers() external onlyOwner {
        if (internalTransfersPaused) {
            internalTransfersPaused = false;
            emit InternalTransferPauseSet(false);
            emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
        }
    }

    /// @notice Emergency freeze of yield strategy operations.
    function pauseYieldOps() external onlyGuardianOrOwner {
        if (!yieldOpsPaused) {
            yieldOpsPaused = true;
            emit YieldOpsPauseSet(true);
            emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
        }
    }

    function unpauseYieldOps() external onlyOwner {
        if (yieldOpsPaused) {
            yieldOpsPaused = false;
            emit YieldOpsPauseSet(false);
            emit EmergencyModeUpdated(depositsPaused, withdrawalsPaused, internalTransfersPaused, yieldOpsPaused);
        }
    }

    /// @notice Sets all granular emergency flags in one transaction.
    function setEmergencyModes(
        bool depositsPaused_,
        bool withdrawalsPaused_,
        bool internalTransfersPaused_,
        bool yieldOpsPaused_
    ) external onlyGuardianOrOwner {
        _setEmergencyModes(depositsPaused_, withdrawalsPaused_, internalTransfersPaused_, yieldOpsPaused_);
    }

    /// @notice Owner-only helper to clear all granular emergency flags.
    function clearEmergencyModes() external onlyOwner {
        _setEmergencyModes(false, false, false, false);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN / ENGINE CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the legacy primary engine and auto-authorizes it.
    /// @dev Backward-compatible entrypoint preserved for existing governance/integration.
    function setMarginEngine(address _marginEngine) external onlyOwner {
        _setPrimaryMarginEngine(_marginEngine);
    }

    /// @notice Authorize or deauthorize an engine contract.
    /// @dev Supports multi-product setup: options engine + perp engine + future engines.
    function setAuthorizedEngine(address engine, bool allowed) external onlyOwner {
        _setAuthorizedEngine(engine, allowed);
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN / RISK
    //////////////////////////////////////////////////////////////*/

    function setRiskModule(address _riskModule) external onlyOwner {
        _setRiskModule(_riskModule);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN / COLLATERAL CONFIG
    //////////////////////////////////////////////////////////////*/

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

        _listCollateralTokenIfNeeded(token);

        emit CollateralTokenConfigured(token, isSupported, decimals, collateralFactorBps);
    }

    /// @notice Sets an optional launch-safety cap for aggregate deposits of one supported token.
    /// @dev `cap == 0` disables the cap. Lowering below current aggregate only blocks further deposits.
    function setTokenDepositCap(address token, uint256 cap) external onlyOwner {
        _requireSupportedToken(token);

        uint256 oldCap = tokenDepositCap[token];
        tokenDepositCap[token] = cap;

        emit TokenDepositCapSet(token, oldCap, cap);
    }

    /// @notice Enables or disables launch-time collateral-universe restriction mode.
    /// @dev When enabled, only tokens flagged through `setLaunchActiveCollateral` may enter through deposit ingress.
    function setCollateralRestrictionMode(bool enabled) external onlyOwner {
        collateralRestrictionMode = enabled;
        emit CollateralRestrictionModeSet(enabled);
    }

    /// @notice Marks a supported token as launch-active or launch-inactive collateral.
    /// @dev Independent from support/configuration; only enforced when restriction mode is enabled.
    function setLaunchActiveCollateral(address token, bool isActive) external onlyOwner {
        _requireSupportedToken(token);
        launchActiveCollateral[token] = isActive;
        emit LaunchActiveCollateralSet(token, isActive);
    }

    /*//////////////////////////////////////////////////////////////
                        ADMIN / YIELD STRATEGY
    //////////////////////////////////////////////////////////////*/

    /// @notice Configure a yield adapter for a token.
    /// @dev
    ///  - forbids changing adapter while strategy shares are still active
    ///  - allows adapter = address(0) to disable the strategy
    ///  - if adapter != 0, adapter.asset() must match token
    function setTokenStrategy(address token, address adapter) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();

        CollateralTokenConfig memory cfg = _requireSupportedToken(token);

        if (cfg.decimals == 0) revert BadDecimals();

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

        _listCollateralTokenIfNeeded(token);

        tokenStrategy[token] = adapter;
        emit TokenStrategySet(token, adapter);
    }
}
