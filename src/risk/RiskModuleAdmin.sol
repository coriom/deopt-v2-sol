// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./RiskModuleMargin.sol";

abstract contract RiskModuleAdmin is RiskModuleMargin {
    /*//////////////////////////////////////////////////////////////
                                OWNERSHIP
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function renounceOwnership() external onlyOwner {
        address oldOwner = owner;
        owner = address(0);

        emit OwnershipTransferred(oldOwner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                GUARDIAN
    //////////////////////////////////////////////////////////////*/

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        _setGuardian(guardian_);
    }

    function clearGuardian() external onlyOwner {
        _setGuardian(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSE
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyGuardianOrOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender);
            emit GlobalPauseSet(true);
        }
    }

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

    function pauseRiskChecks() external onlyGuardianOrOwner {
        if (!riskChecksPaused) {
            riskChecksPaused = true;
            emit RiskChecksPauseSet(true);
            emit EmergencyModeUpdated(riskChecksPaused, collateralValuationPaused, withdrawPreviewPaused);
        }
    }

    function unpauseRiskChecks() external onlyOwner {
        if (riskChecksPaused) {
            riskChecksPaused = false;
            emit RiskChecksPauseSet(false);
            emit EmergencyModeUpdated(riskChecksPaused, collateralValuationPaused, withdrawPreviewPaused);
        }
    }

    function pauseCollateralValuation() external onlyGuardianOrOwner {
        if (!collateralValuationPaused) {
            collateralValuationPaused = true;
            emit CollateralValuationPauseSet(true);
            emit EmergencyModeUpdated(riskChecksPaused, collateralValuationPaused, withdrawPreviewPaused);
        }
    }

    function unpauseCollateralValuation() external onlyOwner {
        if (collateralValuationPaused) {
            collateralValuationPaused = false;
            emit CollateralValuationPauseSet(false);
            emit EmergencyModeUpdated(riskChecksPaused, collateralValuationPaused, withdrawPreviewPaused);
        }
    }

    function pauseWithdrawPreviews() external onlyGuardianOrOwner {
        if (!withdrawPreviewPaused) {
            withdrawPreviewPaused = true;
            emit WithdrawPreviewPauseSet(true);
            emit EmergencyModeUpdated(riskChecksPaused, collateralValuationPaused, withdrawPreviewPaused);
        }
    }

    function unpauseWithdrawPreviews() external onlyOwner {
        if (withdrawPreviewPaused) {
            withdrawPreviewPaused = false;
            emit WithdrawPreviewPauseSet(false);
            emit EmergencyModeUpdated(riskChecksPaused, collateralValuationPaused, withdrawPreviewPaused);
        }
    }

    function setEmergencyModes(
        bool riskChecksPaused_,
        bool collateralValuationPaused_,
        bool withdrawPreviewPaused_
    ) external onlyGuardianOrOwner {
        _setEmergencyModes(riskChecksPaused_, collateralValuationPaused_, withdrawPreviewPaused_);
    }

    function clearEmergencyModes() external onlyOwner {
        _setEmergencyModes(false, false, false);
    }

    /*//////////////////////////////////////////////////////////////
                                CONFIG
    //////////////////////////////////////////////////////////////*/

    function setMarginEngine(address _marginEngine) external onlyOwner {
        if (_marginEngine == address(0)) revert ZeroAddress();

        address old = address(marginEngine);
        marginEngine = IMarginEngineState(_marginEngine);

        emit MarginEngineSet(old, _marginEngine);
    }

    function setOracle(address _oracle) external onlyOwner {
        if (_oracle == address(0)) revert ZeroAddress();

        address old = address(oracle);
        oracle = IOracle(_oracle);

        emit OracleSet(old, _oracle);
    }

    function setMaxOracleDelay(uint256 _maxOracleDelay) external onlyOwner {
        if (_maxOracleDelay > 3600) revert InvalidParams();

        uint256 old = maxOracleDelay;
        maxOracleDelay = _maxOracleDelay;

        emit MaxOracleDelaySet(old, _maxOracleDelay);
    }

    function setOracleDownMmMultiplier(uint256 _multiplierBps) external onlyOwner {
        if (_multiplierBps < BPS_U || _multiplierBps > 100_000) revert InvalidParams();

        uint256 old = oracleDownMmMultiplierBps;
        oracleDownMmMultiplierBps = _multiplierBps;

        emit OracleDownMmMultiplierSet(old, _multiplierBps);
    }

    function setRiskParams(address _baseToken, uint256 _baseMMPerContract, uint256 _imFactorBps) external onlyOwner {
        if (_baseToken == address(0)) revert ZeroAddress();
        if (_baseMMPerContract == 0) revert InvalidParams();
        if (_imFactorBps < BPS_U) revert InvalidParams();

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(_baseToken);
        if (!baseCfg.isSupported) revert TokenNotSupportedInVault(_baseToken);
        if (baseCfg.decimals == 0) revert TokenDecimalsNotConfigured(_baseToken);
        if (uint256(baseCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(_baseToken);
        if (baseCfg.decimals != EXPECTED_BASE_DECIMALS) revert BaseTokenDecimalsNotUSDC(_baseToken, baseCfg.decimals);

        baseCollateralToken = _baseToken;
        baseMaintenanceMarginPerContract = _baseMMPerContract;
        imFactorBps = _imFactorBps;

        emit RiskParamsSet(_baseToken, _baseMMPerContract, _imFactorBps);

        _listTokenIfNeeded(_baseToken);
        collateralConfigs[_baseToken] = CollateralConfig({weightBps: uint64(BPS_U), isEnabled: true});
        emit CollateralConfigSet(_baseToken, uint64(BPS_U), true);
    }

    function setCollateralConfig(address token, uint64 weightBps, bool isEnabled) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (weightBps > BPS_U) revert InvalidParams();

        if (isEnabled) {
            (, uint8 baseDec,) = _loadBase();

            CollateralVault.CollateralTokenConfig memory vcfg = _vaultCfg(token);
            if (!vcfg.isSupported) revert TokenNotSupportedInVault(token);
            if (vcfg.decimals == 0) revert TokenDecimalsNotConfigured(token);
            if (uint256(vcfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(token);

            uint8 tokenDec = vcfg.decimals;
            uint256 diff = tokenDec >= baseDec ? uint256(tokenDec - baseDec) : uint256(baseDec - tokenDec);
            if (diff > MAX_POW10_EXP) revert DecimalsDiffOverflow(token);

            if (weightBps == 0) revert InvalidParams();
        }

        _listTokenIfNeeded(token);
        collateralConfigs[token] = CollateralConfig({weightBps: weightBps, isEnabled: isEnabled});

        emit CollateralConfigSet(token, weightBps, isEnabled);
    }

    function syncCollateralTokensFromVault() external onlyOwner returns (uint256 added) {
        address[] memory all = collateralVault.getCollateralTokens();
        uint256 len = all.length;

        for (uint256 i = 0; i < len; i++) {
            address t = all[i];
            if (t == address(0)) continue;

            if (!isCollateralTokenListed[t]) {
                collateralTokens.push(t);
                isCollateralTokenListed[t] = true;
                added++;
            }
        }

        emit CollateralTokensSyncedFromVault(added);
    }
}