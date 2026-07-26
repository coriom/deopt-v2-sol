// SPDX-License-Identifier: BSL-1.1
pragma solidity ^0.8.20;

import {Capabilities} from "../libraries/Capabilities.sol";
import {Versions} from "../libraries/Versions.sol";

/// @title VaultCapabilityController
/// @notice Abstract least-privilege engine capability subsystem intended to be inherited by `CollateralVaultV2`.
/// @dev
///  Owns ONLY capability storage and the two frozen mutation entrypoints from
///  `ICollateralVault`:
///   - `setEngineCapability(address engine, uint256 capabilityBits, bool allowed)` — governance-only bit-level
///     grant / revoke.
///   - `guardianRevokeEngine(address engine)` — guardian-only immediate full-engine revocation.
///
///  Additionally exposes:
///   - `hasCapabilities(engine, requiredMask)` — all-of bit check used by downstream engines.
///   - `setGuardian(newGuardian)` — governance-only guardian rotation with old/new event.
///
///  Explicit non-scope of this abstract (owned by later WP-04 milestones):
///   - collateral balances, deposits, withdrawals, internal transfers;
///   - per-engine reservation accounting (`applyLock` / `applyUnlock`);
///   - `governanceReleaseOrphanedLock`;
///   - fee / rebate / liquidation / settlement debits;
///   - supported-token whitelist;
///   - pause matrix;
///   - `setAuthorizedEngine(address engine, bool allowed)` (the bulk on/off entrypoint
///     is deferred to CollateralVaultV2 so its semantics can be reconciled with the
///     rest of the vault storage; see PROJECT NOTE below).
///
///  Authority model (spec 12):
///   - `governance` — IMMUTABLE, non-zero. Expected to be `ProtocolTimelock` in
///     production; the compile-time abstract does not verify this beyond the
///     interface (deployment scripts + integration tests are the check).
///   - `guardian` — mutable via `setGuardian(newGuardian) onlyGovernance`. Guardian
///     may only REDUCE authority (guardian-revoke); guardian may never grant.
///
///  Storage model (spec 07):
///   - `_engineCapabilityBits[engine]` — uint256 bitmap. Bits 0..14 correspond to
///     `Capabilities.CAP_*` constants; bits 15..255 are RESERVED and rejected by
///     `_validateCapabilityMask`.
///   - `isAuthorizedEngine(engine)` is DERIVED (`bits != 0`) rather than stored
///     as a second bookkeeping boolean (matches spec 07 "any capability?" gate).
///
///  Reentrancy: no external calls are made in any mutation path.
///
///  PROJECT NOTE — `setAuthorizedEngine`: the `ICollateralVault` interface also
///  declares `setAuthorizedEngine(address engine, bool allowed) external`. Spec 07
///  makes `isAuthorizedEngine` a DERIVED read (`bits != 0`), which leaves no clean
///  semantics for a boolean setter as an independent authority. Resolution is
///  deferred to `ONCHAIN-SUBACCOUNT-COLLATERAL-VAULT-V2-A` so the semantic tie to
///  supported-token whitelist / vault initialization can be reconciled in one place.
///  This abstract implements only the two capability-mutation entrypoints frozen
///  by spec 07.
abstract contract VaultCapabilityController {
    /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Governance authority. Expected to be `ProtocolTimelock` in production.
    /// @dev Immutable at construction. Only this address may call
    ///      `setEngineCapability` and `setGuardian`.
    address public immutable governance;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Guardian authority. Rotatable via `setGuardian(newGuardian) onlyGovernance`.
    ///      MUST be non-zero. Guardian may only revoke, never grant.
    address internal _guardian;

    /// @dev Engine → capability bitmap. Bits 0..14 correspond to `Capabilities.CAP_*`.
    ///      Bits 15..255 are RESERVED and never stored (validated on every mutation).
    mapping(address => uint256) internal _engineCapabilityBits;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every capability mutation. Fully reconstructible.
    event EngineCapabilityChanged(address indexed engine, uint256 addedBits, uint256 removedBits, uint16 eventVersion);

    /// @notice Emitted when the guardian defensively revokes an engine.
    event EngineGuardianRevoked(address indexed engine, address indexed guardian, uint16 eventVersion);

    /// @notice Emitted when governance rotates the guardian.
    event GuardianChanged(address indexed oldGuardian, address indexed newGuardian, uint16 eventVersion);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is not the configured governance authority.
    error OnlyGovernance();

    /// @notice Caller is not the currently configured guardian.
    error OnlyGuardian();

    /// @notice Engine argument is the zero address.
    error InvalidEngine();

    /// @notice Capability mask is either empty or references a reserved bit.
    /// @param mask The rejected mask.
    error InvalidCapabilityMask(uint256 mask);

    /// @notice Governance address supplied at construction was zero.
    error InvalidGovernance();

    /// @notice Guardian address was zero at construction or rotation.
    error InvalidGuardian();

    /// @notice Caller is missing a required capability. Mirrors `ICollateralVault.MissingCapability`.
    /// @dev Not emitted by this abstract; provided for downstream inheritors that
    ///      gate economic functions via `_requireCapability`.
    error MissingCapability(uint256 requiredBits, address caller);

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyGovernance() {
        if (msg.sender != governance) revert OnlyGovernance();
        _;
    }

    modifier onlyGuardian() {
        if (msg.sender != _guardian) revert OnlyGuardian();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address governance_, address guardian_) {
        if (governance_ == address(0)) revert InvalidGovernance();
        if (guardian_ == address(0)) revert InvalidGuardian();
        governance = governance_;
        _guardian = guardian_;
        emit GuardianChanged(address(0), guardian_, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                        GOVERNANCE MUTATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Grant (`allowed == true`) or revoke (`allowed == false`) the bits in
    ///         `capabilityBits` on `engine`.
    /// @dev Mask is bit-OR'd in when granting; bit-AND'd with NOT-mask when revoking.
    ///      Reverts if the mask is empty or contains any reserved (bit >= 15) bit.
    ///      No event is emitted if the mutation would leave the bitmap unchanged.
    function setEngineCapability(address engine, uint256 capabilityBits, bool allowed) external onlyGovernance {
        if (engine == address(0)) revert InvalidEngine();
        _validateCapabilityMask(capabilityBits);

        uint256 oldBits = _engineCapabilityBits[engine];
        uint256 newBits = allowed ? (oldBits | capabilityBits) : (oldBits & ~capabilityBits);

        if (newBits == oldBits) return; // no-op; skip event for reconstructibility efficiency

        _engineCapabilityBits[engine] = newBits;

        uint256 addedBits = newBits & ~oldBits; // bits that flipped 0 → 1
        uint256 removedBits = oldBits & ~newBits; // bits that flipped 1 → 0
        emit EngineCapabilityChanged(engine, addedBits, removedBits, Versions.EVENT_VERSION);
    }

    /// @notice Rotate the guardian. Governance-only. Non-zero new guardian enforced.
    function setGuardian(address newGuardian) external onlyGovernance {
        if (newGuardian == address(0)) revert InvalidGuardian();
        address oldGuardian = _guardian;
        if (oldGuardian == newGuardian) return; // no-op; skip event
        _guardian = newGuardian;
        emit GuardianChanged(oldGuardian, newGuardian, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                        GUARDIAN MUTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Immediately revoke ALL capabilities for `engine`. Guardian-only.
    /// @dev Guardian may only REDUCE. Cannot grant. Cannot restore. Outstanding
    ///      reservations owned by `engine` are intentionally NOT released here;
    ///      that path is owned by the future
    ///      `governanceReleaseOrphanedLock(subKey, token, engine, amount, reason)`
    ///      in CollateralVaultV2 (WP-04B) per spec 07.
    function guardianRevokeEngine(address engine) external onlyGuardian {
        if (engine == address(0)) revert InvalidEngine();

        uint256 oldBits = _engineCapabilityBits[engine];
        if (oldBits != 0) {
            _engineCapabilityBits[engine] = 0;
            emit EngineCapabilityChanged(engine, 0, oldBits, Versions.EVENT_VERSION);
        }
        // Always emit the audit signal, even if the bitmap was already zero — this
        // is a defensive action and observers benefit from the record.
        emit EngineGuardianRevoked(engine, msg.sender, Versions.EVENT_VERSION);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Canonical bitmap read consumed by downstream engines + `SubaccountRegistry`.
    /// @dev Matches `ICollateralVault.engineCapabilityBits(address)`.
    function engineCapabilityBits(address engine) external view returns (uint256) {
        return _engineCapabilityBits[engine];
    }

    /// @notice Fast "engine has ANY capability?" gate. Derived from bitmap != 0.
    /// @dev Matches `ICollateralVault.isAuthorizedEngine(address)`. Spec 07 explicitly
    ///      defines this as `engineCapabilityBits[engine] != 0` (derived, not stored).
    function isAuthorizedEngine(address engine) external view returns (bool) {
        return _engineCapabilityBits[engine] != 0;
    }

    /// @notice All-of capability check. Returns true iff every bit in `requiredMask`
    ///         is currently granted to `engine` AND `requiredMask` is valid.
    /// @dev Helper for downstream engines to enforce `onlyCapability(mask)`.
    ///      Returns false for empty mask or any mask referencing a reserved bit.
    function hasCapabilities(address engine, uint256 requiredMask) external view returns (bool) {
        if (requiredMask == 0) return false;
        if (requiredMask & ~Capabilities.ALL_CAPABILITIES != 0) return false;
        return (_engineCapabilityBits[engine] & requiredMask) == requiredMask;
    }

    /// @notice Current guardian address.
    function guardian() external view returns (address) {
        return _guardian;
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reverts on empty mask or any bit outside `Capabilities.ALL_CAPABILITIES`.
    function _validateCapabilityMask(uint256 mask) internal pure {
        if (mask == 0) revert InvalidCapabilityMask(mask);
        if (mask & ~Capabilities.ALL_CAPABILITIES != 0) revert InvalidCapabilityMask(mask);
    }

    /// @dev Convenience for downstream inheritors: gate an economic function on an
    ///      all-of capability check. Reverts `MissingCapability(mask, caller)` when
    ///      any required bit is missing. Not used by this abstract itself.
    function _requireCapability(uint256 requiredMask) internal view {
        if (requiredMask == 0 || (requiredMask & ~Capabilities.ALL_CAPABILITIES) != 0) {
            revert MissingCapability(requiredMask, msg.sender);
        }
        if ((_engineCapabilityBits[msg.sender] & requiredMask) != requiredMask) {
            revert MissingCapability(requiredMask, msg.sender);
        }
    }
}
