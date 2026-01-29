// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Interface de l'oracle central utilisé par le protocole.
/// @dev Convention: tous les prix sont normalisés en 1e8.
///      getPrice(base, quote) = prix de 1 unité de `base` exprimé en `quote`, en 1e8.
interface IOracle {
    /// @param baseAsset Actif de base (ex: WETH, USDC, etc.)
    /// @param quoteAsset Actif de cotation (ex: USDC)
    /// @return price Prix normalisé en 1e8
    /// @return updatedAt Timestamp UNIX de dernière mise à jour
    function getPrice(address baseAsset, address quoteAsset)
        external
        view
        returns (uint256 price, uint256 updatedAt);
}
