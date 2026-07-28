// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title ICollateralVault (v2)
/// @notice Canonical custody + reservation + capability boundary for the DeOpt V2 hybrid subaccount architecture.
/// @dev
///  Balances keyed by `bytes32 subKey`. Per-engine reservation accounting.
///  Least-privilege capability model per `src/hybrid-v2/libraries/Capabilities.sol`.
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete CollateralVault v2 implementation lives in
///  `ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-A/B` (WP-04A/B). This file
///  introduces no state.
///
///  Pause matrix: `pauseDeposits`, `pauseWithdrawals`, `pauseInternalTransfers`,
///  `pauseYieldOps` are guardian OR owner immediate; corresponding `unpause*`
///  paths are owner-only (recommended >=24h timelock in future variants).
interface ICollateralVault {
    /*//////////////////////////////////////////////////////////////
                              OWNER-CALLABLE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit tokens into the caller's `subaccountId`. Lazy-registers Account 1 as needed.
    function deposit(uint32 subaccountId, address token, uint256 amount) external;

    /// @notice Deposit tokens on behalf of `owner`'s `subaccountId` (third-party top-up).
    function depositFor(address owner, uint32 subaccountId, address token, uint256 amount) external;

    /// @notice Withdraw tokens from the caller's `subaccountId` after margin-safety check.
    function withdraw(uint32 subaccountId, address token, uint256 amount) external;

    /// @notice Atomic same-owner internal transfer between two subaccounts.
    /// @dev Both source and destination MUST remain margin-safe after the transfer.
    function internalTransfer(address token, uint32 fromSubaccountId, uint32 toSubaccountId, uint256 amount) external;

    /*//////////////////////////////////////////////////////////////
                          YIELD ADAPTER INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Move collateral to a yield adapter (interface unchanged from V1).
    function moveToStrategy(uint32 subaccountId, address token, address adapter, uint256 amount) external;

    /// @notice Move collateral back from a yield adapter (interface unchanged from V1).
    function moveFromStrategy(uint32 subaccountId, address token, address adapter, uint256 amount) external;

    /// @notice Opt in or out of yield routing for a token on a subaccount.
    function setYieldOptIn(uint32 subaccountId, address token, bool opt) external;

    /*//////////////////////////////////////////////////////////////
                    ENGINE-CALLABLE (CAPABILITY-GATED)
    //////////////////////////////////////////////////////////////*/

    /// @notice Debit `subKey` balances and external-transfer to `to`.
    /// @dev Caller MUST hold `Capabilities.CAP_WITHDRAW_FOR`.
    function withdrawFor(bytes32 subKey, address to, address token, uint256 amount) external;

    /// @notice Credit `subKey` balances by `amount`.
    /// @dev Caller MUST hold `Capabilities.CAP_CREDIT_COLLATERAL`.
    function creditCollateral(bytes32 subKey, address token, uint256 amount) external;

    /// @notice Reserve `amount` of `token` for `subKey`, attributed to the calling engine.
    /// @dev Caller MUST hold `Capabilities.CAP_LOCK_COLLATERAL`.
    function applyLock(bytes32 subKey, address token, uint256 amount) external;

    /// @notice Release `amount` of the calling engine's OWN reservation for `subKey`.
    /// @dev Caller MUST hold `Capabilities.CAP_UNLOCK_OWN_RESERVATION`. May not
    ///      release another engine's reservation (ISR-008 mitigation).
    function applyUnlock(bytes32 subKey, address token, uint256 amount) external;

    /// @notice Debit `subKey` and credit the fee-recipient subKey.
    /// @dev Caller MUST hold `Capabilities.CAP_APPLY_FEE`.
    function applyFeeDebit(bytes32 subKey, address token, uint256 amount, bytes32 feeRecipientSubKey) external;

    /// @notice Credit `subKey` from `rebateSourceSubKey` by `amount`.
    /// @dev Caller MUST hold `Capabilities.CAP_APPLY_REBATE`.
    function applyRebateCredit(bytes32 subKey, address token, uint256 amount, bytes32 rebateSourceSubKey) external;

    /// @notice Seize collateral from `subKey` on liquidation and credit `liquidatorSubKey`.
    /// @dev Caller MUST hold `Capabilities.CAP_LIQUIDATE_OPTIONS` or `CAP_LIQUIDATE_PERPS`.
    function applyLiquidationDebit(bytes32 subKey, address token, uint256 amount, bytes32 liquidatorSubKey) external;

