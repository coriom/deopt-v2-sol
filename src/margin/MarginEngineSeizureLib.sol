// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";

/// @title MarginEngineSeizureLib
/// @notice External library that hosts the two heavy decimal/oracle conversion helpers used by the
///         multi-asset liquidation seizure loop in `MarginEngine.liquidate(...)`. Marking the
///         functions `external` makes Solidity compile this as a separately-deployed library that
///         the engine calls via `DELEGATECALL`, which keeps the engine bytecode under the EIP-170
///         24,576 byte limit.
/// @dev
///  - Functions are intentionally pure of engine storage; every dependency (`baseCollateralToken`,
///    `vault`, `oracle`, `maxDelay`) is passed in by the caller.
///  - Errors are declared in the library so callers can decode them; selectors match the engine's
///    historical `DecimalsOverflow` / `MathOverflow` errors to preserve external observability.
library MarginEngineSeizureLib {
    /// @dev Defensive upper bound on settlement-asset decimals when computing 10**decimals.
    uint256 internal constant MAX_POW10_EXP = 77;

    /// @dev Canonical normalized price scale.
    uint256 internal constant PRICE_1E8 = 1e8;

    error DecimalsOverflow(address token);
    error MathOverflow();

    /// @notice Converts a value expressed in base-token native units to token native units, rounded
    /// up so the protocol never under-demands collateral from the trader during liquidation seizure.
    /// @dev Mirrors the previous in-engine `_baseValueToTokenAmountUp`. Returns `(0, false)` on any
    /// oracle / vault config issue so the seizure loop can fall through to the next collateral.
    function baseValueToTokenAmountUp(
        address token,
        uint256 baseValue,
        address baseCollateralToken,
        CollateralVault vault,
        IOracle oracle,
        uint32 maxDelay
    ) external view returns (uint256 amtToken, bool ok) {
        if (baseValue == 0) return (0, true);
        if (token == address(0)) return (0, false);

        if (token == baseCollateralToken) {
            return (baseValue, true);
        }

        CollateralVault.CollateralTokenConfig memory baseCfg = vault.getCollateralConfig(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = vault.getCollateralConfig(token);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) return (0, false);
        if (!tokCfg.isSupported || tokCfg.decimals == 0) return (0, false);
        if (uint256(baseCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(baseCollateralToken);
        if (uint256(tokCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(token);

        uint256 px;
        uint256 updatedAt;
        try oracle.getPrice(token, baseCollateralToken) returns (uint256 _p, uint256 _u) {
            px = _p;
            updatedAt = _u;
        } catch {
            return (0, false);
        }
        if (px == 0) return (0, false);

        if (maxDelay > 0) {
            if (updatedAt == 0) return (0, false);
            if (updatedAt > block.timestamp) return (0, false);
            if (block.timestamp - updatedAt > maxDelay) return (0, false);
        }

        uint8 baseDec = baseCfg.decimals;
        uint8 tokDec = tokCfg.decimals;

        uint256 sameDec = Math.mulDiv(baseValue, PRICE_1E8, px, Math.Rounding.Ceil);

        if (tokDec == baseDec) {
            return (sameDec, true);
        }

        if (tokDec > baseDec) {
            uint256 factor = _pow10(uint256(tokDec - baseDec));
            (uint256 mul, bool okMul) = _tryMul(sameDec, factor);
            if (!okMul) return (0, false);
            return (mul, true);
        }

        uint256 factor2 = _pow10(uint256(baseDec - tokDec));
        amtToken = (sameDec + (factor2 - 1)) / factor2;
        return (amtToken, true);
    }

    /// @notice Converts a token-native amount back to base-token native units, rounded down so the
    /// protocol never over-credits the liquidator's seizure.
    /// @dev Mirrors the previous in-engine `_tokenAmountToBaseValueDown`. The caller is responsible
    /// for sourcing a fresh oracle price (`pxTokBase`).
    function tokenAmountToBaseValueDown(
        address token,
        uint256 tokenAmount,
        uint256 pxTokBase,
        address baseCollateralToken,
        CollateralVault vault
    ) external view returns (uint256 baseValue) {
        if (tokenAmount == 0) return 0;
        if (token == baseCollateralToken) return tokenAmount;

        CollateralVault.CollateralTokenConfig memory baseCfg = vault.getCollateralConfig(baseCollateralToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = vault.getCollateralConfig(token);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) return 0;
        if (!tokCfg.isSupported || tokCfg.decimals == 0) return 0;

        if (uint256(baseCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(baseCollateralToken);
        if (uint256(tokCfg.decimals) > MAX_POW10_EXP) revert DecimalsOverflow(token);

        uint8 baseDec = baseCfg.decimals;
        uint8 tokDec = tokCfg.decimals;

        uint256 num = Math.mulDiv(tokenAmount, pxTokBase, PRICE_1E8, Math.Rounding.Floor);

        if (tokDec == baseDec) return num;

        if (baseDec > tokDec) {
            uint256 factor = _pow10(uint256(baseDec - tokDec));
            (uint256 mul, bool okMul) = _tryMul(num, factor);
            if (!okMul) return 0;
            return mul;
        }

        uint256 factor2 = _pow10(uint256(tokDec - baseDec));
        return num / factor2;
    }

    function _pow10(uint256 exp) private pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert MathOverflow();
        return 10 ** exp;
    }

    function _tryMul(uint256 a, uint256 b) private pure returns (uint256 c, bool ok) {
        if (a == 0 || b == 0) return (0, true);
        unchecked {
            c = a * b;
        }
        if (c / a != b) return (0, false);
        return (c, true);
    }
}
