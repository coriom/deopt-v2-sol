// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IPriceSource
/// @notice Interface générique pour une source de prix (Chainlink, Pyth, mock, etc.)
/// @dev
///  - Retourne un prix normalisé en 1e8 décimales.
///  - `updatedAt` est un timestamp UNIX de la dernière mise à jour.
interface IPriceSource {
    /// @return price Prix en 1e8 (ex: 2500$ => 2500 * 1e8)
    /// @return updatedAt Timestamp de dernière mise à jour du prix
    function getLatestPrice()
        external
        view
        returns (uint256 price, uint256 updatedAt);
}
