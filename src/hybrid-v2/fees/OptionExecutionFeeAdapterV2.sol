// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IOptionExecutionFeeHook} from "../interfaces/IOptionExecutionFeeHook.sol";
import {IFeesManagerV2} from "../../fees/IFeesManagerV2.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {OptionOrderTypes} from "../options/OptionOrderTypes.sol";

/// @title OptionExecutionFeeAdapterV2
/// @notice Concrete WP-09 adapter that binds `OptionMatchingEngineV2`'s
///         mandatory `IOptionExecutionFeeHook` boundary to the deployed
///         `FeesManagerV2` fee-pricing engine.
/// @dev
///  Scope (frozen for WP-09):
///   - READ-ONLY. This adapter computes fee/rebate AMOUNTS only. The engine
///     performs the actual accounting through Vault primitives
///     (`applyOptionFeeCharge`, `applyOptionRebate`) so the canonical
///     protocol-fee and rebate-budget subKeys receive/pay the value
///     inside the Vault's own conservation invariant.
///   - The adapter never charges FeesManagerV2's own `consumeFees` state
///     mutation (which requires FeesManager-side consumer allowlisting +
///     internal rebate-budget bookkeeping). Rebate budget in this
///     hybrid-v2 flow is enforced by the Vault's rebate-budget subKey
///     available balance — an unfunded budget causes
///     `applyOptionRebate` to revert `InsufficientAvailableCollateral`,
///     which atomically unwinds the whole trade.
///
///  Unit conversion:
///   - The engine passes `filledQuantity1e8` and `pricePerContract1e8` in
///     1e8 precision. This adapter computes the fill's premium basis in
///     NATIVE `premiumToken` units by scaling with `QUOTE_DECIMALS`,
///     rounded UP so the trader pays fee on at LEAST the honest premium.
///   - The FeesManagerV2 quote's `feeAmount` is returned in native units;
///     the adapter converts it back to 1e8-scale (rounded UP for a fee,
///     rounded DOWN for a rebate) before returning to the engine, where
///     the reverse conversion + final Vault write happens.
///
///  Fail-closed:
///   - Unregistered trader subKey → `ok = false`.
///   - FeesManagerV2 revert (bad schedule / tier / basis) → `ok = false`.
///   - Product mismatch (FeesManager returns non-OPTION) → `ok = false`.
///   - Any invariant that would silently over-refund or under-charge fails
///     closed rather than defaulting to zero.
///
///  Non-goals:
///   - No FeesManager owner surface. No governance path is exposed by
///     this adapter.
///   - No caller allowlist independent of the engine's own capability
///     grant on the Vault side.
///   - No rebate-budget mutation. That state lives on the Vault side.
///   - No production-fees-schedule mutation.
contract OptionExecutionFeeAdapterV2 is IOptionExecutionFeeHook {
    /// @notice The FeesManagerV2 deployment this adapter queries.
    IFeesManagerV2 public immutable FEES_MANAGER;

    /// @notice The Vault whose Registry resolves trader-owner identities.
    ICollateralVault public immutable VAULT;

    /// @notice Canonical Registry (sourced from the Vault). Used to resolve
    ///         `subKey → owner` on every quote.
    ISubaccountRegistry public immutable REGISTRY;

    /// @notice Cached decimals of the frozen QUOTE_TOKEN. Used to translate
    ///         between 1e8-scaled and native amounts.
    uint8 public immutable QUOTE_DECIMALS;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidDependency();

    constructor(address feesManager_, address vault_, address registry_, uint8 quoteDecimals_) {
        if (feesManager_ == address(0) || vault_ == address(0) || registry_ == address(0)) revert InvalidDependency();
        if (quoteDecimals_ == 0) revert InvalidDependency();
        FEES_MANAGER = IFeesManagerV2(feesManager_);
        VAULT = ICollateralVault(vault_);
        REGISTRY = ISubaccountRegistry(registry_);
        QUOTE_DECIMALS = quoteDecimals_;
    }

    /// @inheritdoc IOptionExecutionFeeHook
    function quoteExecutionFee(
        bytes32 subKey,
        address premiumToken,
        uint128 filledQuantity1e8,
        uint128 pricePerContract1e8,
        uint8 orderRole
    ) external view returns (uint128 feeAmount1e8, uint128 rebateAmount1e8, bool ok) {
        if (subKey == bytes32(0) || premiumToken == address(0)) return (0, 0, false);
        address trader = REGISTRY.ownerOf(subKey);
        if (trader == address(0)) return (0, 0, false);
        if (filledQuantity1e8 == 0 || pricePerContract1e8 == 0) return (0, 0, true);

        uint256 basisNative = _premiumBasisNativeCeil(filledQuantity1e8, pricePerContract1e8);
        bool isMaker = (orderRole == OptionOrderTypes.ROLE_MAKER);

        try FEES_MANAGER.quoteFees(
            trader,
            IFeesManagerV2.ProductKind.OPTION,
            IFeesManagerV2.FlowKind.ORDERBOOK,
            isMaker,
            premiumToken,
            basisNative
        ) returns (
            IFeesManagerV2.FeeQuote memory quote
        ) {
            if (quote.product != IFeesManagerV2.ProductKind.OPTION) return (0, 0, false);
            if (quote.settlementAsset != premiumToken) return (0, 0, false);
            if (quote.isMaker != isMaker) return (0, 0, false);
            if (quote.feeAmount == 0) return (0, 0, true);
            if (quote.isRebate) {
                // Rebate — convert native → 1e8 (round DOWN to protect budget).
                return (0, uint128(_nativeTo1e8Floor(quote.feeAmount)), true);
            }
            // Positive fee — convert native → 1e8 (round UP against trader).
            return (uint128(_nativeTo1e8Ceil(quote.feeAmount)), 0, true);
        } catch {
            return (0, 0, false);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev `basisNative = ceil(qty1e8 * price1e8 / 1e8 / 10^(8-quoteDecimals))`.
    function _premiumBasisNativeCeil(uint128 qty1e8, uint128 price1e8) internal view returns (uint256) {
        uint256 basis1e8 = (uint256(qty1e8) * uint256(price1e8)) / 1e8;
        if (basis1e8 == 0) return 0;
        if (QUOTE_DECIMALS <= 8) {
            uint256 divisor = 10 ** (8 - uint256(QUOTE_DECIMALS));
            return (basis1e8 + divisor - 1) / divisor;
        }
        uint256 mult = 10 ** (uint256(QUOTE_DECIMALS) - 8);
        return basis1e8 * mult;
    }

    /// @dev Native → 1e8, rounded UP.
    function _nativeTo1e8Ceil(uint256 native) internal view returns (uint256) {
        if (native == 0) return 0;
        if (QUOTE_DECIMALS <= 8) {
            uint256 mult = 10 ** (8 - uint256(QUOTE_DECIMALS));
            return native * mult;
        }
        uint256 divisor = 10 ** (uint256(QUOTE_DECIMALS) - 8);
        return (native + divisor - 1) / divisor;
    }

    /// @dev Native → 1e8, rounded DOWN.
    function _nativeTo1e8Floor(uint256 native) internal view returns (uint256) {
        if (native == 0) return 0;
        if (QUOTE_DECIMALS <= 8) {
            uint256 mult = 10 ** (8 - uint256(QUOTE_DECIMALS));
            return native * mult;
        }
        uint256 divisor = 10 ** (uint256(QUOTE_DECIMALS) - 8);
        return native / divisor;
    }
}
