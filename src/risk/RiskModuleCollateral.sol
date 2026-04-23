// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./RiskModuleOracle.sol";

/// @notice Collateral valuation layer for RiskModule.
/// @dev
///  Responsibilities:
///   - read effective balances (idle + yield)
///   - convert token native amounts <-> base collateral native amounts
///   - aggregate gross and haircut-adjusted collateral value
///   - provide reusable internal helpers for upper risk layers
///
///  Design notes:
///   - valuation is conservative:
///       * disabled / zero-weight tokens are ignored
///       * non-base tokens with unavailable oracle are ignored
///   - arithmetic is normalized in base token native units
///   - this layer stays product-agnostic: it values collateral only
abstract contract RiskModuleCollateral is RiskModuleOracle {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    struct CollateralValue {
        uint256 grossBaseValue;
        uint256 adjustedBaseValue;
    }

    /*//////////////////////////////////////////////////////////////
                        BALANCE / DECIMAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _effectiveBalanceOf(address user, address token) internal view returns (uint256) {
        try collateralVault.balanceWithYield(user, token) returns (uint256 b) {
            return b;
        } catch {
            return collateralVault.balances(user, token);
        }
    }

    function _requireConfiguredTokenDecimals(address token, uint8 baseDec) internal view returns (uint8 tokenDec) {
        _requireTokenConfiguredIfEnabled(token, baseDec);
        tokenDec = _vaultCfg(token).decimals;
    }

    function _isLaunchActiveCollateral(address token) internal view returns (bool) {
        if (!collateralVault.collateralRestrictionMode()) return true;
        return collateralVault.launchActiveCollateral(token);
    }

    /*//////////////////////////////////////////////////////////////
                        VALUE CONVERSION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Converts native token amount into native base-token value using a 1e8 oracle price.
    /// @dev price1e8 = value of 1 token in units of base token, scaled 1e8.
    function _tokenAmountToBaseValue(address token, uint256 tokenAmount, uint256 price1e8)
        internal
        view
        override
        returns (uint256 baseValue)
    {
        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        uint256 tmp = Math.mulDiv(tokenAmount, price1e8, PRICE_SCALE_U, Math.Rounding.Floor);

        if (baseDec == tokenDec) return tmp;

        if (baseDec > tokenDec) {
            uint256 factor = _pow10(uint256(baseDec - tokenDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        }

        uint256 factor2 = _pow10(uint256(tokenDec - baseDec));
        return tmp / factor2;
    }

    /// @notice Converts native base-token value into native token amount using a 1e8 oracle price.
    function _baseValueToTokenAmount(address token, uint256 baseValue, uint256 price1e8)
        internal
        view
        returns (uint256 tokenAmount)
    {
        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = _vaultCfg(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        uint256 tmp = Math.mulDiv(baseValue, PRICE_SCALE_U, price1e8, Math.Rounding.Floor);

        if (baseDec == tokenDec) return tmp;

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return Math.mulDiv(tmp, factor, 1, Math.Rounding.Floor);
        }

        uint256 factor2 = _pow10(uint256(baseDec - tokenDec));
        return tmp / factor2;
    }

    /// @notice Returns gross base value for a token balance. If conversion is unavailable, returns (0,false).
    function _tryTokenGrossBaseValue(address base, address token, uint256 tokenAmount)
        internal
        view
        returns (uint256 grossBaseValue, bool ok)
    {
        if (tokenAmount == 0) return (0, true);

        if (token == base) return (tokenAmount, true);

        (uint256 price, bool okPx) = _tryGetPrice(token, base);
        if (!okPx || price == 0) return (0, false);

        grossBaseValue = _tokenAmountToBaseValue(token, tokenAmount, price);
        return (grossBaseValue, true);
    }

    /// @notice Applies collateral haircut / weight to a gross base value.
    function _applyCollateralWeight(uint256 grossBaseValue, uint64 weightBps)
        internal
        pure
        returns (uint256 adjustedBaseValue)
    {
        if (grossBaseValue == 0 || weightBps == 0) return 0;
        adjustedBaseValue = Math.mulDiv(grossBaseValue, uint256(weightBps), BPS_U, Math.Rounding.Floor);
    }

    /// @notice Computes gross + adjusted collateral contribution for one token.
    /// @dev Returns (0,0,false) when token cannot be conservatively valued in current context.
    function _tryComputeTokenCollateralValue(address trader, address base, uint8 baseDec, address token)
        internal
        view
        returns (CollateralValue memory value, bool ok)
    {
        CollateralConfig memory rcfg = collateralConfigs[token];
        if (!rcfg.isEnabled || rcfg.weightBps == 0) return (value, false);
        if (!_isLaunchActiveCollateral(token)) return (value, false);

        _requireTokenConfiguredIfEnabled(token, baseDec);

        uint256 bal = _effectiveBalanceOf(trader, token);
        if (bal == 0) return (value, false);

        (uint256 grossBase, bool okGross) = _tryTokenGrossBaseValue(base, token, bal);
        if (!okGross) return (value, false);

        value.grossBaseValue = grossBase;
        value.adjustedBaseValue = _applyCollateralWeight(grossBase, rcfg.weightBps);
        return (value, true);
    }

    /*//////////////////////////////////////////////////////////////
                        AGGREGATE COLLATERAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes total gross and adjusted collateral value in base native units.
    /// @dev
    ///  - conservative aggregation:
    ///      * disabled / zero-weight tokens ignored
    ///      * unpriceable non-base tokens ignored
    ///  - reverts if base token itself is not enabled/configured
    function _computeCollateralValueBase(address trader, address base, uint8 baseDec)
        internal
        view
        whenCollateralValuationNotPaused
        returns (CollateralValue memory total)
    {
        CollateralConfig memory baseRiskCfg = collateralConfigs[base];
        if (!baseRiskCfg.isEnabled || baseRiskCfg.weightBps == 0 || !_isLaunchActiveCollateral(base)) {
            revert TokenNotConfigured(base);
        }

        uint256 n = collateralTokens.length;

        for (uint256 i = 0; i < n; i++) {
            address token = collateralTokens[i];

            (CollateralValue memory value, bool ok) = _tryComputeTokenCollateralValue(trader, base, baseDec, token);
            if (!ok) continue;

            total.grossBaseValue = _addChecked(total.grossBaseValue, value.grossBaseValue);
            total.adjustedBaseValue = _addChecked(total.adjustedBaseValue, value.adjustedBaseValue);
        }
    }

    /// @notice Legacy helper retained for compatibility with upper layers that only need adjusted value.
    function _computeCollateralEquityBase(address trader, address base, uint8 baseDec)
        internal
        view
        whenCollateralValuationNotPaused
        returns (uint256 totalEquityBase)
    {
        CollateralValue memory total = _computeCollateralValueBase(trader, base, baseDec);
        return total.adjustedBaseValue;
    }
}
