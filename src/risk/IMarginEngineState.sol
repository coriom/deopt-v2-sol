// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface minimale en lecture pour le MarginEngine,
///         utilisée par le RiskModule pour lire les positions.
interface IMarginEngineState {
    /// @notice Représente la position nette sur une série d'options.
    /// @dev quantity > 0 : net long, quantity < 0 : net short.
    struct Position {
        int128 quantity;
    }

    /// @notice Nombre total de contrats shorts (toutes séries) pour un trader.
    /// @dev Gardé pour compat / debug, le RiskModule s'appuie surtout sur positions() + getTraderSeries().
    function totalShortContracts(address trader) external view returns (uint256);

    /// @notice Position sur une série donnée pour un trader.
    function positions(address trader, uint256 optionId)
        external
        view
        returns (Position memory);

    /// @notice Liste des séries sur lesquelles le trader a (ou a eu) une position.
    /// @dev Le RiskModule filtrera les séries où la quantité est 0.
    function getTraderSeries(address trader)
        external
        view
        returns (uint256[] memory);
}
