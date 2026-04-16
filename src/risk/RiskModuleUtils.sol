// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "./RiskModuleStorage.sol";

/// @notice Low-level shared helpers for RiskModule.
/// @dev
///  Responsibilities:
///   - collateral token listing helpers
///   - vault config reads
///   - decimal / base-token validation
///   - safe arithmetic helpers
///   - signed saturation helpers
///   - option product config loading
///
///  Design notes:
///   - this layer is intentionally generic and reusable by oracle / collateral / margin submodules
///   - saturating helpers are kept because upper layers currently rely on conservative non-reverting views
///   - strict config validation stays here to centralize base-token / decimals invariants
abstract contract RiskModuleUtils is RiskModuleStorage {
    /*//////////////////////////////////////////////////////////////
                            TOKEN / CONFIG HELPERS
    //////////////////////////////////////////////////////////////*/

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

        baseDec = baseCfg.decimals;
        baseScale = _pow10(uint256(baseDec));
    }

    /// @notice Ensures an enabled token is fully usable for valuation against the configured base token.
    /// @dev Disabled tokens are ignored upstream and therefore pass through.
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
        if (s.contractSize1e8 != PRICE_SCALE_U) revert InvalidContractSize();
    }

    /*//////////////////////////////////////////////////////////////
                            UINT MATH HELPERS
    //////////////////////////////////////////////////////////////*/

    function _addChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        c = a + b;
        if (c < a) revert MathOverflow();
    }

    function _subChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (b > a) revert MathOverflow();
        unchecked {
            c = a - b;
        }
    }

    function _mulChecked(uint256 a, uint256 b) internal pure returns (uint256 c) {
        if (a == 0 || b == 0) return 0;
        c = a * b;
        if (c / a != b) revert MathOverflow();
    }

    /*//////////////////////////////////////////////////////////////
                        SIGNED / SATURATING HELPERS
    //////////////////////////////////////////////////////////////*/

    function _uintToInt256Sat(uint256 x) internal pure returns (int256) {
        uint256 m = uint256(type(int256).max);
        if (x > m) return type(int256).max;
        return SafeCast.toInt256(x);
    }

    function _negUintToInt256Sat(uint256 x) internal pure returns (int256) {
        uint256 m = uint256(type(int256).max);
        if (x > m) return type(int256).min;
        return -SafeCast.toInt256(x);
    }

    function _subInt256Sat(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a - b;
            if (b > 0 && r > a) return type(int256).min;
            if (b < 0 && r < a) return type(int256).max;
        }
    }

    function _addInt256Sat(int256 a, int256 b) internal pure returns (int256 r) {
        unchecked {
            r = a + b;
            if (b > 0 && r < a) return type(int256).max;
            if (b < 0 && r > a) return type(int256).min;
        }
    }

    function _absInt256ToUint(int256 x) internal pure returns (uint256) {
        if (x >= 0) return SafeCast.toUint256(x);
        if (x == type(int256).min) revert MathOverflow();
        return SafeCast.toUint256(-x);
    }

    /*//////////////////////////////////////////////////////////////
                            QUANTITY HELPERS
    //////////////////////////////////////////////////////////////*/

    function _absQuantityU(int128 q) internal pure returns (uint256) {
        if (q >= 0) return SafeCast.toUint256(int256(q));
        if (q == type(int128).min) revert QuantityInt128Min();
        int256 a = -int256(q);
        if (a < 0) revert QuantityAbsOverflow();
        return SafeCast.toUint256(a);
    }
}
