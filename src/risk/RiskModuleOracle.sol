// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./RiskModuleUtils.sol";

abstract contract RiskModuleOracle is RiskModuleUtils {
    function _isOracleDataFresh(uint256 updatedAt) internal view returns (bool) {
        uint256 d = maxOracleDelay;
        if (d == 0) return true;
        if (updatedAt == 0) return false;
        if (updatedAt > block.timestamp) return false;
        return (block.timestamp - updatedAt) <= d;
    }

    /// @dev Best-effort oracle read:
    /// 1) try getPriceSafe(address,address) -> (price, updatedAt, ok)
    /// 2) fallback to legacy getPrice(address,address) -> (price, updatedAt)
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

        (uint256 px, bool okPx) = _tryGetPrice(settlementAsset, base);
        if (!okPx) return (0, false);

        uint256 v1e8 = Math.mulDiv(amount1e8, px, PRICE_SCALE_U, Math.Rounding.Floor);
        valueBase = Math.mulDiv(v1e8, baseScale, PRICE_SCALE_U, Math.Rounding.Floor);
        return (valueBase, true);
    }
}