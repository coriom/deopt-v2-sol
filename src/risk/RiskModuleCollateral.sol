// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./RiskModuleOracle.sol";

abstract contract RiskModuleCollateral is RiskModuleOracle {
    function _effectiveBalanceOf(address user, address token) internal view returns (uint256) {
        try collateralVault.balanceWithYield(user, token) returns (uint256 b) {
            return b;
        } catch {
            return collateralVault.balances(user, token);
        }
    }

    function _tokenAmountToBaseValue(address token, uint256 tokenAmount, uint256 price1e8)
        internal
        view
        returns (uint256 baseValue)
    {
        uint256 tmp = Math.mulDiv(tokenAmount, price1e8, PRICE_SCALE_U, Math.Rounding.Floor);

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        if (baseDec == tokenDec) return tmp;

        if (baseDec > tokenDec) {
            uint256 factor = _pow10(uint256(baseDec - tokenDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        } else {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return tmp / factor;
        }
    }

    function _baseValueToTokenAmount(address token, uint256 baseValue, uint256 price1e8)
        internal
        view
        returns (uint256 tokenAmount)
    {
        uint256 tmp = Math.mulDiv(baseValue, PRICE_SCALE_U, price1e8, Math.Rounding.Floor);

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        if (baseDec == tokenDec) return tmp;

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        } else {
            uint256 factor = _pow10(uint256(baseDec - tokenDec));
            return tmp / factor;
        }
    }

    function _computeCollateralEquityBase(address trader, address base, uint8 baseDec)
        internal
        view
        whenCollateralValuationNotPaused
        returns (uint256 totalEquityBase)
    {
        CollateralConfig memory baseRiskCfg = collateralConfigs[base];
        if (!baseRiskCfg.isEnabled || baseRiskCfg.weightBps == 0) revert TokenNotConfigured(base);

        uint256 n = collateralTokens.length;

        for (uint256 i = 0; i < n; i++) {
            address token = collateralTokens[i];
            CollateralConfig memory rcfg = collateralConfigs[token];
            if (!rcfg.isEnabled || rcfg.weightBps == 0) continue;

            _requireTokenConfiguredIfEnabled(token, baseDec);

            uint256 bal = _effectiveBalanceOf(trader, token);
            if (bal == 0) continue;

            uint256 valueBase;
            if (token == base) {
                valueBase = bal;
            } else {
                (uint256 price, bool okPx) = _tryGetPrice(token, base);
                if (!okPx) continue;
                valueBase = _tokenAmountToBaseValue(token, bal, price);
            }

            uint256 adjusted = Math.mulDiv(valueBase, uint256(rcfg.weightBps), BPS_U, Math.Rounding.Floor);
            totalEquityBase = _addChecked(totalEquityBase, adjusted);
        }

        return totalEquityBase;
    }
}