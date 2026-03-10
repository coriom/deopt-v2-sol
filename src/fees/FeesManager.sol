// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {IFeesManager} from "./IFeesManager.sol";

/// @title FeesManager
/// @notice Module de fees hybride DeOpt v2:
///         defaults onchain + tiers claimés via Merkle root + overrides admin.
/// @dev
///  Modèle économique visé:
///    fee = min(notionalImplicit * notionalFeeBps / 10_000, premium * premiumCapBps / 10_000)
///
///  Le contrat NE déplace PAS de fonds.
///  Le caller (MarginEngine) fournit:
///    - premium effectivement échangé
///    - notionnel implicite retenu par le protocole
///
///  Priorité des paramètres:
///    override actif > tier actif > defaults
///
///  Hardening:
///    - feeBpsCap borne chaque champ bps individuellement
///    - claim Merkle lié à l'epoch courant
///    - expiry optionnelle sur tiers et overrides
///    - ownership en 2-step
contract FeesManager is IFeesManager {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error ZeroAddress();
    error InvalidBps();
    error ProofInvalid();
    error Expired();
    error OwnershipTransferNotInitiated();

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    address public override owner;
    address public override pendingOwner;

    bytes32 public override merkleRoot;
    uint64 public override epoch;

    /// @notice Cap de sécurité appliqué individuellement à chaque champ bps.
    uint16 public override feeBpsCap;

    uint16 public override defaultMakerNotionalFeeBps;
    uint16 public override defaultMakerPremiumCapBps;
    uint16 public override defaultTakerNotionalFeeBps;
    uint16 public override defaultTakerPremiumCapBps;

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

    constructor(
        address _owner,
        uint16 _defaultMakerNotionalFeeBps,
        uint16 _defaultMakerPremiumCapBps,
        uint16 _defaultTakerNotionalFeeBps,
        uint16 _defaultTakerPremiumCapBps,
        uint16 _feeBpsCap
    ) {
        if (_owner == address(0)) revert ZeroAddress();

        owner = _owner;
        emit OwnershipTransferred(address(0), _owner);

        _setFeeBpsCap(_feeBpsCap);
        _setDefaultFees(
            _defaultMakerNotionalFeeBps,
            _defaultMakerPremiumCapBps,
            _defaultTakerNotionalFeeBps,
            _defaultTakerPremiumCapBps
        );
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

    function setFeeBpsCap(uint16 newCap) external onlyOwner {
        _setFeeBpsCap(newCap);
    }

    function setDefaultFees(
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps
    ) external onlyOwner {
        _setDefaultFees(makerNotionalFeeBps, makerPremiumCapBps, takerNotionalFeeBps, takerPremiumCapBps);
    }

    /// @notice Set Merkle root and auto-increment epoch.
    function setMerkleRoot(bytes32 newRoot) external onlyOwner {
        bytes32 old = merkleRoot;
        merkleRoot = newRoot;

        unchecked {
            epoch = epoch + 1;
        }

        emit MerkleRootSet(old, newRoot, epoch);
    }

    /// @notice Set Merkle root with explicit epoch.
    function setMerkleRootWithEpoch(bytes32 newRoot, uint64 newEpoch) external onlyOwner {
        bytes32 old = merkleRoot;
        merkleRoot = newRoot;
        epoch = newEpoch;

        emit MerkleRootSet(old, newRoot, newEpoch);
    }

    /// @notice Set override MM/VIP.
    /// @dev Prioritaire sur tier tant que enabled && !expired.
    function setOverride(
        address trader,
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint64 expiry,
        bool enabled
    ) external onlyOwner {
        if (trader == address(0)) revert ZeroAddress();

        FeeProfile memory profile = _buildCappedProfile(
            makerNotionalFeeBps, makerPremiumCapBps, takerNotionalFeeBps, takerPremiumCapBps
        );

        _overrides[trader] = OverrideFee({profile: profile, expiry: expiry, enabled: enabled});

        emit OverrideSet(
            trader,
            profile.maker.notionalFeeBps,
            profile.maker.premiumCapBps,
            profile.taker.notionalFeeBps,
            profile.taker.premiumCapBps,
            expiry,
            enabled
        );
    }

    function disableOverride(address trader) external onlyOwner {
        if (trader == address(0)) revert ZeroAddress();

        OverrideFee storage o = _overrides[trader];
        o.enabled = false;

        emit OverrideSet(
            trader,
            o.profile.maker.notionalFeeBps,
            o.profile.maker.premiumCapBps,
            o.profile.taker.notionalFeeBps,
            o.profile.taker.premiumCapBps,
            o.expiry,
            false
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IFeesManager
    function claimTier(
        address trader,
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint64 expiry,
        bytes32[] calldata proof
    ) external override {
        if (trader == address(0)) revert ZeroAddress();
        if (msg.sender != trader) revert NotAuthorized();
        if (expiry != 0 && block.timestamp > expiry) revert Expired();

        bytes32 root = merkleRoot;
        if (root == bytes32(0)) revert ProofInvalid();

        _validateBps(makerNotionalFeeBps);
        _validateBps(makerPremiumCapBps);
        _validateBps(takerNotionalFeeBps);
        _validateBps(takerPremiumCapBps);

        uint64 currentEpoch = epoch;

        bytes32 leaf = keccak256(
            abi.encode(
                trader,
                makerNotionalFeeBps,
                makerPremiumCapBps,
                takerNotionalFeeBps,
                takerPremiumCapBps,
                expiry,
                currentEpoch
            )
        );

        bool ok = MerkleProof.verifyCalldata(proof, root, leaf);
        if (!ok) revert ProofInvalid();

        FeeProfile memory profile = _buildCappedProfile(
            makerNotionalFeeBps, makerPremiumCapBps, takerNotionalFeeBps, takerPremiumCapBps
        );

        _tiers[trader] = Tier({profile: profile, expiry: expiry, epoch: currentEpoch});

        emit TierClaimed(
            trader,
            profile.maker.notionalFeeBps,
            profile.maker.premiumCapBps,
            profile.taker.notionalFeeBps,
            profile.taker.premiumCapBps,
            expiry,
            currentEpoch
        );
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
    function getFeeProfile(address trader) public view override returns (FeeProfile memory profile) {
        if (trader == address(0)) revert ZeroAddress();

        OverrideFee memory o = _overrides[trader];
        if (o.enabled && _isActive(o.expiry)) {
            return o.profile;
        }

        Tier memory t = _tiers[trader];
        if (t.epoch != 0 && t.epoch == epoch && _isActive(t.expiry)) {
            return t.profile;
        }

        return _defaultProfile();
    }

    /// @inheritdoc IFeesManager
    function getFeeParams(address trader, bool isMaker) public view override returns (FeeParams memory params) {
        FeeProfile memory profile = getFeeProfile(trader);
        return isMaker ? profile.maker : profile.taker;
    }

    /// @inheritdoc IFeesManager
    function quoteFee(address trader, bool isMaker, uint256 premium, uint256 notionalImplicit)
        public
        view
        override
        returns (FeeQuote memory quote)
    {
        FeeParams memory params = getFeeParams(trader, isMaker);
        quote.paramsUsed = params;

        if (premium == 0 && notionalImplicit == 0) {
            return quote;
        }

        if (params.notionalFeeBps != 0 && notionalImplicit != 0) {
            quote.notionalFee = (notionalImplicit * uint256(params.notionalFeeBps)) / uint256(BPS);
        }

        if (params.premiumCapBps != 0 && premium != 0) {
            quote.premiumCapFee = (premium * uint256(params.premiumCapBps)) / uint256(BPS);
        }

        if (params.notionalFeeBps == 0) {
            quote.appliedFee = quote.premiumCapFee;
            quote.cappedByPremium = quote.premiumCapFee != 0;
            return quote;
        }

        if (params.premiumCapBps == 0) {
            quote.appliedFee = quote.notionalFee;
            quote.cappedByPremium = false;
            return quote;
        }

        if (quote.notionalFee <= quote.premiumCapFee) {
            quote.appliedFee = quote.notionalFee;
            quote.cappedByPremium = false;
        } else {
            quote.appliedFee = quote.premiumCapFee;
            quote.cappedByPremium = true;
        }
    }

    /// @inheritdoc IFeesManager
    function computeFee(address trader, bool isMaker, uint256 premium, uint256 notionalImplicit)
        external
        view
        override
        returns (uint256 fee)
    {
        return quoteFee(trader, isMaker, premium, notionalImplicit).appliedFee;
    }

    /*//////////////////////////////////////////////////////////////
                                 INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _setFeeBpsCap(uint16 newCap) internal {
        if (newCap == 0 || newCap > uint16(BPS)) revert InvalidBps();

        uint16 old = feeBpsCap;
        feeBpsCap = newCap;

        if (defaultMakerNotionalFeeBps > newCap) defaultMakerNotionalFeeBps = newCap;
        if (defaultMakerPremiumCapBps > newCap) defaultMakerPremiumCapBps = newCap;
        if (defaultTakerNotionalFeeBps > newCap) defaultTakerNotionalFeeBps = newCap;
        if (defaultTakerPremiumCapBps > newCap) defaultTakerPremiumCapBps = newCap;

        emit FeeBpsCapSet(old, newCap);
    }

    function _setDefaultFees(
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps
    ) internal {
        _validateBps(makerNotionalFeeBps);
        _validateBps(makerPremiumCapBps);
        _validateBps(takerNotionalFeeBps);
        _validateBps(takerPremiumCapBps);

        defaultMakerNotionalFeeBps = _cap(makerNotionalFeeBps);
        defaultMakerPremiumCapBps = _cap(makerPremiumCapBps);
        defaultTakerNotionalFeeBps = _cap(takerNotionalFeeBps);
        defaultTakerPremiumCapBps = _cap(takerPremiumCapBps);

        emit DefaultFeesSet(
            defaultMakerNotionalFeeBps,
            defaultMakerPremiumCapBps,
            defaultTakerNotionalFeeBps,
            defaultTakerPremiumCapBps
        );
    }

    function _defaultProfile() internal view returns (FeeProfile memory profile) {
        profile.maker = FeeParams({
            notionalFeeBps: defaultMakerNotionalFeeBps,
            premiumCapBps: defaultMakerPremiumCapBps
        });

        profile.taker = FeeParams({
            notionalFeeBps: defaultTakerNotionalFeeBps,
            premiumCapBps: defaultTakerPremiumCapBps
        });
    }

    function _buildCappedProfile(
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps
    ) internal view returns (FeeProfile memory profile) {
        _validateBps(makerNotionalFeeBps);
        _validateBps(makerPremiumCapBps);
        _validateBps(takerNotionalFeeBps);
        _validateBps(takerPremiumCapBps);

        profile.maker = FeeParams({
            notionalFeeBps: _cap(makerNotionalFeeBps),
            premiumCapBps: _cap(makerPremiumCapBps)
        });

        profile.taker = FeeParams({
            notionalFeeBps: _cap(takerNotionalFeeBps),
            premiumCapBps: _cap(takerPremiumCapBps)
        });
    }

    function _validateBps(uint16 bps) internal pure {
        if (bps > uint16(BPS)) revert InvalidBps();
    }

    function _cap(uint16 bps) internal view returns (uint16) {
        uint16 cap_ = feeBpsCap;
        return bps > cap_ ? cap_ : bps;
    }

    function _isActive(uint64 expiry) internal view returns (bool) {
        return expiry == 0 || block.timestamp <= expiry;
    }
}