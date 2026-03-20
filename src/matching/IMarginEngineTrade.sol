// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMarginEngineTrade
/// @notice Interface minimale d’exécution de trades pour le MatchingEngine.
/// @dev Aligné avec MarginEngineTrading.applyTrade(IMarginEngineTrade.Trade).
///      Conventions DeOpt v2:
///       - price est le premium par contrat, exprimé en unités natives du settlementAsset
///         (ex: USDC 6 decimals -> 1 USDC = 1e6)
///       - quantity = nb de contrats
///       - contractSize est hard-locked à 1e8 côté registry
///       - buyer prend +quantity, seller prend -quantity
///       - buyerIsMaker permet d’appliquer un vrai modèle maker/taker côté MarginEngine
///         sans convention implicite fragile
interface IMarginEngineTrade {
    /// @notice Scale canonique historique des prix du protocole.
    /// @dev Conservé pour compatibilité documentaire / helpers offchain.
    uint256 constant PRICE_SCALE = 1e8;

    /// @notice Trade atomique appliqué par le MarginEngine.
    /// @param buyer Adresse de l’acheteur
    /// @param seller Adresse du vendeur
    /// @param optionId Série d’option concernée
    /// @param quantity Nombre de contrats
    /// @param price Premium par contrat en unités natives du settlementAsset
    /// @param buyerIsMaker True si buyer = maker et seller = taker, false sinon
    struct Trade {
        address buyer;
        address seller;
        uint256 optionId;
        uint128 quantity;
        uint128 price;
        bool buyerIsMaker;
    }

    /// @notice Point d’entrée unique appelé par le MatchingEngine autorisé.
    function applyTrade(Trade calldata t) external;

    /// @notice Matching engine actuellement autorisé.
    function matchingEngine() external view returns (address);

    /// @notice Owner du MarginEngine.
    function owner() external view returns (address);

    /// @notice Pause globale legacy du moteur.
    function paused() external view returns (bool);
}