    /// @notice Atomic signed-delta settlement application.
    /// @dev Caller MUST hold `Capabilities.CAP_SETTLE_OPTION`. Positive `delta`
    ///      credits, negative debits. Reverts if debit would underflow available.
    function applySettlementCreditDebit(bytes32 subKey, address token, int256 delta) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Total balance held for (subKey, token), including reservations.
    function balanceOf(bytes32 subKey, address token) external view returns (uint256);

    /// @notice Total amount reserved across all engines for (subKey, token).
    function lockedOf(bytes32 subKey, address token) external view returns (uint256);

    /// @notice Convenience: `balanceOf - lockedOf` for (subKey, token).
    function availableOf(bytes32 subKey, address token) external view returns (uint256);

    /// @notice Amount reserved by a specific engine for (subKey, token).
    function lockedByEngineOf(bytes32 subKey, address token, address engine) external view returns (uint256);

    /// @notice Fast "has any capability?" check for an engine.
    function isAuthorizedEngine(address engine) external view returns (bool);

    /// @notice Bitmask of capabilities currently granted to `engine`.
    function engineCapabilityBits(address engine) external view returns (uint256);

    /// @notice Token whitelist check for CURRENT deposits.
    /// @dev Distinct from `isKnownCollateralToken`: a token may be known
    ///      (and hold existing balances) while currently disabled for new
    ///      deposits. Risk views that require the CANONICAL COLLATERAL
    ///      UNIVERSE (e.g. WP-08 liquidation completeness) MUST iterate the
    ///      universe views below, NOT this enable flag.
    function supportedTokens(address token) external view returns (bool);

    /*//////////////////////////////////////////////////////////////
                    CANONICAL COLLATERAL UNIVERSE
    //////////////////////////////////////////////////////////////*/

    /// @notice Frozen V1 maximum number of DISTINCT collateral tokens that
    ///         may ever enter the canonical collateral universe of this
    ///         Vault deployment. Immutable per deployment (no governance
    ///         setter). Raising it requires a new versioned Vault deployment
    ///         and cutover. Rationale in
    ///         `ONCHAIN_SUBACCOUNT_RISK_EXECUTION_BOUNDS_AND_COLLATERAL_UNIVERSE_V1.md`.
    function maxCollateralTokens() external view returns (uint256);

    /// @notice Current number of tokens in the canonical collateral universe.
    /// @dev Monotone non-decreasing. Bounded above by `maxCollateralTokens()`.
    function collateralTokenCount() external view returns (uint256);

    /// @notice Token at position `index` in insertion order (order of FIRST
    ///         enablement). Reverts on out-of-range index.
    function collateralTokenAt(uint256 index) external view returns (address);

    /// @notice `true` iff `token` has EVER entered the canonical universe.
    ///         Once true, never becomes false. Independent of the current
    ///         deposit-enablement flag returned by `supportedTokens`.
    function isKnownCollateralToken(address token) external view returns (bool);

    /// @notice The entire canonical collateral universe in insertion order.
    /// @dev Bounded size (<= `maxCollateralTokens()`, i.e. 8 in V1). Includes
    ///      tokens that were later disabled — they retain balances + are
    ///      part of the canonical liquidation-completeness universe.
    function collateralUniverse() external view returns (address[] memory);

    /// @notice Well-known internal subKey for the protocol fee vault.
    function protocolFeeVaultSubKey() external view returns (bytes32);

    /// @notice Well-known internal subKey for the insurance fund.
    function insuranceFundSubKey() external view returns (bytes32);

    /*//////////////////////////////////////////////////////////////
                           ADMIN (TIMELOCKED)
    //////////////////////////////////////////////////////////////*/

    /// @notice Grant or revoke a bitmask of capabilities on `engine`.
    /// @dev Caller MUST be the ProtocolTimelock. This is the SOLE engine-authority
    ///      entrypoint: `isAuthorizedEngine(engine)` is derived from
    ///      `engineCapabilityBits(engine) != 0` per spec 07.
    function setEngineCapability(address engine, uint256 capabilityBits, bool allowed) external;

    /// @notice Add a token to the whitelist.
    /// @dev Caller MUST be the ProtocolTimelock.
    function addSupportedToken(address token) external;

