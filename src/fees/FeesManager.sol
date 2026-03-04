// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IFeesManager} from "./IFeesManager.sol";

/// @title FeesManager
/// @notice Hybrid fees config (defaults + Merkle tier allowlist + admin overrides).
/// @dev
///  - No token moves here. MarginEngine computes notional and executes transfers.
///  - Epoch-based Merkle roots enable scalable tier updates offchain.
///  - Per-account overrides enable bespoke terms (MM/VIP) with optional expiry.
///  - Hardening: feeBpsCap upper-bounds any bps returned (defaults/tiers/overrides).
contract FeesManager is IFeesManager {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint16 internal constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error InvalidBps();
    error ProofInvalid();
    error Expired();

    // ownership 2-step
    error OwnershipTransferNotInitiated();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public override owner;
    address public override pendingOwner;

    uint16 public override defaultMakerBps;
    uint16 public override defaultTakerBps;

    /// @notice Hard cap for safety (applies to defaults/tiers/overrides).
    uint16 public override feeBpsCap;

    bytes32 public override merkleRoot;
    uint64 public override epoch;

    mapping(address => Tier) internal _tiers;
    mapping(address => OverrideFee) internal _overrides;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _owner, uint16 _defaultMakerBps, uint16 _defaultTakerBps, uint16 _feeBpsCap) {
        if (_owner == address(0)) revert ZeroAddress();
        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);

        _setFeeBpsCap(_feeBpsCap);
        _setDefaults(_defaultMakerBps, _defaultTakerBps);
    }

    /*//////////////////////////////////////////////////////////////
                         OWNERSHIP (2-step)
    //////////////////////////////////////////////////////////////*/

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        address po = pendingOwner;
        if (msg.sender != po) revert NotAuthorized();
        address oldOwner = owner;
        owner = po;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, po);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        if (pendingOwner == address(0)) revert OwnershipTransferNotInitiated();
        pendingOwner = address(0);
    }

    function renounceOwnership() external onlyOwner {
        if (pendingOwner != address(0)) revert NotAuthorized();
        address oldOwner = owner;
        owner = address(0);
        emit OwnershipTransferred(oldOwner, address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Set defaults (bps). Must respect cap.
    function setDefaults(uint16 makerBps, uint16 takerBps) external onlyOwner {
        _setDefaults(makerBps, takerBps);
    }

    /// @notice Set absolute cap for any bps returned.
    function setFeeBpsCap(uint16 newCap) external onlyOwner {
        _setFeeBpsCap(newCap);
    }

    /// @notice Set Merkle root and increments epoch.
    /// @dev New epoch = old epoch + 1, unless you want to jump; use setMerkleRootWithEpoch.
    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        bytes32 old = merkleRoot;
        merkleRoot = newRoot;
        unchecked {
            epoch = epoch + 1;
        }
        emit MerkleRootSet(old, newRoot, epoch);
    }

    /// @notice Set Merkle root with explicit epoch (for migrations / replays).
    function setMerkleRootWithEpoch(bytes32 newRoot, uint64 newEpoch) external onlyOwner {
        bytes32 old = merkleRoot;
        merkleRoot = newRoot;
        epoch = newEpoch;
        emit MerkleRootSet(old, newRoot, newEpoch);
    }

    /// @notice Manual override for a trader (MM/VIP) with optional expiry.
    /// @dev Precedence: override > tier > default.
    function setOverride(address trader, uint16 makerBps, uint16 takerBps, uint64 expiry, bool enabled)
        external
        onlyOwner
    {
        if (trader == address(0)) revert ZeroAddress();
        _validateBps(makerBps);
        _validateBps(takerBps);

        _overrides[trader] = OverrideFee({
            makerBps: makerBps,
            takerBps: takerBps,
            expiry: expiry,
            enabled: enabled
        });

        emit OverrideSet(trader, makerBps, takerBps, expiry, enabled);
    }

    /// @notice Disable override quickly.
    function disableOverride(address trader) external onlyOwner {
        if (trader == address(0)) revert ZeroAddress();
        OverrideFee storage o = _overrides[trader];
        o.enabled = false;
        emit OverrideSet(trader, o.makerBps, o.takerBps, o.expiry, false);
    }

    /*//////////////////////////////////////////////////////////////
                                  CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFeesManager
    function claimTier(address trader, uint16 makerBps, uint16 takerBps, uint64 expiry, bytes32[] calldata proof)
        external
        override
    {
        if (trader == address(0)) revert ZeroAddress();
        if (msg.sender != trader) revert NotAuthorized();

        _validateBps(makerBps);
        _validateBps(takerBps);

        // If expiry != 0, the claim must not already be expired at claim time.
        if (expiry != 0 && block.timestamp > expiry) revert Expired();

        bytes32 root = merkleRoot;
        if (root == bytes32(0)) revert ProofInvalid();

        bytes32 leaf = keccak256(abi.encode(trader, makerBps, takerBps, expiry, epoch));
        bool ok = MerkleProof.verifyCalldata(proof, root, leaf);
        if (!ok) revert ProofInvalid();

        _tiers[trader] = Tier({makerBps: makerBps, takerBps: takerBps, expiry: expiry, epoch: epoch});

        emit TierClaimed(trader, makerBps, takerBps, expiry, epoch);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function tiers(address trader) external view override returns (Tier memory) {
        return _tiers[trader];
    }

    function overrides(address trader) external view override returns (OverrideFee memory) {
        return _overrides[trader];
    }

    /// @inheritdoc IFeesManager
    function getFeeBps(address trader, bool isMaker) external view override returns (uint16 bps) {
        if (trader == address(0)) revert ZeroAddress();

        // 1) override (if enabled and not expired)
        OverrideFee memory o = _overrides[trader];
        if (o.enabled) {
            if (o.expiry == 0 || block.timestamp <= o.expiry) {
                bps = isMaker ? o.makerBps : o.takerBps;
                return _cap(bps);
            }
        }

        // 2) tier (if not expired)
        Tier memory t = _tiers[trader];
        if (t.epoch != 0) {
            if (t.expiry == 0 || block.timestamp <= t.expiry) {
                bps = isMaker ? t.makerBps : t.takerBps;
                return _cap(bps);
            }
        }

        // 3) defaults
        bps = isMaker ? defaultMakerBps : defaultTakerBps;
        return _cap(bps);
    }

    /// @inheritdoc IFeesManager
    function computeFee(uint256 notional, address trader, bool isMaker) external view override returns (uint256 fee) {
        uint16 bps = this.getFeeBps(trader, isMaker);
        if (notional == 0 || bps == 0) return 0;
        fee = (notional * uint256(bps)) / uint256(BPS);
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _setDefaults(uint16 makerBps, uint16 takerBps) internal {
        _validateBps(makerBps);
        _validateBps(takerBps);

        defaultMakerBps = _cap(makerBps);
        defaultTakerBps = _cap(takerBps);

        emit DefaultsSet(defaultMakerBps, defaultTakerBps);
    }

    function _setFeeBpsCap(uint16 newCap) internal {
        // cap cannot exceed BPS and cannot be 0 (avoid accidental "all fees 0" safety disable).
        if (newCap == 0 || newCap > BPS) revert InvalidBps();
        uint16 old = feeBpsCap;
        feeBpsCap = newCap;
        emit FeeBpsCapSet(old, newCap);

        // Also re-cap defaults if cap reduced.
        if (defaultMakerBps > newCap) defaultMakerBps = newCap;
        if (defaultTakerBps > newCap) defaultTakerBps = newCap;
    }

    function _validateBps(uint16 bps) internal pure {
        if (bps > BPS) revert InvalidBps();
    }

    function _cap(uint16 bps) internal view returns (uint16) {
        uint16 cap = feeBpsCap;
        return bps > cap ? cap : bps;
    }
}