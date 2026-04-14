// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFeesManager
/// @notice Interface du module de fees de DeOpt v2.
/// @dev
///  Modèle cible:
///    fee = min(notionalImplicit * notionalFeeBps / 10_000, premium * premiumCapBps / 10_000)
///
///  - "premium" = cash effectivement échangé au trade (quantity * price), en unités natives du settlementAsset.
///  - "notionalImplicit" = notionnel implicite de référence, calculé côté caller selon la convention du protocole.
///  - Ce module NE déplace PAS de fonds. Il retourne des paramètres / quotes / montants.
///  - Priorité:
///      override actif > tier claimé actif > defaults.
///  - Les tiers sont représentés par une classe de volume explicite, poussée offchain puis claimée onchain.
///  - Les overrides permettent les exceptions MM / VIP avec expiration optionnelle.
///
///  Alignment notes:
///  - this interface intentionally exposes only stable fee surfaces consumed by engines
///  - emergency pause state is internal to the implementation and does not block read quoting
///  - feeBpsCap is an individual-field cap, not a direct applied fee cap
interface IFeesManager {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Paramètres de fee pour un rôle donné (maker ou taker).
    /// @dev
    ///  - notionalFeeBps: pourcentage appliqué au notionnel implicite.
    ///  - premiumCapBps: plafond en pourcentage du premium.
    struct FeeParams {
        uint16 notionalFeeBps;
        uint16 premiumCapBps;
    }

    /// @notice Profil complet de fees maker/taker.
    struct FeeProfile {
        FeeParams maker;
        FeeParams taker;
    }

    /// @notice Classes de volume standard V1.
    /// @dev
    ///  Tier0:   0 – 5M
    ///  Tier1:   5M – 25M
    ///  Tier2:   25M – 100M
    enum VolumeTierClass {
        Tier0,
        Tier1,
        Tier2
    }

    /// @notice Tier claimé onchain depuis une Merkle root.
    struct Tier {
        VolumeTierClass tierClass;
        uint64 expiry; // 0 = no expiry
        uint64 epoch; // epoch du root ayant produit ce tier
    }

    /// @notice Override admin (MM/VIP), prioritaire sur le tier.
    struct OverrideFee {
        FeeProfile profile;
        uint64 expiry; // 0 = no expiry
        bool enabled;
    }

    /// @notice Quote complète de fee pour un trade donné.
    struct FeeQuote {
        uint256 notionalFee;
        uint256 premiumCapFee;
        uint256 appliedFee;
        bool cappedByPremium;
        FeeParams paramsUsed;
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);

    function merkleRoot() external view returns (bytes32);
    function epoch() external view returns (uint64);

    function feeBpsCap() external view returns (uint16);

    function defaultMakerNotionalFeeBps() external view returns (uint16);
    function defaultMakerPremiumCapBps() external view returns (uint16);
    function defaultTakerNotionalFeeBps() external view returns (uint16);
    function defaultTakerPremiumCapBps() external view returns (uint16);

    function tiers(address trader) external view returns (Tier memory);
    function overrides(address trader) external view returns (OverrideFee memory);

    /// @notice Retourne le profil standard associé à une classe de volume.
    function getTierClassProfile(VolumeTierClass tierClass) external view returns (FeeProfile memory profile);

    /// @notice Retourne le profil effectif (override > tier > defaults).
    function getFeeProfile(address trader) external view returns (FeeProfile memory profile);

    /// @notice Retourne les paramètres effectifs pour le rôle demandé.
    function getFeeParams(address trader, bool isMaker) external view returns (FeeParams memory params);

    /// @notice Calcule la fee hybride pour un trader et un rôle donnés.
    /// @param trader Compte concerné
    /// @param isMaker true = maker, false = taker
    /// @param premium Montant premium effectivement échangé (unités natives settlementAsset)
    /// @param notionalImplicit Notionnel implicite de référence (mêmes unités de settlementAsset que le calcul retenu)
    /// @return quote Détail complet de la fee calculée
    function quoteFee(address trader, bool isMaker, uint256 premium, uint256 notionalImplicit)
        external
        view
        returns (FeeQuote memory quote);

    /// @notice Version utilitaire qui retourne uniquement la fee appliquée.
    function computeFee(address trader, bool isMaker, uint256 premium, uint256 notionalImplicit)
        external
        view
        returns (uint256 fee);

    /*//////////////////////////////////////////////////////////////
                                  CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim/update d'un tier onchain via preuve Merkle pour l'epoch courant.
    /// @dev
    ///  Leaf canonique recommandée:
    ///  keccak256(
    ///      abi.encode(
    ///          trader,
    ///          tierClass,
    ///          expiry,
    ///          epoch
    ///      )
    ///  )
    function claimTier(address trader, VolumeTierClass tierClass, uint64 expiry, bytes32[] calldata proof) external;

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed pendingOwner);

    event FeeBpsCapSet(uint16 oldCap, uint16 newCap);

    event DefaultFeesSet(
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps
    );

    event MerkleRootSet(bytes32 indexed oldRoot, bytes32 indexed newRoot, uint64 indexed newEpoch);

    event TierClaimed(address indexed trader, VolumeTierClass tierClass, uint64 expiry, uint64 epoch);

    event OverrideSet(
        address indexed trader,
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint64 expiry,
        bool enabled
    );
}