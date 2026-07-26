// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {ISubaccountRegistry} from "../interfaces/ISubaccountRegistry.sol";
import {ICollateralVault} from "../interfaces/ICollateralVault.sol";
import {SubKey} from "../libraries/SubKey.sol";
import {Capabilities} from "../libraries/Capabilities.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title SubaccountRegistry
/// @notice Canonical immutable identity boundary for the DeOpt V2 hybrid subaccount architecture.
/// @dev
///  External identity: `(address owner, uint32 subaccountId)`.
///  Internal identity: `bytes32 subKey = keccak256(abi.encode(chainId, address(this), owner, subaccountId))`.
///
///  Frozen properties (contract-spec 02):
///   - `subaccountId == 0` is invalid.
///   - The first registered id is always `1`.
///   - Per-owner ids are monotonically increasing with no holes and no reuse.
///   - Registration is permanent. There is no deletion, deactivation, transfer,
///     or governance-driven owner reassignment. The registry has no admin.
///   - Metadata (labels, colors, comments) is NOT stored on chain (INV-META-*).
///
///  Deployment metadata (block + chain id) is captured at construction and pinned
///  in immutables so downstream indexers can subscribe from a deterministic block.
///
///  Capability authority: `registerLazyDefault(owner)` requires the caller to hold
///  `Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT` on `capabilityAuthority` (expected to
///  be the CollateralVault v2). The authority address is immutable. The registry
///  itself owns no capability storage — least-privilege authorization belongs to
///  the vault subsystem per contract-spec 07 (WP-03).
///
///  Deployment cycle: the vault also references the registry (for `existsOf`
///  checks during `deposit`). The two-way immutable reference is resolved at
///  deployment time via CREATE2 salt prediction (predict one address; deploy the
///  other pointing at it; deploy the first at the predicted address). Deployment
///  scripts are out of scope for this milestone.
///
///  Reentrancy: only `registerLazyDefault` makes an external call (a `view` call to
///  the capability authority). All mutation happens after the check, but there is
///  no state that can be re-entered destructively — registration is monotone and
///  idempotent. No reentrancy guard is needed.
contract SubaccountRegistry is ISubaccountRegistry {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Immutable chain id captured at construction.
    uint256 public immutable DEPLOYMENT_CHAIN_ID;

    /// @notice Immutable deployment block number captured at construction.
    uint64 public immutable DEPLOYMENT_BLOCK;

    /// @notice Immutable capability authority reference. Expected to be the CollateralVault v2.
    address public immutable capabilityAuthority;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Interface version string (frozen at "1" for V1 per contract-spec 02).
    string public constant VERSION = "1";

    /// @notice Conservative implementation-side cap for `subaccountsOfPage` limit.
    /// @dev Not an economic invariant. Downstream tooling MAY page around this cap.
    ///      Chosen to bound gas + memory allocation while allowing meaningful pages.
    uint32 public constant MAX_BATCH_SIZE = 256;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Next assignable per-owner subaccount id. `0` = never registered; after
    ///      the first registration this value equals the highest registered id + 1.
    mapping(address => uint32) private _nextIdOfOwner;

    /// @dev Existence flag keyed by canonical subKey.
    mapping(bytes32 => bool) private _existsOfKey;

    /// @dev Reverse-lookup: subKey → canonical owner.
    mapping(bytes32 => address) private _ownerOfKey;

    /// @dev Reverse-lookup: subKey → subaccount id.
    mapping(bytes32 => uint32) private _subaccountIdOfKey;

    /*//////////////////////////////////////////////////////////////
                          CONTRACT-LOCAL ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Constructor argument `capabilityAuthority_` is the zero address.
    error InvalidCapabilityAuthority();

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param capabilityAuthority_ The address that owns the least-privilege capability bitmap
    ///        consulted by `registerLazyDefault`. Expected to be the CollateralVault v2. MUST NOT
    ///        be zero. Deployment plans resolve the two-way immutable reference via CREATE2 salt
    ///        prediction.
    constructor(address capabilityAuthority_) {
        if (capabilityAuthority_ == address(0)) revert InvalidCapabilityAuthority();
        DEPLOYMENT_CHAIN_ID = block.chainid;
        DEPLOYMENT_BLOCK = uint64(block.number);
        capabilityAuthority = capabilityAuthority_;
    }

    /*//////////////////////////////////////////////////////////////
                              MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISubaccountRegistry
    function registerNext() external returns (uint32 subaccountId, bytes32 subKey) {
        address owner = msg.sender;
        if (owner == address(0)) revert InvalidOwner();

        uint32 stored = _nextIdOfOwner[owner];
        subaccountId = stored == 0 ? uint32(1) : stored;
        if (subaccountId == type(uint32).max) revert RegistrationOverflow();

        _nextIdOfOwner[owner] = subaccountId + 1;

        subKey = SubKey.deriveHere(address(this), owner, subaccountId);
        _existsOfKey[subKey] = true;
        _ownerOfKey[subKey] = owner;
        _subaccountIdOfKey[subKey] = subaccountId;

        emit SubaccountCreated(owner, subaccountId, subKey, DEPLOYMENT_CHAIN_ID, Versions.EVENT_VERSION);
    }

    /// @inheritdoc ISubaccountRegistry
    function registerLazyDefault(address owner) external {
        if (owner == address(0)) revert InvalidOwner();

        uint256 bits = ICollateralVault(capabilityAuthority).engineCapabilityBits(msg.sender);
        if (bits & Capabilities.CAP_REGISTER_DEFAULT_ACCOUNT == 0) revert NotAuthorized();

        // Idempotent: any prior registration for this owner implies Account 1 already exists
        // (registerNext starts at 1 and registerLazyDefault only ever writes id 1).
        if (_nextIdOfOwner[owner] != 0) return;

        _nextIdOfOwner[owner] = 2;

        uint32 subaccountId = 1;
        bytes32 subKey = SubKey.deriveHere(address(this), owner, subaccountId);
        _existsOfKey[subKey] = true;
        _ownerOfKey[subKey] = owner;
        _subaccountIdOfKey[subKey] = subaccountId;

        emit SubaccountLazyRegistered(
            owner, subaccountId, subKey, DEPLOYMENT_CHAIN_ID, msg.sender, Versions.EVENT_VERSION
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISubaccountRegistry
    function subKeyOf(address owner, uint32 subaccountId) external view returns (bytes32) {
        return SubKey.deriveHere(address(this), owner, subaccountId);
    }

    /// @inheritdoc ISubaccountRegistry
    function existsOf(address owner, uint32 subaccountId) external view returns (bool) {
        if (subaccountId == 0) return false;
        return _existsOfKey[SubKey.deriveHere(address(this), owner, subaccountId)];
    }

    /// @inheritdoc ISubaccountRegistry
    function ownerOf(bytes32 subKey) external view returns (address) {
        return _ownerOfKey[subKey];
    }

    /// @inheritdoc ISubaccountRegistry
    function subaccountIdOf(bytes32 subKey) external view returns (uint32) {
        return _subaccountIdOfKey[subKey];
    }

    /// @inheritdoc ISubaccountRegistry
    function nextIdFor(address owner) external view returns (uint32) {
        uint32 stored = _nextIdOfOwner[owner];
        return stored == 0 ? uint32(1) : stored;
    }

    /// @inheritdoc ISubaccountRegistry
    function subaccountsOfPage(address owner, uint32 offset, uint32 limit)
        external
        view
        returns (uint32[] memory ids, bytes32[] memory subKeys)
    {
        if (limit > MAX_BATCH_SIZE) limit = MAX_BATCH_SIZE;

        uint32 nextStored = _nextIdOfOwner[owner];
        if (nextStored == 0 || limit == 0) {
            return (new uint32[](0), new bytes32[](0));
        }

        // Account 0 excluded. Treat offset < 1 as 1.
        uint32 startId = offset == 0 ? uint32(1) : offset;

        // Compute exclusive end without overflow.
        uint256 rawEnd = uint256(startId) + uint256(limit);
        uint32 endId = rawEnd >= uint256(nextStored) ? nextStored : uint32(rawEnd);

        if (startId >= endId) {
            return (new uint32[](0), new bytes32[](0));
        }

        uint32 count = endId - startId;
        ids = new uint32[](count);
        subKeys = new bytes32[](count);

        for (uint32 i = 0; i < count; i++) {
            uint32 id = startId + i;
            ids[i] = id;
            subKeys[i] = SubKey.deriveHere(address(this), owner, id);
        }
    }

    /// @inheritdoc ISubaccountRegistry
    function deploymentChainId() external view returns (uint256) {
        return DEPLOYMENT_CHAIN_ID;
    }

    /// @inheritdoc ISubaccountRegistry
    function deploymentBlock() external view returns (uint64) {
        return DEPLOYMENT_BLOCK;
    }

    /// @inheritdoc ISubaccountRegistry
    function version() external pure returns (string memory) {
        return VERSION;
    }
}
