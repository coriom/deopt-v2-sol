// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

// PERPS_V2_CLEARING_ACCOUNT_CONTRACT_V1
// Hardened settlement-liquidity holder for PerpEngineV2.
//
// Custody model (see docs/PERPS_V2_CLEARING_ACCOUNT_CONTRACT_V1.md):
//   - The contract holds an internal balance in CollateralVault under its
//     own address. The balance is created by this contract calling
//     `Vault.deposit(...)` itself, so `msg.sender = this contract` at the
//     Vault-level credit.
//   - The contract has ZERO code paths that call any Vault drain function:
//       * `Vault.withdraw`
//       * `Vault.withdrawFor`
//       * `Vault.transferFromInternalAccount`
//       * `Vault.transferBetweenAccounts`
//       * `Vault.moveToStrategy` / `moveToIdle`
//       * `Vault.setYieldOptIn`
//     Therefore the ONLY way the clearing balance moves is via an
//     `onlyMarginEngine` call to `Vault.transferBetweenAccounts(...)`
//     with this contract as `from` or `to`.
//   - The contract has no owner, no upgradability, no delegatecall, no
//     arbitrary-call surface, and no emergency drain. Governance can
//     remove V1/V2 engine authorization on the Vault side to isolate the
//     clearing balance; there is no clearing-side kill switch. This is
//     deliberate for the V1 rollout per milestone §4 — a
//     governance-gated pause-first emergency recover is a scoped future
//     milestone.
//
// Approval hygiene:
//   Each `fundClearing` call issues a scoped approval to the Vault for
//   exactly the amount to be deposited, then resets to 0 after the
//   deposit resolves. No dangling live approvals across calls.
//
// Funding surface:
//   Permissionless (anyone can top up). Draining is impossible via
//   this contract's own methods. Governance-controlled funding
//   ceremonies are just ordinary permissioned senders calling
//   `fundClearing` — no bespoke ACL required at this layer.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal Vault interface — deposit surface only. This contract
///      intentionally does not know about any Vault drain function, so
///      no calldata to invoke them can ever be constructed here.
interface ICollateralVaultDepositOnly {
    function deposit(address token, uint256 amount) external;
}

contract PerpClearingAccountV2 {
    using SafeERC20 for IERC20;

    /// @notice The CollateralVault this clearing account deposits into.
    /// @dev Immutable; set at construction. No setter exists.
    ICollateralVaultDepositOnly public immutable collateralVault;

    error ZeroAddress();
    error AmountZero();
    error ReceivedZero();

    /// @notice Emitted after a successful `fundClearing` call.
    /// @param funder  address that supplied the ERC20 tokens
    /// @param asset   ERC20 collateral asset deposited
    /// @param amount  amount credited to this contract's Vault balance
    ///                (post fee-on-transfer, i.e. what the Vault actually
    ///                received)
    event ClearingFunded(address indexed funder, address indexed asset, uint256 amount);

    constructor(address _vault) {
        if (_vault == address(0)) revert ZeroAddress();
        collateralVault = ICollateralVaultDepositOnly(_vault);
    }

    /// @notice Fund this clearing account's Vault balance with `amount` of
    ///         `asset`. Caller must have approved at least `amount` on
    ///         `asset` to this contract.
    /// @dev
    ///   Flow:
    ///     1. Pull `amount` of `asset` from `msg.sender` into this contract.
    ///     2. Approve the Vault to withdraw the exact received amount.
    ///     3. Call `Vault.deposit(...)` — Vault credits `msg.sender`
    ///        (which is this contract) in its internal `balances` mapping.
    ///     4. Reset approval to 0 for hygiene (the Vault will already have
    ///        consumed it, but the reset is defense-in-depth against
    ///        deposit implementations that don't fully drain the allowance).
    ///
    ///   Reentrancy stance:
    ///     - `safeTransferFrom` may re-enter for tokens with ERC777 or
    ///       hook-based callbacks. Because this contract has no drain
    ///       surface, no reentrant call can cause a loss. State is not
    ///       mutated in this contract (only Vault state changes), so no
    ///       cross-call state confusion is possible.
    function fundClearing(address asset, uint256 amount) external {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        IERC20 token = IERC20(asset);

        uint256 preBal = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = token.balanceOf(address(this)) - preBal;
        if (received == 0) revert ReceivedZero();

        // Scope the approval to exactly what we deposit; clear afterwards.
        token.forceApprove(address(collateralVault), received);
        collateralVault.deposit(asset, received);
        token.forceApprove(address(collateralVault), 0);

        emit ClearingFunded(msg.sender, asset, received);
    }
}
