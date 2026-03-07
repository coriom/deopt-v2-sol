// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IFeesManager
/// @notice Interface du module de fees hybride de DeOpt v2.
/// @dev
///  Modèle cible:
///    fee = min(notionalImplicit * notionalFeeBps / 10_000, premium * premiumCapBps / 10_000)
///
///  - "premium" = cash effectivement échangé au trade (quantity * price), en unités natives du settlementAsset.
///  - "notionalImplicit" = notionnel implicite de référence, calculé côté caller selon la convention du protocole
///    (ex: strike * quantity, ou autre formule déterministe retenue).
///  - Ce module NE déplace PAS de fonds. Il retourne des paramètres / quotes / montants.
///  - La priorité des paramètres est:
///      override actif > tier actif > defaults.
///  - Les tiers peuvent être poussés offchain puis claim onchain via Merkle root.
///  - Les overrides permettent les exceptions MM / VIP avec expiration optionnelle.
interface IFeesManager {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 constant BPS = 10_000;

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

    /// @notice Tier claimé onchain depuis une Merkle root.
    struct Tier {
        FeeProfile profile;
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
    ///          makerNotionalFeeBps,
    ///          makerPremiumCapBps,
    ///          takerNotionalFeeBps,
    ///          takerPremiumCapBps,
    ///          expiry,
    ///          epoch
    ///      )
    ///  )
    function claimTier(
        address trader,
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint64 expiry,
        bytes32[] calldata proof
    ) external;

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

    event TierClaimed(
        address indexed trader,
        uint16 makerNotionalFeeBps,
        uint16 makerPremiumCapBps,
        uint16 takerNotionalFeeBps,
        uint16 takerPremiumCapBps,
        uint64 expiry,
        uint64 epoch
    );

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