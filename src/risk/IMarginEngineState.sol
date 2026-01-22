// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface minimale en lecture pour le MarginEngine,
///         utilisée par le RiskModule pour lire les positions.
/// @dev Spécification: getTraderSeries() DOIT retourner uniquement les séries OPEN (quantity != 0),
///      sinon risque DoS (boucles de risk computation non bornées).
interface IMarginEngineState {
    /// @notice Représente la position nette sur une série d'options.
    /// @dev quantity > 0 : net long, quantity < 0 : net short, quantity == 0 : fermé.
    struct Position {
        int128 quantity;
    }

    /// @notice Nombre total de contrats shorts (toutes séries OPEN) pour un trader.
    function totalShortContracts(address trader) external view returns (uint256);

    /// @notice Position sur une série donnée pour un trader.
    /// @dev Doit retourner quantity = 0 si aucune position (ne doit pas revert).
    function positions(address trader, uint256 optionId)
        external
        view
        returns (Position memory);

    /// @notice Liste des séries OPEN (positions non nulles) pour un trader.
    /// @dev DOIT être cohérente avec positions(): pour tout id retourné, positions().quantity != 0.
    function getTraderSeries(address trader)
        external
        view
        returns (uint256[] memory);

    /// @notice Longueur de la liste OPEN (utile pagination).
    function getTraderSeriesLength(address trader) external view returns (uint256);

    /// @notice Slice paginée [start, end) sur la liste OPEN.
    function getTraderSeriesSlice(address trader, uint256 start, uint256 end)
        external
        view
        returns (uint256[] memory slice);
}
