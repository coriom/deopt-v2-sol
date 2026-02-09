// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface minimale en lecture pour le MarginEngine,
///         utilisée par le RiskModule pour lire les positions.
/// @dev Spécification:
///  - getTraderSeries() DOIT retourner uniquement les séries OPEN (quantity != 0),
///    sinon risque DoS (boucles de risk computation non bornées).
///  - Quantity hardening: l'implémentation DOIT garantir que `quantity` ne peut jamais
///    valoir type(int128).min (sinon abs(quantity) overflow côté RiskModule).
///
/// Ajouts (compat / sécurité):
///  - Optionnel: helper `isOpenSeries(trader, optionId)` pour vérif O(1) côté consumers.
///  - Optionnel: helper `getPositionQuantity(trader, optionId)` pour éviter la copie struct.
///  - Eventless: interface only.
interface IMarginEngineState {
    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice Représente la position nette sur une série d'options.
    /// @dev quantity > 0 : net long, quantity < 0 : net short, quantity == 0 : fermé.
    ///      WARNING: quantity MUST NOT be type(int128).min.
    struct Position {
        int128 quantity;
    }

    /*//////////////////////////////////////////////////////////////
                                CORE READS
    //////////////////////////////////////////////////////////////*/

    /// @notice Nombre total de contrats shorts (toutes séries OPEN) pour un trader.
    function totalShortContracts(address trader) external view returns (uint256);

    /// @notice Position sur une série donnée pour un trader.
    /// @dev Doit retourner quantity = 0 si aucune position (ne doit pas revert).
    function positions(address trader, uint256 optionId) external view returns (Position memory);

    /// @notice Liste des séries OPEN (positions non nulles) pour un trader.
    /// @dev DOIT être cohérente avec positions(): pour tout id retourné, positions().quantity != 0.
    ///      WARNING: for any id returned, positions().quantity MUST NOT be type(int128).min.
    function getTraderSeries(address trader) external view returns (uint256[] memory);

    /// @notice Longueur de la liste OPEN (utile pagination).
    function getTraderSeriesLength(address trader) external view returns (uint256);

    /// @notice Slice paginée [start, end) sur la liste OPEN.
    function getTraderSeriesSlice(address trader, uint256 start, uint256 end)
        external
        view
        returns (uint256[] memory slice);

    /*//////////////////////////////////////////////////////////////
                         OPTIONAL VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Adresse du registry des séries (OptionProductRegistry).
    function optionRegistry() external view returns (address);

    /// @notice Adresse du CollateralVault.
    function collateralVault() external view returns (address);

    /// @notice Adresse de l’oracle (OracleRouter / IOracle).
    function oracle() external view returns (address);

    /// @notice Adresse du risk module.
    function riskModule() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                         OPTIONAL QUALITY-OF-LIFE
    //////////////////////////////////////////////////////////////*/

    /// @notice Retourne directement la quantité (évite un struct copy côté consommateurs).
    /// @dev Doit respecter la même règle: jamais int128.min.
    function getPositionQuantity(address trader, uint256 optionId) external view returns (int128);

    /// @notice True si la série est dans la liste OPEN (positions non nulles).
    /// @dev Doit être cohérent avec positions(): si true => quantity != 0.
    function isOpenSeries(address trader, uint256 optionId) external view returns (bool);
}
