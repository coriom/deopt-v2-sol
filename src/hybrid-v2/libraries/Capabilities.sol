// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title Capabilities
/// @notice Least-privilege capability bit constants for the DeOpt V2 hybrid subaccount architecture.
/// @dev
///  Capabilities are represented as bit positions on a `uint256` bitmap held in
///  `ICollateralVault.engineCapabilityBits(engine)`. Grants + revocations flow
///  through `ICollateralVault.setEngineCapability(engine, bits, allowed)` under
///  the ProtocolTimelock. Guardian may immediately revoke via
///  `ICollateralVault.guardianRevokeEngine(engine)`.
///
///  Bit assignments come from contract-spec 07. Bit 14 comes from escape-hatch
///  spec 15's capability addition. Bits 15..255 are reserved for future capabilities.
///
///  No blanket AUTHORIZED_ENGINE boolean is exposed by this architecture (per
///  Principle 10). Every capability MUST be granted individually.
///
///  Enforcement of these bits lives in downstream implementation milestones; this
///  library only declares the canonical constants.
library Capabilities {
    /// @notice Permits the caller to lazily register Account 1 for an owner via the registry.
    uint256 internal constant CAP_REGISTER_DEFAULT_ACCOUNT = 1 << 0;

    /// @notice Permits the caller to credit vault balances (deposits from trusted origins).
    uint256 internal constant CAP_CREDIT_COLLATERAL = 1 << 1;

    /// @notice Permits the caller to perform external withdrawals on behalf of a subKey.
    uint256 internal constant CAP_WITHDRAW_FOR = 1 << 2;

    /// @notice Permits the caller to reserve collateral against a subKey.
    uint256 internal constant CAP_LOCK_COLLATERAL = 1 << 3;

    /// @notice Permits the caller to release its OWN reservation only.
    uint256 internal constant CAP_UNLOCK_OWN_RESERVATION = 1 << 4;

    /// @notice Permits the caller to mutate option positions on the OptionsPositionsLedger.
    uint256 internal constant CAP_APPLY_OPTIONS_POSITION_DELTA = 1 << 5;

    /// @notice Permits the caller to mutate perp positions on the PerpsPositionsLedger.
    uint256 internal constant CAP_APPLY_PERP_POSITION_DELTA = 1 << 6;

    /// @notice Permits the caller to debit collateral toward the protocol fee vault subKey.
    uint256 internal constant CAP_APPLY_FEE = 1 << 7;

    /// @notice Permits the caller to credit collateral from the rebate source subKey.
    uint256 internal constant CAP_APPLY_REBATE = 1 << 8;

    /// @notice Permits the caller to apply exercise and settlement to option positions.
    uint256 internal constant CAP_SETTLE_OPTION = 1 << 9;

    /// @notice Permits the caller to liquidate options positions.
    uint256 internal constant CAP_LIQUIDATE_OPTIONS = 1 << 10;

    /// @notice Permits the caller to liquidate perp positions.
    uint256 internal constant CAP_LIQUIDATE_PERPS = 1 << 11;

    /// @notice Reserved capability for internal-transfer flows (unused in V1).
    uint256 internal constant CAP_EXECUTE_INTERNAL_TRANSFER = 1 << 12;

    /// @notice Reserved capability for replay-nonce consumption (unused in V1).
    uint256 internal constant CAP_CONSUME_REPLAY_NONCE = 1 << 13;

    /// @notice Permits an authorized delegate to activate recovery on behalf of the canonical owner.
    /// @dev Not granted by default in V1. Reserved for future wallet-session-keys-v1.
    ///      Introduced by escape-hatch spec 15.
    uint256 internal constant CAP_RECOVERY_ACTIVATE = 1 << 14;

    /// @notice Permits the caller to atomically transfer Options premium value between
    ///         two subKeys of possibly-different owners, in the frozen QUOTE_TOKEN
    ///         numeraire, without moving physical token custody.
    /// @dev Introduced by `ONCHAIN-SUBACCOUNT-OPTION-MATCHING-ENGINE-V2-V1` (WP-08B).
    ///      Enforcement lives in
    ///      `ICollateralVault.applyOptionPremiumTransfer(payerSubKey, receiverSubKey, token, amount)`.
    ///      NARROWLY-SCOPED — the primitive rejects same-subKey, zero amounts,
    ///      unavailable-balance payer, and unknown collateral tokens. It is the
    ///      SOLE Vault path through which a matching engine may move Options
    ///      premium value across owners in V1.
    uint256 internal constant CAP_APPLY_OPTIONS_PREMIUM = 1 << 15;

    /// @notice The highest currently-assigned capability bit index.
    /// @dev Downstream tooling MAY use this to iterate assigned bits.
    ///      Reserved bits above this index are for future capabilities.
    ///      Bit 15 is the CAP_APPLY_OPTIONS_PREMIUM boundary added by WP-08B
    ///      and preserved unchanged by
    ///      `ONCHAIN-SUBACCOUNT-OPTION-ORDER-LIFECYCLE-AND-NONCE-V2-PATCH`.
    ///      Bit 16 remains RESERVED for a future capability extension and
    ///      MUST NOT be granted by any code path in this deployment.
    uint8 internal constant HIGHEST_ASSIGNED_BIT = 15;

    /// @notice Bitmask of every capability currently declared.
    /// @dev Sum of all CAP_* constants above (bits 0..15 set, bits 16..255 zero).
    ///      Any bit at or above index 16 in an engine capability bitmap
    ///      indicates a corrupted or unauthorized grant path.
    uint256 internal constant ALL_CAPABILITIES = (1 << 16) - 1;
}
