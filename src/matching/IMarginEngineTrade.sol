// contracts/matching/IMarginEngineTrade.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IMarginEngineTrade
/// @notice Interface minimale d’exécution de trades pour le MatchingEngine.
/// @dev Aligné avec MarginEngineTrading.applyTrade(IMarginEngineTrade.Trade).
///      Conventions DeOpt v2:
///       - price est en 1e8 et représente le prix par contrat en units du settlementAsset (token units)
///         (cohérent avec MarginEngineTrading qui fait cash = quantity * price).
///       - quantity = nb de contrats (contractSize hard-locked à 1e8 côté registry).
interface IMarginEngineTrade {
    /// @notice Scale canonique des prix.
    uint256 constant PRICE_SCALE = 1e8;

    /// @notice Trade atomique appliqué par le MarginEngine.
    /// @dev buyer prend +quantity, seller prend -quantity.
    struct Trade {
        address buyer;
        address seller;
        uint256 optionId;
        uint128 quantity;
        uint128 price;
    }

    /// @notice Point d’entrée unique appelé par le MatchingEngine autorisé.
    function applyTrade(Trade calldata t) external;

    /// @notice Matching engine actuellement autorisé.
    function matchingEngine() external view returns (address);

    /// @notice Owner du MarginEngine.
    function owner() external view returns (address);

    /// @notice Pause globale du moteur.
    function paused() external view returns (bool);
}
