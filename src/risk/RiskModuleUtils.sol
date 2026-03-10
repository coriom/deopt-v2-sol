// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./RiskModuleStorage.sol";

abstract contract RiskModuleUtils is RiskModuleStorage {
    function _listTokenIfNeeded(address token) internal {
        if (!isCollateralTokenListed[token]) {
            collateralTokens.push(token);
            isCollateralTokenListed[token] = true;
        }
    }

    function _vaultCfg(address token) internal view returns (CollateralVault.CollateralTokenConfig memory cfg) {
        cfg = collateralVault.getCollateralConfig(token);
    }

    function _pow10(uint256 exp) internal pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert InvalidParams();
        return 10 ** exp;
    }

    function _loadBase() internal view returns (address base, uint8 baseDec, uint256 baseScale) {
        base = baseCollateralToken;
        if (base == address(0)) revert BaseTokenNotConfigured();

        CollateralVault.CollateralTokenConfig memory baseCfg = _vaultCfg(base);
        if (!baseCfg.isSupported) revert TokenNotSupportedInVault(base);
        if (baseCfg.decimals == 0) revert TokenDecimalsNotConfigured(base);
        if (uint256(baseCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(base);
        if (baseCfg.decimals != EXPECTED_BASE_DECIMALS) revert BaseTokenDecimalsNotUSDC(base, baseCfg.decimals);

        baseDec = baseCfg.decimals;
        baseScale = _pow10(uint256(baseDec));
    }

    function _requireTokenConfiguredIfEnabled(address token, uint8 baseDec) internal view {
        CollateralConfig memory rcfg = collateralConfigs[token];
        if (!rcfg.isEnabled) return;

        CollateralVault.CollateralTokenConfig memory vcfg = _vaultCfg(token);
        if (!vcfg.isSupported) revert TokenNotSupportedInVault(token);
        if (vcfg.decimals == 0) revert TokenDecimalsNotConfigured(token);
        if (uint256(vcfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(token);

        uint8 tokenDec = vcfg.decimals;
        uint256 diff = tokenDec >= baseDec ? uint256(tokenDec - baseDec) : uint256(baseDec - tokenDec);
        if (diff > MAX_POW10_EXP) revert DecimalsDiffOverflow(token);
    }

    function _getUnderlyingConfig(address underlying)
        internal
        view
        returns (OptionProductRegistry.UnderlyingConfig memory cfg)
    {
        (address o, uint64 spotDown, uint64 spotUp, uint64 volDown, uint64 volUp, bool enabled) =
            optionRegistry.underlyingConfigs(underlying);

        cfg = OptionProductRegistry.UnderlyingConfig({
            oracle: o,
            spotShockDownBps: spotDown,
            spotShockUpBps: spotUp,
            volShockDownBps: volDown,
            volShockUpBps: volUp,
            isEnabled: enabled
        });
    }

    function _requireStandardContractSize(OptionProductRegistry.OptionSeries memory s) internal pure {
        if (s.contractSize1e8 != uint128(PRICE_SCALE_U)) revert InvalidContractSize();
    }

    function _addChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        if (c < a) revert MathOverflow();
    }

    function _uintToInt256Sat(uint256 x) internal pure returns (int256) {
        uint256 m = uint256(type(int256).max);
        if (x > m) return type(int256).max;
        return int256(x);
    }

    function _negUintToInt256Sat(uint256 x) internal pure returns (int256) {
        uint256 m = uint256(type(int256).max);
        if (x > m) return type(int256).min;
        return -int256(x);
    }

    function _subInt256Sat(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a - b;
            if (b > 0 && r > a) return type(int256).min;
            if (b < 0 && r < a) return type(int256).max;
        }
    }

    function _absQuantityU(int128 q) internal pure returns (uint256) {
        if (q >= 0) return uint256(int256(q));
        if (q == type(int128).min) revert QuantityInt128Min();
        int256 a = -int256(q);
        if (a < 0) revert QuantityAbsOverflow();
        return uint256(a);
    }
}