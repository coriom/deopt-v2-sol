// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IOracle
/// @notice Interface de l'oracle central utilisé par le protocole.
/// @dev
///  - Convention: tous les prix sont normalisés en 1e8.
///  - getPrice(base, quote) = prix de 1 unité de `base` exprimé en `quote`, en 1e8.
///  - updatedAt = timestamp UNIX de dernière mise à jour (0 si indisponible).
interface IOracle {
    function getPrice(address baseAsset, address quoteAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt);
}
