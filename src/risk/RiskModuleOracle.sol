// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./RiskModuleUtils.sol";

/// @notice Oracle helper layer for RiskModule.
/// @dev
///  Responsibilities:
///   - best-effort oracle reads with local freshness enforcement
///   - settlement/base conversion helpers
///   - conservative failure behavior for view-side risk computations
///
///  Read policy:
///   1) try `getPriceSafe(base, quote)` => (price, updatedAt, ok)
///   2) fallback to legacy `getPrice(base, quote)` => (price, updatedAt)
///
///  Failure policy:
///   - stale / zero / reverting prices return `(0,false)` in best-effort paths
///   - upper layers decide whether to ignore, fallback, or revert
abstract contract RiskModuleOracle is RiskModuleUtils {
    /*//////////////////////////////////////////////////////////////
                            FRESHNESS HELPERS
    //////////////////////////////////////////////////////////////*/
    function _isOracleDataFresh(uint256 updatedAt) internal view returns (bool) {
        uint256 d = maxOracleDelay;
        if (d == 0) return true;
        if (updatedAt == 0) return false;
        if (updatedAt > block.timestamp) return false;
        return (block.timestamp - updatedAt) <= d;
    }

    /*//////////////////////////////////////////////////////////////
                            PRICE READ HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Best-effort oracle read:
    ///  1) try getPriceSafe(address,address) -> (price, updatedAt, ok)
    ///  2) fallback to legacy getPrice(address,address) -> (price, updatedAt)
    function _tryGetPrice(address base, address quote) internal view returns (uint256 price, bool ok) {
        {
            (bool success, bytes memory data) =
                address(oracle).staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", base, quote));

            if (success && data.length >= 96) {
                (uint256 p, uint256 updatedAt, bool okSafe) = abi.decode(data, (uint256, uint256, bool));
                if (!okSafe || p == 0) return (0, false);
                if (!_isOracleDataFresh(updatedAt)) return (0, false);
                return (p, true);
            }
        }

        try oracle.getPrice(base, quote) returns (uint256 p, uint256 updatedAt) {
            if (p == 0) return (0, false);
            if (!_isOracleDataFresh(updatedAt)) return (0, false);
            return (p, true);
        } catch {
            return (0, false);
        }
    }

    /// @dev Strict read helper built on top of best-effort path.
    function _getPriceStrict(address base, address quote) internal view returns (uint256 price) {
        (uint256 p, bool ok) = _tryGetPrice(base, quote);
        if (!ok) revert OracleUnavailable(base, quote);
        return p;
    }

    /*//////////////////////////////////////////////////////////////
                        CONVERSION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Converts a 1e8 settlement amount into base native units.
    /// @dev
    ///  - if settlementAsset == base:
    ///      amount1e8 * baseScale / 1e8
    ///  - otherwise:
    ///      amount1e8 (settlement 1e8)
    ///        -> settlement native units via settlement decimals
    ///        -> base native units via oracle price + decimal normalization
    ///
    ///  This avoids the decimal mismatch issue of directly multiplying two 1e8-scaled values
    ///  when settlement token decimals differ from base token decimals.
    function _convert1e8SettlementToBaseWithBase(
        address settlementAsset,
        uint256 amount1e8,
        address base,
        uint256 baseScale
    ) internal view returns (uint256 valueBase, bool ok) {
        if (amount1e8 == 0) return (0, true);

        if (settlementAsset == base) {
            return (Math.mulDiv(amount1e8, baseScale, PRICE_SCALE_U, Math.Rounding.Floor), true);
        }

        CollateralVault.CollateralTokenConfig memory setCfg = _vaultCfg(settlementAsset);
        if (!setCfg.isSupported) return (0, false);
        if (setCfg.decimals == 0) return (0, false);
        if (uint256(setCfg.decimals) > MAX_POW10_EXP) return (0, false);

        uint256 settlementScale = _pow10(uint256(setCfg.decimals));
        uint256 settlementAmountNative =
            Math.mulDiv(amount1e8, settlementScale, PRICE_SCALE_U, Math.Rounding.Floor);

        (uint256 px, bool okPx) = _tryGetPrice(settlementAsset, base);
        if (!okPx || px == 0) return (0, false);

        valueBase = _tokenAmountToBaseValue(settlementAsset, settlementAmountNative, px);
        return (valueBase, true);
    }

    /// @notice Converts a 1e8 settlement amount into base native units using configured base token.
    function _convert1e8SettlementToBase(uint256 amount1e8) internal view returns (uint256 valueBase, bool ok) {
        (address base,, uint256 baseScale) = _loadBase();
        return _convert1e8SettlementToBaseWithBase(baseCollateralToken, amount1e8, base, baseScale);
    }
}