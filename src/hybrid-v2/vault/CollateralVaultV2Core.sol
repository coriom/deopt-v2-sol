// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {VaultCapabilityController} from "./VaultCapabilityController.sol";
import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title CollateralVaultV2Core
/// @notice Abstract custody + isolated balance + token-policy foundation of the DeOpt V2
///         shared collateral vault (WP-04A).
/// @dev
///  Owns the FOUNDATION only:
///   - immutable `SubaccountRegistry` reference — canonical identity source;
///   - governance-controlled token allowlist (via inherited `onlyGovernance`);
///   - `mapping((subKey, token) => uint256)` isolated balances;
///   - `mapping(token => uint256)` aggregate accounted liability;
///   - `deposit` (owner-initiated with lazy Account 1) + `depositFor` (third-party);
///   - solvency + reconciliation views;
///   - inherits `VaultCapabilityController` for engine authorization storage.
///
///  Explicit non-scope of V2-A (owned by V2-B):
///   - per-engine collateral reservations (`applyLock` / `applyUnlock`);
///   - aggregate `totalLocked[subKey][token]`;
///   - user withdrawals (`withdraw` / `withdrawFor`);
///   - internal transfers;
///   - fee/rebate/liquidation/settlement debits + credits;
///   - orphaned-lock release;
///   - pause matrix;
///   - yield adapter integration.
///
///  ABI note — `setAuthorizedEngine` was removed from `ICollateralVault` in this
///  milestone. `isAuthorizedEngine(engine)` is DERIVED (`bits != 0`) per spec 07.
///  The sole engine-authority entrypoint is `setEngineCapability`.
///
///  Deployment cycle: `SubaccountRegistry.capabilityAuthority` must point at the
///  deployed vault; the vault stores the registry as an immutable. Resolution via
///  CREATE2 salt / deterministic-nonce / factory in deployment scripts (out of
///  scope for this milestone).
///
///  Lazy Account 1: the vault itself is treated as an "engine" that must hold
///  `Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT` in order for `deposit(subaccountId=1)`
///  to lazily register a fresh owner. Governance grants this to the vault post-
///  deployment. `depositFor` NEVER triggers lazy registration (spec 03).
///
///  This abstract does NOT declare `is ICollateralVault` because it implements only
///  a subset of that interface. V2-B extends this core and completes the interface.
abstract contract CollateralVaultV2Core is VaultCapabilityController, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical identity source. Immutable at construction.
    /// @dev The vault derives subKeys via `REGISTRY.subKeyOf(owner, subaccountId)`
    ///      so the deployment-scoped registry address is bound into every key.
    ISubaccountRegistry public immutable REGISTRY;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Token allowlist. `true` iff governance has enabled the token for deposits.
    mapping(address => bool) internal _tokenEnabled;

    /// @dev Canonical isolated balance per (subKey, token).
    mapping(bytes32 => mapping(address => uint256)) internal _balanceOf;

    /// @dev Aggregate accounted liability per token — the invariant
    ///      `IERC20(token).balanceOf(address(this)) >= _totalAccounted[token]`
    ///      MUST hold at all times.
    mapping(address => uint256) internal _totalAccounted;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every successful deposit.
    /// @dev Matches `ICollateralVault.Deposit`. Reconstructible from indexed subKey +
    ///      readable owner + subaccountId + token + amount + depositor.
    event Deposit(
        bytes32 indexed subKey,
        address indexed owner,
        uint32 indexed subaccountId,
        address token,
        uint256 amount,
        address depositor,
        uint16 eventVersion
    );

    /// @notice Emitted when governance enables a token for deposits.
    event SupportedTokenAdded(address indexed token, uint16 eventVersion);

    /// @notice Emitted when governance disables a token for new deposits.
    /// @dev Existing balances are preserved unconditionally.
    event SupportedTokenRemoved(address indexed token, uint16 eventVersion);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Registry argument at construction was `address(0)`.
    error InvalidRegistry();

    /// @notice Token argument was `address(0)`.
    error InvalidToken();

    /// @notice Owner argument was `address(0)`.
    error InvalidOwner();

    /// @notice Subaccount id argument was zero (Account 0 is invalid).
    error InvalidSubaccountId();

    /// @notice `(owner, subaccountId)` is not registered in the canonical registry.
    error SubaccountNotFound(address owner, uint32 subaccountId);

    /// @notice Token is not in the current allowlist.
    error TokenNotSupported();

    /// @notice Token is already enabled; duplicate allowlist grant rejected.
    error TokenAlreadySupported();

    /// @notice Token is already disabled; duplicate allowlist removal rejected.
    error TokenNotEnabled();

    /// @notice Deposit amount is zero.
    error AmountZero();

    /// @notice Physical balance delta did not equal the requested deposit amount.
    /// @dev Rejects fee-on-transfer, rebasing, and other non-standard ERC-20 tokens
    ///      whose `transferFrom` credits less than requested. Defense in depth even
    ///      when governance mistakenly enables such a token.
    error InvalidTokenBalanceDelta(uint256 requested, uint256 credited);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address registry_, address governance_, address guardian_)
        VaultCapabilityController(governance_, guardian_)
    {
        if (registry_ == address(0)) revert InvalidRegistry();
        REGISTRY = ISubaccountRegistry(registry_);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE — TOKEN POLICY
    //////////////////////////////////////////////////////////////*/

    /// @notice Enable `token` for deposits. Governance-only.
    /// @dev Reverts `InvalidToken` on zero, `TokenAlreadySupported` on duplicate.
    ///      Emits `SupportedTokenAdded`.
    function addSupportedToken(address token) external onlyGovernance {
        if (token == address(0)) revert InvalidToken();
        if (_tokenEnabled[token]) revert TokenAlreadySupported();
        _tokenEnabled[token] = true;
        emit SupportedTokenAdded(token, Versions.EVENT_VERSION);
    }

    /// @notice Disable `token` for new deposits. Governance-only.
    /// @dev Existing balances + aggregate liability are preserved unconditionally.
    ///      Reverts `TokenNotEnabled` if the token is not currently enabled.
    ///      Emits `SupportedTokenRemoved`.
    function removeSupportedToken(address token) external onlyGovernance {
        if (!_tokenEnabled[token]) revert TokenNotEnabled();
        _tokenEnabled[token] = false;
        emit SupportedTokenRemoved(token, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                              DEPOSITS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit `amount` of `token` into the caller's subaccount.
    /// @dev Caller = economic owner. When `subaccountId == 1` and Account 1 does not
    ///      yet exist for the caller, the vault lazily registers it via the registry
    ///      (requires the vault to hold `CAP_REGISTER_DEFAULT_ACCOUNT`; granted by
    ///      governance post-deployment). For any `subaccountId != 1` the account
    ///      MUST be pre-registered via `SubaccountRegistry.registerNext()`.
    ///
    ///      Uses SafeERC20; validates the exact physical balance delta; reverts
    ///      `InvalidTokenBalanceDelta` on any shortfall (fee-on-transfer / rebasing).
    function deposit(uint32 subaccountId, address token, uint256 amount) external nonReentrant {
        address owner = msg.sender;
        if (owner == address(0)) revert InvalidOwner();
        if (subaccountId == 0) revert InvalidSubaccountId();
        if (token == address(0)) revert InvalidToken();
        if (!_tokenEnabled[token]) revert TokenNotSupported();
        if (amount == 0) revert AmountZero();

        // Lazy Account 1 for the owner path.
        if (subaccountId == 1 && !REGISTRY.existsOf(owner, 1)) {
            REGISTRY.registerLazyDefault(owner);
        }
        if (!REGISTRY.existsOf(owner, subaccountId)) revert SubaccountNotFound(owner, subaccountId);

        _pullAndCredit(REGISTRY.subKeyOf(owner, subaccountId), owner, subaccountId, owner, token, amount);
    }

    /// @notice Third-party deposit of `amount` of `token` on behalf of `owner`'s subaccount.
    /// @dev Payer = `msg.sender`, credited owner = `owner`. Does NOT lazily register.
    ///      Requires `(owner, subaccountId)` to already exist. Payer receives no
    ///      ownership or withdrawal authority.
    function depositFor(address owner, uint32 subaccountId, address token, uint256 amount) external nonReentrant {
        if (owner == address(0)) revert InvalidOwner();
        if (subaccountId == 0) revert InvalidSubaccountId();
        if (token == address(0)) revert InvalidToken();
        if (!_tokenEnabled[token]) revert TokenNotSupported();
        if (amount == 0) revert AmountZero();

        if (!REGISTRY.existsOf(owner, subaccountId)) revert SubaccountNotFound(owner, subaccountId);

        _pullAndCredit(REGISTRY.subKeyOf(owner, subaccountId), owner, subaccountId, msg.sender, token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical isolated balance for `(subKey, token)`.
    /// @dev Matches `ICollateralVault.balanceOf` and represents the CANONICAL bookkeeping
    ///      figure for V2-A (no reservations exist yet). V2-B will introduce
    ///      `availableOf = balanceOf - lockedOf` and `lockedOf` semantics.
    function balanceOf(bytes32 subKey, address token) external view returns (uint256) {
        return _balanceOf[subKey][token];
    }

    /// @notice Convenience read using the readable `(owner, subaccountId)` identity.
    function balanceOfAccount(address owner, uint32 subaccountId, address token) external view returns (uint256) {
        return _balanceOf[REGISTRY.subKeyOf(owner, subaccountId)][token];
    }

    /// @notice Whether `token` is currently enabled for new deposits.
    /// @dev Matches `ICollateralVault.supportedTokens`.
    function supportedTokens(address token) external view returns (bool) {
        return _tokenEnabled[token];
    }

    /// @notice Aggregate accounted liability for `token` across all subaccounts.
    /// @dev Increments on every successful deposit; V2-B will manage decrements
    ///      via withdrawals + settlement + liquidation.
    function totalAccounted(address token) external view returns (uint256) {
        return _totalAccounted[token];
    }

    /// @notice Physical ERC-20 balance held by this vault contract.
    function physicalBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice True iff `physicalBalance(token) >= totalAccounted(token)`.
    /// @dev The core custody invariant. Independent chain-side check; the reconciler
    ///      + AT-12 drill assert this against every supported token.
    function isSolvent(address token) external view returns (bool) {
        return IERC20(token).balanceOf(address(this)) >= _totalAccounted[token];
    }

    /// @notice Physical balance minus accounted liability. Zero when insolvent
    ///         (never underflows).
    /// @dev Represents excess collateral that arrived via direct token transfer
    ///      rather than through `deposit` / `depositFor`. Excess is NEVER credited
    ///      to any subaccount by V2-A; excess-recovery policy is deferred.
    function surplus(address token) external view returns (uint256) {
        uint256 physical = IERC20(token).balanceOf(address(this));
        uint256 accounted = _totalAccounted[token];
        return physical > accounted ? physical - accounted : 0;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev SafeERC20 pull + exact balance-delta validation + credit + event.
    ///      Called by both `deposit` and `depositFor`. `nonReentrant` is applied on
    ///      the external entrypoints; this internal helper is not itself guarded but
    ///      is never called from a re-entrant context because both callers hold the
    ///      guard.
    function _pullAndCredit(
        bytes32 subKey,
        address owner,
        uint32 subaccountId,
        address payer,
        address token,
        uint256 amount
    ) internal {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(payer, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        uint256 credited = balanceAfter - balanceBefore;
        if (credited != amount) revert InvalidTokenBalanceDelta(amount, credited);

        _balanceOf[subKey][token] += amount;
        _totalAccounted[token] += amount;

        emit Deposit(subKey, owner, subaccountId, token, amount, payer, Versions.EVENT_VERSION);
    }
}
