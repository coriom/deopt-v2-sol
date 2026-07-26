// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IRecoveryView
/// @notice Immutable safe-withdrawal calculator boundary for recovery paths.
/// @dev
///  Provides primary + fallback safe-withdrawal calculations used by
///  `IEscapeController.escapeWithdraw` and off-chain tooling.
///
///  Every view is monotone-non-increasing during recovery per property P-5
///  (escape-hatch design). Fails closed on any unbounded term.
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete RecoveryView implementation lives in
///  `ONCHAIN-SUBACCOUNT-ESCAPE-CONTROLLER-V1-A` (WP-10A). This file
///  introduces no state.
interface IRecoveryView {
    /// @notice Primary safe-withdrawable amount for `(subKey, token)`.
    /// @dev Routes through the replaceable `IRiskModule` for oracle-derived reserves.
    function recoveryWithdrawableOf(bytes32 subKey, address token) external view returns (uint256);

    /// @notice Immutable fallback safe-withdrawable amount for `(subKey, token)`.
    /// @dev Uses deterministic worst-case reserves; always callable regardless
    ///      of the replaceable risk module's availability.
    function recoveryWithdrawableFallback(bytes32 subKey, address token) external view returns (uint256);

    /// @notice Sum of unresolved short-side obligations denominated in `token` for `subKey`.
    function unresolvedObligationsOf(bytes32 subKey, address token) external view returns (uint256);

    /// @notice Reserve for options awaiting fallback finalization, denominated in `token` for `subKey`.
    function settlementReserveOf(bytes32 subKey, address token) external view returns (uint256);

    /// @notice Reserve for pending liquidation, denominated in `token` for `subKey`.
    function liquidationReserveOf(bytes32 subKey, address token) external view returns (uint256);

    /// @notice Paged list of tokens ever held by `subKey`. Off-chain iteration helper.
    function supportedTokensOf(bytes32 subKey) external view returns (address[] memory);

    /// @notice Reserved perp-specific recovery reserve (returns 0 in V1).
    function perpsRecoveryReserveOf(bytes32 subKey, address token) external view returns (uint256);
}
