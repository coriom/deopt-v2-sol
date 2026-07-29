// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IOptionExecutionFeeHook
/// @notice Mandatory pluggable boundary consumed by `OptionMatchingEngineV2`
///         for per-fill Options fee computation (WP-08B Part H verdict
///         `OPTION_ENGINE_ABSTRACT_PENDING_FEES_INTEGRATION` = FEES-2).
/// @dev
///  V1 posture:
///   - The concrete FeesManagerV2 + ProtocolFeeVault deployment is NOT yet
///     shipped in the hybrid-v2 namespace. Because Part H forbids a permissive
///     zero-fee default, this milestone REQUIRES a concrete fee hook binding
///     — the engine's constructor rejects `address(0)`.
///   - A test-only zero-fee hook is acceptable (documented as such). The
///     production hook is the future WP-09 FeesManagerV2 adapter.
///   - The hook is READ-ONLY: it returns fee/rebate amounts + accepted-flag.
///     The engine performs the debit/credit against the Vault via the
///     approved primitives once the future WP-09 wires them in — for now the
///     engine reads the hook, validates the values, and includes them in
///     the atomic transaction. Rebates are NOT paid in V1 (return zero);
///     the interface reserves the field for forward compatibility.
///
///  Roles + attribution:
///   - `orderRole` is `0` for maker orders and `1` for taker orders (matches
///     `OptionOrderTypes.ROLE_MAKER` / `ROLE_TAKER`).
///   - The hook MAY apply distinct maker/taker rates.
///
///  Frozen return values:
///   - `feeAmount1e8` is the fee to debit from the corresponding subaccount
///     in 1e8 units of `premiumToken`. Rounded UP against the trader by the
///     hook implementation.
///   - `rebateAmount1e8` reserved for future maker-rebate wiring; MUST be
///     zero in V1 (the engine reverts otherwise).
///   - `ok` MUST be true on success. `false` fails the entire execution
///     closed. There is no permissive fallback.
interface IOptionExecutionFeeHook {
    /// @notice Compute the maker/taker fee for a single side of an Options fill.
    /// @param subKey            Canonical subKey of the trader on this side
    /// @param premiumToken      Token used for the fill's premium
    /// @param filledQuantity1e8 Fill quantity in 1e8
    /// @param pricePerContract1e8 Executed premium per contract in 1e8
    /// @param orderRole         0 = MAKER, 1 = TAKER
    /// @return feeAmount1e8     Fee amount in 1e8-scaled `premiumToken` units,
    ///                          rounded UP against the trader
    /// @return rebateAmount1e8  Reserved for future rebate wiring; MUST be 0 in V1
    /// @return ok               true on success; false fails execution closed
    function quoteExecutionFee(
        bytes32 subKey,
        address premiumToken,
        uint128 filledQuantity1e8,
        uint128 pricePerContract1e8,
        uint8 orderRole
    ) external view returns (uint128 feeAmount1e8, uint128 rebateAmount1e8, bool ok);
}