    /// @notice Remove a token from the whitelist.
    /// @dev Caller MUST be the ProtocolTimelock.
    function removeSupportedToken(address token) external;

    /*//////////////////////////////////////////////////////////////
                        PAUSE (GUARDIAN OR OWNER)
    //////////////////////////////////////////////////////////////*/

    function pauseDeposits() external;
    function pauseWithdrawals() external;
    function pauseInternalTransfers() external;
    function pauseYieldOps() external;

    /// @notice Owner-only unpause. Recommended timelocked in future variants.
    function unpauseDeposits() external;
    function unpauseWithdrawals() external;
    function unpauseInternalTransfers() external;
    function unpauseYieldOps() external;

    /*//////////////////////////////////////////////////////////////
                           GUARDIAN EMERGENCY
    //////////////////////////////////////////////////////////////*/

    /// @notice Immediately revoke all capabilities from `engine`. Non-revertible; freezes orphaned locks.
    /// @dev Caller MUST be the Guardian.
    function guardianRevokeEngine(address engine) external;

    /*//////////////////////////////////////////////////////////////
                          GOVERNANCE ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Timelocked release of an orphaned per-engine lock.
    /// @dev Caller MUST be the ProtocolTimelock. `reason` is documented in the event.
    function governanceReleaseOrphanedLock(
        bytes32 subKey,
        address token,
        address engine,
        uint256 amount,
        string calldata reason
    ) external;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 indexed subaccountId,
        address token,
        uint256 amount,
        address depositor,
        uint16 eventVersion
    );

    event Withdraw(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 indexed subaccountId,
        address token,
        uint256 amount,
        address receiver,
        uint16 eventVersion
    );

    event InternalTransfer(
        bytes32 indexed fromSubKey,
        bytes32 indexed toSubKey,
        address indexed token,
        uint256 amount,
        address owner,
        uint32 fromSubaccountId,
        uint32 toSubaccountId,
        uint16 eventVersion
    );

    event CollateralLocked(
        bytes32 indexed subKey, address indexed token, address indexed engine, uint256 amount, uint16 eventVersion
    );

    event CollateralUnlocked(
        bytes32 indexed subKey, address indexed token, address indexed engine, uint256 amount, uint16 eventVersion
    );

    event EngineCapabilityChanged(address indexed engine, uint256 addedBits, uint256 removedBits, uint16 eventVersion);

    event EngineGuardianRevoked(address indexed engine, address indexed guardian, uint16 eventVersion);

    event OrphanedLockReleased(
        bytes32 indexed subKey,
        address indexed token,
        address indexed engine,
        uint256 amount,
        string reason,
        uint16 eventVersion
    );

    event SupportedTokenAdded(address indexed token, uint16 eventVersion);
    event SupportedTokenRemoved(address indexed token, uint16 eventVersion);

    /// @notice Emitted the FIRST time a token enters the canonical collateral
    ///         universe. NOT re-emitted on re-enable of an already-known token.
    ///         `index` is the insertion position in the bounded universe.
    event CollateralTokenEnteredUniverse(address indexed token, uint256 index, uint16 eventVersion);

    event PauseFlagChanged(bytes32 indexed flag, bool paused, address indexed by, uint16 eventVersion);

    event BadDebtSocialized(bytes32 indexed subKey, address indexed token, uint256 residual, uint16 eventVersion);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error OnlyOwner();
    error OnlyGuardianOrOwner();
    error OnlyTimelock();
    error EngineNotAuthorized(address engine);
    error MissingCapability(uint256 requiredBits, address caller);
    error ReservationOwnershipMismatch(address engine);
    error OrphanedLockExists(address engine);

    error AmountZero();
    error TokenNotSupported();
    error InvalidTokenBalanceDelta();
    error InsufficientAvailableCollateral();
    error InsufficientLockedCollateral();
    error PausedOperation();
    error TokenAlreadySupported();
    error SubKeyRequired();

    error UnsafeWithdrawal();
    error UnsafeTransfer();
    error InternalTransferSameSubaccount();
    error InternalTransferCrossOwner();

    /// @notice First-enablement of a new collateral token would push the
    ///         canonical universe above `maxCollateralTokens()`.
    error CollateralUniverseLimitExceeded(uint256 currentCount, uint256 maximum);

    /// @notice `collateralTokenAt(index)` called with an out-of-bounds index.
    error CollateralUniverseIndexOutOfBounds(uint256 index, uint256 count);
}
