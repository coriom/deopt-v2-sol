// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMarginEngineTrade
/// @notice Interface minimale d’exécution de trades pour le MatchingEngine.
/// @dev Objectif: découpler le matching (orderbook/offchain) du moteur de marge.
///      Hypothèses DeOpt v2:
///       - price est en 1e8 (PRICE_SCALE) et représente le prix par contrat (settlementAsset / underlying),
///         cohérent avec OptionProductRegistry (strike/spot/settlement en 1e8).
///       - quantity est un nombre de contrats (contractSize hard-locked à 1e8 côté registry).
///       - Le MarginEngine applique les vérifs: série active, non expirée, close-only si désactivée, etc.
///       - L’implémentation DOIT:
///           * mettre à jour positions buyer/seller
///           * maintenir la liste OPEN series (anti-DoS) et totalShortContracts
///           * faire l’enforcement IM (initial margin) post-trade
///           * émettre l’event TradeExecuted (défini dans MarginEngineTypes)
interface IMarginEngineTrade {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Scale canonique des prix (Chainlink-like).
    uint256 constant PRICE_SCALE = 1e8;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller non autorisé (typiquement: pas le matching engine).
    error NotAuthorized();

    /// @notice Paramètres invalides (buyer/seller/qty/price/optionId).
    error InvalidTrade();

    /*//////////////////////////////////////////////////////////////
                                CORE
    //////////////////////////////////////////////////////////////*/

    /// @notice Exécute un trade entre buyer et seller sur une série optionId.
    /// @dev price en 1e8 (prix par contrat), quantity = nb de contrats.
    ///      Convention: buyer prend +quantity, seller prend -quantity.
    ///      L’implémentation doit protéger:
    ///        - buyer != seller, non-zero addresses
    ///        - quantity>0, price>0
    ///        - quantity <= int128.max (hardening)
    ///        - series non expirée / tradable
    function executeTrade(
        address buyer,
        address seller,
        uint256 optionId,
        uint128 quantity,
        uint128 price
    ) external;

    /*//////////////////////////////////////////////////////////////
                        OPTIONAL VIEW (QUALITY-OF-LIFE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Matching engine actuellement autorisé.
    function matchingEngine() external view returns (address);

    /// @notice Owner du MarginEngine (utile ops).
    function owner() external view returns (address);

    /// @notice Pause globale du moteur (si exposée par l’implémentation).
    function paused() external view returns (bool);
}
