// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title IProtocolFeeVault
/// @notice V2G-R1 — hook + view surface for the production fee
///         treasury module. The vault holds positive-fee proceeds and
///         the rebate reserve in per-asset internal buckets, updated
///         eagerly on each `consumeFees` leg via the {onFeeCharged} /
///         {onRebatePaid} hooks (Option β in the V2G-R design spec).
///
/// @dev    FeesManagerV2 still owns all fee math (`_effectiveRatePpm`,
///         RFQ discount, tier resolution) AND the canonical rebate cap
///         (`rebateBudget`). The vault is intentionally *not* a fee
///         calculator and *not* a cap holder — it is a per-asset book
///         of buckets the operator can reason about as a single
///         contract.
interface IProtocolFeeVault {
    /*//////////////////////////////////////////////////////////////
                                  HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @notice Called by FeesManagerV2 after a positive-fee
    ///         `CollateralVault.transferBetweenAccounts(asset, trader,
    ///         vault, amount)` settles. The vault uses this to update
    ///         {feeBalance}, {grossFeesCollected}, and {netRevenue}.
    function onFeeCharged(address asset, uint256 amount) external;

    /// @notice Called by FeesManagerV2 after a rebate
    ///         `CollateralVault.transferBetweenAccounts(asset, vault,
    ///         trader, amount)` settles. The vault decrements
    ///         {rebateReserve}, increments {rebatesPaid}, and
    ///         decrements {netRevenue}.
    function onRebatePaid(address asset, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Spendable positive-fee balance per asset. Decreases on
    ///         {withdrawRevenue} and {allocateToRebateReserve}.
    function feeBalance(address asset) external view returns (uint256);

    /// @notice Spendable rebate-reserve balance per asset. Decreases
    ///         on {onRebatePaid}; increases on
    ///         {allocateToRebateReserve}.
    function rebateReserve(address asset) external view returns (uint256);

    /// @notice Monotonic cumulative positive-fee inflow per asset.
    function grossFeesCollected(address asset) external view returns (uint256);

    /// @notice Monotonic cumulative rebate outflow per asset.
    function rebatesPaid(address asset) external view returns (uint256);

    /// @notice Cached identity: {grossFeesCollected} − {rebatesPaid}.
    function netRevenue(address asset) external view returns (uint256);

    /// @notice One-time bootstrap flag per asset. Set by {bootstrap}.
    function bootstrapped(address asset) external view returns (bool);

    /// @notice Operator pause for rebate consumption. While true,
    ///         {onRebatePaid} reverts.
    function rebatesPaused() external view returns (bool);

    /// @notice Operator metadata: the canonical destination for
    ///         {withdrawRevenue}. Not enforced as the only allowed
    ///         `to` value — the owner can withdraw to any non-zero
    ///         address — but tooling should default here.
    function revenueReceiver() external view returns (address);

    /// @notice The trusted collateral-vault ledger that holds the
    ///         vault's internal-account funds.
    function collateralVault() external view returns (address);

    /// @notice The trusted FeesManagerV2 instance allowed to call
    ///         {onFeeCharged} and {onRebatePaid}.
    function feesManagerV2() external view returns (address);
}
