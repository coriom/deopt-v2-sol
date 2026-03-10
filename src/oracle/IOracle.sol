// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IOracle
/// @notice Interface de l'oracle central utilisé par le protocole.
/// @dev
///  - Convention: tous les prix sont normalisés en 1e8.
///  - getPrice(base, quote) = prix de 1 unité de `base` exprimé en `quote`, en 1e8.
///  - updatedAt = timestamp UNIX de dernière mise à jour.
///  - Le router peut implémenter:
///      * feed direct
///      * feed reverse inversé
///      * fallback primary / secondary
interface IOracle {
    /// @notice Retourne le prix canonique de `baseAsset` exprimé en `quoteAsset`.
    /// @dev Revert si aucun prix utilisable n'est disponible.
    function getPrice(address baseAsset, address quoteAsset) external view returns (uint256 price, uint256 updatedAt);

    /// @notice Version best-effort.
    /// @dev
    ///  - ok=true  => `price` et `updatedAt` sont exploitables
    ///  - ok=false => aucun prix utilisable n'a été trouvé
    ///  - utile pour les consommateurs qui veulent éviter un revert
    function getPriceSafe(address baseAsset, address quoteAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt, bool ok);
}