// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {CollateralVault} from "../collateral/CollateralVault.sol";
import {IOracle} from "../oracle/IOracle.sol";
import {ICollateralSeizer} from "../liquidation/ICollateralSeizer.sol";

/// @title PerpEngineSeizureLib
/// @notice External library hosting heavy seizure/conversion helpers for PerpEngine.
/// @dev
///  - Marked `external` so Solidity compiles this as a separately-deployed library invoked
///    via `DELEGATECALL`, keeping PerpEngine runtime bytecode below the EIP-170 24,576-byte limit.
///  - Pure of engine storage: every dependency (vault, oracle, seizer, base token) is passed by
///    the caller. The library never reads engine slots directly.
///  - Errors mirror engine-side errors so external observability and selectors stay stable.
library PerpEngineSeizureLib {
    uint256 internal constant PRICE_1E8 = 1e8;
    uint256 internal constant MAX_POW10_EXP = 77;

    error InvalidMarket();
    error MathOverflow();
    error OraclePriceUnavailable();
    error OraclePriceStale();

    /// @notice Multi-asset seizure plan executor used during liquidation.
    /// @dev Mirrors the previous in-engine `_trySeizeViaPlan` byte-for-byte semantically.
    /// @return paidBase Effective base-token-denominated coverage actually transferred to liquidator.
    function trySeizeViaPlan(
        ICollateralSeizer seizer,
        CollateralVault vault,
        address trader,
        address liquidator,
        uint256 targetBase
    ) external returns (uint256 paidBase) {
        if (targetBase == 0) return 0;
        if (address(seizer) == address(0)) return 0;

        address[] memory tokens;
        uint256[] memory amounts;
        uint256 plannedCoveredBase;

        try seizer.computeSeizurePlan(trader, targetBase) returns (
            address[] memory tokensOut, uint256[] memory amountsOut, uint256 baseCovered
        ) {
            if (tokensOut.length != amountsOut.length) return 0;
            if (tokensOut.length == 0 || baseCovered == 0) return 0;

            tokens = tokensOut;
            amounts = amountsOut;
            plannedCoveredBase = baseCovered;
        } catch {
            return 0;
        }

        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            uint256 plannedAmount = amounts[i];

            if (token == address(0) || plannedAmount == 0) continue;

            (bool okSync,) =
                address(vault).call(abi.encodeWithSignature("syncAccountFor(address,address)", trader, token));
            okSync;

            uint256 bal = vault.balances(trader, token);
            uint256 transferAmt = plannedAmount <= bal ? plannedAmount : bal;
            if (transferAmt == 0) continue;

            vault.transferBetweenAccounts(token, trader, liquidator, transferAmt);

            try seizer.previewEffectiveBaseValue(token, transferAmt) returns (
                uint256, uint256 effectiveBaseFloor, bool okPreview
            ) {
                if (okPreview && effectiveBaseFloor != 0) {
                    paidBase += effectiveBaseFloor;
                }
            } catch {}
        }

        if (paidBase > plannedCoveredBase) paidBase = plannedCoveredBase;
        if (paidBase > targetBase) paidBase = targetBase;
    }

    /// @notice Mark price for the liquidation path with optional freshness enforcement.
    /// @dev Mirrors the previous in-engine `_liquidationMarkPrice1e8`.
    ///      Reverts if no usable price is available, or if the resolved price is stale and
    ///      `oracleMaxDelay != 0`.
    function liquidationMarkPrice1e8(IOracle oracle, address underlying, address settlementAsset, uint32 oracleMaxDelay)
        external
        view
        returns (uint256 markPrice1e8)
    {
        uint256 updatedAt;
        {
            (bool success, bytes memory data) = address(oracle)
                .staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", underlying, settlementAsset));

            if (success && data.length >= 96) {
                (uint256 px, uint256 upd, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
                if (safeOk && px != 0) {
                    markPrice1e8 = px;
                    updatedAt = upd;
                }
            }
        }

        if (markPrice1e8 == 0) {
            (markPrice1e8, updatedAt) = oracle.getPrice(underlying, settlementAsset);
            if (markPrice1e8 == 0) revert OraclePriceUnavailable();
        }

        if (oracleMaxDelay != 0) {
            if (updatedAt == 0 || updatedAt > block.timestamp) revert OraclePriceStale();
            if (block.timestamp - updatedAt > uint256(oracleMaxDelay)) revert OraclePriceStale();
        }
    }

    /// @notice Try to read a fresh-or-best-effort 1e8 mark price for an arbitrary token pair.
    /// @dev First tries `getPriceSafe(base, quote)`, then falls back to `getPrice`.
    function tryGetMarkPrice1e8FromPair(IOracle oracle, address base, address quote)
        external
        view
        returns (uint256 price1e8, bool ok)
    {
        {
            (bool success, bytes memory data) =
                address(oracle).staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", base, quote));

            if (success && data.length >= 96) {
                (uint256 px,, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
                if (safeOk && px != 0) return (px, true);
            }
        }

        try oracle.getPrice(base, quote) returns (uint256 px, uint256) {
            if (px == 0) return (0, false);
            return (px, true);
        } catch {
            return (0, false);
        }
    }

    /// @notice Converts a base-denominated value to token-native units using the supplied price.
    /// @dev Rounds down. Mirrors the previous in-engine `_baseValueToTokenAmount`.
    function baseValueToTokenAmount(
        CollateralVault vault,
        address baseToken,
        address token,
        uint256 baseValue,
        uint256 price1e8
    ) external view returns (uint256 tokenAmount) {
        CollateralVault.CollateralTokenConfig memory baseCfg = vault.getCollateralConfig(baseToken);
        CollateralVault.CollateralTokenConfig memory tokCfg = vault.getCollateralConfig(token);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) revert InvalidMarket();
        if (!tokCfg.isSupported || tokCfg.decimals == 0) revert InvalidMarket();

        uint8 baseDec = baseCfg.decimals;
        uint8 tokenDec = tokCfg.decimals;

        uint256 tmp = _mulDivFloor(baseValue, PRICE_1E8, price1e8);

        if (baseDec == tokenDec) return tmp;

        if (tokenDec > baseDec) {
            uint256 factor = _pow10(uint256(tokenDec - baseDec));
            return _mulChecked(tmp, factor);
        }

        uint256 factor2 = _pow10(uint256(baseDec - tokenDec));
        return tmp / factor2;
    }

    /// @notice Converts a settlement-asset-native amount to base-token-native units.
    /// @dev Mirrors the previous in-engine `_settlementNativeToBase`.
    function settlementNativeToBase(
        CollateralVault vault,
        IOracle oracle,
        address baseToken,
        address settlementAsset,
        uint256 settlementAmountNative
    ) external view returns (uint256 baseValue) {
        if (settlementAmountNative == 0) return 0;

        CollateralVault.CollateralTokenConfig memory baseCfg = vault.getCollateralConfig(baseToken);
        CollateralVault.CollateralTokenConfig memory setCfg = vault.getCollateralConfig(settlementAsset);

        if (!baseCfg.isSupported || baseCfg.decimals == 0) revert InvalidMarket();
        if (!setCfg.isSupported || setCfg.decimals == 0) revert InvalidMarket();

        if (settlementAsset == baseToken) return settlementAmountNative;

        (uint256 px, bool ok) = _tryGetPriceInline(oracle, settlementAsset, baseToken);
        if (!ok || px == 0) revert OraclePriceUnavailable();

        uint256 tmp = _mulDivFloor(settlementAmountNative, px, PRICE_1E8);

        if (baseCfg.decimals == setCfg.decimals) return tmp;

        if (baseCfg.decimals > setCfg.decimals) {
            uint256 factor = _pow10(uint256(baseCfg.decimals - setCfg.decimals));
            return _mulChecked(tmp, factor);
        }

        uint256 factor2 = _pow10(uint256(setCfg.decimals - baseCfg.decimals));
        return tmp / factor2;
    }

    function _tryGetPriceInline(IOracle oracle, address base, address quote)
        private
        view
        returns (uint256 price1e8, bool ok)
    {
        {
            (bool success, bytes memory data) =
                address(oracle).staticcall(abi.encodeWithSignature("getPriceSafe(address,address)", base, quote));

            if (success && data.length >= 96) {
                (uint256 px,, bool safeOk) = abi.decode(data, (uint256, uint256, bool));
                if (safeOk && px != 0) return (px, true);
            }
        }

        try oracle.getPrice(base, quote) returns (uint256 px, uint256) {
            if (px == 0) return (0, false);
            return (px, true);
        } catch {
            return (0, false);
        }
    }

    function _pow10(uint256 exp) private pure returns (uint256) {
        if (exp > MAX_POW10_EXP) revert MathOverflow();
        return 10 ** exp;
    }

    function _mulChecked(uint256 a, uint256 b) private pure returns (uint256 c) {
        if (a == 0 || b == 0) return 0;
        c = a * b;
        if (c / a != b) revert MathOverflow();
    }

    function _mulDivFloor(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256) {
        if (denominator == 0) revert MathOverflow();
        return _mulChecked(a, b) / denominator;
    }
}
