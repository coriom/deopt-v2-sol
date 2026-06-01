// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IProtocolFeeVault} from "./IProtocolFeeVault.sol";
import {ICollateralVaultInternalTransfer} from "../collateral/ICollateralVaultInternalTransfer.sol";

/// @title ProtocolFeeVault
/// @notice V2G-R1 — production fee-treasury module. Holds positive-fee
///         proceeds and the rebate reserve in per-asset internal
///         buckets. Wired into {FeesManagerV2} as both
///         `feeRecipient` AND `rebateFundingAccount`.
///
/// @dev    Accounting model:
///          - {onFeeCharged} (called by FM-V2 after a positive-fee
///            transfer settles) credits {feeBalance},
///            {grossFeesCollected}, and {netRevenue}.
///          - {onRebatePaid} (called by FM-V2 after a rebate transfer
///            settles) debits {rebateReserve} and {netRevenue} and
///            credits {rebatesPaid}.
///          - {allocateToRebateReserve} shifts funds from
///            {feeBalance} to {rebateReserve} — pure internal book
///            entry, no chain balance change.
///          - {withdrawRevenue} debits {feeBalance} and calls
///            `transferFromInternalAccount` on the collateral vault
///            to move the underlying funds out to the recipient.
///          - {bootstrap} writes initial buckets per asset, one-time.
///
///         Invariants (offline tested):
///          1. `grossFeesCollected[a] − rebatesPaid[a] == netRevenue[a]`
///          2. `feeBalance[a] + rebateReserve[a] == modeled CV balance`
///          3. `grossFeesCollected[a]` and `rebatesPaid[a]` are
///             monotonically non-decreasing
///          4. Pause: while {rebatesPaused} is true, {onRebatePaid}
///             reverts; {allocateToRebateReserve} and {withdrawRevenue}
///             still work — withdraw can only touch {feeBalance},
///             never {rebateReserve}.
contract ProtocolFeeVault is IProtocolFeeVault, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RevenueReceiverUpdated(address indexed previous, address indexed next);

    event FeeRecorded(address indexed asset, uint256 amount);
    event RebateRecorded(address indexed asset, uint256 amount);
    event RebateReserveAllocated(address indexed asset, uint256 amount);
    event RevenueWithdrawn(address indexed asset, address indexed to, uint256 amount);

    event RebatesPaused(address indexed by);
    event RebatesUnpaused(address indexed by);

    event BootstrapCompleted(
        address indexed asset, uint256 grossFees, uint256 rebates, uint256 feeBalance, uint256 rebateReserve
    );

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error AmountZero();
    error NotOwner();
    error NotFeesManagerV2();
    error InsufficientFeeBalance(uint256 available, uint256 requested);
    error InsufficientRebateReserve(uint256 available, uint256 requested);
    error RebatesPausedError();
    error AlreadyBootstrapped();
    error InvalidBootstrapValues();
    error NotRebatePausedAware();

    /*//////////////////////////////////////////////////////////////
                                IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable override collateralVault;
    address public immutable override feesManagerV2;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    address public owner;
    address public override revenueReceiver;
    bool public override rebatesPaused;

    mapping(address => uint256) public override feeBalance;
    mapping(address => uint256) public override rebateReserve;
    mapping(address => uint256) public override grossFeesCollected;
    mapping(address => uint256) public override rebatesPaid;
    mapping(address => uint256) public override netRevenue;
    mapping(address => bool) public override bootstrapped;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyFeesManagerV2() {
        if (msg.sender != feesManagerV2) revert NotFeesManagerV2();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address owner_, address collateralVault_, address feesManagerV2_) {
        if (owner_ == address(0) || collateralVault_ == address(0) || feesManagerV2_ == address(0)) {
            revert ZeroAddress();
        }

        owner = owner_;
        collateralVault = collateralVault_;
        feesManagerV2 = feesManagerV2_;

        emit OwnershipTransferred(address(0), owner_);
    }

    /*//////////////////////////////////////////////////////////////
                                  OWNER
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setRevenueReceiver(address newReceiver) external onlyOwner {
        if (newReceiver == address(0)) revert ZeroAddress();
        address previous = revenueReceiver;
        revenueReceiver = newReceiver;
        emit RevenueReceiverUpdated(previous, newReceiver);
    }

    /*//////////////////////////////////////////////////////////////
                                  PAUSE
    //////////////////////////////////////////////////////////////*/

    function pauseRebates() external onlyOwner {
        rebatesPaused = true;
        emit RebatesPaused(msg.sender);
    }

    function unpauseRebates() external onlyOwner {
        rebatesPaused = false;
        emit RebatesUnpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                BOOTSTRAP
    //////////////////////////////////////////////////////////////*/

    /// @notice One-time, owner-only initial bucket snapshot for an
    ///         asset. Used at cutover to backfill the V2G-G fee event
    ///         history into the vault's on-chain counters so the vault
    ///         is the single source of truth from day 1.
    /// @dev    Subsequent calls for the same asset revert with
    ///         {AlreadyBootstrapped}. Values must satisfy
    ///         `rebates_ <= grossFees_` and
    ///         `feeBalance_ + rebateReserve_ <= grossFees_ - rebates_`
    ///         (the spendable buckets cannot exceed the net inflow).
    function bootstrap(address asset, uint256 grossFees_, uint256 rebates_, uint256 feeBalance_, uint256 rebateReserve_)
        external
        onlyOwner
    {
        if (asset == address(0)) revert ZeroAddress();
        if (bootstrapped[asset]) revert AlreadyBootstrapped();
        if (rebates_ > grossFees_) revert InvalidBootstrapValues();
        uint256 net = grossFees_ - rebates_;
        if (feeBalance_ + rebateReserve_ > net) revert InvalidBootstrapValues();

        grossFeesCollected[asset] = grossFees_;
        rebatesPaid[asset] = rebates_;
        netRevenue[asset] = net;
        feeBalance[asset] = feeBalance_;
        rebateReserve[asset] = rebateReserve_;
        bootstrapped[asset] = true;

        emit BootstrapCompleted(asset, grossFees_, rebates_, feeBalance_, rebateReserve_);
    }

    /*//////////////////////////////////////////////////////////////
                                  HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IProtocolFeeVault
    function onFeeCharged(address asset, uint256 amount) external override onlyFeesManagerV2 {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        feeBalance[asset] += amount;
        grossFeesCollected[asset] += amount;
        netRevenue[asset] += amount;

        emit FeeRecorded(asset, amount);
    }

    /// @inheritdoc IProtocolFeeVault
    function onRebatePaid(address asset, uint256 amount) external override onlyFeesManagerV2 {
        if (rebatesPaused) revert RebatesPausedError();
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) return;

        uint256 reserve = rebateReserve[asset];
        if (reserve < amount) revert InsufficientRebateReserve(reserve, amount);
        unchecked {
            rebateReserve[asset] = reserve - amount;
        }
        rebatesPaid[asset] += amount;

        // netRevenue is the cached identity grossFees - rebates.
        // Solidity 0.8 arithmetic underflows revert by default, which
        // is the desired behaviour — netRevenue must never go below
        // zero because invariant 1 guarantees rebates <= grossFees.
        netRevenue[asset] -= amount;

        emit RebateRecorded(asset, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN ACTIONS
    //////////////////////////////////////////////////////////////*/

    function allocateToRebateReserve(address asset, uint256 amount) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();
        uint256 fb = feeBalance[asset];
        if (fb < amount) revert InsufficientFeeBalance(fb, amount);
        unchecked {
            feeBalance[asset] = fb - amount;
        }
        rebateReserve[asset] += amount;
        emit RebateReserveAllocated(asset, amount);
    }

    /// @notice Withdraw `amount` of `asset` from the vault's
    ///         {feeBalance} bucket to the external recipient `to`.
    /// @dev    `to` is supplied explicitly per the V2G-R task spec.
    ///         Operator tooling should pass {revenueReceiver} as `to`
    ///         to match the design intent; the contract does not
    ///         enforce equality so the owner can route to ad-hoc
    ///         destinations under timelock authority.
    ///
    ///         Refuses to touch {rebateReserve} — invariant 4. To
    ///         move funds out of the reserve, owner must first call
    ///         {allocateToRebateReserve} in reverse (not currently
    ///         implemented; a future {deallocateFromRebateReserve}
    ///         would be a separate hardening step).
    function withdrawRevenue(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (asset == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountZero();

        uint256 fb = feeBalance[asset];
        if (fb < amount) revert InsufficientFeeBalance(fb, amount);
        unchecked {
            feeBalance[asset] = fb - amount;
        }

        ICollateralVaultInternalTransfer(collateralVault).transferFromInternalAccount(asset, to, amount);

        emit RevenueWithdrawn(asset, to, amount);
    }
}
