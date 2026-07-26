// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

/// @title ISubaccountRegistry
/// @notice Canonical identity boundary for the DeOpt V2 hybrid subaccount architecture.
/// @dev
///  External identity: `(address owner, uint32 subaccountId)`.
///  Internal identity: `bytes32 subKey`, derived by `SubKey.deriveHere(address(this), owner, subaccountId)`.
///  Account 0 is invalid; Account 1 is the lazy default per D-03.
///
///  Ownership is immutable per (owner, subaccountId) pair. Subaccount ids are
///  monotonic per owner starting at 1. Non-transferable in V1 (D-01).
///
///  This interface declares the compile-time boundary consumed by downstream
///  milestones. The concrete SubaccountRegistry implementation lives in
///  `ONCHAIN-SUBACCOUNT-REGISTRY-V1` (WP-02); this file introduces no state.
interface ISubaccountRegistry {
    /*//////////////////////////////////////////////////////////////
                                MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Register the next monotonic subaccount id for the caller.
    /// @dev Caller: `msg.sender = owner`. Emits `SubaccountCreated`. Reverts
    ///      with `InvalidOwner()` if `msg.sender == address(0)`. Reverts with
    ///      `RegistrationOverflow()` if the owner has consumed `type(uint32).max`.
    /// @return subaccountId The newly assigned id (1 for the first call).
    /// @return subKey The canonical internal key for the new subaccount.
    function registerNext() external returns (uint32 subaccountId, bytes32 subKey);

    /// @notice Lazily register Account 1 for `owner` if it does not yet exist.
    /// @dev Caller MUST hold `Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT` via the vault.
    ///      Idempotent: no-op if Account 1 already exists. Reverts with
    ///      `NotAuthorized()` if the caller lacks the capability.
    ///      Emits `SubaccountLazyRegistered` when registration actually occurs.
    /// @param owner The canonical owner for which to lazily register Account 1.
    function registerLazyDefault(address owner) external;

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deterministic derivation of the canonical internal subKey.
    /// @dev Equivalent to `SubKey.deriveHere(address(this), owner, subaccountId)`.
    ///      Returns a non-zero value even when the (owner, subaccountId) pair
    ///      does not yet exist. Callers requiring existence semantics MUST
    ///      pair this with `existsOf`.
    function subKeyOf(address owner, uint32 subaccountId) external view returns (bytes32);

    /// @notice Existence check for a `(owner, subaccountId)` pair.
    function existsOf(address owner, uint32 subaccountId) external view returns (bool);

    /// @notice Reverse-lookup canonical owner for a subKey.
    /// @dev Returns `address(0)` when the subKey has not been registered.
    function ownerOf(bytes32 subKey) external view returns (address);

    /// @notice Reverse-lookup subaccount id for a subKey.
    /// @dev Returns `0` when the subKey has not been registered.
    function subaccountIdOf(bytes32 subKey) external view returns (uint32);

    /// @notice Next assignable subaccount id for `owner`.
    /// @dev Returns `1` before any registration. Returns `type(uint32).max + 1`
    ///      only in the pathological (unreachable in practice) case where
    ///      overflow would occur; implementations SHOULD instead revert on
    ///      registration attempt.
    function nextIdFor(address owner) external view returns (uint32);

    /// @notice Paged enumeration of subaccounts owned by `owner`.
    /// @param owner The owner to enumerate.
    /// @param offset Starting subaccount id offset (>= 0).
    /// @param limit Maximum number of entries to return (bounded by MAX_BATCH_SIZE).
    /// @return ids Subaccount ids in ascending order.
    /// @return subKeys Corresponding subKeys.
    function subaccountsOfPage(address owner, uint32 offset, uint32 limit)
        external
        view
        returns (uint32[] memory ids, bytes32[] memory subKeys);

    /// @notice Immutable chain id at deployment of this registry.
    function deploymentChainId() external view returns (uint256);

    /// @notice Immutable block number at deployment of this registry.
    function deploymentBlock() external view returns (uint64);

    /// @notice Registry interface version string ("1" in V1).
    function version() external pure returns (string memory);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on direct owner-initiated registration.
    event SubaccountCreated(
        address indexed owner, uint32 indexed subaccountId, bytes32 indexed subKey, uint256 chainId, uint16 eventVersion
    );

    /// @notice Emitted when a capability-holding engine lazily registers Account 1.
    event SubaccountLazyRegistered(
        address indexed owner,
        uint32 indexed subaccountId,
        bytes32 indexed subKey,
        uint256 chainId,
        address viaEngine,
        uint16 eventVersion
    );

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner is the zero address.
    error InvalidOwner();

    /// @notice Subaccount id counter for the owner would overflow `uint32`.
    error RegistrationOverflow();

    /// @notice Caller lacks the required capability for a privileged action.
    error NotAuthorized();
}
